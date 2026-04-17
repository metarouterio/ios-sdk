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
}

/// Persistent NWPathMonitor wrapper that publishes connectivity state.
/// Uses NSLock for thread safety (same pattern as CircuitBreaker).
/// Gracefully falls back to .connected if NWPathMonitor is unavailable.
public final class NetworkMonitor: NetworkReachability, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentStatus: NetworkStatus = .connected
    private var handler: (@Sendable (NetworkStatus) -> Void)?
    private var monitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.metarouter.networkMonitor")

    public var currentStatus: NetworkStatus {
        lock.lock(); defer { lock.unlock() }
        return _currentStatus
    }

    public init() {
        let pathMonitor = NWPathMonitor()
        self.monitor = pathMonitor

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let newStatus: NetworkStatus = path.status == .satisfied ? .connected : .disconnected
            self.lock.lock()
            let oldStatus = self._currentStatus
            self._currentStatus = newStatus
            let callback = self.handler
            self.lock.unlock()

            if oldStatus != newStatus {
                Logger.log("Network status changed: \(oldStatus.rawValue) -> \(newStatus.rawValue) (interfaces=\(path.availableInterfaces.map(\.type)), expensive=\(path.isExpensive), constrained=\(path.isConstrained))")
                callback?(newStatus)
            }
        }

        pathMonitor.start(queue: monitorQueue)
    }

    public func onStatusChange(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    public func stop() {
        lock.lock()
        self.handler = nil
        let mon = self.monitor
        self.monitor = nil
        lock.unlock()
        mon?.cancel()
    }

}
