import XCTest
@testable import MetaRouter

/// SessionManager logic tests. Both clocks are injected, so every scenario —
/// including "30 minutes pass" and "the user sets the device clock back" —
/// runs instantly and deterministically.
final class SessionManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: SessionStorage!

    /// Mutable test clocks. Reads are single-threaded in these tests except
    /// where a test says otherwise.
    private final class Clock: @unchecked Sendable {
        var now: Int64
        init(_ now: Int64) { self.now = now }
        func advance(minutes: Int64) { now += minutes * 60_000 }
        func advance(ms: Int64) { now += ms }
    }

    private static let timeoutMinutes = 30
    private static let timeoutMs: Int64 = 30 * 60_000

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.sessionManager.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = SessionStorage(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        storage = nil
        super.tearDown()
    }

    private func makeManager(wall: Clock, mono: Clock) -> SessionManager {
        SessionManager(
            storage: storage,
            timeoutMinutes: Self.timeoutMinutes,
            wallClockMillis: { wall.now },
            monotonicClockMillis: { mono.now }
        )
    }

    // MARK: - Minting

    func testColdStartMintsFirstSession() async {
        let wall = Clock(1_757_400_000_000), mono = Clock(50_000)
        let manager = makeManager(wall: wall, mono: mono)

        let info = await manager.touch()

        XCTAssertEqual(info.sessionId, "1757400000000")
        XCTAssertEqual(info.sessionCount, 1)
        XCTAssertTrue(info.startedNewSession)
        XCTAssertEqual(storage.getSessionId(), "1757400000000")
        XCTAssertEqual(storage.getSessionCount(), 1)
        XCTAssertEqual(storage.getLastActivityMs(), 1_757_400_000_000)
    }

    func testActivityWithinTimeoutExtendsSession() async {
        let wall = Clock(1_757_400_000_000), mono = Clock(50_000)
        let manager = makeManager(wall: wall, mono: mono)
        let first = await manager.touch()

        wall.advance(minutes: 29); mono.advance(minutes: 29)
        let second = await manager.touch()

        XCTAssertEqual(second.sessionId, first.sessionId)
        XCTAssertEqual(second.sessionCount, 1)
        XCTAssertFalse(second.startedNewSession)
        XCTAssertEqual(storage.getLastActivityMs(), wall.now, "extend persists last activity")
    }

    /// The window slides: repeated activity keeps one session alive far past
    /// the timeout measured from its start — the from-start model would end
    /// an actively used session mid-flight.
    func testSlidingWindowOutlivesTimeoutFromStart() async {
        let wall = Clock(1_757_400_000_000), mono = Clock(50_000)
        let manager = makeManager(wall: wall, mono: mono)
        let first = await manager.touch()

        // 4 × 20 min of steady activity = 80 min since session start.
        var last = first
        for _ in 0..<4 {
            wall.advance(minutes: 20); mono.advance(minutes: 20)
            last = await manager.touch()
        }

        XCTAssertEqual(last.sessionId, first.sessionId)
        XCTAssertFalse(last.startedNewSession)
    }

    func testInactivityPastTimeoutRollsOver() async {
        let wall = Clock(1_757_400_000_000), mono = Clock(50_000)
        let manager = makeManager(wall: wall, mono: mono)
        let first = await manager.touch()

        wall.advance(minutes: 31); mono.advance(minutes: 31)
        let second = await manager.touch()

        XCTAssertNotEqual(second.sessionId, first.sessionId)
        XCTAssertEqual(second.sessionId, String(wall.now))
        XCTAssertEqual(second.sessionCount, 2)
        XCTAssertTrue(second.startedNewSession)
    }

    /// Rollover uses `>`: exactly `timeout` of inactivity is still the same
    /// session. Web behaves identically at this boundary; a flipped `>`/`>=`
    /// would silently fork the platforms one millisecond apart.
    func testExactlyAtTimeoutIsStillSameSession() async {
        let wall = Clock(1_757_400_000_000), mono = Clock(50_000)
        let manager = makeManager(wall: wall, mono: mono)
        let first = await manager.touch()

        wall.advance(ms: Self.timeoutMs); mono.advance(ms: Self.timeoutMs)
        let atBoundary = await manager.touch()
        XCTAssertEqual(atBoundary.sessionId, first.sessionId, "elapsed == timeout keeps the session")

        // The boundary touch was itself activity, so measure the next full
        // window from it.
        wall.advance(ms: Self.timeoutMs + 1); mono.advance(ms: Self.timeoutMs + 1)
        let pastBoundary = await manager.touch()
        XCTAssertNotEqual(pastBoundary.sessionId, first.sessionId, "elapsed == timeout + 1ms rolls over")
    }

    // MARK: - In-process clock authority

    /// In-process inactivity is measured on the monotonic clock only: a
    /// wall-clock jump (NTP, user changes the time) during a live session
    /// must neither end it nor extend it.
    func testWallClockJumpDoesNotAffectLiveSession() async {
        let wall = Clock(1_757_400_000_000), mono = Clock(50_000)
        let manager = makeManager(wall: wall, mono: mono)
        let first = await manager.touch()

        // Wall leaps forward 6 hours; only 5 real minutes elapse.
        wall.advance(minutes: 360); mono.advance(minutes: 5)
        let afterForwardJump = await manager.touch()
        XCTAssertEqual(afterForwardJump.sessionId, first.sessionId,
                       "forward wall jump must not end a session with no real inactivity")

        // Wall leaps back a day; 5 more real minutes elapse.
        wall.advance(minutes: -1_440); mono.advance(minutes: 5)
        let afterBackwardJump = await manager.touch()
        XCTAssertEqual(afterBackwardJump.sessionId, first.sessionId,
                       "backward wall jump must not end a session with no real inactivity")
    }

    // MARK: - Restart resume

    func testRestartWithinTimeoutResumesPersistedSession() async {
        storage.setSession(id: "1757400000000", count: 4, lastActivityMs: 1_757_400_000_000)

        // New process: fresh manager, monotonic clock restarted from zero.
        let wall = Clock(1_757_400_000_000 + 10 * 60_000), mono = Clock(1_000)
        let manager = makeManager(wall: wall, mono: mono)

        let info = await manager.touch()

        XCTAssertEqual(info.sessionId, "1757400000000")
        XCTAssertEqual(info.sessionCount, 4)
        XCTAssertFalse(info.startedNewSession)
        XCTAssertEqual(storage.getLastActivityMs(), wall.now, "resume refreshes last activity")
    }

    func testRestartPastTimeoutMintsAndContinuesCounter() async {
        storage.setSession(id: "1757400000000", count: 4, lastActivityMs: 1_757_400_000_000)

        let wall = Clock(1_757_400_000_000 + 31 * 60_000), mono = Clock(1_000)
        let manager = makeManager(wall: wall, mono: mono)

        let info = await manager.touch()

        XCTAssertNotEqual(info.sessionId, "1757400000000")
        XCTAssertEqual(info.sessionCount, 5, "counter is per install, not per session chain")
        XCTAssertTrue(info.startedNewSession)
    }

    /// A persisted last-activity in the future means the device clock was set
    /// back since it was written. Resuming would make the session immortal
    /// (elapsed stays negative until the clock catches up), so it is treated
    /// as expired — at most one extra session, self-healing on the next write.
    func testRestartWithFutureLastActivityMintsNewSession() async {
        let wallNow: Int64 = 1_757_400_000_000
        storage.setSession(id: "1757500000000", count: 2, lastActivityMs: wallNow + 60_000)

        let wall = Clock(wallNow), mono = Clock(1_000)
        let manager = makeManager(wall: wall, mono: mono)

        let info = await manager.touch()

        XCTAssertNotEqual(info.sessionId, "1757500000000")
        XCTAssertEqual(info.sessionCount, 3)
        XCTAssertTrue(info.startedNewSession)
    }

    func testRestartWithLegacyPartialStateMints() async {
        // Id present but no last-activity (e.g. state written by a crashed
        // half-migration) must not resume a window of unknown age.
        defaults.set("1757400000000", forKey: SessionStorageKey.sessionId.rawValue)

        let wall = Clock(1_757_400_600_000), mono = Clock(1_000)
        let manager = makeManager(wall: wall, mono: mono)

        let info = await manager.touch()
        XCTAssertTrue(info.startedNewSession)
        XCTAssertEqual(info.sessionCount, 1)
    }

    /// Persistence is throttled on the extend path: last-activity only matters
    /// across a restart, so sub-window churn is skipped. A flipped or deleted
    /// throttle shows up here as an unexpected write.
    func testExtendPersistsAtMostOncePerThrottleWindow() async {
        let wall = Clock(1_757_400_000_000), mono = Clock(50_000)
        let manager = makeManager(wall: wall, mono: mono)
        _ = await manager.touch()
        let mintedAt = wall.now
        let window = SessionManager.persistThrottleMillis

        // 1ms short of the window monotonically — while the wall clock leaps
        // far past it, so a throttle measured on wall time (the jump-prone
        // clock the monotonic choice exists to avoid) would persist here and
        // fail the first assertion.
        wall.advance(ms: window * 10); mono.advance(ms: window - 1)
        _ = await manager.touch()
        XCTAssertEqual(storage.getLastActivityMs(), mintedAt,
                       "sub-window extend must not hit storage")

        // One more millisecond of real time reaches the window — persists.
        wall.advance(ms: 1); mono.advance(ms: 1)
        _ = await manager.touch()
        XCTAssertEqual(storage.getLastActivityMs(), wall.now,
                       "extend at the throttle boundary persists")
    }

    // MARK: - peek

    func testPeekBeforeFirstTouchIsNil() async {
        let wall = Clock(1_757_400_000_000), mono = Clock(50_000)
        let manager = makeManager(wall: wall, mono: mono)
        let peeked = await manager.peek()
        XCTAssertNil(peeked)
    }

    /// A read is not activity: peek must not extend the window, or a
    /// diagnostics poller could keep a session alive forever.
    func testPeekDoesNotExtendSession() async {
        let wall = Clock(1_757_400_000_000), mono = Clock(50_000)
        let manager = makeManager(wall: wall, mono: mono)
        let first = await manager.touch()

        wall.advance(minutes: 29); mono.advance(minutes: 29)
        let peeked = await manager.peek()
        XCTAssertEqual(peeked?.sessionId, first.sessionId)
        XCTAssertEqual(storage.getLastActivityMs(), 1_757_400_000_000, "peek must not persist activity")

        // 2 more minutes = 31 since the only touch; if peek had extended,
        // this would still be the first session.
        wall.advance(minutes: 2); mono.advance(minutes: 2)
        let second = await manager.touch()
        XCTAssertNotEqual(second.sessionId, first.sessionId)
    }

    // MARK: - Concurrency

    /// A burst of concurrent events at cold start must mint exactly one
    /// session: the actor serializes touch(), so exactly one caller sees
    /// startedNewSession and everyone agrees on the id.
    func testConcurrentColdStartMintsExactlyOneSession() async {
        let wall = Clock(1_757_400_000_000), mono = Clock(50_000)
        let manager = makeManager(wall: wall, mono: mono)

        let infos = await withTaskGroup(of: SessionInfo.self, returning: [SessionInfo].self) { group in
            for _ in 0..<100 {
                group.addTask { await manager.touch() }
            }
            var collected: [SessionInfo] = []
            for await info in group { collected.append(info) }
            return collected
        }

        let ids = Set(infos.map(\.sessionId))
        XCTAssertEqual(ids.count, 1, "every concurrent touch sees the same session")
        XCTAssertEqual(infos.filter(\.startedNewSession).count, 1, "exactly one mint")
        XCTAssertTrue(infos.allSatisfy { $0.sessionCount == 1 })
    }
}
