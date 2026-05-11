import Foundation

/// Bridges `AnalyticsClient`'s init / foreground / background / deep-link callbacks
/// to `LifecycleEventEmitter`. Owns the cold-launch app-state probe so the UIKit
/// dependency stays out of `AnalyticsClient`. Designed as an extension point for
/// richer deep-linking and lifecycle hooks.
internal final class LifecycleCoordinator: @unchecked Sendable {
    private let emitter: LifecycleEventEmitter
    private let initialStateOverride: AppForegroundState?

    init(
        emitter: LifecycleEventEmitter,
        initialStateOverride: AppForegroundState? = nil
    ) {
        self.emitter = emitter
        self.initialStateOverride = initialStateOverride
    }

    func onForeground() async {
        await emitter.emitForegroundFromBackground()
    }

    func onBackground() async {
        await emitter.emitBackgrounded()
    }

    func onReady() async {
        let initialState: AppForegroundState
        if let override = initialStateOverride {
            initialState = override
        } else {
            initialState = await currentAppForegroundState()
        }
        await emitter.emitColdLaunchSequence(initialAppState: initialState)
    }

    func openURL(_ url: URL, sourceApplication: String?) async {
        await emitter.recordOpenedURL(
            url: url.absoluteString,
            sourceApplication: sourceApplication
        )
    }
}

#if canImport(UIKit)
import UIKit

/// Reads `UIApplication.applicationState` on the main actor (it's main-actor
/// isolated) and maps to our platform-neutral `AppForegroundState`.
fileprivate func currentAppForegroundState() async -> AppForegroundState {
    await MainActor.run {
        switch UIApplication.shared.applicationState {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .active
        }
    }
}
#else
/// UIKit unavailable (macOS native, Linux). macOS apps don't have the iOS
/// background-launch scenario (silent push, background fetch), so `.active`
/// is the correct cold-launch assumption — `Application Opened` fires normally.
fileprivate func currentAppForegroundState() async -> AppForegroundState {
    .active
}
#endif
