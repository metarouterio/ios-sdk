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

    func testOverflowBuffersToDiskinsteadOfDropping() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverflowTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 1000
        )

        await queue.setOfflineOverflowEnabled(true)

        // Fill to capacity
        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))
        await queue.enqueue(makeTestEvent(messageId: "e3"))

        // This enqueue should evict e1 to overflow buffer, not drop it
        await queue.enqueue(makeTestEvent(messageId: "e4"))
        await queue.enqueue(makeTestEvent(messageId: "e5"))

        // Memory queue should have newest 3
        let memCount = await queue.count
        XCTAssertEqual(memCount, 3)
        let drained = await queue.drain(max: 10)
        XCTAssertEqual(drained.map(\.messageId), ["e3", "e4", "e5"])

        // Overflow buffer should have evicted events (flush to check)
        await queue.flushOverflowBufferToDisk()
        let overflowBatch = await queue.readOverflowBatch(max: 10)
        XCTAssertEqual(overflowBatch.map(\.messageId), ["e1", "e2"])
    }

    func testOverflowDisabledDropsAsUsual() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverflowDisabledTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 1000
        )

        // Overflow NOT enabled — events should be dropped as usual
        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))
        await queue.enqueue(makeTestEvent(messageId: "e3"))
        await queue.enqueue(makeTestEvent(messageId: "e4"))

        let memCount = await queue.count
        XCTAssertEqual(memCount, 3)

        let overflowCount = await queue.overflowCount()
        XCTAssertEqual(overflowCount, 0, "No overflow events should exist when overflow is disabled")
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

        await queue.setOfflineOverflowEnabled(true)

        // Fill memory, then overflow 8 events (exceeds cap of 5)
        for i in 0..<11 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        // Memory has 3 newest: e8, e9, e10
        let memDrained = await queue.drain(max: 10)
        XCTAssertEqual(memDrained.map(\.messageId), ["e8", "e9", "e10"])

        // Overflow disk should have exactly 5 (cap), with oldest dropped
        await queue.flushOverflowBufferToDisk()
        let overflowBatch = await queue.readOverflowBatch(max: 100)
        XCTAssertEqual(overflowBatch.count, 5)
        // Should have e3..e7 (oldest e0..e2 dropped by disk cap)
        XCTAssertEqual(overflowBatch.map(\.messageId), ["e3", "e4", "e5", "e6", "e7"])
    }

    func testOverflowBatchedWriteNotPerEvent() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverflowBatchTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 10000
        )

        await queue.setOfflineOverflowEnabled(true)

        // Fill memory and overflow 50 events (below batch threshold of 100)
        for i in 0..<53 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        // The overflow file should NOT exist yet since buffer hasn't hit threshold
        let overflowPath = overflowDir.appendingPathComponent("overflow.v1.json")
        let fileExistsBeforeFlush = FileManager.default.fileExists(atPath: overflowPath.path)
        XCTAssertFalse(fileExistsBeforeFlush,
            "Buffer should batch writes, not write per event (50 events < 100 batch threshold)")

        // Explicitly flush buffer to disk
        await queue.flushOverflowBufferToDisk()
        let overflowBatch = await queue.readOverflowBatch(max: 100)
        XCTAssertEqual(overflowBatch.count, 50, "All 50 overflow events should be on disk after flush")
    }

    func testOverflowAutoFlushesAtBatchThreshold() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverflowAutoFlush-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 10000
        )

        await queue.setOfflineOverflowEnabled(true)

        // Overflow 103 events (100 = batch threshold, should auto-flush first 100)
        for i in 0..<106 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        // After 103 overflows, the first 100 should have auto-flushed to disk
        let overflowPath = overflowDir.appendingPathComponent("overflow.v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: overflowPath.path),
            "Overflow should auto-flush to disk at batch threshold")

        // Flush remaining buffer and verify total
        await queue.flushOverflowBufferToDisk()
        let total = await queue.readOverflowBatch(max: 10000)
        XCTAssertEqual(total.count, 103, "All overflow events should be persisted after flush")
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

        await queue.setOfflineOverflowEnabled(true)

        // Fill and overflow
        for i in 0..<6 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }
        await queue.flushOverflowBufferToDisk()

        let overflowPath = overflowDir.appendingPathComponent("overflow.v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: overflowPath.path))

        await queue.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: overflowPath.path),
            "clear() must delete overflow disk file")
        let count = await queue.count
        XCTAssertEqual(count, 0)
    }

    func testFlushToDiskAlsoFlushesOverflowBuffer() async throws {
        let overflowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlushBothTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: overflowDir) }

        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json"),
            maxOfflineDiskEvents: 1000
        )

        await queue.setOfflineOverflowEnabled(true)

        // Fill and overflow (but below batch threshold, so buffer not yet written)
        for i in 0..<6 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        // flushToDisk should persist both memory queue and overflow buffer
        try await queue.flushToDisk()

        // Verify overflow was persisted
        let overflowDisk = DiskStorage(baseDirectory: overflowDir, fileName: "overflow.v1.json")
        let snapshot = await overflowDisk.read()
        XCTAssertEqual(snapshot?.events.count, 3, "Overflow buffer should be flushed by flushToDisk")
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

        await queue1.setOfflineOverflowEnabled(true)
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

        // Rehydrate memory queue
        let rehydrated = await queue2.rehydrate()
        XCTAssertEqual(rehydrated, 3, "Memory queue should rehydrate from main disk")

        // Overflow should still be on disk from previous session
        let overflowBatch = await queue2.readOverflowBatch(max: 100)
        XCTAssertEqual(overflowBatch.count, 5, "Overflow events should persist across app restart")
        XCTAssertEqual(overflowBatch.first?.messageId, "session1-0")
    }

    func testOverflowNoOpWhenStorageNil() async throws {
        let queue = PersistentEventQueue(
            diskStorage: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 3,
            overflowDiskStorage: nil,
            maxOfflineDiskEvents: 1000
        )

        // setOfflineOverflowEnabled is a no-op when storage is nil
        await queue.setOfflineOverflowEnabled(true)

        // Events beyond capacity should just be dropped (existing behavior)
        for i in 0..<5 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        let count = await queue.count
        XCTAssertEqual(count, 3)

        let overflowCount = await queue.overflowCount()
        XCTAssertEqual(overflowCount, 0, "No overflow should exist without overflow storage")
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
