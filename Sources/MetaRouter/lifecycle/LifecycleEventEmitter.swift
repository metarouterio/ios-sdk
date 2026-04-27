import Foundation

/// Process-level foreground state used to gate cold-launch and resume emits.
public enum AppForegroundState: Sendable, Equatable {
    case active
    case inactive
    case background
}

internal enum LifecycleEventNames {
    static let applicationInstalled = "Application Installed"
    static let applicationUpdated = "Application Updated"
    static let applicationOpened = "Application Opened"
    static let applicationBackgrounded = "Application Backgrounded"
}

internal enum LifecycleEventProperties {
    static let version = "version"
    static let build = "build"
    static let previousVersion = "previous_version"
    static let previousBuild = "previous_build"
    static let fromBackground = "from_background"
    static let url = "url"
    static let referringApplication = "referring_application"
}

/// Owns install/update detection, cold-launch vs. resume disambiguation, and
/// the choreography for emitting the four `Application *` lifecycle events.
///
/// The emitter is an `actor` so internal flags (`coldLaunchEmitted`,
/// `coldLaunchSuppressed`, `lastTrackedAppState`, `pendingDeepLink`) are
/// serialised against any concurrent foreground/background notification.
internal actor LifecycleEventEmitter {
    private let enrichmentService: EventEnrichmentService
    private let dispatcher: Dispatcher
    private let storage: LifecycleStorage
    private let appContext: AppContext
    private let hadIdentityBeforeInit: Bool

    private var coldLaunchEmitted: Bool = false
    private var coldLaunchSuppressed: Bool = false
    private var lastTrackedAppState: AppForegroundState = .active
    private var pendingDeepLink: PendingDeepLink?

    private struct PendingDeepLink {
        let url: String
        let source: String?
    }

    init(
        enrichmentService: EventEnrichmentService,
        dispatcher: Dispatcher,
        storage: LifecycleStorage = LifecycleStorage(),
        identityStorage: IdentityStorage = IdentityStorage(),
        appContext: AppContext
    ) {
        self.enrichmentService = enrichmentService
        self.dispatcher = dispatcher
        self.storage = storage
        self.appContext = appContext
        // Snapshot before IdentityManager.initialize() auto-creates an anonymousId,
        // so we can tell a true fresh install (no identity) from an existing user
        // upgrading to a lifecycle-aware SDK build (identity already present).
        self.hadIdentityBeforeInit = identityStorage.hasAnyValue()
    }

    /// Runs once after `AnalyticsClient.lifecycleState = .ready`.
    ///
    /// 1. Compares the persisted `(version, build)` against the current bundle values.
    /// 2. Emits `Application Installed` (true fresh install) or `Application Updated`
    ///    (build/version drift, or first lifecycle launch with prior identity).
    /// 3. Persists current `(version, build)`.
    /// 4. Emits `Application Opened` with `from_background: false` IF the process is
    ///    in the foreground at emit time. Background-launched processes (silent push,
    ///    background fetch) suppress the cold-launch Opened; the next
    ///    `background → active` transition emits instead.
    func emitColdLaunchSequence(initialAppState: AppForegroundState) async {
        let prevVersion = storage.getVersion()
        let prevBuild = storage.getBuild()
        let curr = appContext

        if prevVersion == nil && prevBuild == nil {
            if hadIdentityBeforeInit {
                // Existing user upgrading from a pre-lifecycle SDK build —
                // avoid spurious install spike for the upgraded population.
                await emit(
                    LifecycleEventNames.applicationUpdated,
                    properties: [
                        LifecycleEventProperties.version: .string(curr.version),
                        LifecycleEventProperties.build: .string(curr.build),
                        LifecycleEventProperties.previousVersion: .string("unknown"),
                        LifecycleEventProperties.previousBuild: .string("unknown"),
                    ]
                )
            } else {
                await emit(
                    LifecycleEventNames.applicationInstalled,
                    properties: [
                        LifecycleEventProperties.version: .string(curr.version),
                        LifecycleEventProperties.build: .string(curr.build),
                    ]
                )
            }
        } else if prevVersion != curr.version || prevBuild != curr.build {
            await emit(
                LifecycleEventNames.applicationUpdated,
                properties: [
                    LifecycleEventProperties.version: .string(curr.version),
                    LifecycleEventProperties.build: .string(curr.build),
                    LifecycleEventProperties.previousVersion: .string(prevVersion ?? "unknown"),
                    LifecycleEventProperties.previousBuild: .string(prevBuild ?? "unknown"),
                ]
            )
        }

        storage.setVersionBuild(version: curr.version, build: curr.build)
        lastTrackedAppState = initialAppState

        if initialAppState == .active {
            await emitOpened(fromBackground: false)
            coldLaunchEmitted = true
        } else {
            // Process was woken in background — defer to the next true foreground entry.
            coldLaunchSuppressed = true
        }
    }

    /// Called from `AppLifecycleObserver.onForeground` (didBecomeActive).
    /// No-ops in three cases:
    ///   1. `coldLaunchSuppressed` was set because cold-launch ran in non-active state —
    ///      emit `Application Opened {from_background: false}` here as the cold-launch bridge.
    ///   2. `coldLaunchEmitted == false` — first didBecomeActive on launch; the cold-launch
    ///      path is the sole producer of the first Opened. Suppress.
    ///   3. `lastTrackedAppState != .background` — `inactive → active` transition
    ///      (Control Center, FaceID prompt, system alert). Only `background → active` emits.
    func emitForegroundFromBackground() async {
        if coldLaunchSuppressed {
            await emitOpened(fromBackground: false)
            coldLaunchSuppressed = false
            coldLaunchEmitted = true
            lastTrackedAppState = .active
            return
        }

        guard coldLaunchEmitted else {
            // First didBecomeActive during init — cold-launch path will (or did) emit.
            lastTrackedAppState = .active
            return
        }

        let wasBackground = lastTrackedAppState == .background
        lastTrackedAppState = .active
        guard wasBackground else { return }

        await emitOpened(fromBackground: true)
    }

    /// Called from `AppLifecycleObserver.onBackgroundAsync` BEFORE the dispatcher
    /// flushes to disk so the event is captured by `flushToDisk()`.
    func emitBackgrounded() async {
        lastTrackedAppState = .background
        let event = await enrichmentService.createTrackEvent(
            event: LifecycleEventNames.applicationBackgrounded,
            properties: nil
        )
        await dispatcher.offer(event)
    }

    /// Buffers a deep-link URL (and optional source application) to be attached
    /// to the next `Application Opened` event. One-shot — cleared on emit.
    func openURL(url: String, sourceApplication: String?) {
        pendingDeepLink = PendingDeepLink(url: url, source: sourceApplication)
    }

    private func emitOpened(fromBackground: Bool) async {
        var properties: [String: CodableValue] = [
            LifecycleEventProperties.fromBackground: .bool(fromBackground),
            LifecycleEventProperties.version: .string(appContext.version),
            LifecycleEventProperties.build: .string(appContext.build),
        ]
        if let buf = pendingDeepLink {
            properties[LifecycleEventProperties.url] = .string(buf.url)
            if let source = buf.source {
                properties[LifecycleEventProperties.referringApplication] = .string(source)
            }
            pendingDeepLink = nil
        }
        await emit(LifecycleEventNames.applicationOpened, properties: properties)
    }

    private func emit(_ name: String, properties: [String: CodableValue]?) async {
        let event = await enrichmentService.createTrackEvent(
            event: name,
            properties: properties
        )
        await dispatcher.offer(event)
    }
}
