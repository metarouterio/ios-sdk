import Foundation




public enum MetaRouter {
    private static let proxy = AnalyticsProxy()
    private static let store = RealClientStore()

    // Synchronous-binding initializer for deterministic testing/flows that require immediate binding
    public static func initializeAndWait(with options: InitOptions) async -> AnalyticsInterface {
        proxy.setBootstrapDebugInfo(writeKey: options.writeKey, host: options.ingestionHost.absoluteString)
        let real = AnalyticsClient.initialize(options: options)
        await store.set(real)
        await proxy._bindAndReplay(real)
        return proxy
    }

   @discardableResult
    public static func createAnalyticsClient(with options: InitOptions) -> AnalyticsInterface {
        // Return the proxy immediately; bind happens async (proxy queues pre-bind calls)
        proxy.setBootstrapDebugInfo(writeKey: options.writeKey, host: options.ingestionHost.absoluteString)
        Task {
            let real = AnalyticsClient.initialize(options: options)
            if await store.setIfNil(real) {
                proxy.bind(real)
            } else {
                Logger.warn("MetaRouter.Analytics.initialize() called more than once — subsequent calls are ignored. Use reset() first if you need to re-initialize.")
            }
        }
        return proxy
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
