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
