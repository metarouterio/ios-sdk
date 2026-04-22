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

    /// Events that arrived while memory was at capacity AND the capacity-triggered
    /// disk flush failed. They are held in process memory until the next successful
    /// disk write absorbs them, so a transient disk failure does not cost us events.
    /// Capped at `maxEventCount` — if the overflow itself exceeds the cap, the oldest
    /// pending entries are dropped (same ring-buffer semantics as memory).
    private var pendingOverflow: [EnrichedEventPayload] = []

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

    /// Delete the disk store without taking the lock. Caller MUST hold `diskLock`.
    /// Used by the drain's fatal-config path (already holds the lock) and by the
    /// public `clear()` / `deleteDiskStore()` which acquire it themselves.
    private func deleteDiskStoreLocked() async {
        do {
            try await diskStore.delete()
        } catch {
            Logger.warn("Failed to delete disk store: \(error)")
        }
        _hasDiskData = false
    }

    /// Enqueue an event to the in-memory buffer.
    /// When the queue is at capacity (by count OR byte size), the entire memory queue is flushed
    /// to disk first. If that flush fails AND persistence is enabled, the incoming event is held
    /// in a pending-overflow buffer instead of evicting an older event — parity with the RN SDK's
    /// "owned in JS memory until native write succeeds" contract.
    /// Returns the memory queue count after insertion.
    @discardableResult
    public func enqueue(_ event: EnrichedEventPayload) async -> Int {
        let currentCount = await memoryQueue.count
        let eventSize = Self.estimateEventSize(event)
        if currentCount >= maxEventCount || estimatedBytes + eventSize > maxSizeBytes {
            await flushMemoryToDisk()
        }

        // Disk flush failed (memory still at cap) and persistence is enabled:
        // park in pending-overflow rather than dropping the oldest via the ring buffer.
        // Cap overflow at maxDiskEvents — these events are headed for disk, so they
        // shouldn't exceed the disk's capacity even if disk writes stay unavailable.
        let postFlushCount = await memoryQueue.count
        if maxDiskEvents > 0 && postFlushCount >= maxEventCount {
            pendingOverflow.append(event)
            if pendingOverflow.count > maxDiskEvents {
                let drop = pendingOverflow.count - maxDiskEvents
                pendingOverflow.removeFirst(drop)
                Logger.warn("Pending overflow cap reached — dropped \(drop) oldest")
            }
            return postFlushCount
        }

        let prevCount = await memoryQueue.count
        let newCount = await memoryQueue.enqueue(event)
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
    /// If memory cannot fit both current contents and the requeued events (by count OR bytes),
    /// flushes current memory to disk first so nothing is dropped.
    public func requeueToFront(_ events: [EnrichedEventPayload]) async {
        guard !events.isEmpty else { return }
        let currentCount = await memoryQueue.count
        let addedBytes = events.reduce(0) { $0 + Self.estimateEventSize($1) }
        if currentCount + events.count > maxEventCount || estimatedBytes + addedBytes > maxSizeBytes {
            await flushMemoryToDisk()
        }
        await memoryQueue.requeueToFront(events)
        estimatedBytes += addedBytes
    }

    /// Drop current front batch without requeueing.
    public func dropFront(_ count: Int) async {
        await memoryQueue.dropFront(count)
        if await memoryQueue.count == 0 {
            estimatedBytes = 0
        }
    }

    /// Clear all events from memory, pending-overflow, AND delete the disk store.
    /// Serialized against in-flight drains/flushes via the disk lock.
    public func clear() async {
        await memoryQueue.clear()
        estimatedBytes = 0
        pendingOverflow.removeAll(keepingCapacity: false)
        await diskLock.lock()
        await deleteDiskStoreLocked()
        await diskLock.unlock()
    }

    /// Current number of events in memory.
    public var count: Int {
        get async { await memoryQueue.count }
    }

    /// Returns true if the memory buffer has reached the flush-to-disk threshold.
    /// Also true whenever pending-overflow is non-empty, so a retry flush is attempted.
    public var needsFlushToDisk: Bool {
        get async {
            if !pendingOverflow.isEmpty { return true }
            let eventCount = await memoryQueue.count
            if eventCount >= flushThresholdCount {
                return true
            }
            return estimatedBytes >= flushThresholdBytes
        }
    }

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

    /// Flush the entire memory queue to disk, merging with existing disk contents
    /// and enforcing `maxDiskEvents`. Memory is cleared after a successful write.
    /// Acquires the disk lock — serializes against an in-flight drain.
    /// Returns `true` if at least one event was persisted.
    /// No-op when `maxDiskEvents == 0` (persistence disabled — memory-only pipeline).
    @discardableResult
    public func flushMemoryToDisk() async -> Bool {
        guard maxDiskEvents > 0 else { return false }
        await diskLock.lock()
        let result = await flushMemoryToDiskInternal()
        await diskLock.unlock()
        return result
    }

    /// Drain's single-read primitive. Reads everything from disk and deletes the file
    /// in a single actor hop (no suspends between). Caller MUST hold the disk lock.
    /// Events older than `eventTTL` (7 days) are filtered out before returning.
    /// Returns the live events that were on disk (possibly empty).
    public func readAllFromDiskAndDelete() async -> [EnrichedEventPayload] {
        let snapshot: QueueSnapshot?
        do {
            snapshot = try await diskStore.read()
        } catch {
            Logger.warn("Disk read failed during drain: \(error) — treating as empty")
            snapshot = nil
        }
        let allEvents = snapshot?.events ?? []
        let events = Self.filterExpired(allEvents)
        let dropped = allEvents.count - events.count
        if dropped > 0 {
            Logger.log("Drain TTL filter dropped \(dropped) event(s) older than 7 days")
        }
        if !allEvents.isEmpty {
            try? await diskStore.delete()
            _hasDiskData = false
        } else if _hasDiskData {
            // File was missing or empty — flag was stale
            try? await diskStore.delete()
            _hasDiskData = false
        }
        return events
    }

    /// Full overwrite of the disk store with the given events.
    /// Used by drain for checkpoints and "write remainder on failure."
    /// Caller MUST hold the disk lock.
    /// No-op when `maxDiskEvents == 0` (persistence disabled — memory-only pipeline).
    public func writeDiskStore(_ events: [EnrichedEventPayload]) async {
        guard maxDiskEvents > 0 else { return }
        guard !events.isEmpty else {
            await deleteDiskStoreLocked()
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
    /// Serialized against in-flight drains/flushes via the disk lock.
    public func deleteDiskStore() async {
        await diskLock.lock()
        await deleteDiskStoreLocked()
        await diskLock.unlock()
    }

    /// Delete the disk store without acquiring the lock. Caller MUST hold the lock.
    /// Used by the drain's fatal-config path, which already holds `diskLock`.
    public func deleteDiskStoreHoldingLock() async {
        await deleteDiskStoreLocked()
    }

    /// Read a batch from disk without deleting it. Used by tests and callers that
    /// need to peek at disk contents without the full drain protocol.
    public func readDiskBatch(max count: Int) async -> [EnrichedEventPayload] {
        let snapshot: QueueSnapshot?
        do {
            snapshot = try await diskStore.read()
        } catch {
            Logger.warn("Disk read failed in readDiskBatch: \(error)")
            return []
        }
        guard let snapshot, !snapshot.events.isEmpty else { return [] }
        return Array(snapshot.events.prefix(min(count, snapshot.events.count)))
    }

    /// Internal flush — no lock, caller must hold `diskLock` (or be `flushMemoryToDisk`).
    /// Flushes memory-queue events AND any pending-overflow events in one disk write.
    /// On failure, memory is restored and pending-overflow is left intact so the next
    /// successful flush catches them up.
    private func flushMemoryToDiskInternal() async -> Bool {
        let memoryEvents = await memoryQueue.drain(max: Int.max)
        let overflowEvents = pendingOverflow
        let events = memoryEvents + overflowEvents
        guard !events.isEmpty else { return false }
        estimatedBytes = 0

        do {
            let total = try await diskStore.append(events, maxEvents: maxDiskEvents)
            _hasDiskData = total > 0
            pendingOverflow.removeAll(keepingCapacity: false)
            Logger.log("Memory queue flushed to disk: \(events.count) events, \(total) total on disk")
            return true
        } catch {
            Logger.warn("Failed to flush memory queue to disk: \(error)")
            // Restore memory so events aren't lost; leave pending-overflow untouched
            // so it will be re-attempted on the next flush.
            await memoryQueue.requeueToFront(memoryEvents)
            for event in memoryEvents {
                estimatedBytes += Self.estimateEventSize(event)
            }
            return false
        }
    }

    /// Fast per-event size estimate. Encodes once per event (at enqueue time only).
    private static func estimateEventSize(_ event: EnrichedEventPayload) -> Int {
        (try? jsonEncoder.encode(event))?.count ?? 512
    }

    /// Drop events whose `timestamp` is older than `eventTTL`. Events without a
    /// parseable timestamp are kept (conservative — better to send than silently drop).
    private static func filterExpired(_ events: [EnrichedEventPayload]) -> [EnrichedEventPayload] {
        let cutoff = Date().addingTimeInterval(-eventTTL)
        return events.filter { event in
            guard let ts = DateFormatters.iso8601.date(from: event.timestamp) else { return true }
            return ts >= cutoff
        }
    }
}
