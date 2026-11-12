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
    /// Not `monitor == nil`: the test seam builds a monitor without an NWPathMonitor
    /// that is still live, so stopped-ness needs its own flag.
    private var stopped = false
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

    public convenience init() {
        self.init(startingPathMonitor: true)
    }

    /// Test seam: `false` builds the monitor without an `NWPathMonitor`, so a test
    /// drives `applyPath` itself — the park / time-out / latch / stop paths can then
    /// be exercised deterministically instead of racing the runner's real network.
    internal init(startingPathMonitor: Bool) {
        guard startingPathMonitor else { return }
        let pathMonitor = NWPathMonitor()
        self.monitor = pathMonitor

        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.applyPath(
                satisfied: path.status == .satisfied,
                isWifi: path.usesInterfaceType(.wifi),
                detail: "interfaces=\(path.availableInterfaces.map(\.type)), expensive=\(path.isExpensive), constrained=\(path.isConstrained)"
            )
        }

        pathMonitor.start(queue: monitorQueue)
    }

    internal func applyPath(satisfied: Bool, isWifi: Bool, detail: @autoclosure () -> String = "") {
        let newStatus: NetworkStatus = satisfied ? .connected : .disconnected
        lock.lock()
        // A path already queued when stop() ran would otherwise restore the
        // value stop() just cleared, and every later event would stamp it.
        guard !stopped else {
            lock.unlock()
            return
        }
        let oldStatus = _currentStatus
        _currentStatus = newStatus
        _isWifi = isWifi
        let callback = handler
        let waiters = firstPathWaiters
        firstPathWaiters = [:]
        lock.unlock()
        for waiter in waiters.values { waiter.resume(returning: isWifi) }

        if oldStatus != newStatus {
            Logger.log("Network status changed: \(oldStatus.rawValue) -> \(newStatus.rawValue) (\(detail()))")
            callback?(newStatus)
        }
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

    /// Test seam: lets a test wait until a caller is actually parked before it
    /// delivers a path or stops, instead of sleeping and hoping.
    internal var parkedWaiterCount: Int {
        lock.withLock { firstPathWaiters.count }
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
        self.stopped = true
        let waiters = self.firstPathWaiters
        self.firstPathWaiters = [:]
        let mon = self.monitor
        self.monitor = nil
        lock.unlock()
        mon?.cancel()
        for waiter in waiters.values { waiter.resume(returning: nil) }
    }

}
