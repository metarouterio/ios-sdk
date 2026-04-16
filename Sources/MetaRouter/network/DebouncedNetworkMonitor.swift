import Foundation

/// Wraps a `NetworkReachability` monitor and debounces online transitions.
/// Offline transitions fire immediately; online transitions only fire after
/// connectivity is stable for `debounceSeconds` (default 2s).
public final class DebouncedNetworkMonitor: NetworkReachability, @unchecked Sendable {
    private let inner: NetworkReachability
    private let debounceNs: UInt64
    private let lock = NSLock()
    private var _currentStatus: NetworkStatus
    private var handler: (@Sendable (NetworkStatus) -> Void)?
    private var debounceTask: Task<Void, Never>?

    public var currentStatus: NetworkStatus {
        lock.withLock { _currentStatus }
    }

    /// - Parameters:
    ///   - inner: The underlying network monitor to wrap.
    ///   - debounceSeconds: How long an online signal must be stable before firing. Default 2s.
    public init(inner: NetworkReachability, debounceSeconds: TimeInterval = 2.0) {
        self.inner = inner
        self.debounceNs = UInt64(debounceSeconds * 1_000_000_000)
        self._currentStatus = inner.currentStatus

        inner.onStatusChange { [weak self] rawStatus in
            self?.handleRawStatusChange(rawStatus)
        }
    }

    public func onStatusChange(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {
        lock.withLock { self.handler = handler }
    }

    public func stop() {
        lock.lock()
        handler = nil
        let task = debounceTask
        debounceTask = nil
        lock.unlock()
        task?.cancel()
        inner.stop()
    }

    private func handleRawStatusChange(_ rawStatus: NetworkStatus) {
        lock.lock()
        let oldStatus = _currentStatus

        if rawStatus == .disconnected {
            // Offline: immediate — cancel any pending online debounce
            debounceTask?.cancel()
            debounceTask = nil
            _currentStatus = .disconnected
            let callback = handler
            lock.unlock()

            if oldStatus != .disconnected {
                Logger.log("Debounced network: immediate offline transition")
                callback?(.disconnected)
            }
        } else {
            // Online: debounce — wait for stability before firing
            Logger.log("Debounced network: raw online signal received (current=\(oldStatus.rawValue)), starting \(debounceNs / 1_000_000_000)s debounce")
            debounceTask?.cancel()
            let interval = debounceNs
            debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else {
                    Logger.log("Debounced network: online debounce cancelled (flapping?)")
                    return
                }
                self?.commitOnline()
            }
            lock.unlock()
        }
    }

    private func commitOnline() {
        lock.lock()
        let oldStatus = _currentStatus
        _currentStatus = .connected
        let callback = handler
        lock.unlock()

        if oldStatus != .connected {
            Logger.log("Debounced network: online transition confirmed after debounce")
            callback?(.connected)
        }
    }
}
