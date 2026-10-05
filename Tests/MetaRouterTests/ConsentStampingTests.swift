import XCTest
@testable import MetaRouter

/// Payload-attach: every enriched event — whichever factory or overload produced
/// it — carries `context.consent` read from the consent manager at enrichment
/// time, in the web SDK's shape, and the stamp is point-in-time.
final class ConsentStampingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var consentManager: ConsentManager!
    private var service: EventEnrichmentService!

    private static let registry = [
        ConsentCategory(key: "c0001", defaultOptOut: false),
        ConsentCategory(key: "c0002"),
        ConsentCategory(key: "c0004"),
    ]

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.consentStamping.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        consentManager = ConsentManager(
            storage: ConsentStorage(userDefaults: defaults),
            dispatch: { $0() }
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
            consentManager: consentManager
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        consentManager = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Stamp on every event type

    func testEveryFactoryStampsConsent() async {
        consentManager.registerConsentCategories(Self.registry)
        consentManager.setConsent(Consent(explicit: true, optOut: ["c0002": false]))
        let expected = ConsentContext(explicit: true, optOut: ["c0001": false, "c0002": false, "c0004": true])

        let payloads: [EnrichedEventPayload] = [
            await service.createTrackEvent(event: "Order Completed"),
            await service.createIdentifyEvent(userId: "user-1"),
            await service.createGroupEvent(groupId: "group-1"),
            await service.createScreenEvent(name: "Home"),
            await service.createPageEvent(name: "Landing"),
            await service.createAliasEvent(newUserId: "user-2"),
        ]

        for payload in payloads {
            XCTAssertEqual(payload.context.consent, expected, "\(payload.type) must carry the consent block")
        }
    }

    /// The bridge path enriches via the EventWithIdentity overload with page facts
    /// attached — the stamp must land there too, and must not clobber page.
    func testBridgeShapedEventCarriesConsentAndPage() async {
        consentManager.registerConsentCategories(Self.registry)
        let event = EventWithIdentity(
            type: "track",
            event: "Web Click",
            anonymousId: "anon-1",
            timestamp: "2026-10-05T12:00:00.000Z",
            page: PageContext(url: "https://shop.example.com/cart", title: "Cart")
        )

        let payload = await service.enrichEvent(event)

        XCTAssertEqual(payload.context.consent?.optOut, ["c0001": false, "c0002": true, "c0004": true])
        XCTAssertEqual(payload.context.page?.url, "https://shop.example.com/cart",
                       "consent stamping must not disturb the page block")
        XCTAssertNotNil(payload.context.providers?["metarouter"],
                        "consent stamping must not disturb the session block")
    }

    // MARK: - State transitions

    func testBeforeFirstSetEventsCarryImplicitDefault() async {
        consentManager.registerConsentCategories(Self.registry)

        let payload = await service.createTrackEvent(event: "A")

        XCTAssertEqual(payload.context.consent,
                       ConsentContext(explicit: false, optOut: ["c0001": false, "c0002": true, "c0004": true]))
    }

    func testWithNoRegistryAndNoSetEventsCarryEmptyImplicitDefault() async {
        let payload = await service.createTrackEvent(event: "A")

        XCTAssertEqual(payload.context.consent, ConsentContext(explicit: false, optOut: [:]),
                       "a complete block, never an absent field")
    }

    func testAfterSetConsentEventsCarryReconciledConsent() async {
        consentManager.registerConsentCategories(Self.registry)
        consentManager.setConsent(Consent(explicit: true, optOut: ["c0004": false, "unknown": true]))

        let payload = await service.createTrackEvent(event: "A")

        XCTAssertEqual(payload.context.consent,
                       ConsentContext(explicit: true, optOut: ["c0001": false, "c0002": true, "c0004": false]))
    }

    func testAfterClearConsentEventsCarryImplicitDefaultAgain() async {
        consentManager.registerConsentCategories(Self.registry)
        consentManager.setConsent(Consent(explicit: true, optOut: ["c0002": false, "c0004": false]))
        _ = await service.createTrackEvent(event: "A")

        consentManager.clearConsent()
        let payload = await service.createTrackEvent(event: "B")

        XCTAssertEqual(payload.context.consent,
                       ConsentContext(explicit: false, optOut: ["c0001": false, "c0002": true, "c0004": true]))
    }

    /// Read-your-writes: a set followed immediately by an event stamps the new state.
    func testSetThenEventStampsNewStateWithNoAwaitInBetween() async {
        consentManager.registerConsentCategories(Self.registry)
        consentManager.setConsent(Consent(explicit: true, optOut: ["c0002": false]))
        let payload = await service.createTrackEvent(event: "A")
        XCTAssertEqual(payload.context.consent?.optOut["c0002"], false)

        consentManager.setConsent(Consent(explicit: true, optOut: ["c0002": true]))
        let next = await service.createTrackEvent(event: "B")
        XCTAssertEqual(next.context.consent?.optOut["c0002"], true)
    }

    /// Point-in-time: a later setConsent does not rewrite an already-enriched payload.
    func testStampIsPointInTime() async {
        consentManager.registerConsentCategories(Self.registry)
        consentManager.setConsent(Consent(explicit: true, optOut: ["c0004": false]))
        let before = await service.createTrackEvent(event: "A")

        consentManager.setConsent(Consent(explicit: true, optOut: ["c0004": true]))

        XCTAssertEqual(before.context.consent?.optOut["c0004"], false)
    }

    // MARK: - Wire and disk shape

    private func encodedContext(_ payload: EnrichedEventPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// Pins the wire form against the same encoder the Dispatcher uses. Observed in
    /// pipeline testing: ingest-side normalization can drop `"explicit": false` from
    /// stored events — these prove the SDK always sends the complete block, so any
    /// absence downstream is not ours.
    func testExplicitFalseAndFalseValuesArePresentOnTheWire() async throws {
        consentManager.registerConsentCategories(Self.registry)
        let payload = await service.createTrackEvent(event: "A")

        let json = try encodedContext(payload)

        XCTAssertTrue(json.contains(#""explicit":false"#), json)
        XCTAssertTrue(json.contains(#""c0001":false"#), json)
    }

    func testEmptyOptOutEncodesAsEmptyObject() async throws {
        let payload = await service.createTrackEvent(event: "A")

        let json = try encodedContext(payload)

        XCTAssertTrue(json.contains(#""consent":{"#), json)
        XCTAssertTrue(json.contains(#""optOut":{}"#), json)
    }

    func testTimestampNeverReachesTheWire() async throws {
        consentManager.setConsent(Consent(explicit: true, optOut: ["a": true], timestamp: 1_757_400_000_000))
        let payload = await service.createTrackEvent(event: "A")

        let json = try encodedContext(payload)

        XCTAssertFalse(json.contains("1757400000000"), "internal ordering timestamp leaked: \(json)")
    }

    func testConsentLivesUnderContextNotTopLevel() async throws {
        consentManager.registerConsentCategories(Self.registry)
        let payload = await service.createTrackEvent(event: "A")

        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let context = try XCTUnwrap(object["context"] as? [String: Any])

        XCTAssertNil(object["consent"], "web parity is context.consent, not a top-level block")
        let consent = try XCTUnwrap(context["consent"] as? [String: Any])
        XCTAssertEqual(consent["explicit"] as? Bool, false)
        XCTAssertEqual(consent["optOut"] as? [String: Bool], ["c0001": false, "c0002": true, "c0004": true])
    }

    /// Enriched events are persisted to disk as JSON. A queue written by a build
    /// that predates `context.consent` must still decode — otherwise every event
    /// queued before an upgrade is silently discarded on the first launch after it.
    func testContextWithoutConsentKeyStillDecodes() throws {
        let json = """
        {"app":{"name":"A","version":"1","build":"1","namespace":"com.example"},
         "device":{"manufacturer":"Apple","model":"iPhone","type":"ios"},
         "library":{"name":"metarouter-ios-sdk","version":"1.7.0"},
         "os":{"name":"iOS","version":"17.0"},
         "screen":{"density":3,"width":390,"height":844},
         "locale":"en-US","timezone":"UTC","additional":{}}
        """
        let context = try JSONDecoder().decode(EventContext.self, from: Data(json.utf8))

        XCTAssertNil(context.consent)
    }

    func testConsentContextRoundTripsThroughDisk() throws {
        let original = ConsentContext(explicit: true, optOut: ["c0001": false, "c0004": true])
        let data = try JSONEncoder().encode(original)

        XCTAssertEqual(try JSONDecoder().decode(ConsentContext.self, from: data), original)
    }
}
