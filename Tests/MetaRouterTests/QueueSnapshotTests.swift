import XCTest
@testable import MetaRouter

final class QueueSnapshotTests: XCTestCase {

    func testRoundTripEncoding() throws {
        let events = [makeTestEvent(messageId: "m1"), makeTestEvent(messageId: "m2")]
        let snapshot = QueueSnapshot(events: events)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(QueueSnapshot.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.events.count, 2)
        XCTAssertEqual(decoded.events[0].messageId, "m1")
        XCTAssertEqual(decoded.events[1].messageId, "m2")
    }

    func testDecodingUnknownVersionSkipsWithWarning() throws {
        let json = """
        {"version": 99, "events": []}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(QueueSnapshot.self, from: data)

        XCTAssertEqual(decoded.version, 99)
        XCTAssertEqual(decoded.events.count, 0)
    }

    func testDecodingCorruptEventSkipsIt() throws {
        let validEvent = makeTestEvent(messageId: "valid")
        let validData = try JSONEncoder().encode(validEvent)
        let validJSON = String(data: validData, encoding: .utf8)!

        let json = """
        {"version": 1, "events": [\(validJSON), {"type": "track", "broken": true}]}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(QueueSnapshot.self, from: data)

        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertEqual(decoded.events[0].messageId, "valid")
    }

    func testEstimatedSizeBytes() throws {
        let events = [makeTestEvent(messageId: "m1")]
        let snapshot = QueueSnapshot(events: events)
        let size = snapshot.estimatedSizeBytes

        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThan(size, 10_000)
    }

    func testEmptyEventsRoundTrip() throws {
        let snapshot = QueueSnapshot(events: [])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(QueueSnapshot.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.events.count, 0)
    }
}

// MARK: - Test Helper

private func makeTestEvent(messageId: String = "mid") -> EnrichedEventPayload {
    let ctx = EventContext(
        app: AppContext(name: "a", version: "1", build: "1", namespace: "a"),
        device: DeviceContext(manufacturer: "a", model: "m", name: "n", type: "t"),
        library: LibraryContext(name: "l", version: "1"),
        os: OSContext(name: "iOS", version: "1"),
        screen: ScreenContext(density: 2.0, width: 1, height: 1),
        network: nil,
        locale: "en_US",
        timezone: "UTC"
    )
    return EnrichedEventPayload(
        type: "track", event: "ev", userId: nil, anonymousId: "anon",
        properties: nil, traits: nil, integrations: nil,
        timestamp: "now", writeKey: "wk", messageId: messageId, context: ctx
    )
}
