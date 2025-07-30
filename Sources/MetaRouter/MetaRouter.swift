import Foundation

public enum MetaRouter {
    public struct Analytics {
        /// Initializes the SDK with the given configuration options.
        @MainActor public static func initialize(with options: InitOptions) {
            AnalyticsClient.shared.initialize(with: options)
        }

        /// Returns the shared analytics client
        
        @MainActor public static var client: AnalyticsInterface {
            return AnalyticsClient.shared
        }

        /// Resets the analytics state (e.g., clears user identifiers and queue)
        @MainActor public static func reset() {
            AnalyticsClient.shared.reset()
        }
    }
}
