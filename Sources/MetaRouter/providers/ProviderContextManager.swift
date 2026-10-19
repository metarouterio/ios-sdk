import Foundation

/// Owns the host-set `context.providers` map: in-memory state, bounds, persistence.
/// The public API delegates here; enrichment reads `getAll()` once per event.
///
/// A lock-based class rather than an actor, for the same reason as `ConsentManager`:
/// `setProviderContext` must be read-your-writes synchronous. A host that resolves a
/// vendor id in a callback and tracks on the next line expects that event to carry
/// it, and an actor hop would let enrichment read the old value.
///
/// Deliberately not merged with `ConsentManager` despite the shared shape: consent
/// is a reconciled state machine with a registry, subscribers and staleness
/// arbitration; this is a bounded map written verbatim.
internal final class ProviderContextManager: @unchecked Sendable {

    /// Reserved for the SDK's own block (`sessionID`, `sessionCount`). Enrichment
    /// writes it last and would win anyway, but a write that silently vanished later
    /// is worse than one rejected at the call.
    static let reservedProvider = "metarouter"

    // This map rides on EVERY event and the cluster rejects a single event over
    // 250 KiB (StreamingLimitBytes). Worst case here is 10 x 10 x (256 + 64 + 64)
    // ≈ 38 KB — far more than any real integration needs (a vendor id is a ~36-byte
    // UUID) and well clear of the cap. Exceeding a bound rejects that one write and
    // keeps prior state; it never trims, because a truncated vendor id looks valid
    // and matches nothing.
    static let maxProviders = 10
    static let maxKeysPerProvider = 10
    static let maxValueBytes = 256
    static let maxNameBytes = 64

    /// Debug-only fail-fast for host misuse, injectable: assertions are active in
    /// test builds too, so tests of the release-degrade path swap this to observe
    /// instead of trap. Matches `ConsentManager.debugAssert`.
    internal nonisolated(unsafe) static var debugAssert: @Sendable (String) -> Void = {
        assertionFailure($0)
    }

    private let lock = NSLock()
    private var storage: ProviderContextStorage
    private var providers: [String: [String: CodableValue]]

    /// Commit ordering for off-lock persistence, mirroring `ConsentManager`:
    /// `UserDefaults` writes fire KVO synchronously on the calling thread, so a host
    /// observer writing back here would re-enter a non-recursive lock and hang.
    private var commitSequence: UInt64 = 0
    private let persistLock = NSRecursiveLock()
    private var persistedSequence: UInt64 = 0

    init(storage: ProviderContextStorage) {
        self.storage = storage
        // Loaded eagerly: built once per process before any client, so last
        // launch's values are visible to the very first enrichment — which is what
        // gets the cold-launch events stamped.
        self.providers = storage.get() ?? [:]
    }

    // MARK: - Reads

    /// The full map, for enrichment. A copy: the caller stamps it onto an event
    /// that outlives the lock, and the bounds above keep copying cheap.
    func getAll() -> [String: [String: CodableValue]] {
        lock.lock()
        defer { lock.unlock() }
        return providers
    }

    // MARK: - Writes

    /// Host entry point. `nil` — and anything converting to JSON null — removes the
    /// key rather than stamping a null: a mapping gets nothing useful from a null,
    /// and a host passing nil means "stop sending this".
    func setValue(provider: String, key: String, value: Any?) {
        guard let value else {
            setValue(provider: provider, key: key, codable: nil)
            return
        }
        guard let converted = Self.strictlyConverted(value) else {
            let message = "setProviderContext(\"\(provider)\", key: \"\(key)\"): value is not JSON-representable — ignored"
            Logger.warn(message)
            Self.debugAssert(message)
            return
        }
        if case .null = converted {
            setValue(provider: provider, key: key, codable: nil)
            return
        }
        setValue(provider: provider, key: key, codable: converted)
    }

    /// The one write path for a single key. `codable: nil` removes it, and removing
    /// a provider's last key removes the provider — an empty block would otherwise
    /// ship on every event forever, indistinguishable from a misconfigured one.
    func setValue(provider: String, key: String, codable: CodableValue?) {
        let providerName = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyName = key.trimmingCharacters(in: .whitespacesAndNewlines)

        // NOT lowercased, unlike consent category keys: these are wire paths
        // matched verbatim by pipeline mappings (the Firebase kit reads
        // `context.providers.googleFirebase.appInstanceId`), so canonicalising case
        // would break the mapping this exists to feed.
        guard let providerName = validatedName(providerName, label: "provider"),
              let keyName = validatedName(keyName, label: "key")
        else { return }

        guard providerName != Self.reservedProvider else {
            let message = "setProviderContext: \"\(Self.reservedProvider)\" is reserved for the SDK's own session block — ignored"
            Logger.warn(message)
            Self.debugAssert(message)
            return
        }

        if let codable, let rejection = oversizeRejection(codable, provider: providerName, key: keyName) {
            Logger.warn(rejection)
            Self.debugAssert(rejection)
            return
        }

        lock.lock()
        var existing = providers[providerName] ?? [:]

        if let codable {
            if providers[providerName] == nil && providers.count >= Self.maxProviders {
                lock.unlock()
                let message = "setProviderContext: at most \(Self.maxProviders) providers — \"\(providerName)\" ignored"
                Logger.warn(message)
                Self.debugAssert(message)
                return
            }
            if existing[keyName] == nil && existing.count >= Self.maxKeysPerProvider {
                lock.unlock()
                let message = "setProviderContext: at most \(Self.maxKeysPerProvider) keys per provider — \"\(providerName).\(keyName)\" ignored"
                Logger.warn(message)
                Self.debugAssert(message)
                return
            }
            existing[keyName] = codable
            providers[providerName] = existing
        } else {
            existing.removeValue(forKey: keyName)
            if existing.isEmpty {
                providers.removeValue(forKey: providerName)
            } else {
                providers[providerName] = existing
            }
        }

        let pending = commitLocked()
        lock.unlock()
        persist(pending)
    }

    /// Removes one provider's whole block.
    func clear(provider: String) {
        let providerName = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        guard providers.removeValue(forKey: providerName) != nil else {
            // No commit on a no-op: bumping the sequence for a write that changed
            // nothing would let it supersede a concurrent real commit on disk.
            lock.unlock()
            return
        }

        let pending = commitLocked()
        lock.unlock()
        persist(pending)
    }

    /// Removes everything the host has set. Distinct from `reset()`, which clears
    /// identity and leaves this alone.
    func clearAll() {
        lock.lock()
        guard !providers.isEmpty else {
            lock.unlock()
            return
        }
        providers.removeAll()
        let pending = commitLocked()
        lock.unlock()
        persist(pending)
    }

    // MARK: - Validation

    /// `CodableValue.from` is tolerant by design — a bad element inside a container
    /// is dropped and the rest kept, which suits event properties. Here it would
    /// store a value the host never set (`["id": "abc", "ts": Date()]` becoming
    /// `{"id":"abc"}`, stamped on every event), so any unconvertible element anywhere
    /// rejects the whole write.
    private static func strictlyConverted(_ value: Any) -> CodableValue? {
        if let array = value as? [Any] {
            var converted: [CodableValue] = []
            converted.reserveCapacity(array.count)
            for element in array {
                guard let item = strictlyConverted(element) else { return nil }
                converted.append(item)
            }
            return .array(converted)
        }
        if let dict = value as? [String: Any] {
            var converted: [String: CodableValue] = [:]
            converted.reserveCapacity(dict.count)
            for (key, element) in dict {
                guard let item = strictlyConverted(element) else { return nil }
                converted[key] = item
            }
            return .object(converted)
        }
        return CodableValue.from(value)
    }

    private func validatedName(_ name: String, label: String) -> String? {
        guard !name.isEmpty else {
            let message = "setProviderContext: blank \(label) name — ignored"
            Logger.warn(message)
            Self.debugAssert(message)
            return nil
        }
        // UTF-8 bytes, not characters: the budget above is a byte budget, and one
        // grapheme cluster can carry hundreds of combining marks. Same reasoning as
        // the bridge parser's messageId cap.
        guard name.utf8.count <= Self.maxNameBytes else {
            let message = "setProviderContext: \(label) name exceeds \(Self.maxNameBytes) bytes — ignored"
            Logger.warn(message)
            Self.debugAssert(message)
            return nil
        }
        return name
    }

    /// Nil when the value fits. Measured as encoded JSON so one rule covers scalars
    /// and the nested arrays/objects `CodableValue` allows. An unencodable value is
    /// rejected here, not at persist time where it would already be live in memory.
    private func oversizeRejection(_ value: CodableValue, provider: String, key: String) -> String? {
        let encoded: Data
        do {
            // Wrapped in an array because a bare scalar is a top-level JSON
            // fragment; the two bracket bytes come off again before comparing.
            encoded = try JSONEncoder().encode([value])
        } catch {
            return "setProviderContext(\"\(provider)\", key: \"\(key)\"): value could not be encoded (\(error)) — ignored"
        }
        let byteCount = max(0, encoded.count - 2)
        guard byteCount > Self.maxValueBytes else { return nil }
        return "setProviderContext(\"\(provider)\", key: \"\(key)\"): value is \(byteCount) bytes, limit \(Self.maxValueBytes) — ignored"
    }

    // MARK: - Persistence

    private struct PendingPersist {
        let sequence: UInt64
        let value: [String: [String: CodableValue]]
    }

    /// Caller holds `lock` and must hand the result to `persist` after releasing it.
    private func commitLocked() -> PendingPersist {
        commitSequence += 1
        return PendingPersist(sequence: commitSequence, value: providers)
    }

    /// Writes a commit unless a later one already has. Two threads can leave the
    /// manager lock in the opposite order from their commits; the sequence keeps
    /// disk from ending on an older map than memory.
    private func persist(_ pending: PendingPersist) {
        persistLock.lock()
        defer { persistLock.unlock() }
        guard pending.sequence > persistedSequence else { return }
        persistedSequence = pending.sequence
        if pending.value.isEmpty {
            storage.clear()
        } else {
            storage.set(pending.value)
        }
    }

    // MARK: - Debug

    var debugInfoValue: CodableValue {
        // Values omitted on purpose: these are vendor device identifiers and
        // getDebugInfo is printed into host logs — the same reason advertisingId is
        // redacted there. The shape is what shows a misconfiguration.
        let shape = getAll().mapValues { keys in
            CodableValue.array(keys.keys.sorted().map { .string($0) })
        }
        return .object(shape)
    }

    // MARK: - Test seam

    /// Swaps the backing storage and rebuilds from it, for tests that exercise the
    /// process-wide manager behind `MetaRouter` without touching
    /// `UserDefaults.standard`. Mirrors `ConsentManager._replaceStorageForTesting`.
    func _replaceStorageForTesting(_ newStorage: ProviderContextStorage) {
        persistLock.lock()
        lock.lock()
        storage = newStorage
        providers = newStorage.get() ?? [:]
        commitSequence = 0
        persistedSequence = 0
        lock.unlock()
        persistLock.unlock()
    }
}
