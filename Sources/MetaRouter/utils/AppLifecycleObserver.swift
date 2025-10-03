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
        #endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    #if canImport(UIKit) || canImport(AppKit)
    @objc private func appDidBecomeActive() { onForeground() }
    @MainActor @objc private func appDidEnterBackground() {
        #if canImport(UIKit)
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "MetaRouterFlush") {
            UIApplication.shared.endBackgroundTask(taskId)
        }
        Task { [onBackgroundAsync] in
            await onBackgroundAsync()
            UIApplication.shared.endBackgroundTask(taskId)
        }
        #else
        Task { [onBackgroundAsync] in
            await onBackgroundAsync()
        }
        #endif
    }
    #endif
}
