import Foundation

/// Key for the persisted consent state in UserDefaults.
///
/// Lives in its own namespace, outside `IdentityStorageKey` and `SessionStorageKey`,
/// so `IdentityStorage.clear()` — and therefore `reset()` — never touches it:
/// consent is a compliance record scoped to the device and person, not to the
/// analytics identity. A logout must not resurrect tracking the user opted out of.
public enum ConsentStorageKey: String {
    case state = "metarouter:consent:state"
}

/// Persists the host's consent snapshot across launches as one JSON blob.
///
/// One blob rather than one key per field: the state is replaced atomically on every
/// `setConsent`, and a partially written multi-key state would read back as a
/// consent decision nobody made.
internal struct ConsentStorage: @unchecked Sendable {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func get() -> StoredConsent? {
        guard let data = userDefaults.data(forKey: ConsentStorageKey.state.rawValue) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(StoredConsent.self, from: data)
        } catch {
            // Corrupt state reads as never-set (implicit default) rather than
            // failing: wrong-but-safe beats unusable, and the next setConsent heals
            // it. Unknown keys are tolerated by the decoder, so a downgrade past a
            // build that ADDED a field does not land here; a build that reshapes the
            // blob would, and owes a migration.
            Logger.warn("Stored consent state unreadable — treating as never set: \(error)")
            return nil
        }
    }

    func set(_ stored: StoredConsent) {
        do {
            let data = try JSONEncoder().encode(stored)
            userDefaults.set(data, forKey: ConsentStorageKey.state.rawValue)
        } catch {
            // Unreachable for a Bool/String/Int64 value type, but a throw here must
            // not take down the host — the in-memory state is still correct for
            // this process, only the next launch falls back to the implicit default.
            Logger.warn("Consent state could not be persisted: \(error)")
        }
    }

    /// Production path (the consent-withdrawal half of `clearConsent`), unlike
    /// `SessionStorage.clear()` which is a test-only seam.
    func clear() {
        userDefaults.removeObject(forKey: ConsentStorageKey.state.rawValue)
    }
}
