import Foundation

/// Persistence-aware event queue with a single disk store for both runtime overflow
/// and crash-safety snapshots. Memory is the fast path; disk is the durability path.
///
/// Write paths (all converge to `flushMemoryToDisk`):
/// - `enqueue()` at capacity — flushes entire memory queue to disk before inserting
/// - `requeueToFront()` at capacity — flushes memory to disk, then inserts requeued events
/// - `flushMemoryToDisk()` explicit — called from background lifecycle, threshold, offline push-back
///
/// Read path:
/// - `checkForPersistedEvents()` — cheap boot-time file-existence gate
/// - `readAllFromDiskAndDelete()` — drain's single-read primitive (atomic actor hop)
/// - `writeDiskStore(_:)` — drain's checkpoint + "write remainder on failure" primitive
///
/// Concurrency:
/// - `withDiskLock { }` — acquired by the dispatcher for the full `drainDiskStoreToNetwork`
/// - `flushMemoryToDisk` internally takes the same lock, serializing against drain
public actor PersistentEventQueue {

    private static let jsonEncoder = JSONEncoder()

    /// Events older than this are dropped on read-back from disk.
    static let eventTTL: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    private let maxEventCount: Int
    private let maxSizeBytes: Int
    private let flushThresholdCount: Int
    private let flushThresholdBytes: Int
    private let maxDiskEvents: Int

    private let memoryQueue: EventQueue<EnrichedEventPayload>
    private let diskStore: DiskStorage
    private let diskLock = AsyncMutex()

    /// Running estimate of serialized bytes in the memory queue.
    private var estimatedBytes: Int = 0

    /// Lightweight gate for "is there anything on disk worth draining."
    /// Initialized via `checkForPersistedEvents()` on boot, updated by disk writes/deletes.
    private var _hasDiskData: Bool = false

    public var hasDiskData: Bool { _hasDiskData }

    public init(
        diskStore: DiskStorage,
        maxEventCount: Int = 2000,
        maxSizeBytes: Int = 5_242_880, // 5MB
        flushThresholdCount: Int = 500,
        flushThresholdBytes: Int = 2_097_152, // 2MB
        maxDiskEvents: Int = 10000
    ) {
        self.diskStore = diskStore
        self.maxEventCount = max(1, maxEventCount)
        self.maxSizeBytes = max(1, maxSizeBytes)
        self.flushThresholdCount = max(1, flushThresholdCount)
        self.flushThresholdBytes = max(1, flushThresholdBytes)
        self.memoryQueue = EventQueue<EnrichedEventPayload>(capacity: maxEventCount)
        self.maxDiskEvents = max(0, maxDiskEvents)
    }

    // MARK: - Boot

    /// Cheap file-existence check. Sets `hasDiskData` without parsing the file.
    /// Returns `true` if there are persisted events on disk.
    @discardableResult
    public func checkForPersistedEvents() async -> Bool {
        let exists = await diskStore.exists()
        _hasDiskData = exists
        if exists {
            Logger.log("Persisted events detected on disk — drain will run when online")
        } else {
            Logger.log("No persisted events on disk")
        }
        return exists
    }

    // MARK: - Memory queue operations

    /// Enqueue an event to the in-memory buffer.
    /// When the queue is at capacity, the entire memory queue is flushed to disk first.
    /// Returns the queue count after insertion.
    @discardableResult
    public func enqueue(_ event: EnrichedEventPayload) async -> Int {
        let currentCount = await memoryQueue.count
        if currentCount >= maxEventCount {
            await flushMemoryToDisk()
        }

        let prevCount = await memoryQueue.count
        let newCount = await memoryQueue.enqueue(event)
        let eventSize = Self.estimateEventSize(event)
        if newCount <= prevCount, estimatedBytes > 0, prevCount > 0 {
            estimatedBytes -= estimatedBytes / prevCount
        }
        estimatedBytes += eventSize
        return newCount
    }

    /// Drain up to `max` events from the front of the in-memory buffer. No disk I/O.
    public func drain(max count: Int) async -> [EnrichedEventPayload] {
        let events = await memoryQueue.drain(max: count)
        for event in events {
            estimatedBytes -= Self.estimateEventSize(event)
        }
        estimatedBytes = max(0, estimatedBytes)
        return events
    }

    /// Requeue events at the front (used after retryable send failures).
    /// If memory cannot fit both current contents and the requeued events, flushes
    /// current memory to disk first so nothing is dropped.
    public func requeueToFront(_ events: [EnrichedEventPayload]) async {
        guard !events.isEmpty else { return }
        let currentCount = await memoryQueue.count
        if currentCount + events.count > maxEventCount {
            await flushMemoryToDisk()
        }
        await memoryQueue.requeueToFront(events)
        for event in events {
            estimatedBytes += Self.estimateEventSize(event)
        }
    }

    /// Drop current front batch without requeueing.
    public func dropFront(_ count: Int) async {
        await memoryQueue.dropFront(count)
        if await memoryQueue.count == 0 {
            estimatedBytes = 0
        }
    }

    /// Clear all events from memory AND delete the disk store.
    public func clear() async {
        await memoryQueue.clear()
        estimatedBytes = 0
        await deleteDiskStore()
    }

    /// Current number of events in memory.
    public var count: Int {
        get async { await memoryQueue.count }
    }

    /// Returns true if the memory buffer has reached the flush-to-disk threshold.
    public var needsFlushToDisk: Bool {
        get async {
            let eventCount = await memoryQueue.count
            if eventCount >= flushThresholdCount {
                return true
            }
            return estimatedBytes >= flushThresholdBytes
        }
    }

    // MARK: - Disk lock (exposed for Dispatcher's drain)

    /// Acquire the disk lock. MUST be paired with `releaseDiskLock()`.
    /// Held by `drainDiskStoreToNetwork` for the entire drain duration so that
    /// mid-drain memory flushes do not clobber the drain's remainder write.
    public func acquireDiskLock() async {
        await diskLock.lock()
    }

    /// Release the disk lock.
    public func releaseDiskLock() async {
        await diskLock.unlock()
    }

    // MARK: - Disk operations

    /// Flush the entire memory queue to disk, merging with existing disk contents
    /// and enforcing `maxDiskEvents`. Memory is cleared after a successful write.
    /// Acquires the disk lock — serializes against an in-flight drain.
    /// Returns `true` if at least one event was persisted.
    @discardableResult
    public func flushMemoryToDisk() async -> Bool {
        await diskLock.lock()
        let result = await flushMemoryToDiskInternal()
        await diskLock.unlock()
        return result
    }

    /// Drain's single-read primitive. Reads everything from disk and deletes the file
    /// in a single actor hop (no suspends between). Caller MUST hold the disk lock.
    /// Returns the events that were on disk (possibly empty).
    public func readAllFromDiskAndDelete() async -> [EnrichedEventPayload] {
        let snapshot = await diskStore.read()
        let events = snapshot?.events ?? []
        if !events.isEmpty {
            await diskStore.delete()
            _hasDiskData = false
        } else if _hasDiskData {
            // File was missing or empty — flag was stale
            await diskStore.delete()
            _hasDiskData = false
        }
        return events
    }

    /// Full overwrite of the disk store with the given events.
    /// Used by drain for checkpoints and "write remainder on failure."
    /// Caller MUST hold the disk lock.
    public func writeDiskStore(_ events: [EnrichedEventPayload]) async {
        guard !events.isEmpty else {
            await diskStore.delete()
            _hasDiskData = false
            return
        }
        do {
            try await diskStore.write(QueueSnapshot(events: events))
            _hasDiskData = true
        } catch {
            Logger.warn("Failed to write disk store: \(error)")
        }
    }

    /// Delete the disk store entirely and clear the `hasDiskData` flag.
    public func deleteDiskStore() async {
        await diskStore.delete()
        _hasDiskData = false
    }

    /// Read a batch from disk without deleting it. Used by tests and callers that
    /// need to peek at disk contents without the full drain protocol.
    public func readDiskBatch(max count: Int) async -> [EnrichedEventPayload] {
        guard let snapshot = await diskStore.read() else { return [] }
        let events = snapshot.events
        guard !events.isEmpty else { return [] }
        return Array(events.prefix(min(count, events.count)))
    }

    // MARK: - Private helpers

    /// Internal flush — no lock, caller must hold `diskLock` (or be `flushMemoryToDisk`).
    private func flushMemoryToDiskInternal() async -> Bool {
        let events = await memoryQueue.drain(max: Int.max)
        guard !events.isEmpty else { return false }
        estimatedBytes = 0

        do {
            let total = try await diskStore.append(events, maxEvents: maxDiskEvents)
            _hasDiskData = total > 0
            Logger.log("Memory queue flushed to disk: \(events.count) events, \(total) total on disk")
            return true
        } catch {
            Logger.warn("Failed to flush memory queue to disk: \(error)")
            // Re-enqueue events that failed to persist so they aren't lost
            await memoryQueue.requeueToFront(events)
            for event in events {
                estimatedBytes += Self.estimateEventSize(event)
            }
            return false
        }
    }

    /// Fast per-event size estimate. Encodes once per event (at enqueue time only).
    private static func estimateEventSize(_ event: EnrichedEventPayload) -> Int {
        (try? jsonEncoder.encode(event))?.count ?? 512
    }
}
