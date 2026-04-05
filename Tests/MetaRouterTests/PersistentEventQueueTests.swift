import XCTest
@testable import MetaRouter

final class PersistentEventQueueTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentQueueTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }


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

    func testFlushToDiskWithEmptyQueueSkipsWrite() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )

        try await queue.flushToDisk()

        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let snapshot = await diskStorage.read()
        XCTAssertNil(snapshot, "Empty queue should not write a snapshot to disk")
    }


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

    func testRehydrateIsIdempotentViaDiskDeletion() async throws {
        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let snapshot = QueueSnapshot(events: [makeTestEvent(messageId: "disk1")])
        try await diskStorage.write(snapshot)

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )
        let count1 = await queue.rehydrate()
        XCTAssertEqual(count1, 1)

        // Second rehydrate is a no-op because disk file was deleted
        let count2 = await queue.rehydrate()
        XCTAssertEqual(count2, 0)
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


    func testRehydrateDropsEventsOlderThan7Days() async throws {
        let now = Date()
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 60 * 60)

        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let snapshot = QueueSnapshot(events: [
            makeTestEvent(messageId: "old", timestamp: iso8601(eightDaysAgo)),
            makeTestEvent(messageId: "recent", timestamp: iso8601(sixDaysAgo)),
            makeTestEvent(messageId: "fresh", timestamp: iso8601(now)),
        ])
        try await diskStorage.write(snapshot)

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )
        let rehydrated = await queue.rehydrate()

        XCTAssertEqual(rehydrated, 2)
        let drained = await queue.drain(max: 10)
        XCTAssertEqual(drained.map(\.messageId), ["recent", "fresh"])
    }

    func testRehydrateKeepsEventsWithUnparseableTimestamp() async throws {
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)

        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let snapshot = QueueSnapshot(events: [
            makeTestEvent(messageId: "unparseable", timestamp: "not-a-date"),
            makeTestEvent(messageId: "old", timestamp: iso8601(eightDaysAgo)),
        ])
        try await diskStorage.write(snapshot)

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )
        let rehydrated = await queue.rehydrate()

        // Unparseable kept (fail-open), old one dropped
        XCTAssertEqual(rehydrated, 1)
        let drained = await queue.drain(max: 10)
        XCTAssertEqual(drained[0].messageId, "unparseable")
    }

    func testRehydrateDropsAllExpiredEvents() async throws {
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)

        let diskStorage = DiskStorage(baseDirectory: tempDir)
        let snapshot = QueueSnapshot(events: [
            makeTestEvent(messageId: "e1", timestamp: iso8601(eightDaysAgo)),
            makeTestEvent(messageId: "e2", timestamp: iso8601(tenDaysAgo)),
        ])
        try await diskStorage.write(snapshot)

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )
        let rehydrated = await queue.rehydrate()

        XCTAssertEqual(rehydrated, 0)
        let count = await queue.count
        XCTAssertEqual(count, 0)
    }


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


    func testFullRoundTrip_EnqueueFlushRehydrate() async throws {
        // Phase 1: Enqueue events and flush to disk
        let queue1 = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )
        for i in 0..<5 {
            await queue1.enqueue(makeTestEvent(messageId: "e\(i)"))
        }
        try await queue1.flushToDisk()

        // Simulate new process


        // Phase 2: Create new queue and rehydrate
        let queue2 = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )
        let rehydrated = await queue2.rehydrate()
        XCTAssertEqual(rehydrated, 5)

        // Phase 3: Verify order preserved
        let drained = await queue2.drain(max: 10)
        XCTAssertEqual(drained.count, 5)
        for i in 0..<5 {
            XCTAssertEqual(drained[i].messageId, "e\(i)")
        }
    }

    func testPartialDrainThenFlush() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )

        for i in 0..<5 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }
        _ = await queue.drain(max: 2) // removes e0, e1
        try await queue.flushToDisk()



        let queue2 = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )
        let rehydrated = await queue2.rehydrate()
        XCTAssertEqual(rehydrated, 3)

        let drained = await queue2.drain(max: 10)
        XCTAssertEqual(drained[0].messageId, "e2")
        XCTAssertEqual(drained[2].messageId, "e4")
    }

    func testFlushOverwriteEliminatesDuplicates() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )

        // First flush with 3 events
        for i in 0..<3 {
            await queue.enqueue(makeTestEvent(messageId: "batch1-e\(i)"))
        }
        try await queue.flushToDisk()

        // Drain all, enqueue 2 new events, flush again
        _ = await queue.drain(max: 10)
        await queue.enqueue(makeTestEvent(messageId: "batch2-e0"))
        await queue.enqueue(makeTestEvent(messageId: "batch2-e1"))
        try await queue.flushToDisk()



        let queue2 = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000
        )
        let rehydrated = await queue2.rehydrate()

        // Should only have batch2 events — full overwrite, no duplicates
        XCTAssertEqual(rehydrated, 2)
        let drained = await queue2.drain(max: 10)
        XCTAssertEqual(drained[0].messageId, "batch2-e0")
        XCTAssertEqual(drained[1].messageId, "batch2-e1")
    }
}


private func makeTestEvent(messageId: String = "mid", timestamp: String = "now") -> EnrichedEventPayload {
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
        timestamp: timestamp, writeKey: "wk", messageId: messageId, context: ctx
    )
}

private func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}
