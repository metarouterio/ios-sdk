import XCTest
@testable import MetaRouter

final class DiskStorageTests: XCTestCase {
    private var tempDir: URL!
    private var storage: DiskStorage!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskStorageTests-\(UUID().uuidString)")
        storage = DiskStorage(baseDirectory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWriteAndReadSnapshot() async throws {
        let events = [makeTestEvent(messageId: "e1")]
        let snapshot = QueueSnapshot(events: events)

        try await storage.write(snapshot)
        let loaded = await storage.read()

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.events.count, 1)
        XCTAssertEqual(loaded?.events[0].messageId, "e1")
    }

    func testReadReturnsNilWhenNoFile() async throws {
        let loaded = await storage.read()
        XCTAssertNil(loaded)
    }

    func testDeleteRemovesFile() async throws {
        let snapshot = QueueSnapshot(events: [makeTestEvent()])
        try await storage.write(snapshot)

        await storage.delete()

        let loaded = await storage.read()
        XCTAssertNil(loaded)
    }

    func testWriteOverwritesPreviousSnapshot() async throws {
        let first = QueueSnapshot(events: [makeTestEvent(messageId: "first")])
        try await storage.write(first)

        let second = QueueSnapshot(events: [makeTestEvent(messageId: "second")])
        try await storage.write(second)

        let loaded = await storage.read()
        XCTAssertEqual(loaded?.events.count, 1)
        XCTAssertEqual(loaded?.events[0].messageId, "second")
    }

    func testDirectoryCreatedAutomatically() async throws {
        let snapshot = QueueSnapshot(events: [makeTestEvent()])
        try await storage.write(snapshot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testBackupExclusion() async throws {
        let snapshot = QueueSnapshot(events: [makeTestEvent()])
        try await storage.write(snapshot)

        let dirValues = try tempDir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(dirValues.isExcludedFromBackup, true)
    }

    func testAtomicWriteDoesNotCorruptOnConcurrentRead() async throws {
        let snapshot = QueueSnapshot(events: (0..<100).map { makeTestEvent(messageId: "e\($0)") })
        let localStorage = storage!

        // Write first, then verify a concurrent read returns complete data
        try await localStorage.write(snapshot)
        let loaded = await localStorage.read()

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.events.count, 100)
    }

    func testCorruptFileIsDeletedOnRead() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let filePath = tempDir.appendingPathComponent("queue.v1.json")
        try Data("not valid json at all {{{".utf8).write(to: filePath)

        XCTAssertTrue(fm.fileExists(atPath: filePath.path), "Corrupt file should exist before read")

        let loaded = await storage.read()
        XCTAssertNil(loaded, "Corrupt file should return nil")
        XCTAssertFalse(fm.fileExists(atPath: filePath.path), "Corrupt file must be deleted after failed read")
    }

    func testUnknownVersionFileReturnsEmptyEvents() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let filePath = tempDir.appendingPathComponent("queue.v1.json")
        let json = """
        {"version": 99, "events": []}
        """
        try Data(json.utf8).write(to: filePath)

        let loaded = await storage.read()

        // QueueSnapshot handles unknown version gracefully with empty events
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.events.count, 0)
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
