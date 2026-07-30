import Foundation
import WebKit

/// Registers the bridge on a host-owned WebView: the script message handler (receive
/// side) and the document-start wrapper script (producer side).
///
/// Unlike Android's `addWebMessageListener`, WebKit does not scope a message channel to
/// origins — any page in the WebView can post to a registered handler. Origin scoping
/// is therefore enforced in two cooperating places: the wrapper script defines nothing
/// on non-allowlisted pages, and the handler checks each message's frame origin before
/// processing (neither alone survives a hostile page). Both registrations only affect
/// page loads that start after attach, which is why hosts must attach before `load`.
///
/// `@MainActor` rather than a runtime main-thread hop: WebKit's registration APIs are
/// main-actor-isolated, so the requirement is enforced at compile time and the attach
/// bookkeeping needs no locking.
@MainActor
internal enum WebViewBridge {

    // Origin rules must be scheme://host[:port] — anything else (paths, trailing
    // slashes, wildcards) silently never matches the exact-origin checks.
    private static let originRule = "^https?://[A-Za-z0-9.-]+(:\\d+)?$"

    // WebKit retains the registered handler for the userContentController's lifetime;
    // tracking attached WebViews weakly means a destroyed WebView is never pinned by
    // this bookkeeping, and a duplicate attach warns instead of re-registering.
    private static let attached = NSHashTable<WKWebView>.weakObjects()

    // Registration actually lives on the WKUserContentController, which WebViews can
    // share through a common WKWebViewConfiguration. Tracked separately so a second
    // attach on a shared configuration is refused instead of silently replacing the
    // first attach's handler and allowlist.
    private static let attachedControllers = NSHashTable<WKUserContentController>.weakObjects()

    /// - Returns: true if the attach was accepted and registration ran.
    @discardableResult
    static func attach(
        _ webView: WKWebView,
        allowedOrigins: [String],
        processor: BridgeMessageProcessor
    ) -> Bool {
        if allowedOrigins.isEmpty {
            Logger.warn("attachWebView called with no allowed origins — ignoring.")
            return false
        }
        // Normalize BEFORE validating: the pattern is case-sensitive, so a
        // case-variant scheme would otherwise be rejected as a format problem the
        // host doesn't have — and everything downstream reasons about one list.
        let origins = normalizeOriginRules(allowedOrigins)
        let invalid = origins.filter {
            $0.range(of: originRule, options: .regularExpression) == nil
        }
        if !invalid.isEmpty {
            // Origin scoping is the bridge's security boundary; a wildcard would let
            // any page loaded in this WebView (ads, redirects, hijacked navigation)
            // inject events into the native queue.
            Logger.warn(
                "attachWebView rejects invalid origin rules \(invalid) — "
                    + "use explicit scheme://host[:port] origins."
            )
            return false
        }
        let insecure = origins.filter {
            $0.hasPrefix("http://") && $0 != "http://localhost" && !$0.hasPrefix("http://localhost:")
                && $0 != "http://127.0.0.1" && !$0.hasPrefix("http://127.0.0.1:")
        }
        if !insecure.isEmpty {
            // A cleartext origin is spoofable in transit, and the frame-origin check
            // then trusts an attacker-influenceable value. Fine for local development;
            // warn (not reject) so a misconfigured production allowlist is visible.
            Logger.warn(
                "attachWebView: cleartext origin rules \(insecure) — use https origins "
                    + "outside local development."
            )
        }
        if attached.contains(webView) {
            Logger.warn("attachWebView ignored: this WebView is already attached.")
            return false
        }
        let controller = webView.configuration.userContentController
        if attachedControllers.contains(controller) {
            // A shared WKWebViewConfiguration is already bridged: its handler and
            // document-start script live on the controller and cover this WebView
            // too, under the FIRST attach's allowlist. Re-registering would silently
            // replace that allowlist for every sharing WebView — refuse instead.
            Logger.warn(
                "attachWebView ignored: this WebView shares a WKWebViewConfiguration "
                    + "whose bridge is already registered — the existing origin allowlist "
                    + "applies. Give each WebView its own configuration to attach with "
                    + "different origins."
            )
            return false
        }
        attached.add(webView)

        do {
            try register(webView, allowedOrigins: origins, processor: processor)
            attachedControllers.add(controller)
            Logger.log("WebView bridge attached (origins=\(origins))")
        } catch {
            // A registration failure must not crash the host app — the failure mode is
            // no webview capture, logged. Un-track so a retry works.
            attached.remove(webView)
            Logger.error("WebView bridge attach failed: \(error)")
            return false
        }
        return true
    }

    /// Scheme and host are case-insensitive and default ports are implied, but both
    /// origin checks (wrapper `location.origin`, native frame origin) compare exact
    /// canonical strings — an entry like "https://Shop.Example.com:443" would pass
    /// validation yet never match anything, leaving the bridge silently inert.
    static func normalizeOriginRules(_ rules: [String]) -> [String] {
        return rules.map { rule in
            var origin = rule.lowercased()
            if origin.hasPrefix("https://"), origin.hasSuffix(":443") {
                origin = String(origin.dropLast(4))
            } else if origin.hasPrefix("http://"), origin.hasSuffix(":80") {
                origin = String(origin.dropLast(3))
            }
            return origin
        }
    }

    private static func register(
        _ webView: WKWebView,
        allowedOrigins: [String],
        processor: BridgeMessageProcessor
    ) throws {
        let controller = webView.configuration.userContentController
        let handler = BridgeScriptMessageHandler(
            processor: processor,
            allowedOrigins: Set(allowedOrigins)
        )

        // Build the script FIRST: it is the only step here that can throw, and the
        // un-track-on-failure retry promise in attach() holds only if a failed
        // registration leaves the controller untouched.
        let script = try BridgeWrapperScript.build(allowedOrigins: allowedOrigins)

        // Remove-then-add: registering a duplicate handler name raises an uncatchable
        // NSException inside WebKit, and two WebViews sharing one WKWebViewConfiguration
        // would hit it even though each WebView is only attached once. Removal is the
        // API Android lacks (there the duplicate-name throw is caught instead). The
        // channel name is SDK-reserved: a host handler registered under it would be
        // silently replaced here.
        controller.removeScriptMessageHandler(forName: BridgeWrapperScript.nativeChannelName)
        controller.add(handler, name: BridgeWrapperScript.nativeChannelName)

        // forMainFrameOnly false: allowlisted iframes may produce events, matching
        // Android's behavior; the handler checks every message's frame origin, so a
        // non-allowlisted iframe gets neither the wrapper nor a listening ear.
        controller.addUserScript(WKUserScript(
            source: script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
    }
}

/// The receive side of one attach. WebKit retains registered handlers strongly for the
/// userContentController's lifetime, so this class must never strongly reference the
/// WebView or a client — either would be pinned forever (the classic WKScriptMessageHandler
/// retain cycle). It holds only the processor and resolves the WebView per message from
/// `WKScriptMessage`, which references it weakly.
internal final class BridgeScriptMessageHandler: NSObject, WKScriptMessageHandler {

    private let processor: BridgeMessageProcessor
    private let allowedOrigins: Set<String>

    init(processor: BridgeMessageProcessor, allowedOrigins: Set<String>) {
        self.processor = processor
        self.allowedOrigins = allowedOrigins
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WebKit delivers on the main thread — which is what satisfies process()'s
        // single-confined-thread rule; assumeIsolated makes that contract visible to
        // the compiler and traps loudly if it is ever broken.
        MainActor.assumeIsolated {
            let securityOrigin = message.frameInfo.securityOrigin
            let origin = Self.originString(
                scheme: securityOrigin.protocol,
                host: securityOrigin.host,
                port: Int(securityOrigin.port)
            )
            guard let reply = processReceived(body: message.body, originString: origin) else {
                return
            }
            // No JavaScriptReplyProxy equivalent on WebKit: acks are delivered by
            // invoking the wrapper-defined channel's onmessage, in the frame (and
            // content world) the message came from.
            message.webView?.evaluateJavaScript(
                Self.replyScript(for: reply),
                in: message.frameInfo,
                in: .page
            ) { result in
                if case .failure(let error) = result {
                    // Debug-level: a page that navigated away mid-ack fails here
                    // routinely and is not actionable.
                    Logger.log("WebView bridge reply delivery failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The testable core of the receive side: frame-origin gate → processor.
    /// Returns nil when no reply should be sent (non-allowlisted frame, non-string
    /// body) — a hostile frame gets silence, not an oracle.
    func processReceived(body: Any, originString: String) -> BridgeReply? {
        guard allowedOrigins.contains(originString) else {
            // The native half of the security model (the wrapper's location.origin
            // self-check is the page half). Debug-level: a hostile page could spam
            // this, so it must not flood production logs.
            Logger.log("WebView bridge dropped message from non-allowlisted origin \(originString)")
            return nil
        }
        guard let raw = body as? String else { return nil }
        return processor.process(raw)
    }

    /// Ack delivery script. The reply JSON rides as a JS string literal (JSON string
    /// escaping is valid JS escaping), so the page-visible shape matches Android:
    /// `onmessage` receives an event-like object whose `data` is the reply string.
    static func replyScript(for reply: BridgeReply) -> String {
        let channel = "window.\(BridgeWrapperScript.nativeChannelName)"
        let payload = BridgeReply.jsonString(reply.toJson())
        return "\(channel) && typeof \(channel).onmessage === 'function' && \(channel).onmessage({ data: \(payload) });"
    }

    /// `WKSecurityOrigin` reports 0 for a scheme's default port; the wrapper's
    /// `location.origin` omits default ports the same way, so allowlist entries
    /// written without default ports match both checks consistently.
    static func originString(scheme: String, host: String, port: Int) -> String {
        port == 0 ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }
}
