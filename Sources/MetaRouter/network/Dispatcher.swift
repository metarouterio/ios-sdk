import Foundation

/// Event dispatcher that batches, posts, and applies retry logic per networkBehavior spec
public actor Dispatcher {
    public typealias FatalConfigHandler = @Sendable (_ status: Int) -> Void
    public struct Config: Sendable {
        public let endpointPath: String
        public let timeoutMs: Int
        public let autoFlushThreshold: Int
        public let initialMaxBatchSize: Int
        public init(endpointPath: String = "/v1/batch",
                    timeoutMs: Int = 8000,
                    autoFlushThreshold: Int = 20,
                    initialMaxBatchSize: Int = 100) {
            self.endpointPath = endpointPath
            self.timeoutMs = timeoutMs
            self.autoFlushThreshold = autoFlushThreshold
            self.initialMaxBatchSize = max(1, initialMaxBatchSize)
        }
    }

    private let options: InitOptions
    private let queue: PersistentEventQueue
    private let http: Networking
    private let breaker: CircuitBreaker
    private var maxBatchSize: Int
    private var onFatalConfigError: FatalConfigHandler?

    private var flushTimerTask: Task<Void, Never>? = nil
    private var retryTimerTask: Task<Void, Never>? = nil
    private var isFlushing = false
    private let config: Config
    private var tracingEnabled = false

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
            diskStorage: DiskStorage(baseDirectory: FileManager.default.temporaryDirectory
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

    public func setTracing(_ enabled: Bool) {
        self.tracingEnabled = enabled
        Logger.log("Tracing \(enabled ? "enabled" : "disabled")")
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
            do {
                try await queue.flushToDisk()
                Logger.log("Auto disk flush triggered (threshold reached)")
            } catch {
                Logger.warn("Auto disk flush failed: \(error)")
            }
        }

        if queueLength >= config.autoFlushThreshold {
            await flush()
        }
    }

    /// Flush current memory state to disk.
    public func flushToDisk() async throws {
        try await queue.flushToDisk()
    }

    /// Rehydrate events from disk. Returns the number of events loaded.
    @discardableResult
    public func rehydrate() async -> Int {
        await queue.rehydrate()
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
        }
    }

    public func startFlushLoop(intervalSeconds: Int = 10) {
        // If already running, don't restart — avoids cancelling in-flight requests
        if flushTimerTask != nil { return }

        let interval = max(1, intervalSeconds)
        
        Logger.log(
            "Flush loop started with interval: \(interval) seconds",
            writeKey: options.writeKey,
            host: options.ingestionHost.absoluteString)
        
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


    private func processUntilEmpty() async {
        while await queue.count > 0 {
            let waitMs = breaker.beforeRequest()
            if waitMs > 0 {
                await scheduleRetry(afterMs: waitMs)
                return
            }

            var batch = await queue.drain(max: maxBatchSize)
            guard !batch.isEmpty else { return }
            
            // Add sentAt timestamp to all events in batch
            let sentAt = ISO8601DateFormatter().string(from: Date())
            for i in 0..<batch.count {
                batch[i].sentAt = sentAt
            }
            
            let payload = ["batch": batch]
            let body: Data
            do {
                body = try JSONEncoder().encode(payload)
            } catch {
                Logger.error("Failed to encode batch of \(batch.count) events: \(error)")
                await handleNonRetryableDrop(count: batch.count)
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
                    Logger.log(
                        "API call successful",
                        writeKey: options.writeKey,
                        host: options.ingestionHost.absoluteString)
                }
                
                await handleResponse(resp, originalBatch: batch)
            } catch {
                breaker.onFailure()
                await queue.requeueToFront(batch)
                Logger.warn("API call failed: \(error.localizedDescription), \(await queue.count) event(s) pending retry")
                await scheduleRetry(afterMs: breaker.beforeRequest())
                return
            }
        }
    }

    private func handleResponse(_ resp: NetworkResponse, originalBatch: [EnrichedEventPayload]) async {
        switch resp.statusCode {
        case 200..<300:
            breaker.onSuccess()
            // Gradually recover batch size after 413-induced reduction
            if maxBatchSize < config.initialMaxBatchSize {
                maxBatchSize = min(maxBatchSize * 2, config.initialMaxBatchSize)
            }
            return
        case 500..<600, 408:
            breaker.onFailure()
            await queue.requeueToFront(originalBatch)
            let delay = http.parseRetryAfterMs(from: resp.headers) ?? breaker.beforeRequest()
            Logger.warn("Server error \(resp.statusCode), will retry \(originalBatch.count) event(s) in \(delay)ms")
            await scheduleRetry(afterMs: max(100, delay))
        case 429:
            breaker.onFailure()
            await queue.requeueToFront(originalBatch)
            let headerDelay = http.parseRetryAfterMs(from: resp.headers)
            let cbDelay = breaker.beforeRequest()
            let delay = max(1000, max(headerDelay ?? 0, cbDelay))
            Logger.warn("Rate limited (429), will retry \(originalBatch.count) event(s) in \(delay)ms")
            await scheduleRetry(afterMs: delay)
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
        case 401, 403, 404:
            // Fatal config error: disable client - responsibility of higher layer
            await queue.clear()
            // No breaker change per spec
            onFatalConfigError?(resp.statusCode)
        case 400..<500:
            breaker.onNonRetryable()
            // Drop bad payload and continue
            // Nothing to requeue
        default:
            // Unknown: treat like non-retryable 4xx
            breaker.onNonRetryable()
        }
    }

    private func handleNonRetryableDrop(count: Int) async {
        await queue.dropFront(count)
    }

    private func scheduleRetry(afterMs: Int) async {
        if afterMs <= 0 {
            await flush()
            return
        }
        retryTimerTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(afterMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }
}


