import Foundation

/// Shared classification of HTTP status codes used by both the dispatcher and the overflow drain.
public enum ResponseCategory: Sendable {
    case success
    case serverError
    case rateLimited
    case payloadTooLarge
    case fatalConfig
    case clientError

    public static func from(_ statusCode: Int) -> ResponseCategory {
        switch statusCode {
        case 200..<300: return .success
        case 500..<600, 408: return .serverError
        case 429: return .rateLimited
        case 413: return .payloadTooLarge
        case 401, 403, 404: return .fatalConfig
        case 400..<500: return .clientError
        default: return .clientError
        }
    }
}

/// Event dispatcher that batches, posts, and applies retry logic per networkBehavior spec
public actor Dispatcher {
    public typealias FatalConfigHandler = @Sendable (_ status: Int) -> Void
    public typealias FlushCompleteHandler = @Sendable () async -> Void
    public struct Config: Sendable {
        public let endpointPath: String
        public let timeoutMs: Int
        public let autoFlushThreshold: Int
        public let initialMaxBatchSize: Int
        public let baseRetryDelayMs: Int
        public let maxRetryDelayMs: Int
        public init(endpointPath: String = "/v1/batch",
                    timeoutMs: Int = 8000,
                    autoFlushThreshold: Int = 20,
                    initialMaxBatchSize: Int = 100,
                    baseRetryDelayMs: Int = 1000,
                    maxRetryDelayMs: Int = 8000) {
            self.endpointPath = endpointPath
            self.timeoutMs = timeoutMs
            self.autoFlushThreshold = autoFlushThreshold
            self.initialMaxBatchSize = max(1, initialMaxBatchSize)
            self.baseRetryDelayMs = max(0, baseRetryDelayMs)
            self.maxRetryDelayMs = max(baseRetryDelayMs, maxRetryDelayMs)
        }
    }

    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()
    private static let jsonEncoder = JSONEncoder()

    private let options: InitOptions
    private let queue: PersistentEventQueue
    private let http: Networking
    private let breaker: CircuitBreaker
    private var maxBatchSize: Int
    private var onFatalConfigError: FatalConfigHandler?
    private var onFlushComplete: FlushCompleteHandler?

    private var flushTimerTask: Task<Void, Never>? = nil
    private var retryTimerTask: Task<Void, Never>? = nil
    private var isFlushing = false
    private let config: Config
    private var tracingEnabled = false
    private var consecutiveRetries: Int = 0
    private var isOffline = false
    private var isDraining = false

    /// Primary init accepting a PersistentEventQueue (used by AnalyticsClient).
    public init(
        options: InitOptions,
        http: Networking = NetworkClient(),
        breaker: CircuitBreaker = CircuitBreaker(),
        persistentQueue: PersistentEventQueue,
        config: Config = Config(),
        onFatalConfigError: FatalConfigHandler? = nil
    ) {
        self.options = options
        self.http = http
        self.breaker = breaker
        self.queue = persistentQueue
        self.maxBatchSize = config.initialMaxBatchSize
        self.config = config
        self.onFatalConfigError = onFatalConfigError
    }

    /// Backward-compatible init (tests, simple usage). Creates an internal PersistentEventQueue.
    public init(
        options: InitOptions,
        http: Networking = NetworkClient(),
        breaker: CircuitBreaker = CircuitBreaker(),
        queueCapacity: Int = 2000,
        config: Config = Config(),
        onFatalConfigError: FatalConfigHandler? = nil
    ) {
        self.options = options
        self.http = http
        self.breaker = breaker
        self.queue = PersistentEventQueue(
            diskStore: DiskStorage(baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("metarouter-noop-\(UUID().uuidString)")),
            maxEventCount: queueCapacity
        )
        self.maxBatchSize = config.initialMaxBatchSize
        self.config = config
        self.onFatalConfigError = onFatalConfigError
    }

    public func setFatalConfigHandler(_ handler: FatalConfigHandler?) {
        self.onFatalConfigError = handler
    }

    public func setFlushCompleteHandler(_ handler: FlushCompleteHandler?) {
        self.onFlushComplete = handler
    }

    public func setTracing(_ enabled: Bool) {
        self.tracingEnabled = enabled
        Logger.log("Tracing \(enabled ? "enabled" : "disabled")")
    }

    /// Update offline state. Idempotent — only acts on actual transitions.
    /// When going offline, stops retrying (no point while offline).
    /// When coming online, resets circuit breaker, flushes memory queue,
    /// and starts draining overflow from disk to network in the background.
    public func setOffline(_ offline: Bool) async {
        if !isOffline && offline {
            // Going offline: stop retrying (no point while offline)
            isOffline = true
            retryTimerTask?.cancel()
            retryTimerTask = nil
            Logger.log("Dispatcher paused — device is offline")
        } else if isOffline && !offline {
            // Coming back online: reset stale backoff and flush immediately
            isOffline = false
            breaker.reset()
            consecutiveRetries = 0
            Logger.log("Dispatcher resumed — device is online, triggering flush")
            // Two independent flush paths:
            await flush() // (1) memory queue → network
            // (2) disk store → network directly (background)
            Task { [weak self] in
                await self?.drainDiskStoreToNetwork()
            }
        }
    }

    public func getIsOffline() -> Bool {
        return isOffline
    }

    public func offer(_ event: EnrichedEventPayload) async {
        Logger.log(
            "Enqueuing event {\"messageId\": \"\(event.messageId)\", \"type\": \"\(event.type)\"}",
            writeKey: options.writeKey,
            host: options.ingestionHost.absoluteString)

        let queueLength = await queue.enqueue(event)
        Logger.log(
            "Event enqueued, queue length: \(queueLength)",
            writeKey: options.writeKey,
            host: options.ingestionHost.absoluteString)

        // Check disk flush threshold
        if await queue.needsFlushToDisk {
            let flushed = await queue.flushMemoryToDisk()
            if flushed {
                Logger.log("Auto disk flush triggered (threshold reached)")
            }
        }

        if queueLength >= config.autoFlushThreshold {
            await flush()
        }
    }

    /// Flush current memory state to disk (append + clear memory).
    public func flushToDisk() async {
        await queue.flushMemoryToDisk()
    }

    /// Cheap boot-time check — does the disk store have anything to drain?
    /// Does not parse the file.
    @discardableResult
    public func checkForPersistedEvents() async -> Bool {
        await queue.checkForPersistedEvents()
    }

    public func flush() async {
        guard !isFlushing else { return }
        guard await queue.count > 0 else { return }
        isFlushing = true
        defer { isFlushing = false }
        await processUntilEmpty()
        if await queue.count == 0 {
            Logger.log(
                "Flush completed successfully",
                writeKey: options.writeKey,
                host: options.ingestionHost.absoluteString)
            // Fire onFlushComplete only when online — triggers overflow drain
            if !isOffline, let handler = onFlushComplete {
                await handler()
            }
        }
    }

    public func startFlushLoop(intervalSeconds: Int = 10) {
        // If already running, don't restart — avoids cancelling in-flight requests
        if flushTimerTask != nil { return }

        let interval = max(1, intervalSeconds)

        flushTimerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                await self.flush()
            }
        }
    }

    public func stopFlushLoop() {
        flushTimerTask?.cancel()
        flushTimerTask = nil
    }

    public func cancelScheduledRetry() {
        retryTimerTask?.cancel()
        retryTimerTask = nil
    }

    public func clearAll() async {
        await queue.clear()
    }
    
    
    public func getQueueLength() async -> Int {
        return await queue.count
    }
    
    public func getCircuitState() async -> CircuitState {
        return breaker.getState()
    }
    
    public func getCircuitRemainingMs() async -> Int {
        return breaker.getRemainingCooldownMs()
    }
    
    public func isFlushInProgress() async -> Bool {
        return isFlushing
    }

    /// Send a batch of events directly to the network, bypassing the memory queue.
    /// Used by overflow drain to flush disk events without loading into memory.
    /// Returns the NetworkResponse on success/HTTP error, nil on network/encoding failure.
    public func sendBatchDirect(_ events: [EnrichedEventPayload]) async -> NetworkResponse? {
        guard !events.isEmpty else { return NetworkResponse(statusCode: 200, headers: [:], body: Data()) }

        var batch = events
        let sentAt = Self.isoFormatter.string(from: Date())
        for i in 0..<batch.count {
            batch[i].sentAt = sentAt
        }

        let payload = ["batch": batch]
        let body: Data
        do {
            body = try Self.jsonEncoder.encode(payload)
        } catch {
            Logger.error("Failed to encode overflow batch: \(error)")
            return nil
        }

        let url = options.ingestionHost.appendingPathComponent(config.endpointPath)

        do {
            let resp = try await http.postJSON(url: url, body: body, timeoutMs: config.timeoutMs, additionalHeaders: nil)
            if (200..<300).contains(resp.statusCode) {
                breaker.onSuccess()
            } else {
                Logger.warn("Overflow batch send failed with status \(resp.statusCode)")
            }
            return resp
        } catch {
            Logger.warn("Overflow batch send failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Drain events from the disk store directly to network in batches.
    /// Called on offline→online transition, after successful flush, or at startup.
    /// Does NOT load events into the memory queue.
    ///
    /// Algorithm (O(n) — one read, one delete, iterate in memory):
    /// 1. Acquire the disk lock so mid-drain memory flushes don't clobber our writes.
    /// 2. Read the entire disk file once and delete it.
    /// 3. Iterate batches in memory; checkpoint remaining every 10 successful batches.
    /// 4. On failure / server error / offline-transition, write remainder back to disk.
    ///
    /// Response handling per category:
    /// - SUCCESS: drop batch, restore batch size, continue
    /// - PAYLOAD_TOO_LARGE (413): halve batch size, retry. Drop at batchSize=1
    /// - SERVER_ERROR / RATE_LIMITED (5xx/408/429): persist remainder, stop
    /// - FATAL_CONFIG (401/403/404): delete disk store entirely, fire fatal handler
    /// - CLIENT_ERROR (other 4xx): drop batch, continue
    /// - Network failure (nil): persist remainder, stop
    public func drainDiskStoreToNetwork() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        guard await queue.hasDiskData else { return }
        guard !isOffline else {
            Logger.log("Drain skipped — device is offline")
            return
        }

        await queue.acquireDiskLock()
        defer { Task { await queue.releaseDiskLock() } }

        let all = await queue.readAllFromDiskAndDelete()
        guard !all.isEmpty else { return }

        var remaining = all
        var drainBatchSize = config.initialMaxBatchSize
        var batchesSinceCheckpoint = 0
        let checkpointEvery = 10
        Logger.log("Disk store drain started — \(remaining.count) event(s)")

        while !remaining.isEmpty && !isOffline {
            let take = min(drainBatchSize, remaining.count)
            let batch = Array(remaining.prefix(take))

            guard let resp = await sendBatchDirect(batch) else {
                Logger.warn("Disk drain stopped (network failure) — persisting \(remaining.count) event(s) back to disk")
                await queue.writeDiskStore(remaining)
                return
            }

            switch ResponseCategory.from(resp.statusCode) {
            case .success:
                remaining.removeFirst(take)
                if drainBatchSize < config.initialMaxBatchSize {
                    drainBatchSize = min(drainBatchSize * 2, config.initialMaxBatchSize)
                }
                batchesSinceCheckpoint += 1
                if batchesSinceCheckpoint >= checkpointEvery && !remaining.isEmpty {
                    await queue.writeDiskStore(remaining)
                    batchesSinceCheckpoint = 0
                    Logger.log("Disk drain checkpoint — \(remaining.count) event(s) remaining")
                }

            case .payloadTooLarge:
                if drainBatchSize > 1 {
                    drainBatchSize = max(1, drainBatchSize / 2)
                    Logger.warn("Disk drain 413 — halving batch size to \(drainBatchSize)")
                } else {
                    let ids = batch.map { $0.messageId }.joined(separator: ",")
                    Logger.warn("Disk drain dropping oversize event(s) at batchSize=1; messageIds=\(ids)")
                    remaining.removeFirst(take)
                }

            case .serverError, .rateLimited:
                Logger.warn("Disk drain stopped (\(resp.statusCode)) — persisting \(remaining.count) event(s) back to disk")
                await queue.writeDiskStore(remaining)
                return

            case .fatalConfig:
                Logger.error("Disk drain fatal config error (\(resp.statusCode)) — deleting disk store")
                await queue.deleteDiskStore()
                onFatalConfigError?(resp.statusCode)
                return

            case .clientError:
                let ids = batch.map { $0.messageId }.joined(separator: ",")
                Logger.warn("Disk drain dropping bad batch (\(resp.statusCode)); messageIds=\(ids)")
                remaining.removeFirst(take)
            }
        }

        // Persist final state. If remaining is empty, this deletes any stale checkpoint
        // from an earlier iteration. If non-empty, it's the offline-mid-drain remainder.
        await queue.writeDiskStore(remaining)
        if remaining.isEmpty {
            Logger.log("Disk store drain complete")
        } else {
            Logger.log("Disk drain paused (offline mid-drain) — persisted \(remaining.count) event(s)")
        }
    }

    private func processUntilEmpty() async {
        while await queue.count > 0 {
            guard !isOffline else {
                Logger.log("Offline — flushing \(await queue.count) event(s) to disk")
                await queue.flushMemoryToDisk()
                return
            }

            let waitMs = breaker.beforeRequest()
            if waitMs > 0 {
                Logger.warn("Circuit breaker \(breaker.getState()), retrying in \(waitMs)ms (\(await queue.count) event(s) pending)")
                await scheduleRetry(afterMs: waitMs)
                return
            }

            var batch = await queue.drain(max: maxBatchSize)
            guard !batch.isEmpty else { return }
            
            // Add sentAt timestamp to all events in batch
            let sentAt = Self.isoFormatter.string(from: Date())
            for i in 0..<batch.count {
                batch[i].sentAt = sentAt
            }
            
            let payload = ["batch": batch]
            let body: Data
            do {
                body = try Self.jsonEncoder.encode(payload)
            } catch {
                Logger.error("Failed to encode batch of \(batch.count) events: \(error)")
                // Events already drained from queue — nothing to drop or requeue
                continue
            }

            let url = options.ingestionHost.appendingPathComponent(config.endpointPath)

            Logger.log(
                "Making API call to: \(url.absoluteString)",
                writeKey: options.writeKey,
                host: options.ingestionHost.absoluteString)

            // Add Trace header if tracing is enabled
            var headers: [String: String]? = nil
            if tracingEnabled {
                headers = ["Trace": "true"]
            }

            do {
                let resp = try await http.postJSON(url: url, body: body, timeoutMs: config.timeoutMs, additionalHeaders: headers)

                if (200..<300).contains(resp.statusCode) {
                    consecutiveRetries = 0
                    Logger.log(
                        "API call successful",
                        writeKey: options.writeKey,
                        host: options.ingestionHost.absoluteString)
                }

                let shouldStop = await handleResponse(resp, originalBatch: batch)
                if shouldStop { return }
            } catch {
                consecutiveRetries += 1
                breaker.onFailure()
                await queue.requeueToFront(batch)
                let retryDelay = max(retryFloorMs(), breaker.beforeRequest())
                Logger.warn("API call failed: \(error.localizedDescription), \(await queue.count) event(s) pending retry in \(retryDelay)ms (circuit: \(breaker.getState()), retry #\(consecutiveRetries))")
                await scheduleRetry(afterMs: retryDelay)
                return
            }
        }
    }

    /// Returns `true` if processUntilEmpty should stop (retryable failure scheduled a retry).
    private func handleResponse(_ resp: NetworkResponse, originalBatch: [EnrichedEventPayload]) async -> Bool {
        switch resp.statusCode {
        case 200..<300:
            consecutiveRetries = 0
            breaker.onSuccess()
            // Gradually recover batch size after 413-induced reduction
            if maxBatchSize < config.initialMaxBatchSize {
                maxBatchSize = min(maxBatchSize * 2, config.initialMaxBatchSize)
            }
            return false
        case 500..<600, 408:
            consecutiveRetries += 1
            breaker.onFailure()
            await queue.requeueToFront(originalBatch)
            let serverDelay = http.parseRetryAfterMs(from: resp.headers) ?? breaker.beforeRequest()
            let delay = max(retryFloorMs(), serverDelay)
            Logger.warn("Server error \(resp.statusCode), will retry \(originalBatch.count) event(s) in \(delay)ms (circuit: \(breaker.getState()), retry #\(consecutiveRetries))")
            await scheduleRetry(afterMs: max(100, delay))
            return true
        case 429:
            consecutiveRetries += 1
            breaker.onFailure()
            await queue.requeueToFront(originalBatch)
            let headerDelay = http.parseRetryAfterMs(from: resp.headers)
            let cbDelay = breaker.beforeRequest()
            let delay = max(retryFloorMs(), max(1000, max(headerDelay ?? 0, cbDelay)))
            Logger.warn("Rate limited (429), will retry \(originalBatch.count) event(s) in \(delay)ms (circuit: \(breaker.getState()), retry #\(consecutiveRetries))")
            await scheduleRetry(afterMs: delay)
            return true
        case 413:
            breaker.onNonRetryable()
            if maxBatchSize > 1 {
                maxBatchSize = max(1, maxBatchSize / 2)
                await queue.requeueToFront(originalBatch)
                await scheduleRetry(afterMs: 0)
            } else {
                // Drop oversize events at batchSize=1
                let ids = originalBatch.map { $0.messageId }.joined(separator: ",")
                Logger.warn("Dropping oversize event(s) after 413 at batchSize=1; messageIds=\(ids)")
            }
            return false
        case 401, 403, 404:
            // Fatal config error: disable client - responsibility of higher layer
            await queue.clear()
            // No breaker change per spec
            onFatalConfigError?(resp.statusCode)
            return true
        case 400..<500:
            breaker.onNonRetryable()
            // Drop bad payload and continue
            return false
        default:
            // Unknown: treat like non-retryable 4xx
            breaker.onNonRetryable()
            return false
        }
    }

    /// Exponential backoff floor based on consecutive retries, independent of circuit breaker.
    /// Ensures retries are never instant even while circuit is closed.
    private func retryFloorMs() -> Int {
        guard consecutiveRetries > 0 else { return 0 }
        let exponent = min(consecutiveRetries - 1, 10)
        return min(config.maxRetryDelayMs, config.baseRetryDelayMs * Int(pow(2.0, Double(exponent))))
    }

    private func scheduleRetry(afterMs: Int) async {
        if afterMs <= 0 {
            await flush()
            return
        }
        retryTimerTask?.cancel()
        retryTimerTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(afterMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }
}


