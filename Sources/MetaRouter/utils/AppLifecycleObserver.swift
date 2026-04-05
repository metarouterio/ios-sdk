import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

public final class AppLifecycleObserver: @unchecked Sendable {
    private let onForeground: () -> Void
    private let onBackgroundAsync: () async -> Void

    public init(onForeground: @escaping () -> Void, onBackgroundAsync: @escaping () async -> Void) {
        self.onForeground = onForeground
        self.onBackgroundAsync = onBackgroundAsync

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        #elseif canImport(AppKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        #endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    #if canImport(UIKit) || canImport(AppKit)
    @objc private func appDidBecomeActive() { onForeground() }

    /// Best-effort flush on app termination. We cannot reliably await async work
    /// because the process is about to exit. Task.detached gives maximum chance
    /// of execution, but this may not complete on force-kill or OOM-kill.
    @objc private func appWillTerminate() {
        Task.detached { [onBackgroundAsync] in
            await onBackgroundAsync()
        }
    }

    @MainActor @objc private func appDidEnterBackground() {
        #if canImport(UIKit)
        let endOnce = BackgroundTaskGuard()
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "MetaRouterFlush") {
            // Expiration handler — only end if async work hasn't already ended it
            if endOnce.claim() {
                UIApplication.shared.endBackgroundTask(taskId)
            }
        }
        guard taskId != .invalid else { return }
        Task { [onBackgroundAsync] in
            await onBackgroundAsync()
            if endOnce.claim() {
                await MainActor.run {
                    UIApplication.shared.endBackgroundTask(taskId)
                }
            }
        }
        #else
        Task { [onBackgroundAsync] in
            await onBackgroundAsync()
        }
        #endif
    }
    #endif
}

/// Thread-safe one-shot guard to ensure `endBackgroundTask` is called exactly once.
private final class BackgroundTaskGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
