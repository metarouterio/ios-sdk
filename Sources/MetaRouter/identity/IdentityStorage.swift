import Foundation

/// Keys for storing identity information in UserDefaults
public enum IdentityStorageKey: String {
    case anonymousId = "metarouter:anonymous_id"
    case userId = "metarouter:user_id"
    case groupId = "metarouter:group_id"
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
    }
}

