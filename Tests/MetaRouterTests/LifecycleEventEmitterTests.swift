import XCTest
@testable import MetaRouter

/// Unit tests for `LifecycleEventEmitter`. Each test owns:
///   - a unique UserDefaults suite (lifecycle + identity storage isolation)
///   - a real `EventEnrichmentService` over a stub `ContextProvider`
///   - a real `Dispatcher` whose memory queue we drain directly to inspect emits
///
/// `Dispatcher.offer` does not auto-flush below `autoFlushThreshold` (20), so
/// 1–2 emitted events stay in the queue and we drain them to assert.
final class LifecycleEventEmitterTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var queue: PersistentEventQueue!
    private var dispatcher: Dispatcher!
    private var enrichmentService: EventEnrichmentService!
    private var identityStorage: IdentityStorage!
    private var lifecycleStorage: LifecycleStorage!
    private let appContext = AppContext(name: "test-app", version: "1.5.0", build: "42", namespace: "com.metarouter.test")

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.metarouter.test.lifecycleEmitter.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        identityStorage = IdentityStorage(userDefaults: defaults)
        lifecycleStorage = LifecycleStorage(userDefaults: defaults)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metarouter-emitter-\(UUID().uuidString)")
        let diskStore = DiskStorage(baseDirectory: tempDir)
        queue = PersistentEventQueue(diskStore: diskStore, maxEventCount: 1000)

        let options = TestDataFactory.makeInitOptions()
        dispatcher = Dispatcher(
            options: options,
            http: SilentNetworking(),
            persistentQueue: queue,
            // Push thresholds high so offer() doesn't auto-flush during tests.
            config: Dispatcher.Config(
                endpointPath: "/v1/batch",
                timeoutMs: 8000,
                autoFlushThreshold: 9999,
                initialMaxBatchSize: 100
            )
        )

        let identityManager = IdentityManager(
            storage: identityStorage,
            writeKey: options.writeKey,
            host: options.ingestionHost.absoluteString
        )
        enrichmentService = EventEnrichmentService(
            contextProvider: StubContextProvider(),
            identityManager: identityManager,
            writeKey: options.writeKey
        )
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        queue = nil
        dispatcher = nil
        enrichmentService = nil
        identityStorage = nil
        lifecycleStorage = nil
        try await super.tearDown()
    }

    // cold launch

    func testColdLaunchFreshInstallEmitsInstalledThenOpened() async {
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .active)

        let events = await drain()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "Application Installed")
        XCTAssertEqual(events[1].event, "Application Opened")

        XCTAssertEqual(events[0].properties?["version"], .string("1.5.0"))
        XCTAssertEqual(events[0].properties?["build"], .string("42"))

        XCTAssertEqual(events[1].properties?["from_background"], .bool(false))
        XCTAssertEqual(events[1].properties?["version"], .string("1.5.0"))
        XCTAssertEqual(events[1].properties?["build"], .string("42"))

        XCTAssertEqual(lifecycleStorage.getVersion(), "1.5.0")
        XCTAssertEqual(lifecycleStorage.getBuild(), "42")
    }

    /// Existing user upgrading from a pre-lifecycle SDK build:
    /// no lifecycle storage, but identity storage already exists. Should be
    /// `Application Updated{previous_*=unknown}`, NOT `Application Installed`.
    func testColdLaunchSdkUpgradeEmitsUpdatedThenOpened() async {
        identityStorage.set(.anonymousId, value: "existing-anon")
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .active)

        let events = await drain()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "Application Updated")
        XCTAssertEqual(events[0].properties?["previous_version"], .string("unknown"))
        XCTAssertEqual(events[0].properties?["previous_build"], .string("unknown"))
        XCTAssertEqual(events[0].properties?["version"], .string("1.5.0"))
        XCTAssertEqual(events[0].properties?["build"], .string("42"))

        XCTAssertEqual(events[1].event, "Application Opened")
        XCTAssertEqual(events[1].properties?["from_background"], .bool(false))
    }

    func testColdLaunchSameVersionEmitsOnlyOpened() async {
        lifecycleStorage.setVersionBuild(version: "1.5.0", build: "42")
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .active)

        let events = await drain()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "Application Opened")
        XCTAssertEqual(events[0].properties?["from_background"], .bool(false))
    }

    func testColdLaunchVersionDifferenceEmitsUpdatedThenOpened() async {
        lifecycleStorage.setVersionBuild(version: "1.5.0", build: "37")
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .active)

        let events = await drain()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "Application Updated")
        XCTAssertEqual(events[0].properties?["previous_version"], .string("1.5.0"))
        XCTAssertEqual(events[0].properties?["previous_build"], .string("37"))
        XCTAssertEqual(events[0].properties?["version"], .string("1.5.0"))
        XCTAssertEqual(events[0].properties?["build"], .string("42"))

        XCTAssertEqual(events[1].event, "Application Opened")
    }

    /// Build-only changes count as Updated (parity with Android plan).
    func testColdLaunchBuildOnlyDifferenceEmitsUpdated() async {
        lifecycleStorage.setVersionBuild(version: "1.5.0", build: "41")
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .active)

        let events = await drain()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "Application Updated")
        XCTAssertEqual(events[0].properties?["previous_version"], .string("1.5.0"))
        XCTAssertEqual(events[0].properties?["previous_build"], .string("41"))
    }

    /// Background-launched processes (silent push, background fetch) suppress
    /// the cold-launch Opened. The next true foreground entry emits it.
    func testColdLaunchInBackgroundSuppressesOpenedUntilForeground() async {
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .background)

        var events = await drain()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "Application Installed")

        // First foreground entry emits Opened with from_background:false (cold-launch bridge)
        await emitter.emitForegroundFromBackground()
        events = await drain()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "Application Opened")
        XCTAssertEqual(events[0].properties?["from_background"], .bool(false))
    }

    // foreground / background

    func testBackgroundedEmitsApplicationBackgrounded() async {
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .active)
        _ = await drain()

        await emitter.emitBackgrounded()
        let events = await drain()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "Application Backgrounded")
        // Spec: empty properties payload (Codable encodes nil as omitted)
        XCTAssertNil(events[0].properties)
    }

    func testForegroundAfterBackgroundEmitsOpenedFromBackground() async {
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .active)
        await emitter.emitBackgrounded()
        _ = await drain()

        await emitter.emitForegroundFromBackground()
        let events = await drain()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "Application Opened")
        XCTAssertEqual(events[0].properties?["from_background"], .bool(true))
    }

    /// `inactive → active` transitions (Control Center, FaceID prompt, system
    /// alert) must NOT emit Application Opened. Only `background → active` does.
    func testInactiveToActiveTransitionDoesNotEmit() async {
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .active)
        _ = await drain()

        // Simulate Control Center: didBecomeActive fires without prior didEnterBackground.
        // lastTrackedAppState was .active → still .active → no emit.
        await emitter.emitForegroundFromBackground()
        let events = await drain()
        XCTAssertTrue(events.isEmpty,
                      "inactive→active transition must not emit Application Opened")
    }

    /// First `didBecomeActive` during init should NOT double-emit. Cold-launch
    /// path is the sole producer of the first Opened — the observer's didBecomeActive
    /// is suppressed until cold-launch flips `coldLaunchEmitted`.
    func testFirstForegroundCallBeforeColdLaunchIsSuppressed() async {
        let emitter = makeEmitter()
        // Imagine the observer's didBecomeActive arriving before emitColdLaunchSequence.
        await emitter.emitForegroundFromBackground()
        let preCold = await drain()
        XCTAssertTrue(preCold.isEmpty,
                      "Foreground call before cold launch must suppress (cold-launch path is sole producer)")

        await emitter.emitColdLaunchSequence(initialAppState: .active)
        let cold = await drain()
        XCTAssertEqual(cold.count, 2, "Cold launch should still emit Installed + Opened")
        XCTAssertEqual(cold[0].event, "Application Installed")
        XCTAssertEqual(cold[1].event, "Application Opened")
    }

    /// Second background→active cycle still emits with from_background:true.
    func testTwoBackgroundForegroundCyclesEmitOpenedTwice() async {
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .active)
        _ = await drain()

        await emitter.emitBackgrounded()
        await emitter.emitForegroundFromBackground()
        var events = await drain()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "Application Backgrounded")
        XCTAssertEqual(events[1].event, "Application Opened")
        XCTAssertEqual(events[1].properties?["from_background"], .bool(true))

        await emitter.emitBackgrounded()
        await emitter.emitForegroundFromBackground()
        events = await drain()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].event, "Application Opened")
        XCTAssertEqual(events[1].properties?["from_background"], .bool(true))
    }

    // deep-link buffer

    func testRecordOpenedURLAttachesUrlAndReferringApplicationToNextOpened() async {
        let emitter = makeEmitter()
        await emitter.recordOpenedURL(
            url: "myapp://product/42",
            sourceApplication: "com.example.referrer"
        )
        await emitter.emitColdLaunchSequence(initialAppState: .active)

        let events = await drain()
        XCTAssertEqual(events.count, 2)
        let opened = events[1]
        XCTAssertEqual(opened.event, "Application Opened")
        XCTAssertEqual(opened.properties?["url"], .string("myapp://product/42"))
        XCTAssertEqual(opened.properties?["referring_application"], .string("com.example.referrer"))
    }

    func testDeepLinkBufferIsOneShot() async {
        let emitter = makeEmitter()
        await emitter.recordOpenedURL(url: "myapp://x", sourceApplication: nil)
        await emitter.emitColdLaunchSequence(initialAppState: .active)
        _ = await drain()

        // Second Opened (background→active) without a new recordOpenedURL should not
        // carry buffered URL.
        await emitter.emitBackgrounded()
        await emitter.emitForegroundFromBackground()
        let events = await drain()
        XCTAssertEqual(events.count, 2)
        let opened = events[1]
        XCTAssertEqual(opened.event, "Application Opened")
        XCTAssertNil(opened.properties?["url"])
        XCTAssertNil(opened.properties?["referring_application"])
    }

    func testRecordOpenedURLWithoutSourceOmitsReferringApplication() async {
        let emitter = makeEmitter()
        await emitter.recordOpenedURL(url: "myapp://x", sourceApplication: nil)
        await emitter.emitColdLaunchSequence(initialAppState: .active)

        let events = await drain()
        let opened = events[1]
        XCTAssertEqual(opened.properties?["url"], .string("myapp://x"))
        XCTAssertNil(opened.properties?["referring_application"],
                     "Optional source must be omitted, not emitted as null")
    }

    /// Cold launch in `.inactive` state (rare but possible — pulled-down
    /// notification banner mid-launch, etc.) should suppress just like
    /// `.background` does. The bridge fires on the next true foreground entry.
    func testColdLaunchInInactiveSuppressesOpenedUntilForeground() async {
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .inactive)

        var events = await drain()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "Application Installed")

        await emitter.emitForegroundFromBackground()
        events = await drain()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "Application Opened")
        XCTAssertEqual(events[0].properties?["from_background"], .bool(false))
    }

    /// Deep-link buffered before a cold launch that was suppressed (background-
    /// launched process woken by a deep link) survives the suppression and
    /// attaches to the bridge `Application Opened` when the user actually
    /// foregrounds the app.
    func testDeepLinkSurvivesSuppressedColdLaunch() async {
        let emitter = makeEmitter()
        await emitter.recordOpenedURL(url: "myapp://promo/42", sourceApplication: "com.example.referrer")
        await emitter.emitColdLaunchSequence(initialAppState: .background)
        _ = await drain()

        await emitter.emitForegroundFromBackground()
        let events = await drain()
        XCTAssertEqual(events.count, 1)
        let opened = events[0]
        XCTAssertEqual(opened.event, "Application Opened")
        XCTAssertEqual(opened.properties?["url"], .string("myapp://promo/42"))
        XCTAssertEqual(opened.properties?["referring_application"], .string("com.example.referrer"))
    }

    /// `emitBackgrounded` does NOT consume the deep-link buffer — buffer is
    /// one-shot per `Application Opened`, not per any-emit.
    func testBackgroundedDoesNotConsumeDeepLinkBuffer() async {
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .active)
        _ = await drain()

        await emitter.recordOpenedURL(url: "myapp://x", sourceApplication: nil)
        await emitter.emitBackgrounded()
        let bgEvents = await drain()
        XCTAssertEqual(bgEvents.count, 1)
        XCTAssertEqual(bgEvents[0].event, "Application Backgrounded")
        XCTAssertNil(bgEvents[0].properties?["url"],
                     "Backgrounded must never carry deep-link properties")

        // Buffer should still be intact and attach to the next Opened.
        await emitter.emitForegroundFromBackground()
        let resumeEvents = await drain()
        XCTAssertEqual(resumeEvents.count, 1)
        XCTAssertEqual(resumeEvents[0].event, "Application Opened")
        XCTAssertEqual(resumeEvents[0].properties?["url"], .string("myapp://x"))
    }

    /// Same-bundle no-op cold launch (no install/update event) must still
    /// persist `(version, build)` so subsequent launches see them as "seen".
    func testSameVersionColdLaunchStillPersistsVersionBuild() async {
        // Pre-seed with current bundle's (version, build) — same as `metadata`.
        lifecycleStorage.setVersionBuild(version: "1.5.0", build: "42")
        let emitter = makeEmitter()
        await emitter.emitColdLaunchSequence(initialAppState: .active)
        _ = await drain()

        // Storage values should still match — and crucially, this would also
        // catch a regression where the no-op path skipped the persist call.
        XCTAssertEqual(lifecycleStorage.getVersion(), "1.5.0")
        XCTAssertEqual(lifecycleStorage.getBuild(), "42")
    }

    /// Defensive: `emitBackgrounded` called before any cold-launch sequence
    /// is suppressed. Race scenario — process woken in `.background`, observer
    /// already registered, `didEnterBackground` arriving before async
    /// `initTask → onReady` fires. Without the guard, we'd emit Backgrounded
    /// with no preceding Opened, which is a spec violation.
    func testBackgroundedBeforeColdLaunchIsSuppressed() async {
        let emitter = makeEmitter()
        await emitter.emitBackgrounded()
        let events = await drain()
        XCTAssertTrue(events.isEmpty,
                      "Backgrounded before cold launch must be suppressed to preserve event ordering")
    }

    // helpers

    private func makeEmitter() -> LifecycleEventEmitter {
        return LifecycleEventEmitter(
            enrichmentService: enrichmentService,
            dispatcher: dispatcher,
            storage: lifecycleStorage,
            identityStorage: identityStorage,
            appContext: appContext
        )
    }

    private func drain() async -> [EnrichedEventPayload] {
        return await queue.drain(max: 100)
    }
}

/// Networking stub that swallows every request so flushes have no side-effects
/// in tests that nonetheless drive the dispatcher path.
private final class SilentNetworking: Networking, @unchecked Sendable {
    func postJSON(url: URL, body: Data, timeoutMs: Int, additionalHeaders: [String: String]?) async throws -> NetworkResponse {
        return NetworkResponse(statusCode: 200, headers: [:], body: nil)
    }
    func parseRetryAfterMs(from headers: [String: String]) -> Int? { nil }
}

/// Minimal context provider for enrichment tests — returns a deterministic
/// EventContext without touching real platform APIs.
private struct StubContextProvider: ContextProvider {
    func getContext() async -> EventContext {
        return EventContext(
            app: AppContext(name: "test-app", version: "1.5.0", build: "42", namespace: "com.metarouter.test"),
            device: DeviceContext(manufacturer: "Apple", model: "test-model", type: "ios"),
            library: LibraryContext(name: "metarouter-ios-sdk", version: MetaRouterSDK.version),
            os: OSContext(name: "iOS", version: "18.0"),
            screen: ScreenContext(density: 2.0, width: 100, height: 100),
            network: nil,
            locale: "en_US",
            timezone: "UTC"
        )
    }

    func clearCache() {}
}
