import Foundation
import Network

/// Monitors network reachability using NWPathMonitor.
/// Reports connectivity changes via the `onStatusChange` callback.
public final class NetworkMonitor: NetworkReachability, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var _currentStatus: NetworkStatus
    private var handler: (@Sendable (NetworkStatus) -> Void)?

    public var currentStatus: NetworkStatus {
        lock.withLock { _currentStatus }
    }

    public init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.metarouter.network-monitor")
        self._currentStatus = .disconnected

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let newStatus: NetworkStatus = path.status == .satisfied ? .connected : .disconnected

            self.lock.lock()
            let oldStatus = self._currentStatus
            self._currentStatus = newStatus
            let callback = self.handler
            self.lock.unlock()

            if newStatus != oldStatus {
                Logger.log("Network status changed: \(newStatus)")
                callback?(newStatus)
            }
        }

        monitor.start(queue: queue)
    }

    public func onStatusChange(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {
        lock.withLock { self.handler = handler }
    }

    public func stop() {
        lock.lock()
        handler = nil
        lock.unlock()
        monitor.cancel()
    }
}
