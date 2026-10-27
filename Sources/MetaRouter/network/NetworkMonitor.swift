import Foundation
import Network

/// Connectivity state observed by the SDK.
public enum NetworkStatus: String, Sendable {
    case connected
    case disconnected
}

/// Protocol for testability — allows injecting a stub in tests.
public protocol NetworkReachability: AnyObject, Sendable {
    /// Current snapshot of connectivity.
    var currentStatus: NetworkStatus { get }
    /// Register a callback fired on every status transition.
    func onStatusChange(_ handler: @escaping @Sendable (NetworkStatus) -> Void)
    /// Tear down monitoring.
    func stop()
    /// Whether the current path uses wifi; `nil` until the first path is known.
    /// Read per event by enrichment for `context.network.wifi`.
    var isWifi: Bool? { get }
    /// `isWifi`, waiting up to `timeout` for the first path when none has been
    /// delivered yet. Returns at once when the value is known or can never arrive.
    func awaitIsWifi(timeout: TimeInterval) async -> Bool?
}

extension NetworkReachability {
    /// Conformers that predate interface-type tracking report unknown, which
    /// omits `context.network` rather than failing the host's build.
    public var isWifi: Bool? { nil }

    public func awaitIsWifi(timeout: TimeInterval) async -> Bool? { isWifi }
}

/// Persistent NWPathMonitor wrapper that publishes connectivity state.
/// Uses NSLock for thread safety (same pattern as CircuitBreaker).
/// Gracefully falls back to .connected if NWPathMonitor is unavailable.
public final class NetworkMonitor: NetworkReachability, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentStatus: NetworkStatus = .connected
    private var _isWifi: Bool?
    /// Callers parked until the first path arrives (bounded by their timeout).
    private var firstPathWaiters: [UUID: CheckedContinuation<Bool?, Never>] = [:]
    /// Set once waiting is pointless: stopped, or a wait already timed out. A
    /// monitor that never delivers must cost one bounded wait, not one per event.
    private var stopWaiting = false
    private var handler: (@Sendable (NetworkStatus) -> Void)?
    private var monitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.metarouter.networkMonitor")

    public var currentStatus: NetworkStatus {
        lock.lock(); defer { lock.unlock() }
        return _currentStatus
    }

    public var isWifi: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _isWifi
    }

    public init() {
        let pathMonitor = NWPathMonitor()
        self.monitor = pathMonitor

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let newStatus: NetworkStatus = path.status == .satisfied ? .connected : .disconnected
            self.lock.lock()
            // A path already queued when stop() ran would otherwise restore the
            // value stop() just cleared, and every later event would stamp it.
            guard self.monitor != nil else {
                self.lock.unlock()
                return
            }
            let oldStatus = self._currentStatus
            self._currentStatus = newStatus
            let isWifi = path.usesInterfaceType(.wifi)
            self._isWifi = isWifi
            let callback = self.handler
            let waiters = self.firstPathWaiters
            self.firstPathWaiters = [:]
            self.lock.unlock()
            for waiter in waiters.values { waiter.resume(returning: isWifi) }

            if oldStatus != newStatus {
                Logger.log("Network status changed: \(oldStatus.rawValue) -> \(newStatus.rawValue) (interfaces=\(path.availableInterfaces.map(\.type)), expensive=\(path.isExpensive), constrained=\(path.isConstrained))")
                callback?(newStatus)
            }
        }

        pathMonitor.start(queue: monitorQueue)
    }

    public func awaitIsWifi(timeout: TimeInterval) async -> Bool? {
        // Fast path: known or never coming — no continuation, no suspension per event.
        let (known, settled) = lock.withLock { (_isWifi, _isWifi != nil || stopWaiting) }
        if settled { return known }
        // Rejects negative, NaN and infinite input, which would trap in the UInt64 conversion.
        guard timeout > 0, timeout.isFinite else { return isWifi }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if _isWifi != nil || stopWaiting {
                let value = _isWifi
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            firstPathWaiters[id] = continuation
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.expireFirstPathWaiter(id)
            }
        }
    }

    private func expireFirstPathWaiter(_ id: UUID) {
        lock.lock()
        let waiter = firstPathWaiters.removeValue(forKey: id)
        if waiter != nil { stopWaiting = true }
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    public func onStatusChange(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    public func stop() {
        lock.lock()
        self.handler = nil
        // Unknown, not last-known: a stopped monitor sees no further switches, and
        // stamping a frozen value is the staleness per-event reads exist to remove.
        self._isWifi = nil
        self.stopWaiting = true
        let waiters = self.firstPathWaiters
        self.firstPathWaiters = [:]
        let mon = self.monitor
        self.monitor = nil
        lock.unlock()
        mon?.cancel()
        for waiter in waiters.values { waiter.resume(returning: nil) }
    }

}
