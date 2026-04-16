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

    // MARK: - Offline Overflow Tests

    func testOverflowFlushesEntireQueueToDisk() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverflowTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 1000
        )

        // Fill to capacity
        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))
        await queue.enqueue(makeTestEvent(messageId: "e3"))

        // This enqueue triggers full queue flush to disk, then e4 is the only event in memory
        await queue.enqueue(makeTestEvent(messageId: "e4"))

        // Memory queue should have just the new event
        let memCount = await queue.count
        XCTAssertEqual(memCount, 1)
        let drained = await queue.drain(max: 10)
        XCTAssertEqual(drained.map(\.messageId), ["e4"])

        // Overflow disk should have the full flushed queue
        let overflowBatch = await queue.readOverflowBatch(max: 10)
        XCTAssertEqual(overflowBatch.map(\.messageId), ["e1", "e2", "e3"])
    }

    func testOverflowAlwaysFlushesRegardlessOfOnlineState() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverflowAlwaysTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 1000
        )

        // No setOfflineOverflowEnabled call needed — overflow is always active
        // when overflowDiskStorage exists and queue hits capacity
        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))
        await queue.enqueue(makeTestEvent(messageId: "e3"))
        await queue.enqueue(makeTestEvent(messageId: "e4"))

        let memCount = await queue.count
        XCTAssertEqual(memCount, 1)

        let overflowBatch = await queue.readOverflowBatch(max: 10)
        XCTAssertEqual(overflowBatch.count, 3, "Overflow should always flush to disk when storage exists")
    }

    func testOverflowDiskCapDropsOldest() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverflowCapTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 5
        )

        // Fill memory, then trigger multiple flushes (exceeds cap of 5)
        // Each time the queue hits 3, it flushes all 3 to disk
        for i in 0..<11 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        // Memory has the events after the last flush
        // With capacity 3: flushes at e3 (writes e0,e1,e2), at e6 (writes e3,e4,e5), at e9 (writes e6,e7,e8)
        // Memory has: e9, e10
        let memDrained = await queue.drain(max: 10)
        XCTAssertEqual(memDrained.map(\.messageId), ["e9", "e10"])

        // Overflow disk should have exactly 5 (cap), with oldest dropped
        let overflowBatch = await queue.readOverflowBatch(max: 100)
        XCTAssertEqual(overflowBatch.count, 5)
        // Should have e4..e8 (oldest e0..e3 dropped by disk cap)
        XCTAssertEqual(overflowBatch.map(\.messageId), ["e4", "e5", "e6", "e7", "e8"])
    }

    func testOverflowWritesToDiskImmediately() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverflowImmediateTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 10000
        )

        // Fill to capacity and trigger overflow
        for i in 0..<4 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        // Overflow file should exist immediately (no buffering)
        let overflowPath = overflowDir.appendingPathComponent("overflow.v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: overflowPath.path),
            "Overflow should write to disk immediately on capacity hit, no buffering")

        let overflowBatch = await queue.readOverflowBatch(max: 100)
        XCTAssertEqual(overflowBatch.count, 3, "All 3 flushed events should be on disk")
    }

    func testMultipleOverflowFlushesAccumulate() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverflowAccumulateTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 10000
        )

        // Trigger multiple overflows: 7 events with capacity 3
        // Flush at e3 (writes e0,e1,e2), flush at e6 (writes e3,e4,e5)
        for i in 0..<7 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        // Memory should have e6
        let memCount = await queue.count
        XCTAssertEqual(memCount, 1)

        // Overflow disk should have accumulated events from both flushes
        let overflowBatch = await queue.readOverflowBatch(max: 100)
        XCTAssertEqual(overflowBatch.count, 6)
        XCTAssertEqual(overflowBatch.map(\.messageId), ["e0", "e1", "e2", "e3", "e4", "e5"])
    }

    func testDrainReadsThenRemovesBatches() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrainTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let overflowDisk = DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json")
        // Seed overflow disk with events
        let events = (0..<5).map { makeTestEvent(messageId: "overflow-\($0)") }
        try await overflowDisk.write(QueueSnapshot(events: events))

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 100,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 10000
        )

        // Read batch
        let batch = await queue.readOverflowBatch(max: 3)
        XCTAssertEqual(batch.count, 3)
        XCTAssertEqual(batch.map(\.messageId), ["overflow-0", "overflow-1", "overflow-2"])

        // Remove batch
        await queue.removeOverflowBatch(count: 3)

        // Remaining should be 2
        let remaining = await queue.readOverflowBatch(max: 10)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(remaining.map(\.messageId), ["overflow-3", "overflow-4"])

        // Remove last batch
        await queue.removeOverflowBatch(count: 2)

        // File should be deleted
        let overflowPath = overflowDir.appendingPathComponent("overflow.v1.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: overflowPath.path),
            "Overflow file should be deleted when all events are drained")
    }

    func testClearDeletesOverflowDisk() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClearOverflowTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 1000
        )

        // Fill and trigger overflow flush to disk
        for i in 0..<6 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        let overflowPath = overflowDir.appendingPathComponent("overflow.v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: overflowPath.path))

        await queue.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: overflowPath.path),
            "clear() must delete overflow disk file")
        let count = await queue.count
        XCTAssertEqual(count, 0)
    }

    func testAppKillWhileOfflineThenRelaunchOnline() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelaunchTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        // Phase 1: Simulate offline session — fill memory, overflow to disk
        let queue1 = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 1000
        )

        for i in 0..<8 {
            await queue1.enqueue(makeTestEvent(messageId: "session1-\(i)"))
        }
        // Simulate app backgrounding / kill
        try await queue1.flushToDisk()

        // Phase 2: Simulate relaunch — new queue instance reads from disk
        let queue2 = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 100,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 1000
        )

        // Rehydrate memory queue — with capacity 3, after 8 events:
        // flushes at e3 (writes e0,e1,e2), at e6 (writes e3,e4,e5)
        // memory has e6, e7 at time of flushToDisk
        let rehydrated = await queue2.rehydrate()
        XCTAssertEqual(rehydrated, 2, "Memory queue should rehydrate from main disk")

        // Overflow should still be on disk from previous session
        let overflowBatch = await queue2.readOverflowBatch(max: 100)
        XCTAssertEqual(overflowBatch.count, 6, "Overflow events should persist across app restart")
        XCTAssertEqual(overflowBatch.first?.messageId, "session1-0")
    }

    func testOverflowNoOpWhenStorageNil() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: nil,
            maxOfflineDiskEvents: 1000
        )

        // Events beyond capacity should just be dropped (existing behavior)
        for i in 0..<5 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        let count = await queue.count
        XCTAssertEqual(count, 3)

        // No overflow disk → flushToOverflowDisk is a no-op
        let flushed = await queue.flushToOverflowDisk()
        XCTAssertFalse(flushed, "No overflow should exist without overflow storage")
    }

    func testFlushToOverflowDiskDrainsMemoryQueue() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplicitFlushTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 100,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 10000
        )

        // Enqueue events (below capacity, so no automatic flush)
        for i in 0..<5 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        let memBefore = await queue.count
        XCTAssertEqual(memBefore, 5)

        // Explicitly flush to overflow disk (e.g., when dispatcher detects offline)
        let flushed = await queue.flushToOverflowDisk()
        XCTAssertTrue(flushed)

        // Memory should be empty
        let memAfter = await queue.count
        XCTAssertEqual(memAfter, 0)

        // Overflow disk should have all events
        let overflowBatch = await queue.readOverflowBatch(max: 10)
        XCTAssertEqual(overflowBatch.count, 5)
        XCTAssertEqual(overflowBatch.map(\.messageId), ["e0", "e1", "e2", "e3", "e4"])
    }
}


private func makeTestEvent(messageId: String = "mid", timestamp: String = "now") -> EnrichedEventPayload {
    let ctx = EventContext(
        app: AppContext(name: "a", version: "1", build: "1", namespace: "a"),
        device: DeviceContext(manufacturer: "a", model: "m", type: "t"),
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
