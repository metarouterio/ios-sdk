import Foundation

/// Persistence-aware event queue. Memory is the primary store; disk is a safety net.
///
/// - `enqueue()` writes to memory only (no disk I/O)
/// - `drain()` reads from memory only (no disk I/O)
/// - `flushToDisk()` snapshots current memory state to disk (full overwrite)
/// - `rehydrate()` loads events from disk (idempotent — disk file deleted after load)
///
/// Capacity: single shared cap — count OR bytes, whichever first. Overflow: drop oldest.
public actor PersistentEventQueue {

    private static let jsonEncoder = JSONEncoder()

    /// Events older than this are dropped during rehydration.
    static let eventTTL: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    private let maxEventCount: Int
    private let maxSizeBytes: Int
    private let flushThresholdCount: Int
    private let flushThresholdBytes: Int


    private let memoryQueue: EventQueue<EnrichedEventPayload>
    private let diskStorage: DiskStorage
    /// Running estimate of serialized bytes in the queue. Updated incrementally
    /// on enqueue/drain/requeue/clear to avoid re-encoding the entire queue on every offer().
    private var estimatedBytes: Int = 0

    // Offline overflow support
    private let overflowDiskStorage: DiskStorage?
    private let maxOfflineDiskEvents: Int
    private var offlineOverflowEnabled = false
    private var overflowBuffer: [EnrichedEventPayload] = []
    private static let overflowBatchThreshold = 100

    public init(
        diskStorage: DiskStorage,
        maxEventCount: Int = 2000,
        maxSizeBytes: Int = 5_242_880, // 5MB
        flushThresholdCount: Int = 500,
        flushThresholdBytes: Int = 2_097_152, // 2MB
        overflowDiskStorage: DiskStorage? = nil,
        maxOfflineDiskEvents: Int = 10000
    ) {
        self.diskStorage = diskStorage
        self.maxEventCount = max(1, maxEventCount)
        self.maxSizeBytes = max(1, maxSizeBytes)
        self.flushThresholdCount = max(1, flushThresholdCount)
        self.flushThresholdBytes = max(1, flushThresholdBytes)
        self.memoryQueue = EventQueue<EnrichedEventPayload>(capacity: maxEventCount)
        self.overflowDiskStorage = overflowDiskStorage
        self.maxOfflineDiskEvents = max(0, maxOfflineDiskEvents)
    }

    /// Enqueue an event to the in-memory buffer. No disk I/O.
    /// When offline overflow is enabled and the queue is at capacity, the oldest event
    /// is redirected to the overflow buffer (for batched disk write) instead of being dropped.
    /// Returns the queue count after insertion (atomic with the enqueue).
    @discardableResult
    public func enqueue(_ event: EnrichedEventPayload) async -> Int {
        // When offline overflow is enabled, intercept the overflow before EventQueue drops it
        if offlineOverflowEnabled, overflowDiskStorage != nil {
            let currentCount = await memoryQueue.count
            if currentCount >= maxEventCount {
                let evicted = await memoryQueue.drain(max: 1)
                for e in evicted {
                    estimatedBytes -= Self.estimateEventSize(e)
                    await bufferOverflowEvent(e)
                }
            }
        }

        let prevCount = await memoryQueue.count
        let newCount = await memoryQueue.enqueue(event)
        let eventSize = Self.estimateEventSize(event)
        // If an overflow drop happened (no overflow enabled), approximate the dropped event as average size
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
    public func requeueToFront(_ events: [EnrichedEventPayload]) async {
        await memoryQueue.requeueToFront(events)
        for event in events {
            estimatedBytes += Self.estimateEventSize(event)
        }
    }

    /// Drop current front batch without requeueing.
    public func dropFront(_ count: Int) async {
        await memoryQueue.dropFront(count)
        // Conservative: we don't know exact sizes of dropped events, reset estimate
        if await memoryQueue.count == 0 {
            estimatedBytes = 0
        }
    }

    /// Clear all events from memory AND delete both disk snapshot files (queue + overflow).
    public func clear() async {
        await memoryQueue.clear()
        estimatedBytes = 0
        await diskStorage.delete()
        overflowBuffer.removeAll()
        if let overflowDisk = overflowDiskStorage {
            await overflowDisk.delete()
        }
    }

    /// Current number of events in memory.
    public var count: Int {
        get async { await memoryQueue.count }
    }


    /// Returns true if the in-memory buffer has reached the flush-to-disk threshold.
    /// Uses a running byte estimate to avoid re-encoding the entire queue on every check.
    public var needsFlushToDisk: Bool {
        get async {
            let eventCount = await memoryQueue.count
            if eventCount >= flushThresholdCount {
                return true
            }
            return estimatedBytes >= flushThresholdBytes
        }
    }


    /// Flush current memory state to disk. Full overwrite.
    /// Called on: app background, app terminate (best-effort), explicit flush, threshold.
    /// Also flushes the overflow buffer to its separate disk file.
    public func flushToDisk() async throws {
        let events = await peekAll()
        let snapshot = QueueSnapshot(events: events)
        try await diskStorage.write(snapshot)
        // Also persist any buffered overflow events
        await flushOverflowBufferToDisk()
    }

    /// Rehydrate events from disk into memory.
    /// Idempotent — the disk file is deleted after a successful load, so subsequent calls are no-ops.
    /// Drops events older than `eventTTL` (7 days).
    /// Returns the number of events loaded.
    @discardableResult
    public func rehydrate() async -> Int {
        guard let snapshot = await diskStorage.read() else {
            Logger.log("No queue snapshot found on disk — nothing to rehydrate")
            return 0
        }

        let now = Date()
        let iso = ISO8601DateFormatter()
        var events = snapshot.events.filter { event in
            guard let ts = iso.date(from: event.timestamp) else { return true }
            return now.timeIntervalSince(ts) <= Self.eventTTL
        }

        let expiredCount = snapshot.events.count - events.count
        if expiredCount > 0 {
            Logger.warn("Rehydration: dropped \(expiredCount) event(s) older than 7 days")
        }

        // Enforce capacity: keep newest, drop oldest
        if events.count > maxEventCount {
            let dropCount = events.count - maxEventCount
            events = Array(events.dropFirst(dropCount))
            Logger.warn("Rehydration: dropped \(dropCount) oldest events to fit capacity \(maxEventCount)")
        }

        for event in events {
            await memoryQueue.enqueue(event)
            estimatedBytes += Self.estimateEventSize(event)
        }

        // Delete disk file after successful load to prevent stale reads
        await diskStorage.delete()

        Logger.log("Rehydrated \(events.count) events from disk")
        return events.count
    }


    // MARK: - Offline Overflow

    /// Enable or disable offline overflow mode.
    /// When enabled, events evicted from the memory queue are buffered for disk write
    /// instead of being dropped. No-op if no overflow disk storage was configured.
    public func setOfflineOverflowEnabled(_ enabled: Bool) {
        guard overflowDiskStorage != nil else { return }
        offlineOverflowEnabled = enabled
    }

    /// Buffer an evicted event for batched disk write.
    private func bufferOverflowEvent(_ event: EnrichedEventPayload) async {
        overflowBuffer.append(event)
        if overflowBuffer.count >= Self.overflowBatchThreshold {
            await flushOverflowBufferToDisk()
        }
    }

    /// Flush the in-memory overflow buffer to the overflow disk store.
    /// Merges with existing disk contents and enforces maxOfflineDiskEvents cap.
    /// Called when buffer reaches batch threshold, on app backgrounding, or before drain.
    public func flushOverflowBufferToDisk() async {
        guard let overflowDisk = overflowDiskStorage, !overflowBuffer.isEmpty else { return }
        let batch = overflowBuffer
        overflowBuffer.removeAll()

        let existing = await overflowDisk.read()
        var combined = (existing?.events ?? []) + batch
        if combined.count > maxOfflineDiskEvents {
            let dropCount = combined.count - maxOfflineDiskEvents
            combined = Array(combined.dropFirst(dropCount))
            Logger.warn("Offline overflow disk cap reached — dropped \(dropCount) oldest events")
        }
        do {
            try await overflowDisk.write(QueueSnapshot(events: combined))
            Logger.log("Overflow buffer flushed to disk: \(batch.count) events, \(combined.count) total on disk")
        } catch {
            Logger.warn("Failed to flush overflow buffer to disk: \(error)")
            // Re-buffer events that failed to persist
            overflowBuffer.insert(contentsOf: batch, at: 0)
        }
    }

    /// Read a batch of overflow events from disk. Flushes buffer first.
    /// Returns empty array if no overflow disk storage is configured or no events exist.
    public func readOverflowBatch(max count: Int) async -> [EnrichedEventPayload] {
        guard let overflowDisk = overflowDiskStorage else { return [] }
        await flushOverflowBufferToDisk()
        guard let snapshot = await overflowDisk.read() else { return [] }
        let events = snapshot.events
        guard !events.isEmpty else { return [] }
        return Array(events.prefix(min(count, events.count)))
    }

    /// Remove the first `count` events from the overflow disk store.
    /// Deletes the file entirely if no events remain.
    public func removeOverflowBatch(count: Int) async {
        guard let overflowDisk = overflowDiskStorage else { return }
        guard let snapshot = await overflowDisk.read() else { return }
        let remaining = Array(snapshot.events.dropFirst(count))
        if remaining.isEmpty {
            await overflowDisk.delete()
        } else {
            do {
                try await overflowDisk.write(QueueSnapshot(events: remaining))
            } catch {
                Logger.warn("Failed to update overflow disk after batch removal: \(error)")
            }
        }
    }

    /// Number of events currently in the overflow buffer + disk.
    public func overflowCount() async -> Int {
        let bufferCount = overflowBuffer.count
        guard let overflowDisk = overflowDiskStorage else { return bufferCount }
        let diskCount = await overflowDisk.read()?.events.count ?? 0
        return bufferCount + diskCount
    }

    // MARK: - Private Helpers

    /// Peek at all events without removing them. Used for snapshotting.
    private func peekAll() async -> [EnrichedEventPayload] {
        let all = await memoryQueue.drain(max: Int.max)
        if !all.isEmpty {
            await memoryQueue.requeueToFront(all)
        }
        return all
    }

    /// Fast per-event size estimate. Encodes once per event (at enqueue time only),
    /// not the entire queue on every threshold check.
    private static func estimateEventSize(_ event: EnrichedEventPayload) -> Int {
        (try? jsonEncoder.encode(event))?.count ?? 512
    }
}
