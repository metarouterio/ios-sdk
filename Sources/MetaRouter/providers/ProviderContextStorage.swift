import Foundation

/// Key for the host-set provider context in UserDefaults.
///
/// Its own namespace, outside `IdentityStorageKey`, `SessionStorageKey` and
/// `ConsentStorageKey`, so `IdentityStorage.clear()` — and therefore `reset()` —
/// never touches it: these are install-scoped vendor ids, not user state. A logout
/// that stopped the stamp would make every later event unforwardable.
public enum ProviderContextStorageKey: String {
    case context = "metarouter:providers:context"
}

/// The provider → key → value map the host has set, persisted across launches as
/// one JSON blob.
///
/// Persistence is the point, not a convenience: these values come from vendor SDKs
/// that resolve asynchronously (Firebase's `Analytics.appInstanceID()` is a
/// callback), while `initialize()` emits the cold-launch events and mints the first
/// session on its own init task. A memory-only store would miss those events on
/// *every* launch — exactly the ones a vendor rejects when the id is absent.
///
/// One blob rather than a key per provider: the map is replaced atomically, and a
/// half-written multi-key state would stamp a block nobody configured.
internal struct ProviderContextStorage: @unchecked Sendable {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func get() -> [String: [String: CodableValue]]? {
        guard let data = userDefaults.data(forKey: ProviderContextStorageKey.context.rawValue) else {
            return nil
        }
        do {
            return try JSONDecoder().decode([String: [String: CodableValue]].self, from: data)
        } catch {
            // Corrupt state reads as never-set rather than failing: stamping nothing
            // beats refusing to start, and the host's next set heals it.
            Logger.warn("Stored provider context unreadable — treating as unset: \(error)")
            return nil
        }
    }

    func set(_ value: [String: [String: CodableValue]]) {
        do {
            let data = try JSONEncoder().encode(value)
            userDefaults.set(data, forKey: ProviderContextStorageKey.context.rawValue)
        } catch {
            // Unreachable — the manager rejects unencodable values at the API
            // boundary — but a throw here must not take the host down. In-memory
            // state stays correct; only the next launch falls back to the old blob.
            Logger.warn("Provider context could not be persisted: \(error)")
        }
    }

    /// Production path (`clearAllProviderContext`, and the last key of the last
    /// provider), unlike `SessionStorage.clear()` which is a test-only seam.
    func clear() {
        userDefaults.removeObject(forKey: ProviderContextStorageKey.context.rawValue)
    }
}
