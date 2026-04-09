import XCTest
@testable import MetaRouter

final class CircuitBreakerTests: XCTestCase {
    func testClosedAllowsRequests() {
        let cb = CircuitBreaker(failureThreshold: 3, cooldownMs: 100, maxCooldownMs: 1000, jitterRatio: 0.0)
        XCTAssertEqual(cb.beforeRequest(), 0)
    }

    func testOpensAfterFailures() {
        let cb = CircuitBreaker(failureThreshold: 2, cooldownMs: 100, maxCooldownMs: 1000, jitterRatio: 0.0)
        cb.onFailure()
        cb.onFailure()
        let wait = cb.beforeRequest()
        XCTAssertGreaterThanOrEqual(wait, 50)
    }

    func testHalfOpenAfterCooldown() async {
        let cb = CircuitBreaker(failureThreshold: 1, cooldownMs: 50, maxCooldownMs: 1000, jitterRatio: 0.0)
        cb.onFailure() // open
        var wait = cb.beforeRequest()
        XCTAssertGreaterThan(wait, 0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        wait = cb.beforeRequest()
        XCTAssertEqual(wait, 0) // half-open allows immediate probe
    }

    func testOnSuccessCloses() {
        let cb = CircuitBreaker(failureThreshold: 1, cooldownMs: 50, maxCooldownMs: 1000, jitterRatio: 0.0)
        cb.onFailure()
        _ = cb.beforeRequest()
        cb.onSuccess()
        XCTAssertEqual(cb.beforeRequest(), 0)
    }


    func testResetMovesFromOpenToClosed() {
        let cb = CircuitBreaker(failureThreshold: 1, cooldownMs: 60_000, maxCooldownMs: 120_000, jitterRatio: 0.0)
        cb.onFailure() // trips open
        XCTAssertEqual(cb.getState(), .open)

        cb.reset()
        XCTAssertEqual(cb.getState(), .closed)
        XCTAssertEqual(cb.beforeRequest(), 0, "Should allow requests immediately after reset")
    }

    func testResetClearsOpenCountBackoffEscalation() {
        let cb = CircuitBreaker(failureThreshold: 1, cooldownMs: 1000, maxCooldownMs: 120_000, jitterRatio: 0.0)

        // Trip open multiple times to escalate backoff
        cb.onFailure() // open (openCount=1, cooldown=1000ms)
        cb.onSuccess() // close
        cb.onFailure() // open (openCount=2, cooldown=2000ms)
        cb.onSuccess()
        cb.onFailure() // open (openCount=3, cooldown=4000ms)

        let escalatedWait = cb.beforeRequest()
        XCTAssertGreaterThan(escalatedWait, 2000, "Backoff should have escalated")

        cb.reset()

        // Trip again — should use base cooldown (1000ms), not escalated
        cb.onFailure()
        let freshWait = cb.beforeRequest()
        XCTAssertLessThanOrEqual(freshWait, 1000, "After reset, backoff should start from base")
    }

    func testResetWhileAlreadyClosedIsNoop() {
        let cb = CircuitBreaker(failureThreshold: 3, cooldownMs: 100, maxCooldownMs: 1000, jitterRatio: 0.0)
        XCTAssertEqual(cb.getState(), .closed)

        cb.reset()
        XCTAssertEqual(cb.getState(), .closed)
        XCTAssertEqual(cb.beforeRequest(), 0)
    }
}


