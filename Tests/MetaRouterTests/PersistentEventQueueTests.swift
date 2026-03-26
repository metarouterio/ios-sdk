import XCTest
@testable import MetaRouter

final class PersistentEventQueueTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentQueueTests-\(UUID().uuidString)")
        PersistentEventQueue.resetRehydrationGuard()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - enqueue is memory-only

    func testEnqueueWritesToMemoryOnly() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )

        await queue.enqueue(makeTestEvent(messageId: "e1"))
        let count = await queue.count
        XCTAssertEqual(count, 1)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("queue.v1.json").path
        ))
    }

    // MARK: - drain is memory-only

    func testDrainReadsFromMemoryOnly() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )

        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))

        let drained = await queue.drain(max: 1)
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].messageId, "e1")

        let remaining = await queue.count
        XCTAssertEqual(remaining, 1)
    }

    // MARK: - flushToDisk writes current state

    func testFlushToDiskWritesCurrentMemoryState() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )

        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))

        try await queue.flushToDisk()

        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let snapshot = await diskStorage.read()
        XCTAssertEqual(snapshot?.events.count, 2)
        XCTAssertEqual(snapshot?.events[0].messageId, "e1")
    }

    func testFlushToDiskOverwritesPreviousState() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )

        await queue.enqueue(makeTestEvent(messageId: "e1"))
        try await queue.flushToDisk()

        _ = await queue.drain(max: 1)
        await queue.enqueue(makeTestEvent(messageId: "e2"))
        try await queue.flushToDisk()

        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let snapshot = await diskStorage.read()
        XCTAssertEqual(snapshot?.events.count, 1)
        XCTAssertEqual(snapshot?.events[0].messageId, "e2")
    }

    func testFlushToDiskWithEmptyQueueWritesEmptySnapshot() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )

        try await queue.flushToDisk()

        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let snapshot = await diskStorage.read()
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.events.count, 0)
    }

    // MARK: - Rehydration

    func testRehydrateLoadsEventsFromDisk() async throws {
        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let snapshot = QueueSnapshot(events: [
            makeTestEvent(messageId: "disk1"),
            makeTestEvent(messageId: "disk2"),
        ])
        try await diskStorage.write(snapshot)

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )

        let rehydratedCount = await queue.rehydrate()

        XCTAssertEqual(rehydratedCount, 2)
        let count = await queue.count
        XCTAssertEqual(count, 2)

        let drained = await queue.drain(max: 10)
        XCTAssertEqual(drained[0].messageId, "disk1")
        XCTAssertEqual(drained[1].messageId, "disk2")
    }

    func testRehydrateOnlyHappensOnce() async throws {
        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let snapshot = QueueSnapshot(events: [makeTestEvent(messageId: "disk1")])
        try await diskStorage.write(snapshot)

        let queue1 = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )
        let count1 = await queue1.rehydrate()
        XCTAssertEqual(count1, 1)

        // Write new data to disk for second queue
        try await diskStorage.write(QueueSnapshot(events: [makeTestEvent(messageId: "disk2")]))

        let queue2 = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )
        let count2 = await queue2.rehydrate()
        XCTAssertEqual(count2, 0)

        let q2Count = await queue2.count
        XCTAssertEqual(q2Count, 0)
    }

    func testRehydrateEnforcesCapacity() async throws {
        let events = (0..<10).map { makeTestEvent(messageId: "e\($0)") }
        let diskStorage = DiskStorage(baseDirectory: tempDir)
        try await diskStorage.write(QueueSnapshot(events: events))

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 5,
            maxSizeBytes: 5_000_000
        )
        let rehydrated = await queue.rehydrate()

        XCTAssertEqual(rehydrated, 5)
        let count = await queue.count
        XCTAssertEqual(count, 5)

        let drained = await queue.drain(max: 10)
        XCTAssertEqual(drained[0].messageId, "e5")
        XCTAssertEqual(drained[4].messageId, "e9")
    }

    func testRehydrateDeletesDiskFileAfterLoading() async throws {
        let diskStorage = DiskStorage(baseDirectory: tempDir)
        try await diskStorage.write(QueueSnapshot(events: [makeTestEvent()]))

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )
        _ = await queue.rehydrate()

        let fileExists = FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("queue.v1.json").path
        )
        XCTAssertFalse(fileExists, "Disk file should be deleted after rehydration")
    }

    // MARK: - Capacity enforcement

    func testCapacityEnforcementDropsOldest() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            maxSizeBytes: 5_000_000
        )

        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))
        await queue.enqueue(makeTestEvent(messageId: "e3"))
        await queue.enqueue(makeTestEvent(messageId: "e4"))

        let count = await queue.count
        XCTAssertEqual(count, 3)

        let drained = await queue.drain(max: 10)
        XCTAssertEqual(drained[0].messageId, "e2")
        XCTAssertEqual(drained[2].messageId, "e4")
    }

    // MARK: - Flush threshold

    func testFlushThresholdReachedByCount() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000,
            flushThresholdCount: 3,
            flushThresholdBytes: 5_000_000
        )

        await queue.enqueue(makeTestEvent(messageId: "e1"))
        var needsFlush = await queue.needsFlushToDisk
        XCTAssertFalse(needsFlush)

        await queue.enqueue(makeTestEvent(messageId: "e2"))
        await queue.enqueue(makeTestEvent(messageId: "e3"))
        needsFlush = await queue.needsFlushToDisk
        XCTAssertTrue(needsFlush)
    }

    // MARK: - requeueToFront

    func testRequeueToFront() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )

        await queue.enqueue(makeTestEvent(messageId: "e3"))
        await queue.requeueToFront([
            makeTestEvent(messageId: "e1"),
            makeTestEvent(messageId: "e2"),
        ])

        let drained = await queue.drain(max: 10)
        XCTAssertEqual(drained.map(\.messageId), ["e1", "e2", "e3"])
    }

    // MARK: - clear

    func testClear() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )

        await queue.enqueue(makeTestEvent(messageId: "e1"))
        try await queue.flushToDisk()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("queue.v1.json").path
        ))

        await queue.clear()

        let count = await queue.count
        XCTAssertEqual(count, 0)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("queue.v1.json").path
        ), "clear() must delete disk snapshot to prevent stale rehydration")
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
