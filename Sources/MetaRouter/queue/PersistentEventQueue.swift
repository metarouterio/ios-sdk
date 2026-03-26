import Foundation

/// Persistence-aware event queue. Memory is the primary store; disk is a safety net.
///
/// - `enqueue()` writes to memory only (no disk I/O)
/// - `drain()` reads from memory only (no disk I/O)
/// - `flushToDisk()` snapshots current memory state to disk (full overwrite)
/// - `rehydrate()` loads events from disk once per process lifetime
///
/// Capacity: single shared cap — count OR bytes, whichever first. Overflow: drop oldest.
public actor PersistentEventQueue {

    // MARK: - Process-level rehydration guard

    /// Ensures rehydration happens at most once per process lifetime.
    /// nonisolated(unsafe) is acceptable because it's only toggled once (false->true)
    /// and the worst case of a race is a redundant no-op rehydration attempt.
    private nonisolated(unsafe) static var hasRehydrated = false

    /// Reset for testing only.
    public static func resetRehydrationGuard() {
        hasRehydrated = false
    }

    // MARK: - Configuration

    private let maxEventCount: Int
    private let maxSizeBytes: Int
    private let flushThresholdCount: Int
    private let flushThresholdBytes: Int

    // MARK: - State

    private let memoryQueue: EventQueue<EnrichedEventPayload>
    private let diskStorage: DiskStorage

    // MARK: - Init

    public init(
        diskStorage: DiskStorage,
        maxEventCount: Int = 2000,
        maxSizeBytes: Int = 5_242_880, // 5MB
        flushThresholdCount: Int = 500,
        flushThresholdBytes: Int = 2_097_152 // 2MB
    ) {
        self.diskStorage = diskStorage
        self.maxEventCount = max(1, maxEventCount)
        self.maxSizeBytes = max(1, maxSizeBytes)
        self.flushThresholdCount = max(1, flushThresholdCount)
        self.flushThresholdBytes = max(1, flushThresholdBytes)
        self.memoryQueue = EventQueue<EnrichedEventPayload>(capacity: maxEventCount)
    }

    // MARK: - Memory-only operations (hot path)

    /// Enqueue an event to the in-memory buffer. No disk I/O.
    public func enqueue(_ event: EnrichedEventPayload) async {
        await memoryQueue.enqueue(event)
    }

    /// Drain up to `max` events from the front of the in-memory buffer. No disk I/O.
    public func drain(max count: Int) async -> [EnrichedEventPayload] {
        await memoryQueue.drain(max: count)
    }

    /// Requeue events at the front (used after retryable send failures).
    public func requeueToFront(_ events: [EnrichedEventPayload]) async {
        await memoryQueue.requeueToFront(events)
    }

    /// Drop current front batch without requeueing.
    public func dropFront(_ count: Int) async {
        await memoryQueue.dropFront(count)
    }

    /// Clear all events from memory AND delete the disk snapshot file.
    public func clear() async {
        await memoryQueue.clear()
        await diskStorage.delete()
    }

    /// Current number of events in memory.
    public var count: Int {
        get async { await memoryQueue.count }
    }

    // MARK: - Flush threshold check

    /// Returns true if the in-memory buffer has reached the flush-to-disk threshold.
    public var needsFlushToDisk: Bool {
        get async {
            let eventCount = await memoryQueue.count
            if eventCount >= flushThresholdCount {
                return true
            }
            let events = await peekAll()
            let snapshot = QueueSnapshot(events: events)
            return snapshot.estimatedSizeBytes >= flushThresholdBytes
        }
    }

    // MARK: - Disk operations (cold path)

    /// Flush current memory state to disk. Full overwrite.
    /// Called on: app background, app terminate (best-effort), explicit flush, threshold.
    public func flushToDisk() async throws {
        let events = await peekAll()
        let snapshot = QueueSnapshot(events: events)
        try await diskStorage.write(snapshot)
    }

    /// Rehydrate events from disk into memory. Happens at most once per process lifetime.
    /// Returns the number of events loaded.
    @discardableResult
    public func rehydrate() async -> Int {
        guard !Self.hasRehydrated else {
            Logger.log("Skipping rehydration — already rehydrated this process")
            return 0
        }
        Self.hasRehydrated = true

        guard let snapshot = await diskStorage.read() else {
            Logger.log("No queue snapshot found on disk — nothing to rehydrate")
            return 0
        }

        var events = snapshot.events

        // Enforce capacity: keep newest, drop oldest
        if events.count > maxEventCount {
            let dropCount = events.count - maxEventCount
            events = Array(events.dropFirst(dropCount))
            Logger.warn("Rehydration: dropped \(dropCount) oldest events to fit capacity \(maxEventCount)")
        }

        for event in events {
            await memoryQueue.enqueue(event)
        }

        // Delete disk file after successful load to prevent stale reads
        await diskStorage.delete()

        Logger.log("Rehydrated \(events.count) events from disk")
        return events.count
    }

    // MARK: - Private helpers

    /// Peek at all events without removing them. Used for snapshotting.
    private func peekAll() async -> [EnrichedEventPayload] {
        let all = await memoryQueue.drain(max: Int.max)
        if !all.isEmpty {
            await memoryQueue.requeueToFront(all)
        }
        return all
    }
}
