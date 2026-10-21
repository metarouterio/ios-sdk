import Foundation

/// Receives the current consent on subscription and on every real change. Runs on
/// the main actor, so a handler may touch UI and main-actor-isolated objects
/// directly — no hop, no `@Sendable` capture errors for view controllers.
public typealias ConsentHandler = @MainActor @Sendable (Consent) -> Void
/// Returned by `subscribeToConsent`; call it to stop receiving changes. Idempotent.
public typealias ConsentUnsubscribe = @Sendable () -> Void

/// Canonical consent state: what the host pushes in through `setConsent` and what the
/// SDK stores and stamps on outbound events. Field names and semantics are the web
/// SDK's `context.consent` block verbatim, so the server gates mobile and browser
/// traffic with one rule set — renaming a field here forks every per-integration
/// consent rule downstream.
public struct Consent: Codable, Sendable, Equatable {
    /// `true` when the state reflects an explicit end-user choice (a banner
    /// interaction); `false` for an implicit or regional-default posture. The host
    /// sets it — only the host knows which CMP callback fired — and reconciliation
    /// carries it through untouched.
    public let explicit: Bool

    /// Flat category map with opt-OUT semantics: `true` means blocked. Keys are
    /// lowercase category codes (`c0001`, `analytics`, …). Keys passed to
    /// `setConsent` are trimmed and lowercased before matching `ConsentCategory.key`;
    /// if two collapse to one, opted-out wins.
    public let optOut: [String: Bool]

    /// Epoch milliseconds of the snapshot, as the host's CMP records it. Used for one
    /// thing: a `setConsent` carrying a timestamp older than the newest host-supplied
    /// timestamp is ignored — even across `clearConsent` — because CMP callbacks race
    /// app-launch reads and the newer choice must win regardless of arrival order.
    /// Only host timestamps are compared with each other. Leave nil and the SDK
    /// stamps the device clock for information only — such a call is always applied.
    /// A value too large to be epoch milliseconds (micro- or nanoseconds) is treated
    /// as nil, with a warning.
    /// Never part of the outbound payload.
    public let timestamp: Int64?

    public init(explicit: Bool, optOut: [String: Bool], timestamp: Int64? = nil) {
        self.explicit = explicit
        self.optOut = optOut
        self.timestamp = timestamp
    }

    /// Same decision, ignoring the clock. Subscribers react to this changing, never
    /// to a fresher timestamp on identical values.
    internal func sameDecision(as other: Consent) -> Bool {
        return explicit == other.explicit && optOut == other.optOut
    }

    /// The block as `getDebugInfo()` reports it — the wire shape, no timestamp.
    internal var debugInfoValue: CodableValue {
        return .object([
            "explicit": .bool(explicit),
            "optOut": .object(optOut.mapValues { .bool($0) }),
        ])
    }
}

/// Canonical form of an `optOut` key: trimmed and lowercased. The one definition
/// both the registry and every vendor adapter normalize through, so a key can
/// never be canonical on one side and not the other.
internal enum ConsentKey {
    static func canonical(_ raw: String) -> String {
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Re-keys an `optOut` map canonically, dropping blank keys. Two raw keys that
    /// collapse to one (`C0004` and `c0004`) resolve fail-closed — opted out wins —
    /// because dictionary order is undefined, and a coin flip must never be what
    /// opts a user in.
    static func canonicalize(_ optOut: [String: Bool]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        result.reserveCapacity(optOut.count)
        for (key, value) in optOut {
            let canonicalKey = canonical(key)
            if canonicalKey.isEmpty { continue }
            result[canonicalKey] = (result[canonicalKey] ?? false) || value
        }
        return result
    }
}

/// A consent category the host registers at init, before any values arrive.
///
/// A CMP payload is sparse and vendor-shaped — it will not list every category the
/// pipeline gates on. The registry is what lets the SDK complete an incoming
/// snapshot into a full block: known keys keep their value, unknown keys are
/// dropped, missing categories take `defaultOptOut`.
public struct ConsentCategory: Sendable, Equatable {
    /// Lowercase category code matching the keys in `Consent.optOut`. Registration
    /// normalizes case and whitespace (with a debug assertion), so a `C0001` typo
    /// degrades to a warning in release rather than a category that silently never
    /// matches its incoming value.
    public let key: String

    /// Posture applied when an incoming snapshot does not mention this category.
    /// Defaults to `true` (blocked): a category is opted *in* deliberately, and the
    /// absence of a signal never opts a user in.
    public let defaultOptOut: Bool

    public init(key: String, defaultOptOut: Bool = true) {
        self.key = key
        self.defaultOptOut = defaultOptOut
    }
}
