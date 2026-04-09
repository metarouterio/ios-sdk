import XCTest
@testable import MetaRouter


// MARK: - Test Doubles

/// Stub network monitor for testing. Allows simulating status changes synchronously.
final class StubNetworkMonitor: NetworkReachability, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentStatus: NetworkStatus
    private var handler: (@Sendable (NetworkStatus) -> Void)?

    var currentStatus: NetworkStatus {
        lock.withLock { _currentStatus }
    }

    init(status: NetworkStatus) {
        self._currentStatus = status
    }

    func onStatusChange(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func stop() {
        lock.withLock { handler = nil }
    }

    /// Simulate a network status change (fires handler synchronously).
    func simulate(_ status: NetworkStatus) {
        lock.lock()
        _currentStatus = status
        let callback = handler
        lock.unlock()
        callback?(status)
    }
}


// MARK: - Helpers

private final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [NetworkStatus] = []
    var statuses: [NetworkStatus] { lock.withLock { _statuses } }
    func append(_ status: NetworkStatus) { lock.withLock { _statuses.append(status) } }
}


// MARK: - Tests

final class DebouncedNetworkMonitorTests: XCTestCase {

    // MARK: Task 1 — Offline transitions are immediate

    func testOfflineTransitionIsImmediate() {
        let stub = StubNetworkMonitor(status: .connected)
        let debounced = DebouncedNetworkMonitor(inner: stub, debounceSeconds: 0.1)

        let recorder = StatusRecorder()
        debounced.onStatusChange { status in recorder.append(status) }

        stub.simulate(.disconnected)

        XCTAssertEqual(recorder.statuses, [.disconnected])
        XCTAssertEqual(debounced.currentStatus, .disconnected)
    }

    // MARK: Task 2 — Online transitions are debounced

    func testOnlineTransitionIsDebounced() async {
        let stub = StubNetworkMonitor(status: .disconnected)
        let debounced = DebouncedNetworkMonitor(inner: stub, debounceSeconds: 0.2)

        let recorder = StatusRecorder()
        debounced.onStatusChange { status in recorder.append(status) }

        stub.simulate(.connected)

        XCTAssertEqual(recorder.statuses, [], "Online should not fire before debounce interval")
        XCTAssertEqual(debounced.currentStatus, .disconnected, "currentStatus should not change before debounce")

        try? await Task.sleep(nanoseconds: 350_000_000) // 350ms > 200ms debounce

        XCTAssertEqual(recorder.statuses, [.connected], "Online should fire after debounce interval")
        XCTAssertEqual(debounced.currentStatus, .connected)
    }

    // MARK: Task 3 — Rapid flapping produces single offline

    func testRapidFlappingProducesNoOnlineTransition() async {
        let stub = StubNetworkMonitor(status: .connected)
        let debounced = DebouncedNetworkMonitor(inner: stub, debounceSeconds: 0.2)

        let recorder = StatusRecorder()
        debounced.onStatusChange { status in recorder.append(status) }

        // Rapid flap: offline → online → offline → online → offline
        stub.simulate(.disconnected)
        stub.simulate(.connected)
        stub.simulate(.disconnected)
        stub.simulate(.connected)
        stub.simulate(.disconnected)

        XCTAssertEqual(recorder.statuses, [.disconnected],
            "Rapid flapping should produce single offline, no online")

        try? await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(recorder.statuses, [.disconnected],
            "No delayed online should fire after flapping ends disconnected")
        XCTAssertEqual(debounced.currentStatus, .disconnected)
    }

    // MARK: Task 4 — Debounce timer cancelled on re-disconnect

    func testDebounceTimerCancelledOnReDisconnect() async {
        let stub = StubNetworkMonitor(status: .disconnected)
        let debounced = DebouncedNetworkMonitor(inner: stub, debounceSeconds: 0.2)

        let recorder = StatusRecorder()
        debounced.onStatusChange { status in recorder.append(status) }

        stub.simulate(.connected)
        XCTAssertEqual(recorder.statuses, [], "Online should not fire immediately")

        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms < 200ms debounce
        stub.simulate(.disconnected)

        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms total > 200ms debounce

        XCTAssertEqual(recorder.statuses, [],
            "No transitions should fire: online was cancelled, offline was idempotent")
        XCTAssertEqual(debounced.currentStatus, .disconnected)
    }

    // MARK: Task 5 — Clean transitions work normally

    func testCleanTransitionsWorkNormally() async {
        let stub = StubNetworkMonitor(status: .connected)
        let debounced = DebouncedNetworkMonitor(inner: stub, debounceSeconds: 0.1)

        let recorder = StatusRecorder()
        debounced.onStatusChange { status in recorder.append(status) }

        // Clean offline
        stub.simulate(.disconnected)
        XCTAssertEqual(recorder.statuses, [.disconnected])

        // Clean online — wait for debounce
        stub.simulate(.connected)
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms > 100ms debounce
        XCTAssertEqual(recorder.statuses, [.disconnected, .connected])

        // Another clean offline
        stub.simulate(.disconnected)
        XCTAssertEqual(recorder.statuses, [.disconnected, .connected, .disconnected])

        XCTAssertEqual(debounced.currentStatus, .disconnected)
    }

    // MARK: Task 6 — Stop cancels debounce and cleans up

    func testStopCancelsDebounceAndCleansUp() async {
        let stub = StubNetworkMonitor(status: .disconnected)
        let debounced = DebouncedNetworkMonitor(inner: stub, debounceSeconds: 0.2)

        let recorder = StatusRecorder()
        debounced.onStatusChange { status in recorder.append(status) }

        stub.simulate(.connected)

        debounced.stop()

        try? await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(recorder.statuses, [],
            "No transitions should fire after stop()")
    }

    func testCurrentStatusReflectsInitialInnerStatus() {
        let connectedStub = StubNetworkMonitor(status: .connected)
        let debouncedConnected = DebouncedNetworkMonitor(inner: connectedStub, debounceSeconds: 0.1)
        XCTAssertEqual(debouncedConnected.currentStatus, .connected)

        let disconnectedStub = StubNetworkMonitor(status: .disconnected)
        let debouncedDisconnected = DebouncedNetworkMonitor(inner: disconnectedStub, debounceSeconds: 0.1)
        XCTAssertEqual(debouncedDisconnected.currentStatus, .disconnected)
    }

    // MARK: Task 8 — Integration: rapid flapping produces single flush

    func testRapidFlappingProducesSingleFlushThroughDispatcher() async {
        let stub = StubNetworkMonitor(status: .connected)
        let debounced = DebouncedNetworkMonitor(inner: stub, debounceSeconds: 0.2)

        let flushCounter = FlushCounter()
        let options = TestDataFactory.makeInitOptions()
        let networking = CountingNetworking(counter: flushCounter)
        let dispatcher = Dispatcher(
            options: options,
            http: networking,
            breaker: CircuitBreaker(),
            queueCapacity: 100
        )

        // Enqueue an event
        await dispatcher.offer(makeTestEvent())

        // Wire debounced monitor to dispatcher
        debounced.onStatusChange { status in
            Task {
                if status == .disconnected {
                    await dispatcher.setOffline(true)
                } else {
                    await dispatcher.resetCircuitBreaker()
                    await dispatcher.setOffline(false)
                    await dispatcher.flush()
                }
            }
        }

        // Go offline first
        await dispatcher.setOffline(true)

        // Rapid flap: online → offline → online → offline → online (ends connected)
        stub.simulate(.connected)
        stub.simulate(.disconnected)
        stub.simulate(.connected)
        stub.simulate(.disconnected)
        stub.simulate(.connected)

        // No flush should have happened yet
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        XCTAssertEqual(flushCounter.value, 0, "No flush during flapping")

        // Wait for debounce to complete
        try? await Task.sleep(nanoseconds: 300_000_000) // 350ms total > 200ms debounce

        // Give the flush Task time to execute
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(flushCounter.value, 1, "Exactly one flush after stable reconnect")
    }
}


// MARK: - Integration Test Helpers

private final class FlushCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

private final class CountingNetworking: Networking, @unchecked Sendable {
    private let counter: FlushCounter

    init(counter: FlushCounter) {
        self.counter = counter
    }

    func postJSON(url: URL, body: Data, timeoutMs: Int, additionalHeaders: [String: String]?) async throws -> NetworkResponse {
        counter.increment()
        return NetworkResponse(statusCode: 200, headers: [:], body: Data())
    }

    func parseRetryAfterMs(from headers: [String: String]) -> Int? { nil }
}

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
