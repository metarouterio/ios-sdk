import XCTest
@testable import MetaRouter

/// Consent on the wire: a real `AnalyticsClient` enriches, dispatches, and POSTs,
/// and the assertions read the request body. Covers both entry points — a native
/// `track()` and the WebView bridge sink — so neither depends on a hand-built
/// payload matching the path production takes.
final class ConsentClientPayloadTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.consentClientPayload.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metarouter-consent-payload-\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
        defaults = nil
        suiteName = nil
        tempDir = nil
        super.tearDown()
    }

    private func makeClient(
        consentManager: ConsentManager,
        providerContextManager: ProviderContextManager? = nil,
        recorder: BodyRecordingNetworking
    ) async -> AnalyticsClient {
        let options = InitOptions(writeKey: "wk", ingestionHost: URL(string: "https://example.com")!, flushIntervalSeconds: 999)
        var deps = AnalyticsDependencies()
        deps.persistentQueue = PersistentEventQueue(diskStore: DiskStorage(baseDirectory: tempDir), maxEventCount: 1000)
        deps.networking = recorder
        deps.networkMonitor = StubNetworkMonitor(status: .connected)
        deps.identityManager = IdentityManager(
            storage: IdentityStorage(userDefaults: defaults), writeKey: options.writeKey, host: options.ingestionHost.absoluteString
        )
        deps.sessionStorage = SessionStorage(userDefaults: defaults)
        deps.consentManager = consentManager
        deps.providerContextManager = providerContextManager
        deps.providerContextStorage = ProviderContextStorage(userDefaults: defaults)
        deps.dispatcherConfig = Dispatcher.Config(
            endpointPath: "/v1/batch", timeoutMs: 1000, autoFlushThreshold: 9999, initialMaxBatchSize: 100
        )
        let client = AnalyticsClient.initialize(options: options, deps: deps)
        _ = await client.getAnonymousId()
        try? await Task.sleep(nanoseconds: 200_000_000)
        return client
    }

    private func makeConsentManager() -> ConsentManager {
        let manager = ConsentManager(storage: ConsentStorage(userDefaults: defaults))
        manager.registerConsentCategories([ConsentCategory(key: "c0001", defaultOptOut: false), ConsentCategory(key: "c0004")])
        manager.setConsent(Consent(explicit: true, optOut: ["C0004": false], timestamp: 1_757_400_000_000))
        return manager
    }

    /// Flushes until a POST lands and returns its first event as raw JSON. Repeated,
    /// because enrichment is asynchronous: a flush before the event reaches the
    /// queue sends nothing.
    private func firstPostedEvent(_ client: AnalyticsClient, _ recorder: BodyRecordingNetworking) async throws -> [String: Any] {
        let posted = await TestUtilities.waitFor(timeout: 2) {
            client.flush()
            return !recorder.bodies.isEmpty
        }
        XCTAssertTrue(posted, "nothing was POSTed")
        let body = try XCTUnwrap(recorder.bodies.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let batch = try XCTUnwrap(object["batch"] as? [[String: Any]])
        return try XCTUnwrap(batch.first)
    }

    private func assertConsentBlock(_ event: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let context = try XCTUnwrap(event["context"] as? [String: Any], file: file, line: line)
        let consent = try XCTUnwrap(context["consent"] as? [String: Any], "context.consent missing", file: file, line: line)
        XCTAssertEqual(consent["explicit"] as? Bool, true, file: file, line: line)
        XCTAssertEqual(consent["optOut"] as? [String: Bool], ["c0001": false, "c0004": false], file: file, line: line)
        XCTAssertEqual(Set(consent.keys), ["explicit", "optOut"], "timestamp never reaches the wire", file: file, line: line)
        XCTAssertNil(event["consent"], "not top-level", file: file, line: line)
    }

    func testTrackPostsBodyWithContextConsent() async throws {
        let recorder = BodyRecordingNetworking()
        let client = await makeClient(consentManager: makeConsentManager(), recorder: recorder)

        client.track("Order Completed")

        let event = try await firstPostedEvent(client, recorder)
        XCTAssertEqual(event["event"] as? String, "Order Completed")
        try assertConsentBlock(event)
    }

    /// Enters through `enqueueBridgeEvent`, the sink the WebView message handler
    /// calls, so the stamp is checked on the overload the bridge actually uses.
    func testBridgeEventPostsBodyWithContextConsentAndPage() async throws {
        let recorder = BodyRecordingNetworking()
        let client = await makeClient(consentManager: makeConsentManager(), recorder: recorder)

        let accepted = client.enqueueBridgeEvent(BridgeEnvelope(
            version: 1,
            messageId: "bridge-1",
            type: .track,
            name: "Web Click",
            properties: ["sku": "abc"],
            sentAt: nil,
            page: PageContext(url: "https://shop.example.com/cart", title: "Cart"),
            source: nil
        ))
        XCTAssertTrue(accepted)

        let event = try await firstPostedEvent(client, recorder)
        XCTAssertEqual(event["event"] as? String, "Web Click")
        try assertConsentBlock(event)
        let page = (event["context"] as? [String: Any])?["page"] as? [String: Any]
        XCTAssertEqual(page?["url"] as? String, "https://shop.example.com/cart")
    }

    /// The bridge leg of provider context: a WebView page cannot know the app's
    /// vendor ids, so they must land on bridge events from the native side.
    func testBridgeEventPostsBodyWithProviderContext() async throws {
        let providers = ProviderContextManager(storage: ProviderContextStorage(userDefaults: defaults))
        providers.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123")
        let recorder = BodyRecordingNetworking()
        let client = await makeClient(consentManager: makeConsentManager(), providerContextManager: providers, recorder: recorder)

        XCTAssertTrue(client.enqueueBridgeEvent(BridgeEnvelope(
            version: 1, messageId: "bridge-2", type: .page, name: "Cart", properties: [:],
            sentAt: nil, page: PageContext(url: "https://shop.example.com/cart", title: "Cart"), source: nil
        )))

        let event = try await firstPostedEvent(client, recorder)
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        let block = try XCTUnwrap(context["providers"] as? [String: Any])
        XCTAssertEqual(block["googleFirebase"] as? [String: String], ["appInstanceId": "abc123"])
        XCTAssertNotNil(block["metarouter"], "session block alongside")
    }
}

private final class BodyRecordingNetworking: Networking, @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [Data] = []

    var bodies: [Data] { lock.withLock { _bodies } }

    func postJSON(url: URL, body: Data, timeoutMs: Int, additionalHeaders: [String: String]?) async throws -> NetworkResponse {
        lock.withLock { _bodies.append(body) }
        return NetworkResponse(statusCode: 200, headers: [:], body: nil)
    }

    func parseRetryAfterMs(from headers: [String: String]) -> Int? { nil }
}
