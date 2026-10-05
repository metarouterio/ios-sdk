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

    /// The id of the current analytics session, or nil before the first event
    /// of the process has been enriched. Sessions are minted by events —
    /// reading the id is not activity and never extends or starts one, so a
    /// diagnostics poller cannot keep a session alive. The same value is
    /// stamped on every outbound event at `context.providers.metarouter.sessionID`.
    func getSessionId() async -> String?

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

    // MARK: - Consent

    /// Register the consent category set and each category's default posture.
    ///
    /// Call on `MetaRouter.Analytics.shared` BEFORE `initialize`, and before the first
    /// `setConsent`. The registry is not persisted, and until it is registered the
    /// implicit default is an empty `optOut` — which the server reads as nothing
    /// blocked. `initialize` can emit lifecycle events (`Application Opened`,
    /// `Session Started`) on its init task, so a registration that runs after it
    /// races those events on every launch without stored consent. Registration works
    /// before `initialize` because consent never waits for a client.
    ///
    /// A CMP payload is sparse, and the registry is what lets the SDK complete it into
    /// a full block (keep known keys, drop unknown ones, fill missing ones with the
    /// registered default). Default posture is opt-OUT. Re-registration replaces the
    /// set and recomputes the view of any stored consent against it; it does not merge.
    func registerConsentCategories(_ categories: [ConsentCategory])

    /// Push the current consent state into the SDK.
    ///
    /// The host owns consent acquisition (CMP SDK callback, WebView cookie, …) — feed
    /// the raw payload through an adapter (e.g. `OneTrustAdapter.normalize`) and hand
    /// the canonical result here. The SDK reconciles it against the registered
    /// categories, persists it across launches, and stamps it on every subsequent
    /// outbound event as `context.consent`. Fully replaces prior state; a snapshot
    /// with an older `timestamp` than the stored state is ignored.
    ///
    /// Usable before `initialize` and immediately effective: an event tracked on the
    /// next line carries the new state. Consent never gates delivery — events always
    /// send, and the server gates per integration on the stamped block.
    func setConsent(_ consent: Consent)

    /// The current reconciled consent state. Never nil: before the first `setConsent`
    /// (and after `clearConsent`) this is the implicit default — `explicit: false`
    /// with every registered category at its default posture.
    func getConsent() -> Consent

    /// Wipe the stored consent state and return to the implicit default. This is the
    /// consent-withdrawal path — unlike `reset()`, which clears identity but leaves
    /// consent untouched.
    func clearConsent()

    /// Subscribe to consent changes. The handler is `@MainActor`: it runs on the main
    /// queue, once with the current value right after subscribing (asynchronously,
    /// never inline), then on every real change (value-identical `setConsent` calls
    /// do not fire).
    ///
    /// - Returns: an unsubscribe closure; safe to call more than once. After it
    ///   returns, the handler is not invoked again, even for a delivery that was
    ///   already queued.
    @discardableResult
    func subscribeToConsent(_ handler: @escaping ConsentHandler) -> ConsentUnsubscribe
}
