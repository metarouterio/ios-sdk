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
    
    /// Clears all identity fields
    public func clear() {
        remove(.anonymousId)
        remove(.userId)
        remove(.groupId)
        remove(.advertisingId)
    }

    /// Returns `true` if any identity field is currently persisted.
    /// Used by `LifecycleEventEmitter` to differentiate a true fresh install
    /// (no identity, no lifecycle storage) from an existing user upgrading from
    /// a pre-lifecycle SDK build (identity present, no lifecycle storage).
    public func hasAnyValue() -> Bool {
        return get(.anonymousId) != nil
            || get(.userId) != nil
            || get(.groupId) != nil
            || get(.advertisingId) != nil
    }
}

