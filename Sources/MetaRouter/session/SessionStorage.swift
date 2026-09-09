import Foundation

/// Keys for persisting session state in UserDefaults.
/// These keys live in a namespace separate from `IdentityStorageKey` so they
/// are unaffected by `IdentityStorage.clear()` (and therefore by `reset()`):
/// a logout mid-session must not fragment the analytics session — downstream
/// session-scoped reporting (e.g. GA4) counts the visit, not the login state.
public enum SessionStorageKey: String {
    case sessionId = "metarouter:session:id"
    case sessionCount = "metarouter:session:count"
    case lastActivityMs = "metarouter:session:last_activity_ms"
}

/// Persists the current session id, the lifetime session counter, and the
/// wall-clock time of the last recorded activity, so a session can survive a
/// process restart that happens inside the inactivity window.
///
/// `lastActivityMs` is deliberately wall-clock (epoch milliseconds): a
/// monotonic reading is meaningless across process restarts, which is the
/// only reason this value is persisted at all. In-process inactivity is
/// measured monotonically by `SessionManager` and never read back from here.
public struct SessionStorage: @unchecked Sendable {
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func getSessionId() -> String? {
        return userDefaults.string(forKey: SessionStorageKey.sessionId.rawValue)
    }

    public func getSessionCount() -> Int? {
        // `integer(forKey:)` returns 0 for "absent", which is indistinguishable
        // from a stored 0 — read the object so absence stays nil and a fresh
        // install starts its counter at 1 instead of resuming a phantom count.
        return (userDefaults.object(forKey: SessionStorageKey.sessionCount.rawValue) as? NSNumber)?.intValue
    }

    public func getLastActivityMs() -> Int64? {
        return (userDefaults.object(forKey: SessionStorageKey.lastActivityMs.rawValue) as? NSNumber)?.int64Value
    }

    public func setSession(id: String, count: Int, lastActivityMs: Int64) {
        userDefaults.set(id, forKey: SessionStorageKey.sessionId.rawValue)
        userDefaults.set(count, forKey: SessionStorageKey.sessionCount.rawValue)
        userDefaults.set(NSNumber(value: lastActivityMs), forKey: SessionStorageKey.lastActivityMs.rawValue)
    }

    public func setLastActivityMs(_ value: Int64) {
        userDefaults.set(NSNumber(value: value), forKey: SessionStorageKey.lastActivityMs.rawValue)
    }

    /// Removes all persisted session state. Test-only seam — production code
    /// must never call this. The `metarouter:session:*` namespace separation
    /// exists so nothing — not even `reset()` — can end a session as a side
    /// effect of clearing identity.
    internal func clear() {
        userDefaults.removeObject(forKey: SessionStorageKey.sessionId.rawValue)
        userDefaults.removeObject(forKey: SessionStorageKey.sessionCount.rawValue)
        userDefaults.removeObject(forKey: SessionStorageKey.lastActivityMs.rawValue)
    }
}
