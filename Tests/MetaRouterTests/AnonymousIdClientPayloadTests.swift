import XCTest
@testable import MetaRouter

/// setAnonymousId on the wire: the proxy writes storage directly, and a real
/// `AnalyticsClient` over that same storage must stamp the host id on native and
/// bridge events — whether the write lands before the client exists or after.
final class AnonymousIdClientPayloadTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempDir: URL!
    private var proxy: AnalyticsProxy!

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.anonymousIdPayload.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metarouter-anon-payload-\(UUID().uuidString)")
        proxy = AnalyticsProxy(
            consentManager: ConsentManager(storage: ConsentStorage(userDefaults: defaults)),
            providerContextManager: ProviderContextManager(storage: ProviderContextStorage(userDefaults: defaults)),
            identityStorage: IdentityStorage(userDefaults: defaults)
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
        defaults = nil
        suiteName = nil
        tempDir = nil
        proxy = nil
        super.tearDown()
    }

    private func makeClient(recorder: BodyRecordingNetworking, defaults: UserDefaults? = nil) async -> AnalyticsClient {
        let defaults = defaults ?? self.defaults!
        let options = InitOptions(writeKey: "wk", ingestionHost: URL(string: "https://example.com")!, flushIntervalSeconds: 999)
        var deps = AnalyticsDependencies()
        deps.persistentQueue = PersistentEventQueue(diskStore: DiskStorage(baseDirectory: tempDir), maxEventCount: 1000)
        deps.networking = recorder
        deps.networkMonitor = StubNetworkMonitor(status: .connected)
        // Only the storage: the client builds its IdentityManager over it, the path
        // MetaRouter's shared instance takes.
        deps.identityStorage = IdentityStorage(userDefaults: defaults)
        deps.sessionStorage = SessionStorage(userDefaults: defaults)
        deps.consentStorage = ConsentStorage(userDefaults: defaults)
        deps.providerContextStorage = ProviderContextStorage(userDefaults: defaults)
        deps.dispatcherConfig = Dispatcher.Config(
            endpointPath: "/v1/batch", timeoutMs: 1000, autoFlushThreshold: 9999, initialMaxBatchSize: 100
        )
        let client = AnalyticsClient.initialize(options: options, deps: deps)
        _ = await client.getAnonymousId()
        try? await Task.sleep(nanoseconds: 200_000_000)
        return client
    }

    private func postedEvents(_ client: AnalyticsClient, _ recorder: BodyRecordingNetworking, count: Int) async throws -> [[String: Any]] {
        var events: [[String: Any]] = []
        let posted = await TestUtilities.waitFor(timeout: 2) {
            client.flush()
            events = recorder.bodies.flatMap { body -> [[String: Any]] in
                let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                return object?["batch"] as? [[String: Any]] ?? []
            }
            return events.count >= count
        }
        XCTAssertTrue(posted, "expected \(count) events, got \(events.count)")
        return events
    }

    func testSetBeforeClientExistsStampsNativeAndBridgeEvents() async throws {
        XCTAssertTrue(proxy.setAnonymousId("web-anon-1"))
        let recorder = BodyRecordingNetworking()
        let client = await makeClient(recorder: recorder)

        client.track("Order Completed")
        XCTAssertTrue(client.enqueueBridgeEvent(BridgeEnvelope(
            version: 1, messageId: "bridge-1", type: .track, name: "Web Click", properties: [:],
            sentAt: nil, page: nil, source: nil
        )))

        let events = try await postedEvents(client, recorder, count: 2)
        XCTAssertEqual(Set(events.compactMap { $0["event"] as? String }), ["Order Completed", "Web Click"])
        for event in events {
            XCTAssertEqual(event["anonymousId"] as? String, "web-anon-1", event["event"] as? String ?? "")
        }
    }

    /// The init window: the client exists and has loaded its own id, but the proxy
    /// has not bound it. The proxy's write must still reach the client's next event.
    func testSetAfterClientInitializedStampsTheNextEvent() async throws {
        let recorder = BodyRecordingNetworking()
        let client = await makeClient(recorder: recorder)
        let minted = await client.getAnonymousId()
        XCTAssertNotEqual(minted, "web-anon-1")

        XCTAssertTrue(proxy.setAnonymousId("web-anon-1"))
        client.track("After Handoff")

        let events = try await postedEvents(client, recorder, count: 1)
        XCTAssertEqual(events.first?["anonymousId"] as? String, "web-anon-1")
        let current = await client.getAnonymousId()
        XCTAssertEqual(current, "web-anon-1")
    }

    /// Once bound, the proxy hands the call to the client rather than writing its
    /// own storage, so the client's storage is the one that changes even when the
    /// two are not the same.
    func testBoundProxyForwardsToTheClient() async throws {
        let clientSuite = suiteName + ".client"
        let clientDefaults = try XCTUnwrap(UserDefaults(suiteName: clientSuite))
        defer { clientDefaults.removePersistentDomain(forName: clientSuite) }
        let recorder = BodyRecordingNetworking()
        let client = await makeClient(recorder: recorder, defaults: clientDefaults)
        await proxy._bindAndReplay(client)

        XCTAssertTrue(proxy.setAnonymousId("web-anon-1"))
        client.track("After Handoff")

        let events = try await postedEvents(client, recorder, count: 1)
        XCTAssertEqual(events.first?["anonymousId"] as? String, "web-anon-1")
        XCTAssertNil(IdentityStorage(userDefaults: defaults).get(.anonymousId), "the proxy's own storage is untouched")
    }

    // MARK: - reset() then setAnonymousId (logout adopting the web SDK's new id)

    /// Pre-bind: the reset is queued and replays at bind, after the set wrote storage.
    func testResetThenSetBeforeBindKeepsTheHostId() async throws {
        let recorder = BodyRecordingNetworking()
        let client = await makeClient(recorder: recorder)

        proxy.reset()
        XCTAssertTrue(proxy.setAnonymousId("web-anon-2"))
        try await Task.sleep(nanoseconds: 50_000_000)  // let the reset reach the queue
        await proxy._bindAndReplay(client)

        try await assertAnonymousIdAfterResetSettles("web-anon-2", client, recorder)
    }

    /// End-to-end smoke only: while bound, the reset's Task races the set, so this
    /// cannot force the clear to land after it. The ordering itself is guarded by
    /// the pre-bind test above and the IdentityManagerTests reset() ordering cases.
    func testResetThenSetWhileBoundKeepsTheHostId() async throws {
        let recorder = BodyRecordingNetworking()
        let client = await makeClient(recorder: recorder)
        await proxy._bindAndReplay(client)

        proxy.reset()
        XCTAssertTrue(proxy.setAnonymousId("web-anon-2"))

        try await assertAnonymousIdAfterResetSettles("web-anon-2", client, recorder)
    }

    func testSetThenResetWhileBoundDiscardsTheHostId() async throws {
        let recorder = BodyRecordingNetworking()
        let client = await makeClient(recorder: recorder)
        await proxy._bindAndReplay(client)

        XCTAssertTrue(proxy.setAnonymousId("web-anon-1"))
        proxy.reset()

        let cleared = await TestUtilities.waitFor(timeout: 2) {
            IdentityStorage(userDefaults: self.defaults).get(.anonymousId) == nil
        }
        XCTAssertTrue(cleared, "reset() discards an id set before it")
    }

    /// Waits for the asynchronous reset to have run (the client goes idle), then checks the id survived it and is on the next event.
    private func assertAnonymousIdAfterResetSettles(
        _ expected: String, _ client: AnalyticsClient, _ recorder: BodyRecordingNetworking,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let storage = IdentityStorage(userDefaults: defaults)
        var settled = false
        for _ in 0..<100 where !settled {
            settled = await client.getDebugInfo()["lifecycle"] == .string("idle")
            if !settled { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(settled, "reset never completed", file: file, line: line)
        XCTAssertEqual(storage.get(.anonymousId), expected, file: file, line: line)
        client.track("After Logout")
        let events = try await postedEvents(client, recorder, count: 1)
        XCTAssertEqual(events.first?["anonymousId"] as? String, expected, file: file, line: line)
    }
}
