import XCTest
@testable import MetaRouter

/// Covers the plumbing that carries a bridge envelope's page facts onto the outbound
/// payload: BaseEvent.page → enrichment → context.page.
final class BridgeEventPlumbingTests: XCTestCase {

    private var enrichment: EventEnrichmentService!
    private var identityManager: IdentityManager!

    override func setUp() async throws {
        try await super.setUp()
        identityManager = IdentityManager(writeKey: "test-write-key", host: "https://test.metarouter.com")
        await identityManager.initialize()
        enrichment = EventEnrichmentService(
            contextProvider: MockContextProvider(),
            identityManager: identityManager,
            writeKey: "test-write-key"
        )
    }

    override func tearDown() {
        enrichment = nil
        identityManager = nil
        super.tearDown()
    }

    func testBridgeEventPageFactsLandOnContextPage() async {
        let enriched = await enrichment.enrichEvent(BaseEvent(
            type: EventType.page.rawValue,
            event: "page_view",
            page: PageContext(
                url: "https://www.metarouter.com/booking",
                title: "Book",
                referrer: "https://www.metarouter.com/"
            )
        ))

        XCTAssertEqual(enriched.context.page?.url, "https://www.metarouter.com/booking")
        XCTAssertEqual(enriched.context.page?.title, "Book")
        XCTAssertEqual(enriched.context.page?.referrer, "https://www.metarouter.com/")
    }

    func testNativeEventsCarryNoPageContext() async throws {
        let enriched = await enrichment.enrichEvent(BaseEvent(
            type: EventType.track.rawValue,
            event: "native_action"
        ))

        XCTAssertNil(enriched.context.page)
        // And the key is absent from the wire form, matching web SDK output for
        // native traffic — not serialized as null.
        let json = String(decoding: try JSONEncoder().encode(enriched.context), as: UTF8.self)
        XCTAssertFalse(json.contains("\"page\""))
    }

    func testIdentityAndMessageIdComeFromNativeEnrichmentNotTheEnvelope() async {
        let enriched = await enrichment.enrichEvent(BaseEvent(
            type: EventType.track.rawValue,
            event: "product_viewed",
            page: PageContext(url: "https://www.metarouter.com/search")
        ))

        let nativeAnonymousId = await identityManager.getOrCreateAnonymousId()
        XCTAssertEqual(enriched.anonymousId, nativeAnonymousId)
        // The envelope's messageId exists for bridge dedup only; the outbound event
        // gets a native ID like every other event.
        XCTAssertTrue(MessageIdGenerator.isValid(enriched.messageId))
    }
}
