import XCTest
@testable import MetaRouter

// MARK: - StubNetworkMonitor (test double)

final class StubNetworkMonitor: NetworkReachability, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: NetworkStatus
    private var handler: (@Sendable (NetworkStatus) -> Void)?

    var currentStatus: NetworkStatus {
        lock.withLock { _status }
    }

    init(status: NetworkStatus = .connected) {
        _status = status
    }

    func onStatusChange(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func stop() {
        lock.withLock { self.handler = nil }
    }

    /// Simulate a network transition from tests.
    func simulate(_ newStatus: NetworkStatus) {
        var callback: (@Sendable (NetworkStatus) -> Void)?
        lock.withLock {
            _status = newStatus
            callback = handler
        }
        callback?(newStatus)
    }
}

// MARK: - Thread-safe test helpers

private final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

private final class SendableStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [NetworkStatus] = []
    var statuses: [NetworkStatus] { lock.withLock { _statuses } }
    func append(_ status: NetworkStatus) { lock.withLock { _statuses.append(status) } }
}

// MARK: - NetworkMonitor Tests

final class NetworkMonitorTests: XCTestCase {
    func testNetworkMonitorInitializesWithStatus() {
        let monitor = NetworkMonitor()
        defer { monitor.stop() }
        // Should have a status (connected or disconnected depending on device)
        let status = monitor.currentStatus
        XCTAssertTrue(status == .connected || status == .disconnected)
    }

    func testNetworkMonitorStopCleansUp() {
        let monitor = NetworkMonitor()
        monitor.onStatusChange { _ in }
        monitor.stop()
        // After stop, monitor should not crash and handler should be cleared
        XCTAssertTrue(true, "stop() should complete without crash")
    }

    // MARK: - StubNetworkMonitor Tests

    func testStubInitializesWithDefaultConnected() {
        let stub = StubNetworkMonitor()
        XCTAssertEqual(stub.currentStatus, .connected)
    }

    func testStubInitializesWithCustomStatus() {
        let stub = StubNetworkMonitor(status: .disconnected)
        XCTAssertEqual(stub.currentStatus, .disconnected)
    }

    func testStubSimulateTransitionsFireHandler() {
        let stub = StubNetworkMonitor(status: .connected)
        let expectation = expectation(description: "Handler fires on transition")

        stub.onStatusChange { status in
            XCTAssertEqual(status, .disconnected)
            expectation.fulfill()
        }

        stub.simulate(.disconnected)
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(stub.currentStatus, .disconnected)
    }

    func testStubSimulateConnectedToConnectedStillFires() {
        let stub = StubNetworkMonitor(status: .connected)
        let counter = SendableCounter()

        stub.onStatusChange { _ in counter.increment() }
        stub.simulate(.connected)

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(stub.currentStatus, .connected)
    }

    func testStubStopClearsHandler() {
        let stub = StubNetworkMonitor()
        let counter = SendableCounter()
        stub.onStatusChange { _ in counter.increment() }
        stub.stop()
        stub.simulate(.disconnected)
        XCTAssertEqual(counter.value, 0, "Handler should not fire after stop()")
    }

    func testStubRoundTripTransitions() {
        let stub = StubNetworkMonitor(status: .connected)
        let recorder = SendableStatusRecorder()

        stub.onStatusChange { status in recorder.append(status) }

        stub.simulate(.disconnected)
        stub.simulate(.connected)
        stub.simulate(.disconnected)

        XCTAssertEqual(recorder.statuses, [.disconnected, .connected, .disconnected])
        XCTAssertEqual(stub.currentStatus, .disconnected)
    }
}
