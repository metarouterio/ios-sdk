import Foundation




public enum MetaRouter {
    // One consent manager per process, built with the proxy rather than at
    // initialize: it needs nothing from a client, so consent is usable before
    // initialize() (a CMP callback can fire first), during async init, and across
    // reset()/re-initialize — every client this type binds stamps from this same
    // instance. Consent is a device-scoped compliance record, not identity, which
    // is why reset() leaves it alone.
    private static let consentManager = ConsentManager(storage: ConsentStorage())
    // One per process, for the same reasons as consent plus one more: it loads from
    // storage at construction, before any client exists, so last launch's vendor ids
    // are already on the cold-launch events initialize() goes on to emit.
    private static let providerContextManager = ProviderContextManager(storage: ProviderContextStorage())
    // One instance for the proxy and every client, passed explicitly like the
    // managers above: setAnonymousId before bind and reset()'s ordering note write
    // through the proxy's, and the client's clear and reads must hit the same one.
    private static let identityStorage = IdentityStorage()
    private static let proxy = AnalyticsProxy(
        consentManager: consentManager,
        providerContextManager: providerContextManager,
        identityStorage: identityStorage
    )
    private static let store = RealClientStore()

    /// Test seam for the process-wide manager; see `ConsentManager._replaceStorageForTesting`.
    internal static var _consentManagerForTesting: ConsentManager { consentManager }

    /// Test seam for the process-wide manager; see `ProviderContextManager._replaceStorageForTesting`.
    internal static var _providerContextManagerForTesting: ProviderContextManager { providerContextManager }

    private static var clientDependencies: AnalyticsDependencies {
        var deps = AnalyticsDependencies.production
        deps.consentManager = consentManager
        deps.providerContextManager = providerContextManager
        deps.identityStorage = identityStorage
        return deps
    }

    /// Returns once this initialize has taken effect, or at once when a later
    /// initialize or reset superseded it (logged as a warning; that later call takes
    /// effect after this returns): it is not guaranteed to return with this call's
    /// client bound.
    public static func initializeAndWait(with options: InitOptions) async -> AnalyticsInterface {
        guard passesConfigGate(options) else {
            proxy.detachCalls()
            proxy.lifecycle.enqueue { await disableSession() }
            fireConfigError(options)
            await proxy.lifecycle.run {}
            return proxy
        }
        proxy.supersedeForInitialize()
        let epoch = proxy.lifecycleEpoch()
        await proxy.lifecycle.run {
            guard proxy.lifecycleEpoch() == epoch else { return logSuperseded(waited: true) }
            await proxy._clearConfigDisabled()
            let real = AnalyticsClient.initialize(options: options.discardingConfigCallback(), deps: clientDependencies)
            guard await proxy._bindIfCurrent(real, epoch: epoch) else {
                shutdown(real)
                return logSuperseded(waited: true)
            }
            shutdown(await store.get())
            await store.set(real)
        }
        return proxy
    }

   @discardableResult
    public static func createAnalyticsClient(with options: InitOptions) -> AnalyticsInterface {
        // Return the proxy immediately; bind happens async (proxy queues pre-bind calls)
        guard passesConfigGate(options) else {
            proxy.detachCalls()
            proxy.lifecycle.enqueue { await disableSession() }
            fireConfigError(options)
            return proxy
        }
        let epoch = proxy.lifecycleEpoch()
        proxy.lifecycle.enqueue {
            guard proxy.lifecycleEpoch() == epoch else { return logSuperseded() }
            guard await store.get() == nil else {
                Logger.warn("MetaRouter.Analytics.initialize() called more than once — subsequent calls are ignored. Use reset() first if you need to re-initialize.")
                return
            }
            await proxy._clearConfigDisabled()
            let real = AnalyticsClient.initialize(options: options.discardingConfigCallback(), deps: clientDependencies)
            guard await proxy._bindIfCurrent(real, epoch: epoch) else {
                shutdown(real)
                return logSuperseded()
            }
            await store.set(real)
        }
        return proxy
    }

    /// The release half of the invalid-config contract: construction recorded the
    /// verdict, this is where it takes effect. On invalid config no client is created —
    /// the proxy is still returned so call sites never see nil, and the SDK is inert
    /// for the session, mirroring the 401/403/404 graceful-disable for local config.
    /// The log fires here; the callback fires from `fireConfigError`, once the disable
    /// is queued. Both on the caller's thread.
    private static func passesConfigGate(_ options: InitOptions) -> Bool {
        proxy.setBootstrapDebugInfo(
            writeKey: options.writeKey,
            host: options.ingestionHost.absoluteString,
            configError: options.configError?.description
        )
        guard let error = options.configError else { return true }
        Logger.error("MetaRouter disabled for this session — \(error.description)")
        return false
    }

    /// After the disable is queued: a fallback initialize from the callback must queue behind it.
    private static func fireConfigError(_ options: InitOptions) {
        if let error = options.configError { options.onConfigError?(error) }
    }

    /// An initialize call with invalid config disables the whole session, even a
    /// re-initialize over a previously valid client: silently keeping the stale
    /// client running would mask the config error (a bound client also shadows the
    /// bootstrap debug info that reports it). Fail visible, not quiet. Marking the
    /// proxy disabled also resolves any suspended awaiters — no bind is coming.
    ///
    /// Runs on `proxy.lifecycle`, after the caller's `proxy.detachCalls()`: detached on
    /// the queue instead, it would also drop calls made after a later valid initialize.
    private static func disableSession() async {
        await discardClient()
        await proxy._markConfigDisabled()
    }

    /// Runs on `proxy.lifecycle`.
    private static func discardClient() async {
        await proxy._unbindState()
        shutdown(await store.get())
        await store.clear()
    }

    private static func logSuperseded(waited: Bool = false) {
        let message = "initialize skipped: a later reset() or initialize superseded it"
        // An awaited initialize returns without its client bound: worth surfacing.
        if waited { Logger.warn(message) } else { Logger.log(message) }
    }

    private static func shutdown(_ client: (any AnalyticsInterface)?) {
        (client as? AnalyticsClient)?.shutdown()
    }

    public enum Analytics {
        @discardableResult
        public static func initialize(with options: InitOptions) -> AnalyticsInterface {
            MetaRouter.createAnalyticsClient(with: options)
        }

        @discardableResult
        public static func initializeAndWait(with options: InitOptions) async -> AnalyticsInterface {
            await MetaRouter.initializeAndWait(with: options)
        }


        /// Idiomatic singleton-style accessor matching Apple SDK conventions
        /// (`URLSession.shared`, `UserDefaults.standard`, `FileManager.default`).
        /// Returns the same buffered proxy `initialize(with:)` returns — calls
        /// made before `initialize` are queued and replayed on bind.
        public static var shared: AnalyticsInterface { proxy }

        @available(*, deprecated, renamed: "shared",
                   message: "Use MetaRouter.Analytics.shared. client() will be removed in v2.0.")
        public static func client() -> AnalyticsInterface { proxy }

        public static func reset() {
            // Detached here, not on the queue: a call on the next line must not reach
            // the client being discarded.
            proxy.detachCalls()
            proxy.lifecycle.enqueue { await discardClient() }
        }

        public static func resetAndWait() async {
            proxy.detachCalls()
            await proxy.lifecycle.run { await discardClient() }
        }

        public static func setDebugLogging(_ enabled: Bool) {
            Logger.setDebugLogging(enabled)
        }
    }
}
