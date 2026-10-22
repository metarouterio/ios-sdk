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
    /// Call on `MetaRouter.Analytics.shared` BEFORE `initialize`. The registry is not
    /// persisted, and until it is registered the
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
    /// A `setConsent` that arrives first is stored as-is and completed on registration.
    func registerConsentCategories(_ categories: [ConsentCategory])

    /// Push the current consent state into the SDK.
    ///
    /// The host owns consent acquisition (CMP SDK callback, WebView cookie, …) — feed
    /// the raw payload through an adapter (e.g. `OneTrustAdapter.normalize`) and hand
    /// the canonical result here. The SDK reconciles it against the registered
    /// categories, persists it across launches, and stamps it on every subsequent
    /// outbound event as `context.consent`. Keys are matched case-insensitively and
    /// sent lowercase. Fully replaces prior state, with one exception: a snapshot
    /// whose `timestamp` is older than the newest host-supplied `timestamp` since the
    /// last `clearConsent` is ignored as a stale CMP replay. Untimestamped calls are
    /// never rejected and are not compared with any timestamp.
    ///
    /// Usable before `initialize` and immediately effective: an event tracked on the
    /// next line carries the new state. Consent never gates delivery — events always
    /// send, and the server gates per integration on the stamped block.
    ///
    /// - Returns: `false` when the snapshot was ignored as stale; the previous state
    ///   stands.
    @discardableResult
    func setConsent(_ consent: Consent) -> Bool

    /// The current reconciled consent state. Never nil: before the first `setConsent`
    /// (and after `clearConsent`) this is the implicit default — `explicit: false`
    /// with every registered category at its default posture.
    func getConsent() -> Consent

    /// Wipe the stored consent state, timestamp history included, and return to the
    /// implicit default. Any `setConsent` after it applies, so do not re-push a CMP
    /// snapshot from before the clear. Unlike `reset()`, which clears identity but
    /// leaves consent untouched.
    func clearConsent()

    /// Subscribe to consent changes. The handler is `@MainActor`: it runs on the main
    /// queue, once with the current value right after subscribing (asynchronously,
    /// never inline), then on every real change (value-identical `setConsent` calls
    /// do not fire).
    ///
    /// - Returns: the subscription. Keep it: delivery continues until `cancel()`,
    ///   even if the reference is dropped. After `cancel()` returns on the main
    ///   actor, the handler is not invoked again, even for a delivery already queued.
    func subscribeToConsent(_ handler: @escaping ConsentHandler) -> ConsentSubscription
}

// MARK: - Defaults for host conformers

/// Defaults for every requirement added after the protocol first shipped, so a host
/// type conforming to `AnalyticsInterface` (a test fake, a wrapper) keeps compiling
/// across a minor SDK upgrade. The SDK's own types implement all of these; the
/// defaults only ever run on a host conformer.
///
/// Each one warns and does nothing, rather than trapping: a wrapper that forgets to
/// forward a new call loses that call — visible in the log — instead of either
/// breaking the host's build or crashing in production. Any requirement added to
/// the protocol from here on gets a default in this extension for the same reason.
extension AnalyticsInterface {

    @MainActor
    public func attachWebView(_ webView: WKWebView, allowedOrigins: [String]) {
        Self.warnNotImplemented("attachWebView")
    }

    public func registerConsentCategories(_ categories: [ConsentCategory]) {
        Self.warnNotImplemented("registerConsentCategories")
    }

    /// `false`: nothing was applied.
    @discardableResult
    public func setConsent(_ consent: Consent) -> Bool {
        Self.warnNotImplemented("setConsent")
        return false
    }

    /// The implicit default with nothing registered — the same answer a fresh SDK
    /// gives before any category registration or `setConsent`.
    public func getConsent() -> Consent {
        Self.warnNotImplemented("getConsent")
        return Consent(explicit: false, optOut: [:])
    }

    public func clearConsent() {
        Self.warnNotImplemented("clearConsent")
    }

    public func subscribeToConsent(_ handler: @escaping ConsentHandler) -> ConsentSubscription {
        Self.warnNotImplemented("subscribeToConsent")
        return ConsentSubscription(onCancel: {})
    }

    /// Warns once per type and method: a wrapper that forwards `track` but not
    /// `getConsent` would otherwise log on every event.
    private static func warnNotImplemented(_ method: String) {
        guard ProtocolDefaultProbe.record("\(Self.self).\(method)") else { return }
        Logger.warn("\(method) is not implemented by \(Self.self) — the call was ignored. A type wrapping the SDK must forward it to MetaRouter.Analytics. Logged once.")
    }
}

/// Records which `Type.method` defaults above have run — a set, so it is bounded by
/// the number of conforming types and stays cheap in release, where it gates the
/// warning to once each. The defaults also removed the compiler's check that the
/// SDK's own types implement each requirement: a signature that drifts (a new
/// parameter, a changed isolation) silently stops being the witness, and the call
/// becomes a logged no-op. Tests drive every requirement through the protocol on
/// the SDK's types and assert this stays empty.
internal enum ProtocolDefaultProbe {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _hits: Set<String> = []

    /// `true` the first time `key` is recorded.
    static func record(_ key: String) -> Bool { lock.withLock { _hits.insert(key).inserted } }
    static var hits: Set<String> { lock.withLock { _hits } }
    static func reset() { lock.withLock { _hits.removeAll() } }
}
