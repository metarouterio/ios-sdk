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
}


