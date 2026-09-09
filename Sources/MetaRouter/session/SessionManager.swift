import Foundation

/// Event emitted when a new session is minted and `fireSessionStarted` is on.
/// The name matches the web SDK's session-management sync verbatim, so
/// downstream mappings keyed on the event name treat both platforms as one.
internal enum SessionEventNames {
    static let sessionStarted = "Session Started"
}

/// Synchronous handler slot for "a new session was minted".
///
/// Exists instead of an actor-isolated setter so the handler can be installed
/// synchronously during client construction: an async setter would race the
/// cold launch — a pre-bind buffered event replays the moment the client binds
/// and can mint the first session before a `Task`-scheduled setter runs, which
/// would silently drop the very first `Session Started` of every install.
internal final class SessionStartRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (SessionInfo) -> Void)?

    func set(_ newHandler: @escaping @Sendable (SessionInfo) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        handler = newHandler
    }

    /// Fires outside the lock: the handler re-enters the analytics client
    /// (which eventually re-enters the session actor), and holding the lock
    /// across that would invite deadlock the moment anyone fires from two
    /// threads.
    func fire(_ info: SessionInfo) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(info)
    }
}

/// Snapshot of the session an event belongs to, returned by `SessionManager.touch()`.
internal struct SessionInfo: Sendable, Equatable {
    /// Epoch milliseconds of the session's first activity, as a string —
    /// the same format the web SDK's generic MetaRouter session mints, so
    /// pipeline mappings see one shape from both platforms.
    let sessionId: String
    /// Lifetime session ordinal for this install, starting at 1.
    let sessionCount: Int
    /// True exactly once per session: on the touch that minted it. Drives the
    /// optional `Session Started` event without a second bookkeeping channel.
    let startedNewSession: Bool
}

/// Owns the sliding-inactivity session: mints, extends, and rolls it over.
///
/// A session ends after `timeout` of inactivity (default 30 minutes), where
/// activity is any `touch()` — one per outbound event. The window slides:
/// activity extends the session indefinitely, matching the web SDK's generic
/// MetaRouter session and GA4's native app-session model, NOT the web GA4
/// injector's from-start cap (which would end a 35-minute active browse
/// mid-flight).
///
/// Two clocks, on purpose:
/// - In-process inactivity is measured on a monotonic clock that keeps
///   counting through deep sleep (`MonotonicClock`). Wall-clock can jump
///   minutes in either direction (NTP, user changes) and would end or
///   immortalize a session that saw no real inactivity.
/// - Across process restarts only wall-clock survives, so the persisted
///   last-activity is epoch ms. A wall reading from the future (clock was
///   set back since it was written) is treated as expired: resuming would
///   make the session immortal — elapsed stays negative until the clock
///   catches up — while minting costs at most one extra session and
///   self-heals on the next write.
///
/// Rollover uses `>` (exactly `timeout` old is still the same session) to
/// stay boundary-identical with the web implementation.
internal actor SessionManager {

    static let defaultTimeoutMinutes = 30

    /// The persisted last-activity only matters across a process restart, where
    /// its precision competes with a timeout of at least one minute — so a write
    /// per event is pure cfprefsd churn under a chatty producer (webview bridge,
    /// rapid screen tracking). Throttled to one write per window; under a
    /// monotone wall clock, a crash loses at most this much of the inactivity
    /// window. A backward wall jump inside one window followed by process death
    /// can instead overstate the persisted activity by the jump size — healed at
    /// the next persist, and able to resurrect a dead session only if the jump
    /// exceeds the timeout itself.
    static let persistThrottleMillis: Int64 = 5_000

    /// Notified on every mint. `nonisolated let` so the owner can install the
    /// handler synchronously at construction time (see `SessionStartRelay`).
    nonisolated let onSessionStart = SessionStartRelay()

    private let storage: SessionStorage
    private let timeoutMillis: Int64
    private let wallClockMillis: () -> Int64
    private let monotonicClockMillis: () -> Int64

    private var sessionId: String?
    private var sessionCount: Int = 0
    private var lastActivityMono: Int64 = 0
    /// Monotonic time of the last storage write, for the persist throttle —
    /// monotonic so a wall-clock jump cannot stall persistence.
    private var lastPersistedMono: Int64 = 0

    static func epochClockMillis() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    init(
        storage: SessionStorage,
        timeoutMinutes: Int = SessionManager.defaultTimeoutMinutes,
        wallClockMillis: @escaping () -> Int64 = SessionManager.epochClockMillis,
        monotonicClockMillis: @escaping () -> Int64 = MonotonicClock.continuousMillis
    ) {
        // Bounds are enforced with clamp-and-warn at the InitOptions boundary;
        // by here a non-positive timeout is SDK-internal misuse, not user input.
        precondition(timeoutMinutes > 0, "timeoutMinutes must be > 0")
        self.storage = storage
        self.timeoutMillis = Int64(timeoutMinutes) * 60 * 1000
        self.wallClockMillis = wallClockMillis
        self.monotonicClockMillis = monotonicClockMillis
    }

    /// Records activity and returns the session it belongs to, minting or
    /// rolling over first when the inactivity window has lapsed. Call once
    /// per outbound event; the actor serializes concurrent callers so a
    /// burst of events at cold start mints exactly one session.
    func touch() -> SessionInfo {
        let wallNow = wallClockMillis()
        let monoNow = monotonicClockMillis()

        if sessionId != nil {
            if monoNow - lastActivityMono > timeoutMillis {
                return mint(wallNow: wallNow, monoNow: monoNow)
            }
            lastActivityMono = monoNow
            if monoNow - lastPersistedMono >= Self.persistThrottleMillis {
                storage.setLastActivityMs(wallNow)
                lastPersistedMono = monoNow
            }
            return SessionInfo(sessionId: sessionId!, sessionCount: sessionCount, startedNewSession: false)
        }

        // First touch of this process: resume the persisted session when the
        // restart happened inside the inactivity window.
        if let storedId = storage.getSessionId(),
           let storedLast = storage.getLastActivityMs(),
           storedLast <= wallNow,
           wallNow - storedLast <= timeoutMillis {
            sessionId = storedId
            sessionCount = storage.getSessionCount() ?? 1
            lastActivityMono = monoNow
            // Once per process — no throttle needed, and skipping it would leave
            // the pre-restart timestamp in place for up to a throttle window.
            storage.setLastActivityMs(wallNow)
            lastPersistedMono = monoNow
            return SessionInfo(sessionId: storedId, sessionCount: sessionCount, startedNewSession: false)
        }

        return mint(wallNow: wallNow, monoNow: monoNow)
    }

    /// The current session without recording activity — a read must not extend
    /// the inactivity window, or a diagnostics poller could keep a session
    /// alive forever. Returns nil before the first `touch()` of the process;
    /// stale-past-timeout is acceptable for a diagnostic read.
    func peek() -> SessionInfo? {
        guard let id = sessionId else { return nil }
        return SessionInfo(sessionId: id, sessionCount: sessionCount, startedNewSession: false)
    }

    private func mint(wallNow: Int64, monoNow: Int64) -> SessionInfo {
        // Continue the persisted lifetime counter even when the session itself
        // expired — the ordinal is per install, not per session chain.
        let previousCount = sessionCount > 0 ? sessionCount : (storage.getSessionCount() ?? 0)
        let newId = String(wallNow)
        sessionId = newId
        sessionCount = previousCount + 1
        lastActivityMono = monoNow
        storage.setSession(id: newId, count: sessionCount, lastActivityMs: wallNow)
        lastPersistedMono = monoNow
        let info = SessionInfo(sessionId: newId, sessionCount: sessionCount, startedNewSession: true)
        // Safe to re-enter: a handler that tracks an event enriches on a new
        // Task, and that enrichment's touch() sees the session minted above —
        // startedNewSession is false, so the relay cannot loop.
        onSessionStart.fire(info)
        return info
    }
}
