import Foundation

public enum MetaRouter {
    public enum Analytics {
        /// Initializes the SDK with the given configuration options.
        @discardableResult
        public static func initialize(with options: InitOptions) async throws -> AnalyticsInterface {
            let client = try AnalyticsClient.initialize(options: options)
            await AnalyticsClientStore.shared.set(client)
            return client
        }

        /// Returns the current analytics client.
        public static func client() async -> AnalyticsInterface {
            guard let client = await AnalyticsClientStore.shared.get() else {
                fatalError("❌ AnalyticsClient has not been initialized. Call MetaRouter.Analytics.initialize() first.")
            }
            return client
        }

        /// Resets the analytics client state.
        public static func reset() async {
            if let existing = await AnalyticsClientStore.shared.get() {
                await existing.cleanup()
            }
            await AnalyticsClientStore.shared.clear()
        }
    }
}
