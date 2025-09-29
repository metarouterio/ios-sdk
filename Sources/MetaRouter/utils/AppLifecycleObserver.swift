import Foundation

#if canImport(UIKit)
import UIKit
#endif

public final class AppLifecycleObserver: @unchecked Sendable {
    private let onForeground: () -> Void
    private let onBackground: () -> Void

    public init(onForeground: @escaping () -> Void, onBackground: @escaping () -> Void) {
        self.onForeground = onForeground
        self.onBackground = onBackground
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
        #endif
    }

    deinit {
        #if canImport(UIKit)
        NotificationCenter.default.removeObserver(self)
        #endif
    }

    #if canImport(UIKit)
    @objc private func appDidBecomeActive() { onForeground() }
    @objc private func appDidEnterBackground() { onBackground() }
    #endif
}


