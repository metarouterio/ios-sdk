import Foundation

/// Bounded record of recently seen bridge `messageId`s.
///
/// Redelivery happens when the page re-posts after a lost ack, so a duplicate can only
/// arrive within a short window of the original — entries older than `ttlMillis` can be
/// treated as never-seen. The size bound exists because a long-lived webview session
/// would otherwise grow the store for its whole lifetime; when full, the oldest entry is
/// evicted first since it is also the one least likely to still be inside any redelivery
/// window.
///
/// In-memory only: a duplicate delivered across a process restart is indistinguishable
/// from a fresh event and rare enough not to justify disk I/O on the message path.
internal final class BridgeDedupStore: @unchecked Sendable {

    static let defaultMaxEntries = 1_000
    static let defaultTtlMillis: Int64 = 5 * 60 * 1000

    // The tick→nanosecond scaling factors are process-constant; fetch once, not on
    // every clock read on the message path.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Monotonic: immune to wall-clock jumps (NTP, user time changes), and — unlike
    /// `ProcessInfo.systemUptime` or `mach_absolute_time`, which pause in deep sleep —
    /// `mach_continuous_time` is documented to keep incrementing while the device is
    /// asleep, so the window measures real elapsed time, which is what a redelivery
    /// window means.
    static func continuousClockMillis() -> Int64 {
        let nanos = mach_continuous_time() * UInt64(timebase.numer) / UInt64(timebase.denom)
        return Int64(nanos / 1_000_000)
    }

    private let maxEntries: Int
    private let ttlMillis: Int64
    /// Must be safe to call from any thread — the default is; test clocks run
    /// single-threaded.
    private let clock: () -> Int64

    // Insertion-ordered bookkeeping so eviction removes the oldest messageId. The array
    // stays at most maxEntries long, so the O(n) removals are bounded and cheap. Guarded
    // by the lock: messages arrive on the WebView's thread while the SDK may probe from
    // background workers.
    private let lock = NSLock()
    private var seen: [String: Int64] = [:]
    private var insertionOrder: [String] = []

    init(
        maxEntries: Int = BridgeDedupStore.defaultMaxEntries,
        ttlMillis: Int64 = BridgeDedupStore.defaultTtlMillis,
        clock: @escaping () -> Int64 = BridgeDedupStore.continuousClockMillis
    ) {
        precondition(maxEntries > 0, "maxEntries must be > 0")
        precondition(ttlMillis > 0, "ttlMillis must be > 0")
        self.maxEntries = maxEntries
        self.ttlMillis = ttlMillis
        self.clock = clock
    }

    /// Records `messageId` and reports whether it was new.
    ///
    /// - Returns: `true` if unseen (or seen only outside the TTL window) — caller should
    ///   process the message; `false` for a live duplicate — caller should drop it.
    ///   A duplicate does NOT refresh the original timestamp: refreshing would let a
    ///   producer stuck in a re-post loop keep its entry alive forever.
    func markIfNew(_ messageId: String) -> Bool {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }

        if let firstSeenAt = seen[messageId], now - firstSeenAt < ttlMillis {
            return false
        }
        // Remove before re-insert so an expired entry moves to the back of the
        // eviction order instead of keeping its stale position.
        if seen.removeValue(forKey: messageId) != nil {
            insertionOrder.removeAll { $0 == messageId }
        }
        seen[messageId] = now
        insertionOrder.append(messageId)
        if seen.count > maxEntries {
            let eldest = insertionOrder.removeFirst()
            seen.removeValue(forKey: eldest)
        }
        return true
    }

    /// Removes a recorded id. Used when the message it marked never entered the
    /// delivery path — leaving it recorded would make a legitimate producer retry
    /// read as a duplicate of an event that was actually lost.
    func forget(_ messageId: String) {
        lock.lock()
        defer { lock.unlock() }
        if seen.removeValue(forKey: messageId) != nil {
            insertionOrder.removeAll { $0 == messageId }
        }
    }

    func size() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }
}
