import Foundation

/// Manages user, group, and anonymous identity for analytics events.
/// - Loads or generates a persistent anonymous ID.
/// - Tracks current user and group IDs.
/// - Can enrich events with identity information.
/// - Supports reset for logout/testing scenarios.
public actor IdentityManager {
    private let storage: IdentityStorage
    private let writeKey: String
    private let host: String
    
    private var anonymousId: String?
    private var userId: String?
    private var groupId: String?
    
    public init(storage: IdentityStorage = IdentityStorage(), writeKey: String, host: String) {
        self.storage = storage
        self.writeKey = writeKey
        self.host = host
    }
    
    /// Initializes the manager by loading or generating an anonymous ID.
    /// Should be called before using other methods.
    public func initialize() async {
        // Load anonymous ID or generate a new one
        if let storedAnonId = storage.get(.anonymousId) {
            self.anonymousId = storedAnonId
            Logger.log("Loaded stored anonymous ID: \(storedAnonId)", writeKey: writeKey, host: host)
        } else {
            let newId = UUID().uuidString.lowercased()
            storage.set(.anonymousId, value: newId)
            self.anonymousId = newId
            Logger.log("Generated and stored new anonymous ID: \(newId)", writeKey: writeKey, host: host)
        }
        
        // Load userId and groupId if they exist
        self.userId = storage.get(.userId)
        self.groupId = storage.get(.groupId)
        
        Logger.log(
            "IdentityManager initialized with anonymous ID: \(anonymousId ?? "nil") userId: \(userId ?? "undefined") groupId: \(groupId ?? "undefined")",
            writeKey: writeKey,
            host: host
        )
    }
    
    /// Retrieves the current anonymous ID.
    public func getAnonymousId() -> String? {
        return anonymousId
    }
    
    /// Sets the user ID for the current session.
    public func identify(_ userId: String) {
        self.userId = userId
        storage.set(.userId, value: userId)
        Logger.log("User identified: \(userId)", writeKey: writeKey, host: host)
    }
    
    /// Sets the group ID for the current session.
    public func group(_ groupId: String) {
        self.groupId = groupId
        storage.set(.groupId, value: groupId)
        Logger.log("User grouped: \(groupId)", writeKey: writeKey, host: host)
    }
    
    /// Retrieves the current user ID.
    public func getUserId() -> String? {
        return userId
    }
    
    /// Retrieves the current group ID.
    public func getGroupId() -> String? {
        return groupId
    }
    
    /// Returns identity information for event enrichment.
    public func getIdentityInfo() -> (anonymousId: String, userId: String?, groupId: String?) {
        return (
            anonymousId: anonymousId ?? "unknown",
            userId: userId,
            groupId: groupId
        )
    }
    
    /// Resets the identity manager to its initial state.
    /// Clears all user and group IDs, and removes the anonymous ID from storage.
    public func reset() {
        self.anonymousId = nil
        self.userId = nil
        self.groupId = nil
        storage.clear()
        Logger.log("IdentityManager reset", writeKey: writeKey, host: host)
    }
}

