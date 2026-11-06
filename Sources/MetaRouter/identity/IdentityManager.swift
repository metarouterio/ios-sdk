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
    private var advertisingId: String?
    
    public init(storage: IdentityStorage = IdentityStorage(), writeKey: String, host: String) {
        self.storage = storage
        self.writeKey = writeKey
        self.host = host
    }
    
    /// Initializes the manager by loading or generating an anonymous ID.
    /// Should be called before using other methods.
    public func initialize() async {
        getOrCreateAnonymousId()
        // The lifecycle emitter snapshots install state when the client is built,
        // before this runs; past that point the marker would only misreport a
        // later launch (e.g. lifecycle tracking enabled in a future release).
        storage.clearHostSetMarker()

        // Load userId, groupId, and advertisingId if they exist
        self.userId = storage.get(.userId)
        self.groupId = storage.get(.groupId)
        self.advertisingId = storage.get(.advertisingId)

        // Redact advertisingId in logs for privacy
        let redactedAdvertisingId = advertisingId.map { "\($0.prefix(8))***" } ?? "undefined"

        Logger.log(
            "IdentityManager initialized with anonymous ID: \(anonymousId ?? "nil") userId: \(userId ?? "undefined") groupId: \(groupId ?? "undefined") advertisingId: \(redactedAdvertisingId)",
            writeKey: writeKey,
            host: host
        )
    }
    
    /// Retrieves the current anonymous ID.
    public func getAnonymousId() -> String? {
        return currentAnonymousId()
    }

    /// Returns the current anonymous ID, generating and persisting one if missing.
    /// Safe to call before `initialize()` or after `reset()` — guarantees a stable,
    /// persisted ID across subsequent calls.
    @discardableResult
    public func getOrCreateAnonymousId() -> String {
        // Storage first: setAnonymousId writes there from outside this actor (the
        // proxy, before a client is bound), and the next event must carry it. The
        // in-memory copy only re-seeds storage if something else wiped it.
        let (id, created) = storage.getOrCreateAnonymousId {
            anonymousId ?? UUID().uuidString.lowercased()
        }
        if created {
            Logger.log("Generated and stored new anonymous ID: \(id)", writeKey: writeKey, host: host)
        } else if id != anonymousId {
            Logger.log("Loaded stored anonymous ID: \(id)", writeKey: writeKey, host: host)
        }
        self.anonymousId = id
        return id
    }

    /// Replaces the anonymous ID with one the host owns (e.g. the id a WebView's web
    /// SDK already uses). Nonisolated and storage-backed so it is read-your-writes
    /// and works before `initialize`; see `apply(hostAnonymousId:to:)`.
    @discardableResult
    nonisolated public func setAnonymousId(_ anonymousId: String) -> Bool {
        Self.apply(hostAnonymousId: anonymousId, to: storage)
    }

    /// See `IdentityStorage.noteResetRequested()`.
    nonisolated func noteResetRequested() {
        storage.noteResetRequested()
    }

    /// Longest accepted host anonymousId, in UTF-8 bytes. Generous for any web or
    /// vendor id (a UUID is 36), and it rides on every event.
    static let maxHostAnonymousIdBytes = 256

    /// Validates and stores a host-provided anonymousId. Shared by the proxy (which
    /// writes before any client exists) and the client.
    /// - Returns: `false` when rejected; the stored anonymousId is unchanged.
    static func apply(hostAnonymousId raw: String, to storage: IdentityStorage) -> Bool {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = storage.get(.anonymousId)  // for the warnings only
        guard !id.isEmpty else {
            Logger.warn("setAnonymousId rejected: the value is empty after trimming whitespace. anonymousId unchanged (\(current ?? "none stored yet")).")
            return false
        }
        let bytes = id.utf8.count
        guard bytes <= maxHostAnonymousIdBytes else {
            Logger.warn("setAnonymousId rejected: the value is \(bytes) bytes, over the \(maxHostAnonymousIdBytes)-byte limit (starts '\(id.prefix(40))'). anonymousId unchanged (\(current ?? "none stored yet")).")
            return false
        }
        let (previous, changed) = storage.setHostAnonymousId(id)
        if changed {
            Logger.log("Anonymous ID set by host: \(id) (was \(previous ?? "none stored yet"))")
        }
        return true
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

    /// Sets the advertising ID for the current session.
    public func setAdvertisingId(_ advertisingId: String?) {
        self.advertisingId = advertisingId
        if let advertisingId = advertisingId {
            storage.set(.advertisingId, value: advertisingId)
            // Redact advertisingId in logs for privacy
            let redactedId = "\(advertisingId.prefix(8))***"
            Logger.log("Advertising ID set: \(redactedId)", writeKey: writeKey, host: host)
        } else {
            storage.remove(.advertisingId)
            Logger.log("Advertising ID cleared", writeKey: writeKey, host: host)
        }
    }

    /// Retrieves the current advertising ID.
    public func getAdvertisingId() -> String? {
        return advertisingId
    }

    /// Clears the advertising ID for GDPR compliance.
    /// This is equivalent to calling setAdvertisingId(nil) but more explicit for compliance purposes.
    public func clearAdvertisingId() {
        self.advertisingId = nil
        storage.remove(.advertisingId)
        Logger.log("Advertising ID cleared for GDPR compliance", writeKey: writeKey, host: host)
    }

    /// Returns identity information for event enrichment. Generates the anonymous
    /// ID if none is stored, so the first event after `reset()` carries a new one
    /// rather than a placeholder.
    public func getIdentityInfo() -> (anonymousId: String, userId: String?, groupId: String?) {
        return (
            anonymousId: getOrCreateAnonymousId(),
            userId: userId,
            groupId: groupId
        )
    }
    
    private func currentAnonymousId() -> String? {
        storage.get(.anonymousId) ?? anonymousId
    }

    /// Resets the identity manager to its initial state.
    /// Clears all user and group IDs, and removes the anonymous ID (host-set or not)
    /// from storage — unless the host set one after `noteResetRequested()`.
    public func reset() {
        self.anonymousId = nil
        self.userId = nil
        self.groupId = nil
        self.advertisingId = nil
        storage.clear()
        Logger.log("IdentityManager reset", writeKey: writeKey, host: host)
    }
}

