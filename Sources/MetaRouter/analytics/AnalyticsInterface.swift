import Foundation

public protocol AnalyticsInterface: AnyObject, Sendable {
    func track(_ event: String, properties: [String: Any]?)
    func track(_ event: String)

    func identify(_ userId: String, traits: [String: Any]?)
    func identify(_ userId: String)

    func group(_ groupId: String, traits: [String: Any]?)
    func group(_ groupId: String)

    func screen(_ name: String, properties: [String: Any]?)
    func screen(_ name: String)

    func page(_ name: String, properties: [String: Any]?)
    func page(_ name: String)

    func alias(_ newUserId: String)
    func enableDebugLogging()
    func getAnonymousId() async -> String
    func getDebugInfo() async -> [String: CodableValue]
    func flush()
    func reset()
    func setAdvertisingId(_ advertisingId: String?)
    func clearAdvertisingId()
    func setTracing(_ enabled: Bool)

    /// Buffers a deep-link URL to be attached to the next `Application Opened`
    /// event as the `url` (and optionally `referring_application`) property.
    /// Call from `application(_:open:options:)` or `scene(_:openURLContexts:)`,
    /// and from `application(_:didFinishLaunchingWithOptions:)` for cold-launch
    /// deep-link capture using `launchOptions[.url]` / `[.sourceApplication]`.
    /// Buffered values are one-shot — cleared after the next emit.
    func handleDeepLink(url: URL, sourceApplication: String?)
}
