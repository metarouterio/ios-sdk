import XCTest
@testable import MetaRouter

/// initialize, reset and an invalid-config disable take effect in call order
/// (sc-42966). As separate Tasks they ran in any order.
final class LifecycleOrderingTests: XCTestCase {
    /// Built with the debug assert silenced, as InitOptionsTests does.
    private func invalidOptions() -> InitOptions {
        let original = InitOptions.debugAssert
        InitOptions.debugAssert = { _ in }
        defer { InitOptions.debugAssert = original }
        return InitOptions(writeKey: "", ingestionHost: "https://example.com")
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String?
        var value: String? { lock.lock(); defer { lock.unlock() }; return _value }
        func set(_ v: String) { lock.lock(); _value = v; lock.unlock() }
    }

    /// nil when it has not resolved in time (a waiter left suspended for good).
    private func anonymousId(_ analytics: AnalyticsInterface) async -> String? {
        let box = Box()
        Task { box.set(await analytics.getAnonymousId()) }
        _ = await TestUtilities.waitFor(timeout: 2) { box.value != nil }
        return box.value
    }

    override func tearDown() async throws {
        await MetaRouter.Analytics.resetAndWait()
        // These drive the static MetaRouter, whose clients persist identity and
        // sessions to UserDefaults.standard (which outlives the process). Keys removed
        // directly: IdentityStorage.clear() also consumes reset-ordering bookkeeping.
        let defaults = UserDefaults.standard
        let identityKeys: [IdentityStorageKey] = [.anonymousId, .userId, .groupId, .advertisingId]
        for key in identityKeys.map(\.rawValue) + [
            "metarouter:anonymous_id_host_set",
            SessionStorageKey.sessionId.rawValue,
            SessionStorageKey.sessionCount.rawValue,
            SessionStorageKey.lastActivityMs.rawValue,
        ] {
            defaults.removeObject(forKey: key)
        }
        try await super.tearDown()
    }

    func testAValidInitializeAfterAnInvalidOneWins() async {
        for round in 0..<20 {
            await MetaRouter.Analytics.resetAndWait()

            MetaRouter.Analytics.initialize(with: invalidOptions())
            let analytics = MetaRouter.Analytics.initialize(
                with: InitOptions(writeKey: "wk", ingestionHost: "https://example.com")
            )

            let id = await anonymousId(analytics)
            XCTAssertNotNil(id, "round \(round): getAnonymousId never resolved")
            XCTAssertNotEqual(id, "", "round \(round): answered from the refused session")
            let info = await analytics.getDebugInfo()
            XCTAssertEqual(info["proxy"]?.boolValue, false, "round \(round): the valid client is not bound")
        }
    }

    func testAnInitializeRightAfterResetBindsTheNewClient() async {
        for round in 0..<20 {
            await MetaRouter.Analytics.resetAndWait()
            _ = await MetaRouter.Analytics.initializeAndWait(
                with: InitOptions(writeKey: "wk-a111", ingestionHost: "https://example.com")
            )

            MetaRouter.Analytics.reset()
            let analytics = MetaRouter.Analytics.initialize(
                with: InitOptions(writeKey: "wk-b222", ingestionHost: "https://example.com")
            )

            let id = await anonymousId(analytics)
            XCTAssertNotNil(id, "round \(round): getAnonymousId never resolved")
            let info = await analytics.getDebugInfo()
            XCTAssertEqual(info["writeKey"], .string("***b222"), "round \(round): the second initialize was lost")
        }
    }

    func testACallMadeAfterAValidReInitializeReachesTheNewClient() async {
        await MetaRouter.Analytics.resetAndWait()

        MetaRouter.Analytics.initialize(with: invalidOptions())
        let analytics = MetaRouter.Analytics.initialize(
            with: InitOptions(writeKey: "wk", ingestionHost: "https://example.com", flushIntervalSeconds: 999)
        )
        analytics.track("after valid initialize")

        _ = await anonymousId(analytics)
        var length = 0
        for _ in 0..<50 where length == 0 {
            length = (await analytics.getDebugInfo())["queueLength"]?.intValue ?? 0
            if length == 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertEqual(length, 1, "the track was dropped with the refused session")
    }

    func testACallMadeAfterResetWaitsForTheNextClient() async {
        await MetaRouter.Analytics.resetAndWait()

        MetaRouter.Analytics.initialize(with: InitOptions(writeKey: "wk-a111", ingestionHost: "https://example.com"))
        MetaRouter.Analytics.reset()
        MetaRouter.Analytics.shared.track("after reset")
        let analytics = await MetaRouter.Analytics.initializeAndWait(
            with: InitOptions(writeKey: "wk-b222", ingestionHost: "https://example.com", flushIntervalSeconds: 999)
        )

        var info = await analytics.getDebugInfo()
        for _ in 0..<50 where (info["queueLength"]?.intValue ?? 0) == 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            info = await analytics.getDebugInfo()
        }
        XCTAssertEqual(info["writeKey"], .string("***b222"))
        XCTAssertEqual(info["queueLength"]?.intValue, 1, "the track went to the client reset() discarded")
    }

    /// A fallback initialize made from inside onConfigError is the host's last call,
    /// so it must win over the disable of the refused one.
    func testAFallbackInitializeFromOnConfigErrorBinds() async {
        await MetaRouter.Analytics.resetAndWait()
        let original = InitOptions.debugAssert
        InitOptions.debugAssert = { _ in }
        let refused = InitOptions(writeKey: "", ingestionHost: "https://example.com", onConfigError: { _ in
            MetaRouter.Analytics.initialize(
                with: InitOptions(writeKey: "wk-fall", ingestionHost: "https://example.com", flushIntervalSeconds: 999)
            )
        })
        InitOptions.debugAssert = original

        let analytics = MetaRouter.Analytics.initialize(with: refused)
        _ = await anonymousId(analytics)
        let info = await analytics.getDebugInfo()
        XCTAssertEqual(info["proxy"]?.boolValue, false, "nothing is bound")
        XCTAssertEqual(info["writeKey"], .string("***fall"))
    }

    /// While an initializeAndWait waits for its turn, calls wait for the new client
    /// (an identify sent to the old one would miss it), and none is dropped at the
    /// pipe's cap.
    func testCallsMadeWhileInitializeAndWaitWaitsReachTheNewClient() async {
        let proxy = AnalyticsProxy()
        let a = MockAnalyticsInterface(), b = MockAnalyticsInterface()
        proxy.bind(a)
        proxy.supersedeForInitialize()
        let epoch = proxy.lifecycleEpoch()
        for i in 0..<30 { proxy.track("e\(i)") }
        let didBind = await proxy._bindIfCurrent(b, epoch: epoch)

        XCTAssertTrue(didBind)
        XCTAssertEqual(a.callCount, 0)
        XCTAssertEqual(b.callCount, 30)
    }

    /// reset() lands while the first initialize is building its client (seen in the
    /// demo app): the identify made after it must reach the next client, not be
    /// replayed into the discarded one.
    func testAnIdentifyAfterAResetDuringInitializeReachesTheNextClient() async {
        var lost: [Int] = []
        for round in 0..<40 {
            await MetaRouter.Analytics.resetAndWait()

            MetaRouter.Analytics.initialize(
                with: InitOptions(writeKey: "wk-a111", ingestionHost: "https://example.com", flushIntervalSeconds: 999)
            )
            if round % 4 != 0 { usleep(useconds_t(round * 50)) }
            MetaRouter.Analytics.reset()
            MetaRouter.Analytics.shared.identify("u\(round)")
            let analytics = MetaRouter.Analytics.initialize(
                with: InitOptions(writeKey: "wk-b222", ingestionHost: "https://example.com", flushIntervalSeconds: 999)
            )

            _ = await anonymousId(analytics)
            var length = 0
            for _ in 0..<25 where length == 0 {
                length = (await analytics.getDebugInfo())["queueLength"]?.intValue ?? 0
                if length == 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            if length != 1 { lost.append(round) }
        }
        XCTAssertEqual(lost, [], "the identify went to the client reset() discarded")
    }
}

/// A client the SDK discards stops: its flush loop no longer keeps the dispatcher
/// (and its writeKey and host) running for the life of the process.
final class DiscardedClientShutdownTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.shutdown.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metarouter-shutdown-\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testShutdownReleasesTheDispatcher() async {
        await assertShutdownReleasesTheDispatcher(waitForInit: true)
    }

    /// Discarded before its init finished: init must not restart the flush loop.
    func testShutdownDuringInitReleasesTheDispatcher() async {
        await assertShutdownReleasesTheDispatcher(waitForInit: false)
    }


    /// The disk file is shared by every client, and the next one drains it. A
    /// discarded client that spilled to disk earlier (e.g. on backgrounding) must not
    /// drain it too: two queues on one file send duplicates.
    func testShutdownLeavesTheSharedDiskFileAlone() async {
        let recorder = BodyRecordingNetworking()
        let options = InitOptions(writeKey: "wk", ingestionHost: URL(string: "https://example.com")!, flushIntervalSeconds: 999)
        var deps = AnalyticsDependencies()
        let queue = PersistentEventQueue(diskStore: DiskStorage(baseDirectory: tempDir), maxEventCount: 100)
        deps.persistentQueue = queue
        deps.networking = recorder
        deps.networkMonitor = StubNetworkMonitor(status: .connected)
        deps.identityManager = IdentityManager(
            storage: IdentityStorage(userDefaults: defaults), writeKey: "wk", host: "https://example.com"
        )
        deps.sessionStorage = SessionStorage(userDefaults: defaults)
        deps.consentManager = ConsentManager(storage: ConsentStorage(userDefaults: defaults))
        deps.providerContextStorage = ProviderContextStorage(userDefaults: defaults)
        let client = AnalyticsClient.initialize(options: options, deps: deps)
        _ = await client.getAnonymousId()
        try? await Task.sleep(nanoseconds: 200_000_000)

        _ = await queue.enqueue(diskEvent())
        _ = await queue.flushMemoryToDisk()
        client.track("queued")
        client.shutdown()

        let flushed = await TestUtilities.waitFor(timeout: 5) { !recorder.bodies.isEmpty }
        XCTAssertTrue(flushed, "the queued event gets its one flush")
        try? await Task.sleep(nanoseconds: 300_000_000)
        let sent = recorder.bodies.map { String(decoding: $0, as: UTF8.self) }.joined()
        XCTAssertFalse(sent.contains("on-disk"), "the discarded client drained the shared disk file")
        let other = PersistentEventQueue(diskStore: DiskStorage(baseDirectory: tempDir), maxEventCount: 100)
        let stillOnDisk = await other.checkForPersistedEvents()
        XCTAssertTrue(stillOnDisk)
    }

    private func diskEvent() -> EnrichedEventPayload {
        let context = EventContext(
            app: AppContext(name: "a", version: "1", build: "1", namespace: "a"),
            device: DeviceContext(manufacturer: "a", model: "m", type: "t"),
            library: LibraryContext(name: "l", version: "1"),
            os: OSContext(name: "iOS", version: "1"),
            screen: ScreenContext(density: 2.0, width: 1, height: 1),
            network: nil,
            locale: "en_US",
            timezone: "UTC"
        )
        return EnrichedEventPayload(
            type: "track", event: "on-disk", userId: nil, anonymousId: "anon",
            properties: nil, traits: nil, integrations: nil,
            timestamp: ISO8601DateFormatter().string(from: Date()), writeKey: "other", messageId: "on-disk-1", context: context
        )
    }

    private func assertShutdownReleasesTheDispatcher(waitForInit: Bool) async {
        weak var weakDispatcher: Dispatcher?
        do {
            let options = InitOptions(writeKey: "wk", ingestionHost: URL(string: "https://example.com")!, flushIntervalSeconds: 1)
            let queue = PersistentEventQueue(diskStore: DiskStorage(baseDirectory: tempDir), maxEventCount: 100)
            let dispatcher = Dispatcher(options: options, http: BodyRecordingNetworking(), persistentQueue: queue)
            weakDispatcher = dispatcher
            var deps = AnalyticsDependencies()
            deps.persistentQueue = queue
            deps.dispatcher = dispatcher
            deps.networkMonitor = StubNetworkMonitor(status: .connected)
            deps.identityManager = IdentityManager(
                storage: IdentityStorage(userDefaults: defaults), writeKey: "wk", host: "https://example.com"
            )
            deps.sessionStorage = SessionStorage(userDefaults: defaults)
            deps.consentManager = ConsentManager(storage: ConsentStorage(userDefaults: defaults))
            deps.providerContextStorage = ProviderContextStorage(userDefaults: defaults)
            let client = AnalyticsClient.initialize(options: options, deps: deps)
            if waitForInit { _ = await client.getAnonymousId() }

            client.shutdown()
        }

        let released = await TestUtilities.waitFor(timeout: 5) { weakDispatcher == nil }
        XCTAssertTrue(released, "the flush loop still holds the discarded dispatcher")
    }
}
