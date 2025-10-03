import Foundation

public enum CircuitState: Sendable { case closed, open, halfOpen }

/// Circuit breaker that prevents cascading failures by tracking request success/failure.
///
/// **States:**
/// - `.closed`: All requests allowed, tracking consecutive failures.
/// - `.open`: Requests blocked for a cooldown period after hitting failure threshold.
/// - `.halfOpen`: After cooldown, limited concurrent "probe" requests allowed to test recovery.
///
/// **Behavior:**
/// - Call `beforeRequest()` to check if a request is allowed; returns delay in ms (0 = proceed immediately).
/// - Call `onSuccess()` after a successful request to reset failure count and close the circuit.
/// - Call `onFailure()` after a retryable failure (5xx, 408, 429) to increment failure count.
/// - Call `onNonRetryable()` after non-retryable errors (4xx except 408/429) to reset failure count without state change.
///
/// **Backoff:**
/// - Exponential: cooldown doubles each time the circuit opens, up to `maxCooldownMs`.
/// - Jitter: randomizes delay by ±`jitterRatio` to avoid thundering herd.
///
/// **Thread safety:** Uses NSLock for synchronization.
public final class CircuitBreaker: @unchecked Sendable {
    private let failureThreshold: Int
    private let baseCooldownMs: Int
    private let maxCooldownMs: Int
    private let jitterRatio: Double
    private let halfOpenMaxConcurrent: Int

    private var state: CircuitState = .closed
    private var consecutiveFailures = 0
    private var openCount = 0
    private var openUntil: Date = .distantPast
    private var halfOpenInFlight = 0
    private let lock = NSLock()

    public init(
        failureThreshold: Int = 3,
        cooldownMs: Int = 10_000,
        maxCooldownMs: Int = 120_000,
        jitterRatio: Double = 0.2,
        halfOpenMaxConcurrent: Int = 1
    ) {
        self.failureThreshold = max(1, failureThreshold)
        self.baseCooldownMs = max(0, cooldownMs)
        self.maxCooldownMs = max(cooldownMs, maxCooldownMs)
        self.jitterRatio = max(0, jitterRatio)
        self.halfOpenMaxConcurrent = max(1, halfOpenMaxConcurrent)
    }

    public func onSuccess() {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures = 0
        if state != .closed {
            state = .closed
            halfOpenInFlight = 0
        }
    }

    public func onFailure() {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures += 1
        if state == .closed && consecutiveFailures >= failureThreshold {
            tripOpen()
        } else if state == .halfOpen {
            // Failure in half-open -> reopen with increased cooldown
            tripOpen()
        }
    }

    public func onNonRetryable() {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures = 0
        // Do not change state per spec
    }

    /// Returns delayMs to wait before allowing next request, or 0 if allowed immediately
    public func beforeRequest() -> Int {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        switch state {
        case .closed:
            return 0
        case .open:
            if now >= openUntil {
                state = .halfOpen
                halfOpenInFlight = 0
                return 0
            }
            return max(0, Int(openUntil.timeIntervalSince(now) * 1000))
        case .halfOpen:
            if halfOpenInFlight >= halfOpenMaxConcurrent {
                // Suggest small delay to retry later
                return 200
            }
            halfOpenInFlight += 1
            return 0
        }
    }

    private func tripOpen() {
        openCount += 1
        let delay = backoffMs()
        openUntil = Date().addingTimeInterval(TimeInterval(Double(delay) / 1000.0))
        state = .open
        consecutiveFailures = 0
        halfOpenInFlight = 0
    }

    private func backoffMs() -> Int {
        let exponent = max(0, openCount - 1)
        let base = min(maxCooldownMs, baseCooldownMs * Int(pow(2.0, Double(exponent))))
        let jitter = Int(Double(base) * jitterRatio)
        let delta = jitter == 0 ? 0 : Int.random(in: -jitter...jitter)
        return max(0, base + delta)
    }
    
    // MARK: - State Inspection (for getDebugInfo)
    
    /// Get the current circuit breaker state
    public func getState() -> CircuitState {
        lock.lock(); defer { lock.unlock() }
        return state
    }
    
    /// Get remaining cooldown time in milliseconds (0 if not in open state)
    public func getRemainingCooldownMs() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard state == .open else { return 0 }
        let remaining = Int(openUntil.timeIntervalSince(Date()) * 1000)
        return max(0, remaining)
    }
}


