import XCTest
@testable import MetaRouter

/// Session stamping at the enrichment funnel: every enriched event — whichever
/// factory or overload produced it — must carry `context.providers.metarouter`
/// with the current session, and enriching must drive the session lifecycle
/// (extend / rollover) because enrichment is the one path all event sources share.
final class SessionEnrichmentTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    private final class Clock: @unchecked Sendable {
        var now: Int64
        init(_ now: Int64) { self.now = now }
        func advance(minutes: Int64) { now += minutes * 60_000 }
    }

    private var wall: Clock!
    private var mono: Clock!
    private var service: EventEnrichmentService!

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.sessionEnrichment.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        wall = Clock(1_757_400_000_000)
        mono = Clock(50_000)
        let sessionManager = SessionManager(
            storage: SessionStorage(userDefaults: defaults),
            wallClockMillis: { [wall] in wall!.now },
            monotonicClockMillis: { [mono] in mono!.now }
        )
        service = EventEnrichmentService(
            contextProvider: MockContextProvider(),
            identityManager: IdentityManager(
                storage: IdentityStorage(userDefaults: defaults),
                writeKey: "test-key",
                host: "https://test.example.com"
            ),
            writeKey: "test-key",
            sessionManager: sessionManager
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        wall = nil
        mono = nil
        service = nil
        super.tearDown()
    }

    private func session(of payload: EnrichedEventPayload) -> [String: CodableValue]? {
        payload.context.providers?["metarouter"]
    }

    // MARK: - Stamp on every event type

    func testEveryFactoryStampsSession() async {
        let payloads: [EnrichedEventPayload] = [
            await service.createTrackEvent(event: "Order Completed"),
            await service.createIdentifyEvent(userId: "user-1"),
            await service.createGroupEvent(groupId: "group-1"),
            await service.createScreenEvent(name: "Home"),
            await service.createPageEvent(name: "Landing"),
            await service.createAliasEvent(newUserId: "user-2"),
        ]

        for payload in payloads {
            XCTAssertEqual(session(of: payload)?["sessionID"], .string("1757400000000"),
                           "\(payload.type) must carry the session id")
            XCTAssertEqual(session(of: payload)?["sessionCount"], .int(1),
                           "\(payload.type) must carry the session count")
        }
    }

    /// The bridge path enriches via the EventWithIdentity overload with page
    /// facts attached — the stamp must land there too, and must not clobber page.
    func testBridgeShapedEventCarriesSessionAndPage() async {
        let event = EventWithIdentity(
            type: "track",
            event: "Web Click",
            anonymousId: "anon-1",
            timestamp: "2026-09-09T12:00:00.000Z",
            page: PageContext(url: "https://shop.example.com/cart", title: "Cart")
        )

        let payload = await service.enrichEvent(event)

        XCTAssertEqual(session(of: payload)?["sessionID"], .string("1757400000000"))
        XCTAssertEqual(payload.context.page?.url, "https://shop.example.com/cart",
                       "session stamping must not disturb the page block")
    }

    // MARK: - Session lifecycle driven by enrichment

    func testEventsWithinTimeoutShareOneSession() async {
        let first = await service.createTrackEvent(event: "A")
        wall.advance(minutes: 20); mono.advance(minutes: 20)
        let second = await service.createTrackEvent(event: "B")

        XCTAssertEqual(session(of: first)?["sessionID"], session(of: second)?["sessionID"])
        XCTAssertEqual(session(of: second)?["sessionCount"], .int(1))
    }

    func testInactivityGapRollsSessionMidStream() async {
        let before = await service.createTrackEvent(event: "A")
        wall.advance(minutes: 31); mono.advance(minutes: 31)
        let after = await service.createTrackEvent(event: "B")

        XCTAssertNotEqual(session(of: before)?["sessionID"], session(of: after)?["sessionID"])
        XCTAssertEqual(session(of: after)?["sessionID"], .string(String(wall.now)))
        XCTAssertEqual(session(of: after)?["sessionCount"], .int(2))
    }

    /// A cold-start burst of concurrent enrichments must agree on one session —
    /// the actor serializes the touch, so exactly one mint happens.
    func testConcurrentEnrichmentMintsExactlyOneSession() async {
        let payloads = await withTaskGroup(of: EnrichedEventPayload.self, returning: [EnrichedEventPayload].self) { group in
            for i in 0..<50 {
                group.addTask { [service] in await service!.createTrackEvent(event: "Event \(i)") }
            }
            var collected: [EnrichedEventPayload] = []
            for await payload in group { collected.append(payload) }
            return collected
        }

        let ids = Set(payloads.compactMap { session(of: $0)?["sessionID"]?.stringValue })
        XCTAssertEqual(ids.count, 1, "every concurrent enrichment sees the same session")
    }

    // MARK: - Wire and disk shape

    func testProvidersEncodesToWebParityJSON() async throws {
        var context = await MockContextProvider().getContext()
        context.providers = ["metarouter": [
            "sessionID": .string("1757400000000"),
            "sessionCount": .int(3),
        ]]
        let payload = EnrichedEventPayload(
            type: "track",
            event: "A",
            anonymousId: "anon-1",
            timestamp: "2026-09-09T12:00:00.000Z",
            writeKey: "k",
            messageId: "m",
            context: context
        )

        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contextJSON = try XCTUnwrap(json["context"] as? [String: Any])
        let providers = try XCTUnwrap(contextJSON["providers"] as? [String: Any])
        let metarouter = try XCTUnwrap(providers["metarouter"] as? [String: Any])

        XCTAssertEqual(metarouter["sessionID"] as? String, "1757400000000",
                       "web-parity path: context.providers.metarouter.sessionID")
        XCTAssertEqual(metarouter["sessionCount"] as? Int, 3)
    }

    /// Events persisted to disk by a build that predates `providers` must still
    /// decode — a required key here would silently discard a customer's entire
    /// pre-upgrade offline queue on their first launch after updating.
    func testPayloadWithoutProvidersKeyStillDecodes() throws {
        let legacyJSON = """
        {
          "type": "track",
          "event": "Legacy Event",
          "anonymousId": "anon-legacy",
          "timestamp": "2026-01-01T00:00:00.000Z",
          "writeKey": "k",
          "messageId": "m",
          "context": {
            "app": {"name": "TestApp", "version": "1.0.0", "build": "123", "namespace": "com.test.app"},
            "device": {"manufacturer": "Apple", "model": "iPhone15,2", "type": "ios"},
            "library": {"name": "metarouter-ios", "version": "1.0.0"},
            "os": {"name": "iOS", "version": "17.0"},
            "screen": {"density": 3, "width": 393, "height": 852},
            "locale": "en-US",
            "timezone": "America/New_York",
            "additional": {}
          }
        }
        """

        let payload = try JSONDecoder().decode(EnrichedEventPayload.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(payload.event, "Legacy Event")
        XCTAssertNil(payload.context.providers)
    }
}
