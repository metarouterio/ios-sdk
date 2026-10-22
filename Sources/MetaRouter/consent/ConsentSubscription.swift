import Combine
import Foundation

/// Returned by `subscribeToConsent`: keep it for as long as the handler should run.
///
/// Not cancelled on deinit. Consent changes are compliance signals, so a dropped
/// reference must not silently stop them; a discarded subscription delivers for the
/// life of the process instead (the compiler warns on a discarded result). Conforms
/// to Combine's `Cancellable`, so `AnyCancellable(subscription)` stores it in a
/// cancellable set — and that wrapper, unlike this type, does cancel on deinit.
public final class ConsentSubscription: Cancellable, @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    /// Whether `cancel()` has been called.
    public var isCancelled: Bool { lock.withLock { onCancel == nil } }

    /// Stops delivery. Idempotent. Called from the main actor, the handler is not
    /// invoked again, even for a delivery that was already queued.
    public func cancel() {
        let pending = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { onCancel = nil }
            return onCancel
        }
        pending?()
    }
}
