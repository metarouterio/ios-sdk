import Foundation




public enum MetaRouter {
    private static let proxy = AnalyticsProxy()
    private static let store = RealClientStore()

    // Synchronous-binding initializer for deterministic testing/flows that require immediate binding
    public static func initializeAndWait(with options: InitOptions) async -> AnalyticsInterface {
        guard passesConfigGate(options) else {
            await disableSession()
            return proxy
        }
        await proxy._clearConfigDisabled()
        let real = AnalyticsClient.initialize(options: options.discardingConfigCallback())
        await store.set(real)
        await proxy._bindAndReplay(real)
        return proxy
    }

   @discardableResult
    public static func createAnalyticsClient(with options: InitOptions) -> AnalyticsInterface {
        // Return the proxy immediately; bind happens async (proxy queues pre-bind calls)
        guard passesConfigGate(options) else {
            Task { await disableSession() }
            return proxy
        }
        Task {
            await proxy._clearConfigDisabled()
            let real = AnalyticsClient.initialize(options: options.discardingConfigCallback())
            if await store.setIfNil(real) {
                proxy.bind(real)
            } else {
                Logger.warn("MetaRouter.Analytics.initialize() called more than once — subsequent calls are ignored. Use reset() first if you need to re-initialize.")
            }
        }
        return proxy
    }

    /// The release half of the invalid-config contract: construction recorded the
    /// verdict, this is where it takes effect. On invalid config no client is created —
    /// the proxy is still returned so call sites never see nil, and the SDK is inert
    /// for the session, mirroring the 401/403/404 graceful-disable for local config.
    /// Log and callback fire synchronously on the caller's thread.
    private static func passesConfigGate(_ options: InitOptions) -> Bool {
        proxy.setBootstrapDebugInfo(
            writeKey: options.writeKey,
            host: options.ingestionHost.absoluteString,
            configError: options.configError?.description
        )
        guard let error = options.configError else { return true }
        Logger.error("MetaRouter disabled for this session — \(error.description)")
        options.onConfigError?(error)
        return false
    }

    /// An initialize call with invalid config disables the whole session, even a
    /// re-initialize over a previously valid client: silently keeping the stale
    /// client running would mask the config error (a bound client also shadows the
    /// bootstrap debug info that reports it). Fail visible, not quiet. Marking the
    /// proxy disabled also resolves any suspended awaiters — no bind is coming.
    private static func disableSession() async {
        await proxy._unbindAndClear()
        await store.clear()
        await proxy._markConfigDisabled()
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
            Task {
                proxy.unbind()
                await store.clear()
            }
        }

        public static func resetAndWait() async {
            await proxy._unbindAndClear()
            await store.clear()
        }

        public static func setDebugLogging(_ enabled: Bool) {
            Logger.setDebugLogging(enabled)
        }
    }
}
