import XCTest
@testable import MetaRouter

/// End-to-end consent behavior: through a real AnalyticsClient (payloads captured
/// at the network layer) and through the MetaRouter entry point (the process-wide
/// manager shared by proxy and client, surviving reset).
final class ConsentIntegrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    private static let registry = [
        ConsentCategory(key: "c0001", defaultOptOut: false),
        ConsentCategory(key: "c0002"),
        ConsentCategory(key: "c0004"),
    ]

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.consentIntegration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Direct client harness

    private struct Harness {
        let client: AnalyticsClient
        let manager: ConsentManager
        let queue: PersistentEventQueue
        let recorder: ConsentRecordingNetworking
        let tempDir: URL

        func collectEvents() async -> [EnrichedEventPayload] {
            let queued = await queue.drain(max: 100)
            return recorder.recorded + queued
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeHarness() -> Harness {
        let options = InitOptions(
            writeKey: "wk",
            ingestionHost: URL(string: "https://example.com")!,
            flushIntervalSeconds: 999
        )
        let manager = ConsentManager(storage: ConsentStorage(userDefaults: defaults), dispatch: { $0() })
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metarouter-consent-integration-\(UUID().uuidString)")
        let queue = PersistentEventQueue(diskStore: DiskStorage(baseDirectory: tempDir), maxEventCount: 1000)
        let recorder = ConsentRecordingNetworking()

        var deps = AnalyticsDependencies()
        deps.persistentQueue = queue
        deps.networking = recorder
        deps.consentManager = manager
        deps.sessionStorage = SessionStorage(userDefaults: defaults)
        deps.identityManager = IdentityManager(
            storage: IdentityStorage(userDefaults: defaults),
            writeKey: options.writeKey,
            host: options.ingestionHost.absoluteString
        )
        deps.identityStorage = IdentityStorage(userDefaults: defaults)
        deps.lifecycleStorage = LifecycleStorage(userDefaults: defaults)
        deps.appContext = AppContext(name: "test-app", version: "1.7.0", build: "42", namespace: "com.metarouter.test")
        deps.initialAppState = .active
        deps.dispatcherConfig = Dispatcher.Config(
            endpointPath: "/v1/batch", timeoutMs: 1000, autoFlushThreshold: 9999, initialMaxBatchSize: 100
        )

        let client = AnalyticsClient.initialize(options: options, deps: deps)
        return Harness(client: client, manager: manager, queue: queue, recorder: recorder, tempDir: tempDir)
    }

    private func poll(timeout: TimeInterval = 2.0, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func trackAndCollect(_ harness: Harness, _ event: String) async -> EnrichedEventPayload? {
        harness.client.track(event)
        var events: [EnrichedEventPayload] = []
        _ = await poll {
            events += await harness.collectEvents()
            return events.contains { $0.event == event }
        }
        return events.first { $0.event == event }
    }

    // MARK: - Payload shape through the real client

    func testEventBeforeAnySetCarriesImplicitDefault() async {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        _ = await harness.client.getAnonymousId()
        harness.client.registerConsentCategories(Self.registry)

        let payload = await trackAndCollect(harness, "Before")

        XCTAssertEqual(payload?.context.consent,
                       ConsentContext(explicit: false, optOut: ["c0001": false, "c0002": true, "c0004": true]))
    }

    func testSetConsentThenEventCarriesReconciledConsent() async {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        _ = await harness.client.getAnonymousId()
        harness.client.registerConsentCategories(Self.registry)

        harness.client.setConsent(OneTrustAdapter.normalize(["C0002": 1, "C0004": 0, "C0099": 1], explicit: true))
        let payload = await trackAndCollect(harness, "After")

        XCTAssertEqual(payload?.context.consent,
                       ConsentContext(explicit: true, optOut: ["c0001": false, "c0002": false, "c0004": true]))
    }

    func testClearConsentThenEventCarriesImplicitDefaultAgain() async {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        _ = await harness.client.getAnonymousId()
        harness.client.registerConsentCategories(Self.registry)
        harness.client.setConsent(Consent(explicit: true, optOut: ["c0002": false, "c0004": false]))
        _ = await trackAndCollect(harness, "Consented")

        harness.client.clearConsent()
        let payload = await trackAndCollect(harness, "Cleared")

        XCTAssertEqual(payload?.context.consent,
                       ConsentContext(explicit: false, optOut: ["c0001": false, "c0002": true, "c0004": true]))
    }

    func testLaterSetDoesNotRewriteAnEmittedEvent() async {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        _ = await harness.client.getAnonymousId()
        harness.client.registerConsentCategories(Self.registry)
        harness.client.setConsent(Consent(explicit: true, optOut: ["c0004": false]))
        let before = await trackAndCollect(harness, "Before")

        harness.client.setConsent(Consent(explicit: true, optOut: ["c0004": true]))
        let after = await trackAndCollect(harness, "After")

        XCTAssertEqual(before?.context.consent?.optOut["c0004"], false)
        XCTAssertEqual(after?.context.consent?.optOut["c0004"], true)
    }

    // MARK: - reset() vs clearConsent()

    func testResetLeavesConsentIntact() async {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        _ = await harness.client.getAnonymousId()
        harness.client.registerConsentCategories(Self.registry)
        harness.client.setConsent(Consent(explicit: true, optOut: ["c0002": false], timestamp: 7))

        harness.client.reset()
        _ = await poll { await harness.client.getDebugInfo()["lifecycle"] == .string("idle") }

        XCTAssertEqual(harness.client.getConsent().optOut, ["c0001": false, "c0002": false, "c0004": true])
        XCTAssertEqual(ConsentStorage(userDefaults: defaults).get()?.consent?.timestamp, 7, "still persisted")
    }

    func testDebugInfoCarriesConsent() async {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        harness.client.registerConsentCategories(Self.registry)
        harness.client.setConsent(Consent(explicit: true, optOut: ["c0002": false]))

        let info = await harness.client.getDebugInfo()

        XCTAssertEqual(info["consent"], .object([
            "explicit": .bool(true),
            "optOut": .object(["c0001": .bool(false), "c0002": .bool(false), "c0004": .bool(true)]),
        ]))
    }

    // MARK: - Through MetaRouter: one manager for proxy and client

    /// The MetaRouter entry point owns a process-wide manager over
    /// `UserDefaults.standard`. The test seam points it at this test's suite for the
    /// duration and back at standard afterwards, so nothing the test writes lands
    /// on the developer's machine or leaks into a parallel test.
    private func isolateSharedConsent() async {
        await MetaRouter.Analytics.resetAndWait()
        MetaRouter._consentManagerForTesting._replaceStorageForTesting(ConsentStorage(userDefaults: defaults))
        addTeardownBlock {
            await MetaRouter.Analytics.resetAndWait()
            MetaRouter._consentManagerForTesting._replaceStorageForTesting(ConsentStorage())
        }
    }

    func testConsentSetBeforeInitializeIsSeenByTheInitializedClientAndSurvivesReset() async {
        await isolateSharedConsent()

        let shared = MetaRouter.Analytics.shared
        shared.registerConsentCategories(Self.registry)
        shared.setConsent(Consent(explicit: true, optOut: ["c0004": false]))
        let expected = Consent(explicit: true, optOut: ["c0001": false, "c0002": true, "c0004": false])

        let client = await MetaRouter.Analytics.initializeAndWait(with: TestDataFactory.makeInitOptions())
        XCTAssertTrue(client.getConsent().sameDecision(as: expected), "proxy read after bind")

        let debug = await client.getDebugInfo()
        XCTAssertEqual(debug["proxy"], .bool(false), "debug info comes from the real client…")
        XCTAssertEqual(debug["consent"], .object([
            "explicit": .bool(true),
            "optOut": .object(["c0001": .bool(false), "c0002": .bool(true), "c0004": .bool(false)]),
        ]), "…which stamps from the same manager the pre-init set landed on")

        await MetaRouter.Analytics.resetAndWait()
        XCTAssertTrue(MetaRouter.Analytics.shared.getConsent().sameDecision(as: expected),
                      "reset clears identity, never consent")

        let reinitialized = await MetaRouter.Analytics.initializeAndWait(with: TestDataFactory.makeInitOptions())
        XCTAssertTrue(reinitialized.getConsent().sameDecision(as: expected), "re-initialized client sees it too")
    }
}

private final class ConsentRecordingNetworking: Networking, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [EnrichedEventPayload] = []

    var recorded: [EnrichedEventPayload] {
        lock.withLock { _events }
    }

    private struct Batch: Decodable {
        let batch: [EnrichedEventPayload]
    }

    func postJSON(url: URL, body: Data, timeoutMs: Int, additionalHeaders: [String: String]?) async throws -> NetworkResponse {
        if let decoded = try? JSONDecoder().decode(Batch.self, from: body) {
            lock.withLock { _events.append(contentsOf: decoded.batch) }
        }
        return NetworkResponse(statusCode: 200, headers: [:], body: nil)
    }

    func parseRetryAfterMs(from headers: [String: String]) -> Int? { nil }
}
