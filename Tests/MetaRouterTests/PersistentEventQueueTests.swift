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

    private func makeQueue(maxEventCount: Int = 2000, maxDiskEvents: Int = 10_000) -> PersistentEventQueue {
        PersistentEventQueue(
            diskStore: DiskStorage(baseDirectory: tempDir),
            maxEventCount: maxEventCount,
            maxSizeBytes: 5_000_000,
            maxDiskEvents: maxDiskEvents
        )
    }

    private var diskFilePath: URL {
        tempDir.appendingPathComponent("queue.v1.json")
    }

    func testEnqueueWritesToMemoryOnly() async throws {
        let queue = makeQueue()
        await queue.enqueue(makeTestEvent(messageId: "e1"))

        let count = await queue.count
        XCTAssertEqual(count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: diskFilePath.path))
    }

    func testDrainReadsFromMemoryOnly() async throws {
        let queue = makeQueue()
        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))

        let drained = await queue.drain(max: 1)
        XCTAssertEqual(drained.map(\.messageId), ["e1"])

        let remaining = await queue.count
        XCTAssertEqual(remaining, 1)
    }

    func testFlushMemoryToDiskWritesAndClearsMemory() async throws {
        let queue = makeQueue()
        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))

        let flushed = await queue.flushMemoryToDisk()
        XCTAssertTrue(flushed)

        let count = await queue.count
        XCTAssertEqual(count, 0, "Memory should be empty after flush")

        let snapshot = try await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.map(\.messageId), ["e1", "e2"])
    }

    func testFlushMemoryToDiskAppendsToExistingDiskContents() async throws {
        let queue = makeQueue()

        // First flush
        await queue.enqueue(makeTestEvent(messageId: "e1"))
        _ = await queue.flushMemoryToDisk()

        // Second flush — should append, not overwrite
        await queue.enqueue(makeTestEvent(messageId: "e2"))
        _ = await queue.flushMemoryToDisk()

        let snapshot = try await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.map(\.messageId), ["e1", "e2"],
            "Second flush should append to existing disk contents")
    }

    func testFlushMemoryToDiskEnforcesMaxDiskEvents() async throws {
        let queue = makeQueue(maxEventCount: 100, maxDiskEvents: 5)

        for i in 0..<12 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }
        _ = await queue.flushMemoryToDisk()

        let snapshot = try await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.count, 5, "Disk cap should drop oldest")
        XCTAssertEqual(snapshot?.events.first?.messageId, "e7")
        XCTAssertEqual(snapshot?.events.last?.messageId, "e11")
    }

    func testFlushMemoryToDiskWithEmptyQueueIsNoOp() async throws {
        let queue = makeQueue()
        let flushed = await queue.flushMemoryToDisk()
        XCTAssertFalse(flushed)

        let snapshot = try await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertNil(snapshot)
    }


    func testEnqueueAtCapacityFlushesEntireMemoryToDisk() async throws {
        let queue = makeQueue(maxEventCount: 3)

        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))
        await queue.enqueue(makeTestEvent(messageId: "e3"))

        // e4 triggers a flush of e1-e3 to disk before inserting
        await queue.enqueue(makeTestEvent(messageId: "e4"))

        let memCount = await queue.count
        XCTAssertEqual(memCount, 1, "Memory should only have e4 after capacity flush")
        let drained = await queue.drain(max: 10)
        XCTAssertEqual(drained.map(\.messageId), ["e4"])

        let snapshot = try await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.map(\.messageId), ["e1", "e2", "e3"])
    }

    func testMultipleCapacityOverflowsAccumulateOnDisk() async throws {
        let queue = makeQueue(maxEventCount: 3)

        // 7 events with memory cap 3: flushes at e4 (wrote e1-e3) and at e7 (wrote e4-e6)
        for i in 1...7 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        let memCount = await queue.count
        XCTAssertEqual(memCount, 1)

        let snapshot = try await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.map(\.messageId), ["e1", "e2", "e3", "e4", "e5", "e6"])
    }


    func testRequeueToFrontPreservesOrderBelowCapacity() async throws {
        let queue = makeQueue()
        await queue.enqueue(makeTestEvent(messageId: "e3"))
        await queue.requeueToFront([
            makeTestEvent(messageId: "e1"),
            makeTestEvent(messageId: "e2"),
        ])

        let drained = await queue.drain(max: 10)
        XCTAssertEqual(drained.map(\.messageId), ["e1", "e2", "e3"])
    }

    func testRequeueToFrontAtCapacityFlushesMemoryToDisk() async throws {
        let queue = makeQueue(maxEventCount: 3)

        // Fill memory to capacity
        await queue.enqueue(makeTestEvent(messageId: "m1"))
        await queue.enqueue(makeTestEvent(messageId: "m2"))
        await queue.enqueue(makeTestEvent(messageId: "m3"))

        // Requeue 2 more — combined 5 > cap 3, so memory flushes first
        await queue.requeueToFront([
            makeTestEvent(messageId: "r1"),
            makeTestEvent(messageId: "r2"),
        ])

        // Memory should have the requeued events only
        let drained = await queue.drain(max: 10)
        XCTAssertEqual(drained.map(\.messageId), ["r1", "r2"],
            "Requeued events stay in memory")

        // m1-m3 should be on disk (no drops)
        let snapshot = try await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.map(\.messageId), ["m1", "m2", "m3"],
            "Displaced memory events must land on disk, not be dropped")
    }

    func testCheckForPersistedEventsReturnsFalseWhenNoFile() async throws {
        let queue = makeQueue()
        let has = await queue.checkForPersistedEvents()
        XCTAssertFalse(has)
        let hasDisk = await queue.hasDiskData
        XCTAssertFalse(hasDisk)
    }

    func testCheckForPersistedEventsReturnsTrueWhenFileExists() async throws {
        // Seed the disk
        let disk = DiskStorage(baseDirectory: tempDir)
        try await disk.write(QueueSnapshot(events: [makeTestEvent(messageId: "seeded")]))

        let queue = makeQueue()
        let has = await queue.checkForPersistedEvents()
        XCTAssertTrue(has)
        let hasDisk = await queue.hasDiskData
        XCTAssertTrue(hasDisk)
    }

    func testCheckForPersistedEventsDoesNotLoadIntoMemory() async throws {
        let disk = DiskStorage(baseDirectory: tempDir)
        let events = (0..<5).map { makeTestEvent(messageId: "disk-\($0)") }
        try await disk.write(QueueSnapshot(events: events))

        let queue = makeQueue()
        _ = await queue.checkForPersistedEvents()

        let memCount = await queue.count
        XCTAssertEqual(memCount, 0, "Memory queue must start empty — events stay on disk")
    }


    func testReadAllFromDiskAndDeleteClearsFile() async throws {
        let disk = DiskStorage(baseDirectory: tempDir)
        let events = (0..<5).map { makeTestEvent(messageId: "d\($0)") }
        try await disk.write(QueueSnapshot(events: events))

        let queue = makeQueue()
        _ = await queue.checkForPersistedEvents()

        let loaded = await queue.readAllFromDiskAndDelete()
        XCTAssertEqual(loaded.map(\.messageId), ["d0", "d1", "d2", "d3", "d4"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: diskFilePath.path))
        let hasDisk = await queue.hasDiskData
        XCTAssertFalse(hasDisk)
    }

    func testWriteDiskStoreOverwrites() async throws {
        let queue = makeQueue()
        await queue.writeDiskStore([makeTestEvent(messageId: "v1")])
        await queue.writeDiskStore([makeTestEvent(messageId: "v2-a"), makeTestEvent(messageId: "v2-b")])

        let snapshot = try await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.map(\.messageId), ["v2-a", "v2-b"])
        let hasDisk = await queue.hasDiskData
        XCTAssertTrue(hasDisk)
    }

    func testWriteDiskStoreWithEmptyDeletesFile() async throws {
        let queue = makeQueue()
        await queue.writeDiskStore([makeTestEvent(messageId: "v1")])
        await queue.writeDiskStore([])

        XCTAssertFalse(FileManager.default.fileExists(atPath: diskFilePath.path))
        let hasDisk = await queue.hasDiskData
        XCTAssertFalse(hasDisk)
    }

    func testDeleteDiskStoreClearsFlag() async throws {
        let queue = makeQueue()
        await queue.writeDiskStore([makeTestEvent(messageId: "e1")])
        let hasDisk = await queue.hasDiskData
        XCTAssertTrue(hasDisk)

        await queue.deleteDiskStore()
        let hasDiskAfter = await queue.hasDiskData
        XCTAssertFalse(hasDiskAfter)
        XCTAssertFalse(FileManager.default.fileExists(atPath: diskFilePath.path))
    }


    func testClearEmptiesMemoryAndDisk() async throws {
        let queue = makeQueue()
        await queue.enqueue(makeTestEvent(messageId: "m1"))
        _ = await queue.flushMemoryToDisk()
        await queue.enqueue(makeTestEvent(messageId: "m2"))

        await queue.clear()

        let count = await queue.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: diskFilePath.path))
        let hasDisk = await queue.hasDiskData
        XCTAssertFalse(hasDisk)
    }


    func testFlushThresholdReachedByCount() async throws {
        let queue = PersistentEventQueue(
            diskStore: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 2000,
            maxSizeBytes: 5_000_000,
            flushThresholdCount: 3,
            flushThresholdBytes: 5_000_000,
            maxDiskEvents: 10_000
        )

        await queue.enqueue(makeTestEvent(messageId: "e1"))
        var needsFlush = await queue.needsFlushToDisk
        XCTAssertFalse(needsFlush)

        await queue.enqueue(makeTestEvent(messageId: "e2"))
        await queue.enqueue(makeTestEvent(messageId: "e3"))
        needsFlush = await queue.needsFlushToDisk
        XCTAssertTrue(needsFlush)
    }


    func testFlushMemoryToDiskIsNoOpWhenMaxDiskEventsZero() async throws {
        let queue = makeQueue(maxDiskEvents: 0)
        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))

        let flushed = await queue.flushMemoryToDisk()
        XCTAssertFalse(flushed, "flush should report no-op when persistence is disabled")

        XCTAssertFalse(FileManager.default.fileExists(atPath: diskFilePath.path),
                       "No disk file should be written when maxDiskEvents == 0")

        let memCount = await queue.count
        XCTAssertEqual(memCount, 2, "Events should remain in memory when persistence is disabled")
    }

    func testEnqueueAtCapacityDropsOldestWhenMaxDiskEventsZero() async throws {
        let queue = makeQueue(maxEventCount: 3, maxDiskEvents: 0)

        for i in 1...5 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: diskFilePath.path),
                       "Nothing should ever hit disk when persistence is disabled")

        let drained = await queue.drain(max: 10)
        XCTAssertEqual(drained.map(\.messageId), ["e3", "e4", "e5"],
                       "Memory queue should drop oldest (ring buffer) when persistence disabled")
    }

    func testWriteDiskStoreIsNoOpWhenMaxDiskEventsZero() async throws {
        let queue = makeQueue(maxDiskEvents: 0)
        await queue.writeDiskStore([makeTestEvent(messageId: "e1")])

        XCTAssertFalse(FileManager.default.fileExists(atPath: diskFilePath.path),
                       "writeDiskStore should no-op when persistence is disabled")
        let has = await queue.hasDiskData
        XCTAssertFalse(has)
    }

    func testRequeueToFrontDropsNewestWhenMaxDiskEventsZero() async throws {
        let queue = makeQueue(maxEventCount: 3, maxDiskEvents: 0)

        // Fill memory: e1, e2, e3
        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))
        await queue.enqueue(makeTestEvent(messageId: "e3"))

        // Simulate a retry: drain (sends a batch), it fails, requeue to front
        let batch = await queue.drain(max: 2)
        XCTAssertEqual(batch.map(\.messageId), ["e1", "e2"])

        // Memory now: [e3]. Requeue [e1, e2] to front.
        await queue.requeueToFront([makeTestEvent(messageId: "e1"), makeTestEvent(messageId: "e2")])

        // Memory should be [e1, e2, e3] — fits, no eviction
        var contents = await queue.drain(max: 10)
        XCTAssertEqual(contents.map(\.messageId), ["e1", "e2", "e3"])

        // Now harder case: cap=2, fill with [a, b], requeue [r1, r2] — r1/r2 must survive,
        // newest (b) must be dropped, NOT oldest (a) → drop-from-back semantics
        let q2 = makeQueue(maxEventCount: 2, maxDiskEvents: 0)
        await q2.enqueue(makeTestEvent(messageId: "a"))
        await q2.enqueue(makeTestEvent(messageId: "b"))
        await q2.requeueToFront([makeTestEvent(messageId: "r1"), makeTestEvent(messageId: "r2")])

        XCTAssertFalse(FileManager.default.fileExists(atPath: diskFilePath.path),
                       "no disk file should be written in 0-mode")

        contents = await q2.drain(max: 10)
        XCTAssertEqual(contents.map(\.messageId), ["r1", "r2"],
                       "requeued events must survive; newest entries (a, b) get dropped from the back")
    }


    func testPersistsAcrossInstances() async throws {
        let queue1 = makeQueue()
        for i in 0..<5 {
            await queue1.enqueue(makeTestEvent(messageId: "s1-\(i)"))
        }
        _ = await queue1.flushMemoryToDisk()

        // Simulate relaunch
        let queue2 = makeQueue()
        let has = await queue2.checkForPersistedEvents()
        XCTAssertTrue(has)

        // Events are not in memory — they're on disk for the drain to pick up
        let memCount = await queue2.count
        XCTAssertEqual(memCount, 0)

        let drained = await queue2.readAllFromDiskAndDelete()
        XCTAssertEqual(drained.map(\.messageId), ["s1-0", "s1-1", "s1-2", "s1-3", "s1-4"])
    }

    func testReadAllFromDiskAndDeleteFiltersEventsOlderThanTTL() async throws {
        let iso = ISO8601DateFormatter()
        let recent = iso.string(from: Date())
        let expired = iso.string(from: Date().addingTimeInterval(-8 * 24 * 60 * 60)) // 8 days ago

        let disk = DiskStorage(baseDirectory: tempDir)
        let events = [
            makeTestEvent(messageId: "expired-1", timestamp: expired),
            makeTestEvent(messageId: "recent-1", timestamp: recent),
            makeTestEvent(messageId: "expired-2", timestamp: expired),
            makeTestEvent(messageId: "recent-2", timestamp: recent),
        ]
        try await disk.write(QueueSnapshot(events: events))

        let queue = makeQueue()
        _ = await queue.checkForPersistedEvents()
        let drained = await queue.readAllFromDiskAndDelete()

        XCTAssertEqual(drained.map(\.messageId), ["recent-1", "recent-2"],
                       "Events older than 7 days should be filtered out on drain")
    }

    // Pending overflow on disk write failure

    /// Poison the tempDir path so DiskStorage.ensureDirectory fails.
    /// Creates a regular file where the queue expects a directory.
    private func poisonDiskPath() throws {
        try FileManager.default.createDirectory(
            at: tempDir.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: tempDir)
    }

    func testPendingOverflowPreservesEventsWhenDiskWriteFailsAtCapacity() async throws {
        try poisonDiskPath()
        let queue = makeQueue(maxEventCount: 3)

        for i in 1...5 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        // Nothing should have been dropped (neither memory ring-buffer nor disk).
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: diskFilePath.path),
                       "No disk file should be created while path is poisoned")

        // Recover: remove the poison so subsequent flush can succeed.
        try FileManager.default.removeItem(at: tempDir)

        // Next successful flush should persist all 5 events (3 memory + 2 pending overflow).
        let flushed = await queue.flushMemoryToDisk()
        XCTAssertTrue(flushed)

        let snapshot = try await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.map(\.messageId), ["e1", "e2", "e3", "e4", "e5"],
                       "No events should be lost across failure + recovery")
    }

    func testPendingOverflowRetainedAcrossRepeatedFailures() async throws {
        try poisonDiskPath()
        let queue = makeQueue(maxEventCount: 2)

        // memory cap 2 + 4 overflow events = 6 total, all must survive
        for i in 1...6 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        try FileManager.default.removeItem(at: tempDir)
        _ = await queue.flushMemoryToDisk()

        let snapshot = try await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.count, 6)
    }

    //  Byte cap enforcement on enqueue

    func testEnqueueAtByteCapFlushesMemoryToDisk() async throws {
        // maxSizeBytes small enough that a few test events exceed it.
        let queue = PersistentEventQueue(
            diskStore: DiskStorage(baseDirectory: tempDir),
            maxEventCount: 1000,   // count cap won't trip
            maxSizeBytes: 1500,
            maxDiskEvents: 10_000
        )

        for i in 1...8 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }

        let memCount = await queue.count
        XCTAssertLessThan(memCount, 8, "Byte cap should have triggered a flush; memory should not hold all 8")

        XCTAssertTrue(FileManager.default.fileExists(atPath: diskFilePath.path),
                      "Byte cap flush should have written to disk")
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
