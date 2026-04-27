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

    public func setVersion(_ value: String) {
        userDefaults.set(value, forKey: LifecycleStorageKey.version.rawValue)
    }

    public func setBuild(_ value: String) {
        userDefaults.set(value, forKey: LifecycleStorageKey.build.rawValue)
    }

    public func setVersionBuild(version: String, build: String) {
        setVersion(version)
        setBuild(build)
    }

    /// Removes the persisted version and build. Intended for tests.
    public func clear() {
        userDefaults.removeObject(forKey: LifecycleStorageKey.version.rawValue)
        userDefaults.removeObject(forKey: LifecycleStorageKey.build.rawValue)
    }
}
