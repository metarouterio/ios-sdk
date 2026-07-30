import Foundation
import WebKit

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

    /// Tells the SDK the app is opening with this URL. Buffers the URL to be
    /// attached to the next `Application Opened` event as the `url` (and
    /// optionally `referring_application`) property. Call from
    /// `application(_:open:options:)` or `scene(_:openURLContexts:)`, and from
    /// `application(_:didFinishLaunchingWithOptions:)` for cold-launch capture
    /// using `launchOptions[.url]` / `[.sourceApplication]`. One-shot — cleared
    /// after the next emit.
    func recordOpenedURL(_ url: URL, sourceApplication: String?)

    /// Attach the webview event bridge to a host-owned WebView.
    ///
    /// Pages loaded from `allowedOrigins` get a `window.metarouterBridge` object with
    /// `track(name, properties)` and `page(name, properties)` methods. Calls are
    /// enveloped in the page, validated and deduplicated natively, enriched with the
    /// device's identity and context, and delivered through the normal event queue —
    /// webview activity and native activity arrive as one user.
    ///
    /// Call this when the WebView is created, **before** `load(_:)` — the
    /// registrations only apply to page loads that start afterwards. The SDK never
    /// discovers webviews on its own: the host owns the WebView, this call is the
    /// explicit hand-off. Main-actor-isolated because WebView configuration is
    /// main-thread work; create the WebView and attach in the same place.
    ///
    /// Origins must be explicit (`https://host[:port]`); the wildcard `"*"` is
    /// rejected, since origin scoping is what keeps arbitrary pages from injecting
    /// events into the native queue.
    ///
    /// - Parameters:
    ///   - webView: The host-owned WebView to bridge
    ///   - allowedOrigins: Explicit page origins allowed to produce events
    @MainActor
    func attachWebView(_ webView: WKWebView, allowedOrigins: [String])
}
