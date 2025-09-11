import XCTest

@testable import MetaRouter

final class EventEnrichmentTests: XCTestCase {

    var enrichmentService: EventEnrichmentService!
    var mockContextProvider: MockContextProvider!

    override func setUp() {
        super.setUp()
        mockContextProvider = MockContextProvider()
        enrichmentService = EventEnrichmentService(
            contextProvider: mockContextProvider,
            writeKey: "test-write-key"
        )
    }

    override func tearDown() {
        enrichmentService = nil
        mockContextProvider = nil
        super.tearDown()
    }

    // MARK: - Message ID Generation Tests

    func testMessageIdGeneration() {
        let messageId1 = MessageIdGenerator.generate()
        let messageId2 = MessageIdGenerator.generate()

        // Should be unique
        XCTAssertNotEqual(messageId1, messageId2)

        // Should have timestamp-uuid format
        XCTAssertTrue(messageId1.contains("-"))
        XCTAssertTrue(MessageIdGenerator.isValid(messageId1))
        XCTAssertTrue(MessageIdGenerator.isValid(messageId2))
    }

    func testMessageIdWithCustomTimestamp() {
        let customDate = Date(timeIntervalSince1970: 1_694_123_456)
        let messageId = MessageIdGenerator.generate(timestamp: customDate)

        XCTAssertTrue(MessageIdGenerator.isValid(messageId))

        let extractedDate = MessageIdGenerator.extractTimestamp(from: messageId)
        XCTAssertNotNil(extractedDate)
        XCTAssertEqual(
            extractedDate!.timeIntervalSince1970, customDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMessageIdValidation() {
        // Valid message IDs
        XCTAssertTrue(
            MessageIdGenerator.isValid("1694123456789-550E8400-E29B-41D4-A716-446655440000"))

        // Invalid message IDs
        XCTAssertFalse(MessageIdGenerator.isValid("invalid-id"))
        XCTAssertFalse(MessageIdGenerator.isValid("1694123456789"))
        XCTAssertFalse(
            MessageIdGenerator.isValid("not-a-timestamp-550E8400-E29B-41D4-A716-446655440000"))
        XCTAssertFalse(MessageIdGenerator.isValid("1694123456789-invalid-uuid"))
    }

    func testTimestampExtraction() {
        let originalTimestamp: TimeInterval = 1694123456.789
        let originalDate = Date(timeIntervalSince1970: originalTimestamp)
        let messageId = MessageIdGenerator.generate(timestamp: originalDate)

        let extractedDate = MessageIdGenerator.extractTimestamp(from: messageId)
        XCTAssertNotNil(extractedDate)
        XCTAssertEqual(extractedDate!.timeIntervalSince1970, originalTimestamp, accuracy: 0.001)

        // Test invalid message ID
        XCTAssertNil(MessageIdGenerator.extractTimestamp(from: "invalid-message-id"))
    }

    // MARK: - Event Enrichment Tests

    func testBasicEventEnrichment() async {
        let event = EventWithIdentity(
            type: "track",
            event: "Test Event",
            userId: "user123",
            anonymousId: "anon123",
            properties: ["key": .string("value")],
            timestamp: "2023-09-08T10:30:45.000Z"
        )

        let enriched = await enrichmentService.enrichEvent(event)

        // Verify original event data is preserved
        XCTAssertEqual(enriched.type, "track")
        XCTAssertEqual(enriched.event, "Test Event")
        XCTAssertEqual(enriched.userId, "user123")
        XCTAssertEqual(enriched.anonymousId, "anon123")
        XCTAssertEqual(enriched.properties?["key"], .string("value"))
        XCTAssertEqual(enriched.timestamp, "2023-09-08T10:30:45.000Z")

        // Verify enrichment data is added
        XCTAssertEqual(enriched.writeKey, "test-write-key")
        XCTAssertFalse(enriched.messageId.isEmpty)
        XCTAssertTrue(MessageIdGenerator.isValid(enriched.messageId))
        XCTAssertNotNil(enriched.context)
        XCTAssertEqual(enriched.context.app.name, "TestApp")
    }

    func testCustomMessageIdEnrichment() async {
        let customMessageId = "1694123456789-CUSTOM-MESSAGE-ID-A716-446655440000"
        let event = EventWithIdentity(
            type: "identify",
            userId: "user456",
            anonymousId: "anon456",
            timestamp: "2023-09-08T11:00:00.000Z"
        )

        let enriched = await enrichmentService.enrichEvent(event, messageId: customMessageId)

        XCTAssertEqual(enriched.messageId, customMessageId)
        XCTAssertEqual(enriched.type, "identify")
        XCTAssertEqual(enriched.userId, "user456")
    }

    func testBaseEventEnrichment() async {
        let baseEvent = BaseEvent(
            type: "track",
            event: "Base Event",
            userId: "user789",
            properties: ["source": .string("test")]
        )

        let enriched = await enrichmentService.enrichEvent(baseEvent)

        XCTAssertEqual(enriched.type, "track")
        XCTAssertEqual(enriched.event, "Base Event")
        XCTAssertEqual(enriched.userId, "user789")
        XCTAssertEqual(enriched.properties?["source"], .string("test"))
        XCTAssertFalse(enriched.anonymousId.isEmpty)
        XCTAssertFalse(enriched.timestamp.isEmpty)
        XCTAssertTrue(MessageIdGenerator.isValid(enriched.messageId))
    }

    func testBaseEventEnrichmentWithCustomAnonymousId() async {
        let baseEvent = BaseEvent(
            type: "page",
            properties: ["url": .string("/home")]
        )

        let customAnonymousId = "custom-anon-id"
        let enriched = await enrichmentService.enrichEvent(
            baseEvent, anonymousId: customAnonymousId)

        XCTAssertEqual(enriched.anonymousId, customAnonymousId)
        XCTAssertEqual(enriched.type, "page")
        XCTAssertEqual(enriched.properties?["url"], .string("/home"))
    }

    // MARK: - Convenience Event Creation Tests

    func testCreateTrackEvent() async {
        let enriched = await enrichmentService.createTrackEvent(
            event: "Button Clicked",
            properties: ["button_id": .string("subscribe")],
            userId: "user123"
        )

        XCTAssertEqual(enriched.type, "track")
        XCTAssertEqual(enriched.event, "Button Clicked")
        XCTAssertEqual(enriched.userId, "user123")
        XCTAssertEqual(enriched.properties?["button_id"], .string("subscribe"))
        XCTAssertFalse(enriched.anonymousId.isEmpty)
    }

    func testCreateIdentifyEvent() async {
        let enriched = await enrichmentService.createIdentifyEvent(
            userId: "user456",
            traits: ["name": .string("John Doe"), "email": .string("john@example.com")]
        )

        XCTAssertEqual(enriched.type, "identify")
        XCTAssertEqual(enriched.userId, "user456")
        XCTAssertEqual(enriched.traits?["name"], .string("John Doe"))
        XCTAssertEqual(enriched.traits?["email"], .string("john@example.com"))
    }

    func testCreateGroupEvent() async {
        let enriched = await enrichmentService.createGroupEvent(
            groupId: "group789",
            traits: ["company": .string("Acme Corp")],
            userId: "user123"
        )

        XCTAssertEqual(enriched.type, "group")
        XCTAssertEqual(enriched.userId, "user123")
        XCTAssertEqual(enriched.properties?["groupId"], .string("group789"))
        XCTAssertEqual(enriched.traits?["company"], .string("Acme Corp"))
    }

    func testCreateScreenEvent() async {
        let enriched = await enrichmentService.createScreenEvent(
            name: "Home Screen",
            properties: ["section": .string("main")],
            userId: "user123"
        )

        XCTAssertEqual(enriched.type, "screen")
        XCTAssertEqual(enriched.properties?["name"], .string("Home Screen"))
        XCTAssertEqual(enriched.properties?["section"], .string("main"))
        XCTAssertEqual(enriched.userId, "user123")
    }

    func testCreatePageEvent() async {
        let enriched = await enrichmentService.createPageEvent(
            name: "/dashboard",
            properties: ["referrer": .string("/home")],
            userId: "user123"
        )

        XCTAssertEqual(enriched.type, "page")
        XCTAssertEqual(enriched.properties?["name"], .string("/dashboard"))
        XCTAssertEqual(enriched.properties?["referrer"], .string("/home"))
    }

    func testCreateAliasEvent() async {
        let enriched = await enrichmentService.createAliasEvent(
            newUserId: "new-user-id",
            previousUserId: "old-user-id"
        )

        XCTAssertEqual(enriched.type, "alias")
        XCTAssertEqual(enriched.userId, "new-user-id")
        XCTAssertEqual(enriched.properties?["previousId"], .string("old-user-id"))
    }

    // MARK: - JSON Serialization Tests

    func testJsonSerialization() async throws {
        let event = EventWithIdentity(
            type: "track",
            event: "Test JSON",
            userId: "user123",
            anonymousId: "anon123",
            timestamp: "2023-09-08T12:00:00.000Z"
        )

        let enriched = await enrichmentService.enrichEvent(event)

        // Test JSON data creation
        let jsonData = try enriched.toJsonData()
        XCTAssertFalse(jsonData.isEmpty)

        // Test JSON string creation
        let jsonString = try enriched.toJsonString()
        XCTAssertTrue(jsonString.contains("Test JSON"))
        XCTAssertTrue(jsonString.contains("user123"))
        XCTAssertTrue(jsonString.contains("test-write-key"))

        // Test pretty JSON
        let prettyJson = try enriched.toPrettyJsonString()
        XCTAssertTrue(prettyJson.contains("\n"))  // Should have newlines for pretty printing
    }

    func testJsonRoundTrip() async throws {
        let event = EventWithIdentity(
            type: "identify",
            userId: "user456",
            anonymousId: "anon456",
            traits: ["name": .string("Jane Doe")],
            timestamp: "2023-09-08T13:00:00.000Z"
        )

        let enriched = await enrichmentService.enrichEvent(event)
        let jsonData = try enriched.toJsonData()

        // Decode back to verify round-trip works
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(EnrichedEventPayload.self, from: jsonData)

        XCTAssertEqual(decoded.type, enriched.type)
        XCTAssertEqual(decoded.userId, enriched.userId)
        XCTAssertEqual(decoded.writeKey, enriched.writeKey)
        XCTAssertEqual(decoded.messageId, enriched.messageId)
        XCTAssertEqual(decoded.context.app.name, enriched.context.app.name)
    }

    // MARK: - Edge Cases

    func testEnrichmentWithNilProperties() async {
        let event = EventWithIdentity(
            type: "track",
            event: "No Properties Event",
            userId: nil,
            anonymousId: "anon789",
            properties: nil,
            timestamp: "2023-09-08T14:00:00.000Z"
        )

        let enriched = await enrichmentService.enrichEvent(event)

        XCTAssertEqual(enriched.type, "track")
        XCTAssertNil(enriched.userId)
        XCTAssertNil(enriched.properties)
        XCTAssertEqual(enriched.anonymousId, "anon789")
    }

    func testConcurrentEnrichment() async {
        let events = (0..<10).map { i in
            EventWithIdentity(
                type: "track",
                event: "Concurrent Event \(i)",
                userId: "user\(i)",
                anonymousId: "anon\(i)",
                timestamp: "2023-09-08T15:00:00.000Z"
            )
        }

        let enrichedEvents = await withTaskGroup(of: EnrichedEventPayload.self) { group in
            for event in events {
                group.addTask {
                    return await self.enrichmentService.enrichEvent(event)
                }
            }

            var results: [EnrichedEventPayload] = []
            for await enriched in group {
                results.append(enriched)
            }
            return results
        }

        XCTAssertEqual(enrichedEvents.count, 10)

        // Verify all events were properly enriched
        for enriched in enrichedEvents {
            XCTAssertEqual(enriched.type, "track")
            XCTAssertTrue(enriched.event?.starts(with: "Concurrent Event") ?? false)
            XCTAssertEqual(enriched.writeKey, "test-write-key")
            XCTAssertTrue(MessageIdGenerator.isValid(enriched.messageId))
        }
    }
}

// MARK: - Mock Context Provider for Testing

final class MockContextProvider: ContextProvider, @unchecked Sendable {

    func getContext() async -> EventContext {
        return EventContext(
            app: AppContext(
                name: "TestApp",
                version: "1.0.0",
                build: "123",
                namespace: "com.test.app"
            ),
            device: DeviceContext(
                manufacturer: "Apple",
                model: "iPhone15,2",
                name: "Test Device",
                type: "phone"
            ),
            library: LibraryContext(
                name: "test-sdk",
                version: "1.0.0"
            ),
            os: OSContext(
                name: "iOS",
                version: "17.0"
            ),
            screen: ScreenContext(
                density: 3.0,
                width: 1179,
                height: 2556
            ),
            network: NetworkContext(wifi: true),
            locale: "en_US",
            timezone: "America/New_York"
        )
    }

    func clearCache() {
        // Mock implementation - no-op
    }
}
