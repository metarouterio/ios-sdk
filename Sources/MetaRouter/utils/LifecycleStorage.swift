import Foundation

/// Keys for persisting the last-seen application version/build in UserDefaults.
/// These keys live in a namespace separate from `IdentityStorageKey` so they
/// are unaffected by `IdentityStorage.clear()` (and therefore by `reset()`).
public enum LifecycleStorageKey: String {
    case version = "metarouter:lifecycle:version"
    case build = "metarouter:lifecycle:build"
}

/// Persists the last application version/build the SDK observed on cold launch.
/// Used by `LifecycleEventEmitter` to decide whether to emit `Application Installed`
/// or `Application Updated`.
///
/// Storage is kept intentionally separate from `IdentityStorage` so a user's
/// `reset()` call cannot wipe install/update state.
public struct LifecycleStorage: @unchecked Sendable {
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func getVersion() -> String? {
        return userDefaults.string(forKey: LifecycleStorageKey.version.rawValue)
    }

    public func getBuild() -> String? {
        return userDefaults.string(forKey: LifecycleStorageKey.build.rawValue)
    }

    /// Version and build are persisted together to keep them in lockstep — the
    /// lifecycle emitter treats `(version, build)` as a pair, so independent
    /// setters would let the two halves drift and trigger spurious
    /// `Application Updated` events on the next cold launch.
    public func setVersionBuild(version: String, build: String) {
        userDefaults.set(version, forKey: LifecycleStorageKey.version.rawValue)
        userDefaults.set(build, forKey: LifecycleStorageKey.build.rawValue)
    }

    /// Removes the persisted version and build. Test-only seam — production code
    /// must never call this. The whole point of the `metarouter:lifecycle:*`
    /// namespace separation is that nothing — not even `reset()` — can wipe
    /// install/update state.
    internal func clear() {
        userDefaults.removeObject(forKey: LifecycleStorageKey.version.rawValue)
        userDefaults.removeObject(forKey: LifecycleStorageKey.build.rawValue)
    }
}
