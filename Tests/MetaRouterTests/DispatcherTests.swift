import XCTest
@testable import MetaRouter

// MARK: - Test Helpers

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

/// Creates a minimal enriched event for testing
private func makeTestEvent(messageId: String = "mid") -> EnrichedEventPayload {
    let ctx = EventContext(
        app: AppContext(name: "a", version: "1", build: "1", namespace: "a"),
        device: DeviceContext(manufacturer: "a", model: "m", name: "n", type: "t"),
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

// MARK: - Existing Tests

final class DispatcherTests: XCTestCase {
    func testFlushSuccessRemovesBatch() async throws {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = Dispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 100)

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
        let dispatcher = Dispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 10, onFatalConfigError: { status in statusHolder.value = status })

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        XCTAssertEqual(statusHolder.value, 401)
    }

    func testTracingDisabledByDefault() async throws {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = Dispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 100)

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        XCTAssertNil(stub.lastHeaders)
    }

    func testTracingEnabledAddsHeader() async throws {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = Dispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 100)

        await dispatcher.setTracing(true)
        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()

        XCTAssertNotNil(stub.lastHeaders)
        XCTAssertEqual(stub.lastHeaders?["Trace"], "true")
    }

    func testTracingCanBeDisabled() async throws {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = Dispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 100)

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
        let dispatcher = Dispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 100)

        await dispatcher.setTracing(true)

        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()
        XCTAssertEqual(stub.lastHeaders?["Trace"], "true")

        stub.lastHeaders = nil
        await dispatcher.offer(makeTestEvent())
        await dispatcher.flush()
        XCTAssertEqual(stub.lastHeaders?["Trace"], "true")
    }

    // MARK: - HTTP Response Handling Tests

    func testFatalConfig403ClearsQueue() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .http(403)
        let statusHolder = StatusHolder()
        let dispatcher = Dispatcher(
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
        let dispatcher = Dispatcher(
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
        let dispatcher = Dispatcher(
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

        let dispatcher = Dispatcher(
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

        let dispatcher = Dispatcher(
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

        let dispatcher = Dispatcher(
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

        let dispatcher = Dispatcher(
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

        let dispatcher = Dispatcher(
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

        let dispatcher = Dispatcher(
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

        let dispatcher = Dispatcher(
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
        let dispatcher = Dispatcher(
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

    func testFlushToDiskDelegatesToQueue() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DispatcherDiskTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }


        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = Dispatcher(
            options: options,
            http: stub,
            breaker: CircuitBreaker(),
            persistentQueue: PersistentEventQueue(
                diskStorage: DiskStorage(baseDirectory: tempDir),
                maxEventCount: 100
            )
        )

        await dispatcher.offer(makeTestEvent(messageId: "disk-test"))
        try await dispatcher.flushToDisk()

        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let snapshot = await diskStorage.read()
        XCTAssertEqual(snapshot?.events.count, 1)
        XCTAssertEqual(snapshot?.events[0].messageId, "disk-test")
    }

    // MARK: - Rehydration + Multi-Batch Flush Tests

    func testRehydratedEventsFlushInMultipleBatches() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RehydrationBatchTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Seed disk with 250 events
        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let events = (0..<250).map { makeTestEvent(messageId: "rehydrated-\($0)") }
        let snapshot = QueueSnapshot(events: events)
        try await diskStorage.write(snapshot)

        let recorder = BatchRecordingNetworking()
        let dispatcher = Dispatcher(
            options: TestDataFactory.makeInitOptions(),
            http: recorder,
            breaker: CircuitBreaker(),
            persistentQueue: PersistentEventQueue(
                diskStorage: DiskStorage(baseDirectory: tempDir),
                maxEventCount: 2000
            ),
            config: Dispatcher.Config(initialMaxBatchSize: 100)
        )

        let rehydrated = await dispatcher.rehydrate()
        XCTAssertEqual(rehydrated, 250)

        await dispatcher.flush()

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "All rehydrated events should be drained")
        XCTAssertEqual(recorder.callCount, 3, "250 events with batchSize=100 should take 3 API calls")

        let batchSizes = recorder.batchSizes
        XCTAssertEqual(batchSizes, [100, 100, 50], "Batches should be 100, 100, 50")
    }

    func testRehydratedEventsPlusNewEventsAllDrainInSingleFlush() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RehydrationPlusNewTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Seed disk with 5 events
        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let diskEvents = (0..<5).map { makeTestEvent(messageId: "rehydrated-\($0)") }
        try await diskStorage.write(QueueSnapshot(events: diskEvents))

        let recorder = BatchRecordingNetworking()
        let dispatcher = Dispatcher(
            options: TestDataFactory.makeInitOptions(),
            http: recorder,
            breaker: CircuitBreaker(),
            persistentQueue: PersistentEventQueue(
                diskStorage: DiskStorage(baseDirectory: tempDir),
                maxEventCount: 2000
            ),
            config: Dispatcher.Config(initialMaxBatchSize: 100)
        )

        let rehydrated = await dispatcher.rehydrate()
        XCTAssertEqual(rehydrated, 5)

        // Add new events after rehydration (before flush)
        for i in 0..<3 {
            await dispatcher.offer(makeTestEvent(messageId: "new-\(i)"))
        }

        await dispatcher.flush()

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "All events (rehydrated + new) should be drained")
        XCTAssertEqual(recorder.callCount, 1, "8 events should fit in a single batch")

        let batchSizes = recorder.batchSizes
        XCTAssertEqual(batchSizes, [8], "All 8 events should be in one batch")
    }

    func testRehydrationOverCapacityDropsOldestAndFlushesRemainder() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RehydrationOverCapTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Seed disk with 150 events, but queue capacity is only 50
        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let events = (0..<150).map { makeTestEvent(messageId: "evt-\($0)") }
        try await diskStorage.write(QueueSnapshot(events: events))

        let recorder = BatchRecordingNetworking()
        let dispatcher = Dispatcher(
            options: TestDataFactory.makeInitOptions(),
            http: recorder,
            breaker: CircuitBreaker(),
            persistentQueue: PersistentEventQueue(
                diskStorage: DiskStorage(baseDirectory: tempDir),
                maxEventCount: 50
            ),
            config: Dispatcher.Config(initialMaxBatchSize: 25)
        )

        let rehydrated = await dispatcher.rehydrate()
        // Should cap at 50, dropping the 100 oldest
        XCTAssertEqual(rehydrated, 50, "Rehydration should cap at maxEventCount")

        await dispatcher.flush()

        let remaining = await dispatcher.getQueueLength()
        XCTAssertEqual(remaining, 0, "All capped events should be drained")
        XCTAssertEqual(recorder.callCount, 2, "50 events with batchSize=25 should take 2 API calls")
        XCTAssertEqual(recorder.batchSizes, [25, 25])
    }

    func testProcessUntilEmptyDrainsAcrossBatchBoundary() async throws {
        // Verifies the while-loop in processUntilEmpty continues
        // when events exceed maxBatchSize without rehydration
        let options = TestDataFactory.makeInitOptions()
        let recorder = BatchRecordingNetworking()
        let dispatcher = Dispatcher(
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

    // MARK: - Auto-Flush Tests

    func testAutoFlushTriggersAtThreshold() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        stub.mode = .success

        let dispatcher = Dispatcher(
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
}

// MARK: - BatchRecordingNetworking

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

// MARK: - CallSequencer

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
