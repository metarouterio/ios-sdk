import XCTest
@testable import MetaRouter

final class SessionStorageTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.sessionStorage.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRoundTripSessionState() {
        let storage = SessionStorage(userDefaults: defaults)

        XCTAssertNil(storage.getSessionId())
        XCTAssertNil(storage.getSessionCount())
        XCTAssertNil(storage.getLastActivityMs())

        storage.setSession(id: "1757400000000", count: 3, lastActivityMs: 1_757_400_123_456)

        XCTAssertEqual(storage.getSessionId(), "1757400000000")
        XCTAssertEqual(storage.getSessionCount(), 3)
        XCTAssertEqual(storage.getLastActivityMs(), 1_757_400_123_456)
    }

    func testSetLastActivityUpdatesOnlyLastActivity() {
        let storage = SessionStorage(userDefaults: defaults)
        storage.setSession(id: "1757400000000", count: 2, lastActivityMs: 1_000)

        storage.setLastActivityMs(2_000)

        XCTAssertEqual(storage.getSessionId(), "1757400000000")
        XCTAssertEqual(storage.getSessionCount(), 2)
        XCTAssertEqual(storage.getLastActivityMs(), 2_000)
    }

    func testClearRemovesAllKeys() {
        let storage = SessionStorage(userDefaults: defaults)
        storage.setSession(id: "1757400000000", count: 1, lastActivityMs: 1_000)
        storage.clear()

        XCTAssertNil(storage.getSessionId())
        XCTAssertNil(storage.getSessionCount())
        XCTAssertNil(storage.getLastActivityMs())
    }

    /// Session storage uses the `metarouter:session:*` key prefix and is NOT
    /// enumerated by `IdentityStorage.clear()`. This is the structural
    /// guarantee that `reset()` cannot end a session as a side effect of
    /// clearing identity — a logout mid-session must not fragment the
    /// analytics session.
    func testIdentityStorageClearDoesNotTouchSessionKeys() {
        let identityStorage = IdentityStorage(userDefaults: defaults)
        identityStorage.set(.anonymousId, value: "abc")
        identityStorage.set(.userId, value: "user-1")

        let sessionStorage = SessionStorage(userDefaults: defaults)
        sessionStorage.setSession(id: "1757400000000", count: 5, lastActivityMs: 9_000)

        identityStorage.clear()

        XCTAssertNil(identityStorage.get(.anonymousId), "identity cleared")
        XCTAssertNil(identityStorage.get(.userId), "identity cleared")
        XCTAssertEqual(sessionStorage.getSessionId(), "1757400000000",
                       "session storage must survive IdentityStorage.clear()")
        XCTAssertEqual(sessionStorage.getSessionCount(), 5,
                       "session storage must survive IdentityStorage.clear()")
        XCTAssertEqual(sessionStorage.getLastActivityMs(), 9_000,
                       "session storage must survive IdentityStorage.clear()")
    }

    /// A stored count of 0 must read back as 0, not as "absent" — the reader
    /// uses object(forKey:), not integer(forKey:), precisely for this.
    func testStoredZeroCountIsNotAbsent() {
        let storage = SessionStorage(userDefaults: defaults)
        storage.setSession(id: "1", count: 0, lastActivityMs: 1)
        XCTAssertEqual(storage.getSessionCount(), 0)
    }

    func testKeysUseExpectedNamespace() {
        XCTAssertEqual(SessionStorageKey.sessionId.rawValue, "metarouter:session:id")
        XCTAssertEqual(SessionStorageKey.sessionCount.rawValue, "metarouter:session:count")
        XCTAssertEqual(SessionStorageKey.lastActivityMs.rawValue, "metarouter:session:last_activity_ms")
    }
}
