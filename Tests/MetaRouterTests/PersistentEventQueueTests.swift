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

    // MARK: - Memory queue basics

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

    // MARK: - flushMemoryToDisk

    func testFlushMemoryToDiskWritesAndClearsMemory() async throws {
        let queue = makeQueue()
        await queue.enqueue(makeTestEvent(messageId: "e1"))
        await queue.enqueue(makeTestEvent(messageId: "e2"))

        let flushed = await queue.flushMemoryToDisk()
        XCTAssertTrue(flushed)

        let count = await queue.count
        XCTAssertEqual(count, 0, "Memory should be empty after flush")

        let snapshot = await DiskStorage(baseDirectory: tempDir).read()
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

        let snapshot = await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.map(\.messageId), ["e1", "e2"],
            "Second flush should append to existing disk contents")
    }

    func testFlushMemoryToDiskEnforcesMaxDiskEvents() async throws {
        let queue = makeQueue(maxEventCount: 100, maxDiskEvents: 5)

        for i in 0..<12 {
            await queue.enqueue(makeTestEvent(messageId: "e\(i)"))
        }
        _ = await queue.flushMemoryToDisk()

        let snapshot = await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.count, 5, "Disk cap should drop oldest")
        XCTAssertEqual(snapshot?.events.first?.messageId, "e7")
        XCTAssertEqual(snapshot?.events.last?.messageId, "e11")
    }

    func testFlushMemoryToDiskWithEmptyQueueIsNoOp() async throws {
        let queue = makeQueue()
        let flushed = await queue.flushMemoryToDisk()
        XCTAssertFalse(flushed)

        let snapshot = await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertNil(snapshot)
    }

    // MARK: - Capacity overflow flushes to disk (no drops)

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

        let snapshot = await DiskStorage(baseDirectory: tempDir).read()
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

        let snapshot = await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.map(\.messageId), ["e1", "e2", "e3", "e4", "e5", "e6"])
    }

    // MARK: - requeueToFront at capacity (bug fix)

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
        let snapshot = await DiskStorage(baseDirectory: tempDir).read()
        XCTAssertEqual(snapshot?.events.map(\.messageId), ["m1", "m2", "m3"],
            "Displaced memory events must land on disk, not be dropped")
    }

    // MARK: - checkForPersistedEvents

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

    // MARK: - Drain primitives

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

        let snapshot = await DiskStorage(baseDirectory: tempDir).read()
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

    // MARK: - Clear

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

    // MARK: - Flush threshold

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

    // MARK: - Cross-session persistence

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
