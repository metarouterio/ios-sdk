import XCTest
@testable import MetaRouter

/// Payload-attach for host-set provider context: every enriched event — whichever
/// factory or overload produced it, native or bridge-sourced — carries
/// `context.providers.<provider>.<key>` alongside the SDK's own `metarouter`
/// session block, read at enrichment time.
final class ProviderContextStampingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var providerContext: ProviderContextManager!
    private var service: EventEnrichmentService!
    private var savedDebugAssert: (@Sendable (String) -> Void)!

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.providerContextStamping.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        savedDebugAssert = ProviderContextManager.debugAssert
        ProviderContextManager.debugAssert = { _ in }
        providerContext = ProviderContextManager(
            storage: ProviderContextStorage(userDefaults: defaults)
        )
        service = EventEnrichmentService(
            contextProvider: MockContextProvider(),
            identityManager: IdentityManager(
                storage: IdentityStorage(userDefaults: defaults),
                writeKey: "test-key",
                host: "https://test.example.com"
            ),
            writeKey: "test-key",
            sessionManager: SessionManager(storage: SessionStorage(userDefaults: defaults)),
            consentManager: ConsentManager(
                storage: ConsentStorage(userDefaults: defaults),
                dispatch: { $0() }
            ),
            providerContextManager: providerContext
        )
    }

    override func tearDown() {
        ProviderContextManager.debugAssert = savedDebugAssert
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        providerContext = nil
        service = nil
        savedDebugAssert = nil
        super.tearDown()
    }

    // MARK: - Stamp on every event type

    func testEveryFactoryStampsProviderContext() async {
        providerContext.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123")

        let payloads: [EnrichedEventPayload] = [
            await service.createTrackEvent(event: "Order Completed"),
            await service.createIdentifyEvent(userId: "user-1"),
            await service.createGroupEvent(groupId: "group-1"),
            await service.createScreenEvent(name: "Home"),
            await service.createPageEvent(name: "Landing"),
            await service.createAliasEvent(newUserId: "user-2"),
        ]

        for payload in payloads {
            XCTAssertEqual(
                payload.context.providers?["googleFirebase"],
                ["appInstanceId": .string("abc123")],
                "\(payload.type) must carry the provider block"
            )
        }
    }

    /// The point of the feature: the bridge path enriches through the
    /// EventWithIdentity overload, so a value only the native app knows reaches
    /// events the web page produced.
    func testBridgeShapedEventCarriesProviderContextAndPage() async {
        providerContext.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123")
        let event = EventWithIdentity(
            type: "track",
            event: "Web Click",
            anonymousId: "anon-1",
            timestamp: "2026-10-05T12:00:00.000Z",
            page: PageContext(url: "https://shop.example.com/cart", title: "Cart")
        )

        let payload = await service.enrichEvent(event)

        XCTAssertEqual(payload.context.providers?["googleFirebase"], ["appInstanceId": .string("abc123")])
        XCTAssertEqual(payload.context.page?.url, "https://shop.example.com/cart",
                       "provider stamping must not disturb the page block")
        XCTAssertNotNil(payload.context.consent,
                        "provider stamping must not disturb the consent block")
    }

    func testMultipleProvidersAllAppear() async {
        providerContext.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123")
        providerContext.setValue(provider: "googleFirebase", key: "nonPersonalizedAds", value: false)
        providerContext.setValue(provider: "adjust", key: "adid", value: "adj-1")

        let payload = await service.createTrackEvent(event: "Order Completed")

        XCTAssertEqual(payload.context.providers?["googleFirebase"], [
            "appInstanceId": .string("abc123"),
            "nonPersonalizedAds": .bool(false),
        ])
        XCTAssertEqual(payload.context.providers?["adjust"], ["adid": .string("adj-1")])
    }

    // MARK: - Coexistence with the SDK's own block

    func testSessionBlockSurvivesAlongsideHostProviders() async {
        providerContext.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123")

        let payload = await service.createTrackEvent(event: "Order Completed")

        let session = payload.context.providers?["metarouter"]
        XCTAssertNotNil(session?["sessionID"])
        XCTAssertNotNil(session?["sessionCount"])
        XCTAssertEqual(payload.context.providers?.count, 2)
    }

    func testNoHostProvidersLeavesTheSessionBlockExactlyAsBefore() async {
        // Pins the no-op case: an untouched API must emit the same providers block
        // as the build before this feature.
        let payload = await service.createTrackEvent(event: "Order Completed")

        XCTAssertEqual(payload.context.providers?.count, 1)
        XCTAssertNotNil(payload.context.providers?["metarouter"]?["sessionID"])
    }

    /// The API refuses `metarouter`, so this covers the other half: a value that
    /// reached the map by another route (a storage blob from a build with different
    /// rules) still cannot displace the session stamp.
    func testSessionBlockWinsOverAMetarouterEntryThatBypassedTheApi() async {
        ProviderContextStorage(userDefaults: defaults).set([
            "metarouter": ["sessionID": .string("hijacked"), "sessionCount": .int(999)]
        ])
        let smuggled = ProviderContextManager(
            storage: ProviderContextStorage(userDefaults: defaults)
        )
        XCTAssertEqual(smuggled.getAll()["metarouter"]?["sessionID"], .string("hijacked"),
                       "precondition: the value is in the map")

        let service = EventEnrichmentService(
            contextProvider: MockContextProvider(),
            identityManager: IdentityManager(
                storage: IdentityStorage(userDefaults: defaults),
                writeKey: "test-key",
                host: "https://test.example.com"
            ),
            writeKey: "test-key",
            sessionManager: SessionManager(storage: SessionStorage(userDefaults: defaults)),
            consentManager: ConsentManager(
                storage: ConsentStorage(userDefaults: defaults),
                dispatch: { $0() }
            ),
            providerContextManager: smuggled
        )

        let payload = await service.createTrackEvent(event: "Order Completed")

        XCTAssertNotEqual(payload.context.providers?["metarouter"]?["sessionID"], .string("hijacked"))
        XCTAssertNotEqual(payload.context.providers?["metarouter"]?["sessionCount"], .int(999))
        XCTAssertEqual(payload.context.providers?["metarouter"]?["sessionCount"], .int(1))
    }

    // MARK: - Point-in-time

    func testStampReflectsStateAtEnrichmentTime() async {
        let before = await service.createTrackEvent(event: "Before")
        providerContext.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123")
        let after = await service.createTrackEvent(event: "After")

        XCTAssertNil(before.context.providers?["googleFirebase"],
                     "an already-enriched payload is immutable; a later set never rewrites it")
        XCTAssertEqual(after.context.providers?["googleFirebase"], ["appInstanceId": .string("abc123")])
    }

    func testRemovalStopsTheStamp() async {
        providerContext.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123")
        _ = await service.createTrackEvent(event: "With")
        providerContext.clear(provider: "googleFirebase")

        let payload = await service.createTrackEvent(event: "Without")

        XCTAssertNil(payload.context.providers?["googleFirebase"])
        XCTAssertEqual(payload.context.providers?.count, 1, "only the session block remains")
    }

    func testValuePersistedByAPriorLaunchIsStampedWithoutAnySetThisProcess() async {
        ProviderContextStorage(userDefaults: defaults).set([
            "googleFirebase": ["appInstanceId": .string("from-last-launch")]
        ])

        // Stands in for the next cold launch — what gets Application Opened and the
        // first Session Started stamped, which a memory-only store would miss.
        let service = EventEnrichmentService(
            contextProvider: MockContextProvider(),
            identityManager: IdentityManager(
                storage: IdentityStorage(userDefaults: defaults),
                writeKey: "test-key",
                host: "https://test.example.com"
            ),
            writeKey: "test-key",
            sessionManager: SessionManager(storage: SessionStorage(userDefaults: defaults)),
            consentManager: ConsentManager(
                storage: ConsentStorage(userDefaults: defaults),
                dispatch: { $0() }
            ),
            providerContextManager: ProviderContextManager(
                storage: ProviderContextStorage(userDefaults: defaults)
            )
        )

        let payload = await service.createTrackEvent(event: "Application Opened")

        XCTAssertEqual(
            payload.context.providers?["googleFirebase"],
            ["appInstanceId": .string("from-last-launch")]
        )
    }

    // MARK: - Wire shape

    func testProviderBlockEncodesAtTheExpectedJsonPath() async throws {
        providerContext.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123")
        let payload = await service.createTrackEvent(event: "Order Completed")

        let data = try JSONEncoder().encode(payload)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let context = try XCTUnwrap(root["context"] as? [String: Any])
        let providers = try XCTUnwrap(context["providers"] as? [String: Any])
        let firebase = try XCTUnwrap(providers["googleFirebase"] as? [String: Any])

        // Pins the exact path a pipeline mapping matches verbatim. Renaming any
        // segment forks every mapping keyed on it.
        XCTAssertEqual(firebase["appInstanceId"] as? String, "abc123")
    }
}
