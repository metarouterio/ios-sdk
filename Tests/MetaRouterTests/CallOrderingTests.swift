import XCTest
@testable import MetaRouter

/// Back-to-back host calls must run in call order, through the proxy and the client.
/// A Task per call let `identify("u1"); track("Purchase")` enrich the track first and
/// ship it without the userId. One call pair rarely loses the race, so these run
/// many in a row.
final class CallOrderingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.callOrdering.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metarouter-call-ordering-\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
        defaults = nil
        suiteName = nil
        tempDir = nil
        super.tearDown()
    }

    private func makeClient(recorder: BodyRecordingNetworking) async -> AnalyticsClient {
        let options = InitOptions(writeKey: "wk", ingestionHost: URL(string: "https://example.com")!, flushIntervalSeconds: 999)
        var deps = AnalyticsDependencies()
        deps.persistentQueue = PersistentEventQueue(diskStore: DiskStorage(baseDirectory: tempDir), maxEventCount: 1000)
        deps.networking = recorder
        deps.networkMonitor = StubNetworkMonitor(status: .connected)
        deps.identityStorage = IdentityStorage(userDefaults: defaults)
        deps.sessionStorage = SessionStorage(userDefaults: defaults)
        deps.consentStorage = ConsentStorage(userDefaults: defaults)
        deps.providerContextStorage = ProviderContextStorage(userDefaults: defaults)
        deps.lifecycleStorage = LifecycleStorage(userDefaults: defaults)
        deps.dispatcherConfig = Dispatcher.Config(
            endpointPath: "/v1/batch", timeoutMs: 1000, autoFlushThreshold: 9999, initialMaxBatchSize: 1000
        )
        let client = AnalyticsClient.initialize(options: options, deps: deps)
        _ = await client.getAnonymousId()
        return client
    }

    private func postedEvents(_ client: AnalyticsClient, _ recorder: BodyRecordingNetworking,
                              where include: @escaping ([String: Any]) -> Bool,
                              count: Int) async -> [[String: Any]] {
        var events: [[String: Any]] = []
        let posted = await TestUtilities.waitFor(timeout: 10) {
            client.flush()
            events = recorder.bodies.flatMap { body -> [[String: Any]] in
                let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                return object?["batch"] as? [[String: Any]] ?? []
            }.filter(include)
            return events.count >= count
        }
        XCTAssertTrue(posted, "expected \(count) events, got \(events.count)")
        return events
    }

    func testTrackRightAfterIdentifyCarriesThatUserIdThroughTheProxy() async {
        let recorder = BodyRecordingNetworking()
        let client = await makeClient(recorder: recorder)
        let proxy = AnalyticsProxy(
            consentManager: ConsentManager(storage: ConsentStorage(userDefaults: defaults)),
            providerContextManager: ProviderContextManager(storage: ProviderContextStorage(userDefaults: defaults)),
            identityStorage: IdentityStorage(userDefaults: defaults)
        )
        await proxy._bindAndReplay(client)

        let rounds = 50
        for i in 0..<rounds {
            proxy.identify("u\(i)")
            proxy.track("t\(i)")
        }

        let events = await postedEvents(client, recorder, where: {
            $0["type"] as? String == "identify" || ($0["event"] as? String)?.hasPrefix("t") == true
        }, count: rounds * 2)

        var expected: [String] = []
        for i in 0..<rounds { expected += ["identify:u\(i)", "track:t\(i)"] }
        XCTAssertEqual(events.map { "\($0["type"] as? String ?? ""):\(($0["event"] as? String) ?? ($0["userId"] as? String) ?? "")" },
                       expected, "events must leave in call order")
        for event in events where event["type"] as? String == "track" {
            let name = event["event"] as? String ?? ""
            XCTAssertEqual(event["userId"] as? String, "u" + name.dropFirst(),
                           "\(name) must carry the userId identified right before it")
        }
    }

    func testCallsQueuedBeforeBindReplayInCallOrder() async {
        for _ in 0..<50 {
            let proxy = AnalyticsProxy()
            let mock = MockAnalyticsInterface()
            for i in 0..<10 {
                proxy.identify("u\(i)")
                proxy.track("t\(i)")
            }
            proxy.bind(mock)
            let forwarded = await TestUtilities.waitFor { mock.callCount == 20 }
            XCTAssertTrue(forwarded)

            var expected: [AnalyticsCall] = []
            for i in 0..<10 {
                expected += [.identify(userId: "u\(i)", traits: nil), .track(event: "t\(i)", properties: nil)]
            }
            XCTAssertEqual(mock.calls, expected)
        }
    }
}
