import Foundation




public enum MetaRouter {
    private static let proxy = AnalyticsProxy()
    private static let store = RealClientStore()

    // Synchronous-binding initializer for deterministic testing/flows that require immediate binding
    public static func initializeAndWait(with options: InitOptions) async -> AnalyticsInterface {
        let real = AnalyticsClient.initialize(options: options)
        if await store.setIfNil(real) {
            await proxy._bindAndReplay(real)
        }
        return proxy
    }

   @discardableResult
    public static func createAnalyticsClient(with options: InitOptions) -> AnalyticsInterface {
        // Return the proxy immediately; bind happens async (proxy queues pre-bind calls)
        Task {
            let real = AnalyticsClient.initialize(options: options)
            if await store.setIfNil(real) {
                proxy.bind(real) 
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
