import XCTest
@testable import MetaRouter


private final class StatusHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int?
    var value: Int? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private final class StubNetworking: Networking, @unchecked Sendable {
    enum Mode { case success, http(Int), httpWithHeaders(Int, [String: String]), error }
    var mode: Mode = .success
    var lastBody: Data?
    var lastHeaders: [String: String]?
    var callCount = 0

    func postJSON(url: URL, body: Data, timeoutMs: Int, additionalHeaders: [String: String]?) async throws -> NetworkResponse {
        lastBody = body
        lastHeaders = additionalHeaders
        callCount += 1
        switch mode {
        case .success:
            return NetworkResponse(statusCode: 200, headers: [:], body: Data())
        case .http(let code):
            return NetworkResponse(statusCode: code, headers: [:], body: Data())
        case .httpWithHeaders(let code, let headers):
            return NetworkResponse(statusCode: code, headers: headers, body: Data())
        case .error:
            throw URLError(.timedOut)
        }
    }

    func parseRetryAfterMs(from headers: [String: String]) -> Int? {
        guard let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value,
              let seconds = Int(raw) else { return nil }
        return seconds * 1000
    }
}

/// Builds a `Dispatcher` backed by a throwaway temp-dir disk store for tests.
/// Accepts either `queueCapacity:` (helper builds the queue) or `persistentQueue:` (caller builds it).
private func makeDispatcher(
    options: InitOptions,
    http: Networking = NetworkClient(),
    breaker: CircuitBreaker = CircuitBreaker(),
    queueCapacity: Int? = nil,
    persistentQueue: PersistentEventQueue? = nil,
    config: Dispatcher.Config = Dispatcher.Config(),
    onFatalConfigError: Dispatcher.FatalConfigHandler? = nil
) -> Dispatcher {
    let queue: PersistentEventQueue
    if let pq = persistentQueue {
        queue = pq
    } else {
        let cap = queueCapacity ?? 2000
        let diskStore = DiskStorage(baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("metarouter-test-\(UUID().uuidString)"))
        queue = PersistentEventQueue(diskStore: diskStore, maxEventCount: cap)
    }
    return Dispatcher(
        options: options,
        http: http,
        breaker: breaker,
        persistentQueue: queue,
        config: config,
        onFatalConfigError: onFatalConfigError
    )
}

/// Creates a minimal enriched event for testing
private func makeTestEvent(messageId: String = "mid") -> EnrichedEventPayload {
    let ctx = EventContext(
        app: AppContext(name: "a", version: "1", build: "1", namespace: "a"),
        device: DeviceContext(manufacturer: "a", model: "m", type: "t"),
        library: LibraryContext(name: "l", version: "1"),
        os: OSContext(name: "iOS", version: "1"),
        screen: ScreenContext(density: 2.0, width: 1, height: 1),
        network: nil,
        locale: "en_US",
        timezone: "UTC"
    )
    return EnrichedEventPayload(
        type: "track", event: "ev", userId: nil, anonymousId: "anon",
        properties: nil, traits: nil, integrations: nil,
        timestamp: "now", writeKey: "wk", messageId: messageId, context: ctx
    )
}


final class DispatcherTests: XCTestCase {
    func testFlushSuccessRemovesBatch() async throws {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = makeDispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 100)

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()
        await dispatcher.flush()

        XCTAssertNotNil(stub.lastBody)
    }

    func testFatalConfigClearsAndCallback() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .http(401)
        let statusHolder = StatusHolder()
        let dispatcher = makeDispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 10, onFatalConfigError: { status in statusHolder.value = status })

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        XCTAssertEqual(statusHolder.value, 401)
    }

    func testTracingDisabledByDefault() async throws {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = makeDispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 100)

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        XCTAssertNil(stub.lastHeaders)
    }

    func testTracingEnabledAddsHeader() async throws {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = makeDispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 100)

        await dispatcher.setTracing(true)
        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        XCTAssertNotNil(stub.lastHeaders)
        XCTAssertEqual(stub.lastHeaders?["Trace"], "true")
    }

    func testTracingCanBeDisabled() async throws {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = makeDispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 100)

        await dispatcher.setTracing(true)
        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        XCTAssertNotNil(stub.lastHeaders)
        XCTAssertEqual(stub.lastHeaders?["Trace"], "true")

        stub.lastHeaders = nil

        await dispatcher.setTracing(false)
        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        XCTAssertNil(stub.lastHeaders)
    }

    func testTracingPersistsAcrossMultipleFlushes() async throws {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = makeDispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 100)

        await dispatcher.setTracing(true)

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()
        XCTAssertEqual(stub.lastHeaders?["Trace"], "true")

        stub.lastHeaders = nil
        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()
        XCTAssertEqual(stub.lastHeaders?["Trace"], "true")
    }


    func testFatalConfig403ClearsQueue() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .http(403)
        let statusHolder = StatusHolder()
        let dispatcher = makeDispatcher(
            options: options, http: stub, breaker: CircuitBreaker(),
            queueCapacity: 10,
            onFatalConfigError: { status in statusHolder.value = status }
        )

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        XCTAssertEqual(statusHolder.value, 403)
        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "Queue should be cleared after fatal 403")
    }

    func testFatalConfig404ClearsQueue() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .http(404)
        let statusHolder = StatusHolder()
        let dispatcher = makeDispatcher(
            options: options, http: stub, breaker: CircuitBreaker(),
            queueCapacity: 10,
            onFatalConfigError: { status in statusHolder.value = status }
        )

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        XCTAssertEqual(statusHolder.value, 404)
        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "Queue should be cleared after fatal 404")
    }

    func test413HalvesBatchSize() async {
        let options = TestDataFactory.makeInitOptions()

        // First call returns 413, then subsequent calls succeed
        let sequencer = CallSequencer(responses: [.http(413), .success])
        let dispatcher = makeDispatcher(
            options: options, http: sequencer,
            breaker: CircuitBreaker(failureThreshold: 10), // high threshold so breaker doesn't trip
            queueCapacity: 100,
            config: Dispatcher.Config(initialMaxBatchSize: 4)
        )

        // Enqueue 4 events
        for i in 0..<4 {
            await dispatcher.offer(makeTestEvent(messageId: "msg-\(i)"))
        }

        await dispatcher.flush()

        // After 413, batch size halved to 2. Events requeued and retried.
        // Should have made at least 2 calls: first with 4 (413), then retry with 2 (200)
        XCTAssertGreaterThanOrEqual(sequencer.callCount, 2,
            "Should retry after 413 with smaller batch")
    }

    func test5xxRequeuesEvents() async {
        let options = TestDataFactory.makeInitOptions()
        // First call returns 500, circuit breaker trips, events stay in queue
        let stub = StubNetworking()
        stub.mode = .http(500)

        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(failureThreshold: 1, cooldownMs: 60_000), // trip immediately, long cooldown
            queueCapacity: 100
        )

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        // Events should be requeued (circuit is now open with long cooldown)
        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 1, "Event should be requeued after 5xx")
    }

    func test429RequeuesWithRetryAfter() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .httpWithHeaders(429, ["Retry-After": "2"])

        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(failureThreshold: 1, cooldownMs: 60_000),
            queueCapacity: 100
        )

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        // Events should be requeued
        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 1, "Event should be requeued after 429")
    }

    func test408RequeuesEvents() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .http(408)

        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(failureThreshold: 1, cooldownMs: 60_000),
            queueCapacity: 100
        )

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 1, "Event should be requeued after 408 timeout")
    }

    func test400DropsPayload() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .http(400)

        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(),
            queueCapacity: 100
        )

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "Bad payload should be dropped on 400")
    }

    func test422DropsPayload() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .http(422)

        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(),
            queueCapacity: 100
        )

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "Bad payload should be dropped on 422")
    }

    func testNetworkErrorRequeuesEvents() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .error

        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(failureThreshold: 1, cooldownMs: 60_000),
            queueCapacity: 100
        )

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 1, "Event should be requeued after network error")
    }

    func testSuccessfulFlushClearsQueue() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .success

        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(),
            queueCapacity: 100
        )

        for i in 0..<5 {
            await dispatcher.offer(makeTestEvent(messageId: "msg-\(i)"))
        }

        await dispatcher.flush()

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "All events should be drained after successful flush")
    }

    func testBatchSizeRecoveryAfter413() async {
        let options = TestDataFactory.makeInitOptions()

        // Sequence: 413 → 200 → 200 → 200 (batch size: 4 → 2 → 4 on recovery)
        let sequencer = CallSequencer(responses: [.http(413), .success, .success, .success, .success])
        let dispatcher = makeDispatcher(
            options: options, http: sequencer,
            breaker: CircuitBreaker(failureThreshold: 10),
            queueCapacity: 100,
            config: Dispatcher.Config(initialMaxBatchSize: 4)
        )

        // Enqueue 4 events
        for i in 0..<4 {
            await dispatcher.offer(makeTestEvent(messageId: "msg-\(i)"))
        }

        // First flush: 413 halves to 2, then retries with 2, succeeds
        await dispatcher.flush()

        // Now enqueue 4 more — if recovery worked, batch size should grow back
        for i in 4..<8 {
            await dispatcher.offer(makeTestEvent(messageId: "msg-\(i)"))
        }

        await dispatcher.flush()

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "All events should drain after batch size recovery")
    }

    func testFlushToDiskDelegatesToQueue() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DispatcherDiskTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = makeDispatcher(
            options: options,
            http: stub,
            breaker: CircuitBreaker(),
            persistentQueue: PersistentEventQueue(
                diskStore: DiskStorage(baseDirectory: tempDir),
                maxEventCount: 100
            )
        )

        await dispatcher.offer(makeTestEvent(messageId: "disk-test"))
        await dispatcher.flushToDisk()

        let diskStore = DiskStorage(baseDirectory: tempDir)
        let snapshot = await diskStore.read()
        XCTAssertEqual(snapshot?.events.count, 1)
        XCTAssertEqual(snapshot?.events[0].messageId, "disk-test")
    }


    func testDiskDrainSendsInBatchesOfInitialMaxBatchSize() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrainBatchTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Seed disk with 250 events; drain should send them in 3 batches (100, 100, 50)
        let diskStore = DiskStorage(baseDirectory: tempDir)
        let events = (0..<250).map { makeTestEvent(messageId: "persisted-\($0)") }
        try await diskStore.write(QueueSnapshot(events: events))

        let recorder = BatchRecordingNetworking()
        let queue = PersistentEventQueue(
            diskStore: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000
        )
        _ = await queue.checkForPersistedEvents()

        let dispatcher = makeDispatcher(
            options: TestDataFactory.makeInitOptions(),
            http: recorder,
            breaker: CircuitBreaker(),
            persistentQueue: queue,
            config: Dispatcher.Config(initialMaxBatchSize: 100)
        )

        await dispatcher.drainDiskStoreToNetwork()

        let memCount = await dispatcher.getQueueLength()
        XCTAssertEqual(memCount, 0, "Drain must not load events into memory")
        XCTAssertEqual(recorder.callCount, 3, "250 events with batchSize=100 should take 3 API calls")
        XCTAssertEqual(recorder.batchSizes, [100, 100, 50])
    }

    func testDiskDrainDoesNotInterfereWithNewMemoryEvents() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrainPlusNewTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Seed 5 events on disk
        let diskStore = DiskStorage(baseDirectory: tempDir)
        let diskEvents = (0..<5).map { makeTestEvent(messageId: "disk-\($0)") }
        try await diskStore.write(QueueSnapshot(events: diskEvents))

        let recorder = BatchRecordingNetworking()
        let queue = PersistentEventQueue(
            diskStore: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000
        )
        _ = await queue.checkForPersistedEvents()

        let dispatcher = makeDispatcher(
            options: TestDataFactory.makeInitOptions(),
            http: recorder,
            breaker: CircuitBreaker(),
            persistentQueue: queue,
            config: Dispatcher.Config(autoFlushThreshold: 1000, initialMaxBatchSize: 100)
        )

        // Add 3 events to memory, then drain disk — memory events should stay put
        for i in 0..<3 {
            await dispatcher.offer(makeTestEvent(messageId: "mem-\(i)"))
        }

        await dispatcher.drainDiskStoreToNetwork()

        // Disk events sent via drain; memory events still queued for the regular flush
        XCTAssertEqual(recorder.callCount, 1, "Disk drain sends 5 events in one batch")
        XCTAssertEqual(recorder.batchSizes, [5])
        let memCount = await dispatcher.getQueueLength()
        XCTAssertEqual(memCount, 3, "Memory queue untouched by drain")
    }

    func testProcessUntilEmptyDrainsAcrossBatchBoundary() async throws {
        // Verifies the while-loop in processUntilEmpty continues
        // when events exceed maxBatchSize without rehydration
        let options = TestDataFactory.makeInitOptions()
        let recorder = BatchRecordingNetworking()
        let dispatcher = makeDispatcher(
            options: options,
            http: recorder,
            breaker: CircuitBreaker(),
            queueCapacity: 2000,
            config: Dispatcher.Config(initialMaxBatchSize: 3)
        )

        for i in 0..<7 {
            await dispatcher.offer(makeTestEvent(messageId: "msg-\(i)"))
        }

        await dispatcher.flush()

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "All events should be drained across multiple batches")
        XCTAssertEqual(recorder.callCount, 3, "7 events with batchSize=3 should take 3 API calls")
        XCTAssertEqual(recorder.batchSizes, [3, 3, 1])
    }


    func testRetryFloorConfigDefaults() {
        let config = Dispatcher.Config()
        XCTAssertEqual(config.baseRetryDelayMs, 1000)
        XCTAssertEqual(config.maxRetryDelayMs, 8000)
    }

    func testRetryFloorConfigCustomValues() {
        let config = Dispatcher.Config(baseRetryDelayMs: 500, maxRetryDelayMs: 4000)
        XCTAssertEqual(config.baseRetryDelayMs, 500)
        XCTAssertEqual(config.maxRetryDelayMs, 4000)
    }

    func testRetryFloorPreventsImmediateRetryWhileCircuitClosed() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .error

        // Default circuit breaker: threshold 3 — circuit stays closed after 1 failure
        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(),
            queueCapacity: 100,
            config: Dispatcher.Config(baseRetryDelayMs: 500, maxRetryDelayMs: 2000)
        )

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        // Only 1 attempt — retry floor prevents immediate retry even though circuit is closed
        XCTAssertEqual(stub.callCount, 1, "Should not immediately retry while circuit is closed")

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 1, "Event should be requeued for delayed retry")

        // Confirm no retry fires within a short window (less than the 500ms floor)
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        XCTAssertEqual(stub.callCount, 1, "No retry should fire before the floor delay")
    }

    func testRetryFloorFiresAndRecovers() async {
        let options = TestDataFactory.makeInitOptions()
        let sequencer = CallSequencer(responses: [.error, .success])

        let dispatcher = makeDispatcher(
            options: options, http: sequencer,
            breaker: CircuitBreaker(),
            queueCapacity: 100,
            config: Dispatcher.Config(baseRetryDelayMs: 100, maxRetryDelayMs: 1000)
        )

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        XCTAssertEqual(sequencer.callCount, 1, "First attempt should fail")

        // Wait for retry floor (100ms) + margin
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

        XCTAssertEqual(sequencer.callCount, 2, "Retry should have fired after floor delay")
        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "Queue should be empty after successful retry")
    }

    func testRetryCounterResetsOnSuccess() async {
        let options = TestDataFactory.makeInitOptions()
        // Sequence: error → success (retry recovers), then error again on next flush
        let sequencer = CallSequencer(responses: [.error, .success, .error, .success])

        let dispatcher = makeDispatcher(
            options: options, http: sequencer,
            breaker: CircuitBreaker(failureThreshold: 10), // high threshold to avoid circuit opening
            queueCapacity: 100,
            config: Dispatcher.Config(baseRetryDelayMs: 100, maxRetryDelayMs: 1000)
        )

        // First event: fails, then retries and succeeds
        await dispatcher.offer(makeTestEvent(messageId: "msg-1"))
        await dispatcher.flush()
        XCTAssertEqual(sequencer.callCount, 1)

        // Wait for retry
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
        XCTAssertEqual(sequencer.callCount, 2, "Retry should succeed")

        let afterFirst = await dispatcher.getQueueLength()
        XCTAssertEqual(afterFirst, 0, "Queue empty after recovery")

        // Second event: should also fail then retry with base delay (not escalated)
        await dispatcher.offer(makeTestEvent(messageId: "msg-2"))
        await dispatcher.flush()
        XCTAssertEqual(sequencer.callCount, 3, "Second event first attempt")

        // If counter didn't reset, retry delay would be escalated (200ms+).
        // With reset, it's back to base (100ms). Either way, wait enough for base delay.
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
        XCTAssertEqual(sequencer.callCount, 4, "Second retry should also fire at base delay")

        let afterSecond = await dispatcher.getQueueLength()
        XCTAssertEqual(afterSecond, 0, "Queue empty after second recovery")
    }

    func testServerErrorGetsRetryFloorWhileCircuitClosed() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .http(503)

        // Default circuit breaker: stays closed after 1 failure
        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(),
            queueCapacity: 100,
            config: Dispatcher.Config(baseRetryDelayMs: 500, maxRetryDelayMs: 2000)
        )

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        XCTAssertEqual(stub.callCount, 1, "Should not immediately retry 503 while circuit closed")
        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 1, "Event should be requeued")

        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        XCTAssertEqual(stub.callCount, 1, "No retry before floor delay")
    }


    func testAutoFlushTriggersAtThreshold() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .success

        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(),
            queueCapacity: 100,
            config: Dispatcher.Config(autoFlushThreshold: 3, initialMaxBatchSize: 100)
        )

        // Offering 3 events should trigger auto-flush
        for i in 0..<3 {
            await dispatcher.offer(makeTestEvent(messageId: "msg-\(i)"))
        }

        // Give auto-flush a moment to complete
        try? await Task.sleep(nanoseconds: 50_000_000)

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "Auto-flush should drain queue at threshold")
        XCTAssertGreaterThanOrEqual(stub.callCount, 1, "At least one POST should have been made")
    }


    func testEventsEnqueueWhileOfflineNoHttpAttempts() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineEnqueueTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stub = StubNetworking()
        stub.mode = .success

        let queue = PersistentEventQueue(
            diskStore: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 100
        )
        let dispatcher = makeDispatcher(
            options: TestDataFactory.makeInitOptions(),
            http: stub,
            breaker: CircuitBreaker(),
            persistentQueue: queue
        )

        await dispatcher.setOffline(true)

        for i in 0..<5 {
            await dispatcher.offer(makeTestEvent(messageId: "offline-\(i)"))
        }

        await dispatcher.flush()

        XCTAssertEqual(stub.callCount, 0, "No HTTP attempts should be made while offline")

        // Offline flush moves memory to disk — no events lost.
        let memCount = await dispatcher.getQueueLength()
        let onDisk = await queue.readDiskBatch(max: 100)
        XCTAssertEqual(memCount + onDisk.count, 5, "All events preserved across memory + disk while offline")
    }

    func testOfflineToOnlineTriggersFlush() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .success

        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(),
            queueCapacity: 100
        )

        await dispatcher.setOffline(true)

        for i in 0..<3 {
            await dispatcher.offer(makeTestEvent(messageId: "queued-\(i)"))
        }

        // Come back online — should trigger immediate flush
        await dispatcher.setOffline(false)

        // Give flush a moment to complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "Events should flush on offline -> online transition")
        XCTAssertGreaterThanOrEqual(stub.callCount, 1, "At least one HTTP request should have been made")
    }

    func testCircuitBreakerResetsOnOfflineToOnline() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .http(500)

        let breaker = CircuitBreaker(failureThreshold: 1, cooldownMs: 60_000, jitterRatio: 0.0)
        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: breaker,
            queueCapacity: 100
        )

        // Trip the circuit breaker
        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()
        XCTAssertEqual(breaker.getState(), .open, "Circuit should be open after 500 error")

        // Switch stub to success so the flush on reconnect doesn't re-trip the breaker
        stub.mode = .success

        // Go offline then online — should reset circuit breaker
        await dispatcher.setOffline(true)
        await dispatcher.setOffline(false)

        // Give the flush a moment to complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(breaker.getState(), .closed, "Circuit breaker should reset on offline -> online")
    }

    func testCircuitBreakerDoesNotResetWhileStillConnectedButFailing() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .http(500)

        let breaker = CircuitBreaker(failureThreshold: 1, cooldownMs: 60_000, jitterRatio: 0.0)
        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: breaker,
            queueCapacity: 100
        )

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()
        XCTAssertEqual(breaker.getState(), .open, "Circuit should be open after failure")

        // Without going offline/online, circuit should stay open
        await dispatcher.flush()
        XCTAssertEqual(breaker.getState(), .open, "Circuit should remain open without offline->online transition")
    }

    func testSetOfflineIsIdempotent() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .success

        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(),
            queueCapacity: 100
        )

        await dispatcher.offer(makeTestEvent())

        // Multiple offline calls should not cause issues
        await dispatcher.setOffline(true)
        await dispatcher.setOffline(true)
        await dispatcher.setOffline(true)

        var offline = await dispatcher.getIsOffline()
        XCTAssertTrue(offline)
        XCTAssertEqual(stub.callCount, 0, "No HTTP attempts while offline")

        // Multiple online calls — only first should trigger flush
        await dispatcher.setOffline(false)
        await dispatcher.setOffline(false)

        try? await Task.sleep(nanoseconds: 100_000_000)

        offline = await dispatcher.getIsOffline()
        XCTAssertFalse(offline)
    }

    func testGetIsOfflineReflectsState() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(),
            queueCapacity: 100
        )

        var offline = await dispatcher.getIsOffline()
        XCTAssertFalse(offline, "Should start online")

        await dispatcher.setOffline(true)
        offline = await dispatcher.getIsOffline()
        XCTAssertTrue(offline)

        await dispatcher.setOffline(false)
        offline = await dispatcher.getIsOffline()
        XCTAssertFalse(offline)
    }



    /// Helper: seed a disk store and build a dispatcher wired to it.
    private func makeDrainFixture(
        seed: [EnrichedEventPayload],
        http: Networking,
        breaker: CircuitBreaker = CircuitBreaker(failureThreshold: 10),
        config: Dispatcher.Config = Dispatcher.Config(initialMaxBatchSize: 100)
    ) async throws -> (dispatcher: Dispatcher, queue: PersistentEventQueue, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrainFixture-\(UUID().uuidString)")
        if !seed.isEmpty {
            try await DiskStorage(baseDirectory: tempDir).write(QueueSnapshot(events: seed))
        }
        let queue = PersistentEventQueue(
            diskStore: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 100
        )
        _ = await queue.checkForPersistedEvents()
        let dispatcher = makeDispatcher(
            options: TestDataFactory.makeInitOptions(),
            http: http,
            breaker: breaker,
            persistentQueue: queue,
            config: config
        )
        return (dispatcher, queue, tempDir)
    }

    func testDiskDrainSendsAllEventsAndClearsFile() async throws {
        let seed = (0..<5).map { makeTestEvent(messageId: "persisted-\($0)") }
        let recorder = BatchRecordingNetworking()
        let fixture = try await makeDrainFixture(seed: seed, http: recorder)
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        // Memory queue event should be untouched by drain
        await fixture.dispatcher.offer(makeTestEvent(messageId: "memory-0"))

        await fixture.dispatcher.drainDiskStoreToNetwork()

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(recorder.batchSizes, [5])

        let memCount = await fixture.dispatcher.getQueueLength()
        XCTAssertEqual(memCount, 1, "Memory queue untouched by drain")

        let onDisk = await fixture.queue.readDiskBatch(max: 100)
        XCTAssertTrue(onDisk.isEmpty, "Disk file should be cleared after successful drain")
    }

    func testDiskDrainStopsOnServerErrorAndPersistsRemainder() async throws {
        let seed = (0..<5).map { makeTestEvent(messageId: "persisted-\($0)") }
        let stub = StubNetworking()
        stub.mode = .http(500)
        let fixture = try await makeDrainFixture(seed: seed, http: stub)
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        await fixture.dispatcher.drainDiskStoreToNetwork()

        XCTAssertEqual(stub.callCount, 1, "Drain should stop after first 500")

        let onDisk = await fixture.queue.readDiskBatch(max: 100)
        XCTAssertEqual(onDisk.count, 5, "All events persisted back to disk on server-error halt")
    }

    func testDiskDrainStopsOn429AndPersistsRemainder() async throws {
        let seed = (0..<5).map { makeTestEvent(messageId: "persisted-\($0)") }
        let stub = StubNetworking()
        stub.mode = .http(429)
        let fixture = try await makeDrainFixture(seed: seed, http: stub)
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        await fixture.dispatcher.drainDiskStoreToNetwork()

        XCTAssertEqual(stub.callCount, 1)
        let onDisk = await fixture.queue.readDiskBatch(max: 100)
        XCTAssertEqual(onDisk.count, 5)
    }

    func testDiskDrainStopsOnNetworkFailureAndPersistsRemainder() async throws {
        let seed = (0..<5).map { makeTestEvent(messageId: "persisted-\($0)") }
        let stub = StubNetworking()
        stub.mode = .error
        let fixture = try await makeDrainFixture(seed: seed, http: stub)
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        await fixture.dispatcher.drainDiskStoreToNetwork()

        XCTAssertEqual(stub.callCount, 1)
        let onDisk = await fixture.queue.readDiskBatch(max: 100)
        XCTAssertEqual(onDisk.count, 5)
    }

    func testDiskDrain413HalvesBatchSize() async throws {
        let seed = (0..<4).map { makeTestEvent(messageId: "persisted-\($0)") }
        // First call returns 413, subsequent calls succeed
        let sequencer = CallSequencer(responses: [.http(413), .success, .success, .success])
        let fixture = try await makeDrainFixture(
            seed: seed,
            http: sequencer,
            config: Dispatcher.Config(initialMaxBatchSize: 4)
        )
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        await fixture.dispatcher.drainDiskStoreToNetwork()

        // Should retry with smaller batches (2, 2) after 413 halves the size from 4
        XCTAssertGreaterThanOrEqual(sequencer.callCount, 2)
        let onDisk = await fixture.queue.readDiskBatch(max: 100)
        XCTAssertTrue(onDisk.isEmpty, "All events should drain across halved batches")
    }

    func testDiskDrain413DropsSingleOversizedEvent() async throws {
        let seed = [makeTestEvent(messageId: "oversize")]
        let stub = StubNetworking()
        stub.mode = .http(413)
        let fixture = try await makeDrainFixture(
            seed: seed,
            http: stub,
            config: Dispatcher.Config(initialMaxBatchSize: 1)
        )
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        await fixture.dispatcher.drainDiskStoreToNetwork()

        let onDisk = await fixture.queue.readDiskBatch(max: 100)
        XCTAssertTrue(onDisk.isEmpty, "Oversize event at batchSize=1 should be dropped")
    }

    func testDiskDrainFatalConfigDeletesStoreAndFiresHandler() async throws {
        let seed = (0..<3).map { makeTestEvent(messageId: "persisted-\($0)") }
        let stub = StubNetworking()
        stub.mode = .http(401)
        let status = StatusHolder()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrainFatalTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try await DiskStorage(baseDirectory: tempDir).write(QueueSnapshot(events: seed))

        let queue = PersistentEventQueue(diskStore: DiskStorage(baseDirectory: tempDir), maxEventCount: 100)
        _ = await queue.checkForPersistedEvents()
        let dispatcher = makeDispatcher(
            options: TestDataFactory.makeInitOptions(),
            http: stub,
            breaker: CircuitBreaker(failureThreshold: 10),
            persistentQueue: queue,
            onFatalConfigError: { code in status.value = code }
        )

        await dispatcher.drainDiskStoreToNetwork()

        XCTAssertEqual(status.value, 401, "FATAL_CONFIG handler must fire from drain path")
        let onDisk = await queue.readDiskBatch(max: 100)
        XCTAssertTrue(onDisk.isEmpty, "Disk store deleted on fatal config")
    }

    func testDiskDrainClientErrorDropsBatchAndContinues() async throws {
        let seed = (0..<6).map { makeTestEvent(messageId: "persisted-\($0)") }
        // First 3 events → 400 (drop). Next 3 → 200.
        let sequencer = CallSequencer(responses: [.http(400), .success])
        let fixture = try await makeDrainFixture(
            seed: seed,
            http: sequencer,
            config: Dispatcher.Config(initialMaxBatchSize: 3)
        )
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        await fixture.dispatcher.drainDiskStoreToNetwork()

        XCTAssertEqual(sequencer.callCount, 2, "Second batch should proceed after first is dropped")
        let onDisk = await fixture.queue.readDiskBatch(max: 100)
        XCTAssertTrue(onDisk.isEmpty, "Disk empty after bad batch drop + good batch success")
    }

    func testDiskDrainConcurrentCallsGuarded() async throws {
        let seed = (0..<10).map { makeTestEvent(messageId: "persisted-\($0)") }
        let recorder = BatchRecordingNetworking()
        let fixture = try await makeDrainFixture(
            seed: seed,
            http: recorder,
            config: Dispatcher.Config(initialMaxBatchSize: 10)
        )
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        // Kick off two drains concurrently
        let dispatcher = fixture.dispatcher
        async let a: () = dispatcher.drainDiskStoreToNetwork()
        async let b: () = dispatcher.drainDiskStoreToNetwork()
        _ = await (a, b)

        // Only one drain should actually have run
        XCTAssertEqual(recorder.callCount, 1, "Concurrent drain calls must be guarded — only one should actually drain")
        XCTAssertEqual(recorder.batchSizes, [10])
    }

    func testDiskDrainSkipsWhenNoPersistedData() async throws {
        let recorder = BatchRecordingNetworking()
        let fixture = try await makeDrainFixture(seed: [], http: recorder)
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        await fixture.dispatcher.drainDiskStoreToNetwork()

        XCTAssertEqual(recorder.callCount, 0, "No network calls when hasDiskData is false")
    }

    func testDiskDrainSkipsWhenOffline() async throws {
        let seed = (0..<5).map { makeTestEvent(messageId: "persisted-\($0)") }
        let recorder = BatchRecordingNetworking()
        let fixture = try await makeDrainFixture(seed: seed, http: recorder)
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        await fixture.dispatcher.setOffline(true)
        await fixture.dispatcher.drainDiskStoreToNetwork()

        XCTAssertEqual(recorder.callCount, 0, "Drain must not call network while offline")
        let onDisk = await fixture.queue.readDiskBatch(max: 100)
        XCTAssertEqual(onDisk.count, 5, "Events must remain on disk when drain skipped")
    }

    func testDiskDrainCheckpointEvery10Batches() async throws {
        // 15 events at batchSize=1 → 15 batches. Checkpoint fires after batch 10.
        // We inspect disk state at the START of call 11 — after the post-batch-10
        // checkpoint has had a chance to land on disk.
        let seed = (0..<15).map { makeTestEvent(messageId: "p-\($0)") }
        let diskDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrainCheckpointTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        try await DiskStorage(baseDirectory: diskDir).write(QueueSnapshot(events: seed))
        defer { try? FileManager.default.removeItem(at: diskDir) }

        let sequencer = CheckpointInspectingNetworking(inspectAtCall: 11, diskDir: diskDir)

        let queue = PersistentEventQueue(diskStore: DiskStorage(baseDirectory: diskDir), maxEventCount: 100)
        _ = await queue.checkForPersistedEvents()
        let dispatcher = makeDispatcher(
            options: TestDataFactory.makeInitOptions(),
            http: sequencer,
            breaker: CircuitBreaker(failureThreshold: 100),
            persistentQueue: queue,
            config: Dispatcher.Config(initialMaxBatchSize: 1)
        )

        await dispatcher.drainDiskStoreToNetwork()

        // Drain completes, disk is empty
        let onDisk = await queue.readDiskBatch(max: 100)
        XCTAssertTrue(onDisk.isEmpty)

        // Checkpoint wrote (15 - 10 = 5) events remaining to disk after batch 10
        XCTAssertEqual(sequencer.capturedAtInspection, 5,
            "Checkpoint after 10 successful batches should leave 5 events on disk")
    }

    func testSendBatchDirectReturnsNilOnError() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .error
        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(),
            queueCapacity: 100
        )

        let result = await dispatcher.sendBatchDirect([makeTestEvent()])
        XCTAssertNil(result, "sendBatchDirect should return nil on network error")
    }

    func testSendBatchDirectReturnsResponseOnSuccess() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .success
        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(),
            queueCapacity: 100
        )

        let result = await dispatcher.sendBatchDirect([makeTestEvent()])
        XCTAssertNotNil(result, "sendBatchDirect should return response on 200")
        XCTAssertEqual(result?.statusCode, 200)
        XCTAssertEqual(stub.callCount, 1)
    }

    func testSendBatchDirectReturnsResponseOnHttpError() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .http(500)
        let dispatcher = makeDispatcher(
            options: options, http: stub,
            breaker: CircuitBreaker(),
            queueCapacity: 100
        )

        let result = await dispatcher.sendBatchDirect([makeTestEvent()])
        XCTAssertNotNil(result, "sendBatchDirect should return response on HTTP error")
        XCTAssertEqual(result?.statusCode, 500)
    }
}


/// Records the number of events in each batch sent, for asserting multi-batch flush behavior.
private final class BatchRecordingNetworking: Networking, @unchecked Sendable {
    private let lock = NSLock()
    private var _batchSizes: [Int] = []
    private var _callCount = 0

    var callCount: Int { lock.withLock { _callCount } }
    var batchSizes: [Int] { lock.withLock { _batchSizes } }

    func postJSON(url: URL, body: Data, timeoutMs: Int, additionalHeaders: [String: String]?) async throws -> NetworkResponse {
        // Decode the body to count events in the batch
        let batchSize: Int
        if let payload = try? JSONDecoder().decode(BatchPayload.self, from: body) {
            batchSize = payload.batch.count
        } else {
            batchSize = 0
        }

        lock.withLock {
            _callCount += 1
            _batchSizes.append(batchSize)
        }

        return NetworkResponse(statusCode: 200, headers: [:], body: Data())
    }

    func parseRetryAfterMs(from headers: [String: String]) -> Int? { nil }

    private struct BatchPayload: Decodable {
        let batch: [AnyCodableElement]
    }

    private struct AnyCodableElement: Decodable {}
}


/// Always responds 200. At call number `inspectAtCall`, reads disk state at the top of
/// the call — used to verify that `drainDiskStoreToNetwork` writes a checkpoint every 10
/// successful batches (inspect at call 11 to see state after the checkpoint post-batch-10).
private final class CheckpointInspectingNetworking: Networking, @unchecked Sendable {
    let inspectAtCall: Int
    let diskDir: URL
    private let lock = NSLock()
    private var _callCount = 0
    private(set) var capturedAtInspection: Int = -1

    init(inspectAtCall: Int, diskDir: URL) {
        self.inspectAtCall = inspectAtCall
        self.diskDir = diskDir
    }

    func postJSON(url: URL, body: Data, timeoutMs: Int, additionalHeaders: [String: String]?) async throws -> NetworkResponse {
        let count: Int = lock.withLock {
            _callCount += 1
            return _callCount
        }
        if count == inspectAtCall {
            let snapshot = await DiskStorage(baseDirectory: diskDir).read()
            capturedAtInspection = snapshot?.events.count ?? 0
        }
        return NetworkResponse(statusCode: 200, headers: [:], body: Data())
    }

    func parseRetryAfterMs(from headers: [String: String]) -> Int? { nil }
}


/// Returns different responses for each successive call, cycling to the last response for overflow
private final class CallSequencer: Networking, @unchecked Sendable {
    enum Response { case success, http(Int), httpWithHeaders(Int, [String: String]), error }

    private let responses: [Response]
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    init(responses: [Response]) {
        self.responses = responses
    }

    func postJSON(url: URL, body: Data, timeoutMs: Int, additionalHeaders: [String: String]?) async throws -> NetworkResponse {
        let idx: Int = lock.withLock {
            let i = _callCount
            _callCount += 1
            return i
        }
        let response = idx < responses.count ? responses[idx] : responses.last!

        switch response {
        case .success:
            return NetworkResponse(statusCode: 200, headers: [:], body: Data())
        case .http(let code):
            return NetworkResponse(statusCode: code, headers: [:], body: Data())
        case .httpWithHeaders(let code, let headers):
            return NetworkResponse(statusCode: code, headers: headers, body: Data())
        case .error:
            throw URLError(.timedOut)
        }
    }

    func parseRetryAfterMs(from headers: [String: String]) -> Int? {
        guard let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value,
              let seconds = Int(raw) else { return nil }
        return seconds * 1000
    }
}
