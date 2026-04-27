import Foundation

#if canImport(UIKit)
import UIKit
#endif

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
        let initialState = await readInitialAppState()
        await emitter.emitColdLaunchSequence(initialAppState: initialState)
    }

    func handleDeepLink(url: URL, sourceApplication: String?) async {
        await emitter.handleDeepLink(
            url: url.absoluteString,
            sourceApplication: sourceApplication
        )
    }

    /// Reads current process foreground state. Hops to `MainActor` on iOS because
    /// `UIApplication.shared.applicationState` is main-actor isolated. Tests
    /// short-circuit via `initialStateOverride`.
    private func readInitialAppState() async -> AppForegroundState {
        if let override = initialStateOverride { return override }
        #if canImport(UIKit)
        return await MainActor.run {
            switch UIApplication.shared.applicationState {
            case .active: return AppForegroundState.active
            case .inactive: return .inactive
            case .background: return .background
            @unknown default: return .active
            }
        }
        #else
        return .active
        #endif
    }
}
