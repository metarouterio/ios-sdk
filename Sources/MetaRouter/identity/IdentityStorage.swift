import Foundation

/// Keys for storing identity information in UserDefaults
public enum IdentityStorageKey: String {
    case anonymousId = "metarouter:anonymous_id"
    case userId = "metarouter:user_id"
    case groupId = "metarouter:group_id"
    case advertisingId = "metarouter:advertising_id"
}

/// Handles persistence of identity fields using UserDefaults
public struct IdentityStorage: @unchecked Sendable {
    private let userDefaults: UserDefaults

    // Process-wide: the proxy writes a host-set anonymousId through its own
    // instance while a client's IdentityManager may be minting one through
    // another. Both check-and-set under this lock so neither overwrites the other.
    private static let anonymousIdLock = NSLock()

    /// Present from a host-set anonymousId on a device that had none until the next
    /// `IdentityManager.initialize`, so that launch's install detection still sees
    /// the device as fresh. Not an `IdentityStorageKey`: bookkeeping, not identity.
    private static let hostSetMarkerKey = "metarouter:anonymous_id_host_set"

    /// `reset()` ordering. The host's reset() notes the request synchronously and
    /// its clear runs later in the same process; a host id set in between must
    /// survive that clear. In memory, because nothing about it survives a relaunch,
    /// and per defaults store so separate stores (tests) never share it. Guarded by
    /// `anonymousIdLock`.
    private struct ResetOrdering {
        var pending = 0
        var hostSetSinceRequest = false
    }
    private nonisolated(unsafe) static var resetOrdering: [ObjectIdentifier: ResetOrdering] = [:]
    private var orderingKey: ObjectIdentifier { ObjectIdentifier(userDefaults) }
    
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }
    
    /// Retrieves an identity field from storage
    public func get(_ key: IdentityStorageKey) -> String? {
        return userDefaults.string(forKey: key.rawValue)
    }
    
    /// Stores an identity field
    public func set(_ key: IdentityStorageKey, value: String) {
        userDefaults.set(value, forKey: key.rawValue)
    }
    
    /// Removes an identity field from storage
    public func remove(_ key: IdentityStorageKey) {
        userDefaults.removeObject(forKey: key.rawValue)
    }
    
    /// Clears all identity fields. When it is the clear of a requested `reset()`
    /// (see `noteResetRequested()`), keeps a host-set anonymousId written after
    /// that request.
    public func clear() {
        Self.anonymousIdLock.withLock {
            var ordering = Self.resetOrdering[orderingKey]
            let keepAnonymousId = ordering?.hostSetSinceRequest ?? false
            if var o = ordering, o.pending > 0 {
                o.pending -= 1
                ordering = o.pending > 0 ? o : nil
                Self.resetOrdering[orderingKey] = ordering
            }
            guard !keepAnonymousId else { return }
            remove(.anonymousId)
            userDefaults.removeObject(forKey: Self.hostSetMarkerKey)
        }
        remove(.userId)
        remove(.groupId)
        remove(.advertisingId)
    }

    /// The stored anonymousId, or `make()` stored as the new one when none exists.
    func getOrCreateAnonymousId(_ make: () -> String) -> (id: String, created: Bool) {
        Self.anonymousIdLock.withLock {
            if let stored = get(.anonymousId) { return (stored, false) }
            let id = make()
            set(.anonymousId, value: id)
            return (id, true)
        }
    }

    /// Stores a host-provided anonymousId. Marks it host-set when the device had no
    /// anonymousId yet, so `hasAnyValue()` keeps reporting a fresh install.
    /// - Returns: the anonymousId it replaced, and whether anything was written
    ///   (`false` when `id` is already stored).
    @discardableResult
    func setHostAnonymousId(_ id: String) -> (previous: String?, changed: Bool) {
        Self.anonymousIdLock.withLock {
            // Before the unchanged check: re-setting the current id right after
            // reset() must keep it too.
            if Self.resetOrdering[orderingKey] != nil {
                Self.resetOrdering[orderingKey]?.hostSetSinceRequest = true
            }
            let previous = get(.anonymousId)
            guard previous != id else { return (previous, false) }
            if previous == nil { userDefaults.set(true, forKey: Self.hostSetMarkerKey) }
            set(.anonymousId, value: id)
            return (previous, true)
        }
    }

    /// Called synchronously when the host calls `reset()`, before the asynchronous
    /// clear is queued: from here, only a host id set after this call survives it.
    func noteResetRequested() {
        Self.anonymousIdLock.withLock {
            var ordering = Self.resetOrdering[orderingKey] ?? ResetOrdering()
            ordering.pending += 1
            ordering.hostSetSinceRequest = false
            Self.resetOrdering[orderingKey] = ordering
        }
    }

    var hasHostSetMarker: Bool {
        userDefaults.object(forKey: Self.hostSetMarkerKey) != nil
    }

    /// Ends the host-set marker's window. Called once install detection has read it.
    func clearHostSetMarker() {
        Self.anonymousIdLock.withLock { userDefaults.removeObject(forKey: Self.hostSetMarkerKey) }
    }

    /// Returns `true` if any identity field is currently persisted.
    /// Used by `LifecycleEventEmitter` to differentiate a true fresh install
    /// (no identity, no lifecycle storage) from an existing user upgrading from
    /// a pre-lifecycle SDK build (identity present, no lifecycle storage).
    /// A host-set anonymousId on a device that had none does not count: the
    /// host can set it before the first `initialize`, which is still an install.
    public func hasAnyValue() -> Bool {
        return (get(.anonymousId) != nil && !hasHostSetMarker)
            || get(.userId) != nil
            || get(.groupId) != nil
            || get(.advertisingId) != nil
    }
}

