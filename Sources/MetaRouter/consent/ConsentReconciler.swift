import Foundation

/// Reconciles an incoming consent snapshot against the registered category set.
///
/// Reconciliation *completes* the block so every outbound event carries a full,
/// uniform consent map — known categories keep their incoming value, unknown keys
/// are dropped, missing categories get their registered default. It never gates
/// delivery: events send regardless, and the server decides per integration.
internal enum ConsentReconciler {

    /// - Parameters:
    ///   - incoming: consent as supplied by the host (already adapter-normalized).
    ///   - registry: registered categories, already deduplicated by the manager. An
    ///     empty registry passes every `optOut` value through: with nothing to
    ///     reconcile against, dropping keys would silently discard the host's signal.
    ///     The caller owns warning about that path.
    ///
    /// Incoming keys are canonicalized first, on both paths. The registry is
    /// lowercase, so a host calling `setConsent` with OneTrust's native `C0004`
    /// would otherwise miss the lookup and get the registered default — silently
    /// dropping an opt-out whenever that default is opt-in.
    static func reconcile(_ incoming: Consent, against registry: [ConsentCategory]) -> Consent {
        let optOut = ConsentKey.canonicalize(incoming.optOut)
        if registry.isEmpty {
            return Consent(explicit: incoming.explicit, optOut: optOut, timestamp: incoming.timestamp)
        }
        var completed: [String: Bool] = [:]
        completed.reserveCapacity(registry.count)
        for category in registry {
            completed[category.key] = optOut[category.key] ?? category.defaultOptOut
        }
        return Consent(explicit: incoming.explicit, optOut: completed, timestamp: incoming.timestamp)
    }

    /// The state events carry before the host ever calls `setConsent`: not an
    /// "unknown" marker but a real block — `explicit: false` with every registered
    /// category at its default — so the server gates it exactly like an
    /// implicit-consent web visitor.
    static func implicitDefault(for registry: [ConsentCategory]) -> Consent {
        var optOut: [String: Bool] = [:]
        optOut.reserveCapacity(registry.count)
        for category in registry {
            optOut[category.key] = category.defaultOptOut
        }
        return Consent(explicit: false, optOut: optOut)
    }
}
