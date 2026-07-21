import WebKit
import XCTest
@testable import MetaRouter

final class WebViewBridgeTests: XCTestCase {

    private final class RecordingSink: BridgeEventSink {
        var accept = true
        var enqueued: [BridgeEnvelope] = []

        func enqueue(_ envelope: BridgeEnvelope) -> Bool {
            if accept { enqueued.append(envelope) }
            return accept
        }
    }

    private let origins = ["https://www.metarouter.com"]

    private func makeProcessor() -> (RecordingSink, BridgeMessageProcessor) {
        let sink = RecordingSink()
        return (sink, BridgeMessageProcessor(sink: sink))
    }

    // MARK: - Attach

    @MainActor
    func testAttachRegistersHandlerAndWrapperScript() {
        let webView = WKWebView()
        let (_, processor) = makeProcessor()

        let attached = WebViewBridge.attach(webView, allowedOrigins: origins, processor: processor)

        XCTAssertTrue(attached)
        let scripts = webView.configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].source.contains("window.metarouterBridge"))
        XCTAssertEqual(scripts[0].injectionTime, .atDocumentStart)
        XCTAssertFalse(scripts[0].isForMainFrameOnly)
    }

    @MainActor
    func testAttachRejectsTheWildcardOrigin() {
        let webView = WKWebView()
        let (_, processor) = makeProcessor()

        let attached = WebViewBridge.attach(webView, allowedOrigins: ["*"], processor: processor)

        XCTAssertFalse(attached)
        XCTAssertTrue(webView.configuration.userContentController.userScripts.isEmpty)
    }

    @MainActor
    func testAttachRejectsAnEmptyOriginList() {
        let webView = WKWebView()
        let (_, processor) = makeProcessor()

        XCTAssertFalse(WebViewBridge.attach(webView, allowedOrigins: [], processor: processor))
    }

    @MainActor
    func testAttachRejectsMalformedOriginRulesInsteadOfFailingDownstream() {
        let webView = WKWebView()
        let (_, processor) = makeProcessor()

        // Each of these would silently never match the exact-origin checks.
        XCTAssertFalse(WebViewBridge.attach(webView, allowedOrigins: ["https://x.com/"], processor: processor))
        XCTAssertFalse(WebViewBridge.attach(webView, allowedOrigins: ["https://x.com/path"], processor: processor))
        XCTAssertFalse(WebViewBridge.attach(webView, allowedOrigins: ["x.com"], processor: processor))
        XCTAssertFalse(WebViewBridge.attach(webView, allowedOrigins: ["https://*.x.com"], processor: processor))
        XCTAssertTrue(webView.configuration.userContentController.userScripts.isEmpty)
    }

    @MainActor
    func testOriginRulesAreNormalizedSoCaseAndDefaultPortVariantsMatch() {
        // Scheme/host case and explicit default ports pass validation but would never
        // match the canonical origin the page reports — normalized at attach so the
        // allowlist entry a host plausibly writes actually works.
        XCTAssertEqual(
            WebViewBridge.normalizeOriginRules(["https://Shop.MetaRouter.com:443"]),
            ["https://shop.metarouter.com"]
        )
        XCTAssertEqual(
            WebViewBridge.normalizeOriginRules(["HTTP://Example.com:80"]),
            ["http://example.com"]
        )
        // Non-default ports are meaningful and preserved.
        XCTAssertEqual(
            WebViewBridge.normalizeOriginRules(["http://localhost:8080", "https://x.com:8443"]),
            ["http://localhost:8080", "https://x.com:8443"]
        )

        let webView = WKWebView()
        let (_, processor) = makeProcessor()
        XCTAssertTrue(WebViewBridge.attach(
            webView,
            allowedOrigins: ["https://Shop.MetaRouter.com:443"],
            processor: processor
        ))
        let script = webView.configuration.userContentController.userScripts[0].source
        XCTAssertTrue(script.contains(#"["https://shop.metarouter.com"]"#))
        XCTAssertFalse(script.contains("Shop.MetaRouter.com"))
    }

    @MainActor
    func testSecondAttachOnASharedConfigurationIsRefusedWithoutClobberingTheFirst() {
        let configuration = WKWebViewConfiguration()
        let webViewA = WKWebView(frame: .zero, configuration: configuration)
        let webViewB = WKWebView(frame: .zero, configuration: configuration)
        let (_, processor) = makeProcessor()

        XCTAssertTrue(WebViewBridge.attach(
            webViewA, allowedOrigins: ["https://a.metarouter.com"], processor: processor
        ))
        // Registration lives on the shared controller: re-registering for B would
        // silently replace A's handler and allowlist, dropping all of A's events.
        XCTAssertFalse(WebViewBridge.attach(
            webViewB, allowedOrigins: ["https://b.metarouter.com"], processor: processor
        ))

        let scripts = configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].source.contains("a.metarouter.com"))
        XCTAssertFalse(scripts[0].source.contains("b.metarouter.com"))
    }

    @MainActor
    func testSecondAttachOnTheSameWebViewIsRejected() {
        let webView = WKWebView()
        let (_, processor) = makeProcessor()

        XCTAssertTrue(WebViewBridge.attach(webView, allowedOrigins: origins, processor: processor))
        // Re-registering must be refused rather than re-adding the handler and script.
        XCTAssertFalse(WebViewBridge.attach(webView, allowedOrigins: origins, processor: processor))
        XCTAssertEqual(webView.configuration.userContentController.userScripts.count, 1)
    }

    // MARK: - Message flow (via the handler's testable seam; WKScriptMessage is not
    // constructible in tests, so the frame-origin string and body arrive as the
    // delegate method would pass them)

    func testReceivedMessageFlowsThroughTheProcessorAndAcks() {
        let (sink, processor) = makeProcessor()
        let handler = BridgeScriptMessageHandler(processor: processor, allowedOrigins: Set(origins))

        let reply = handler.processReceived(
            body: #"{"version":1,"messageId":"m-1","type":"page","name":"page_view","properties":{}}"#,
            originString: "https://www.metarouter.com"
        )

        XCTAssertEqual(sink.enqueued.count, 1)
        XCTAssertEqual(sink.enqueued[0].name, "page_view")
        XCTAssertEqual(reply?.toJson(), #"{"status":"ok","messageId":"m-1"}"#)
    }

    func testInvalidMessageIsRejectedWithAReplyAndNeverEnqueued() {
        let (sink, processor) = makeProcessor()
        let handler = BridgeScriptMessageHandler(processor: processor, allowedOrigins: Set(origins))

        let reply = handler.processReceived(
            body: "{not json",
            originString: "https://www.metarouter.com"
        )

        XCTAssertEqual(sink.enqueued.count, 0)
        XCTAssertEqual(reply?.code, "malformed_json")
    }

    func testNonStringMessageBodyIsIgnoredWithoutAReply() {
        let (sink, processor) = makeProcessor()
        let handler = BridgeScriptMessageHandler(processor: processor, allowedOrigins: Set(origins))

        XCTAssertNil(handler.processReceived(body: NSNull(), originString: "https://www.metarouter.com"))
        XCTAssertNil(handler.processReceived(body: 42, originString: "https://www.metarouter.com"))
        XCTAssertEqual(sink.enqueued.count, 0)
    }

    func testMessageFromNonAllowlistedFrameIsIgnoredWithoutAReply() {
        let (sink, processor) = makeProcessor()
        let handler = BridgeScriptMessageHandler(processor: processor, allowedOrigins: Set(origins))

        // A valid envelope from the wrong frame gets silence, not an oracle: no reply
        // reveals whether the allowlist check or the parser rejected it.
        let reply = handler.processReceived(
            body: #"{"version":1,"messageId":"m-1","type":"track","name":"x"}"#,
            originString: "https://evil.example"
        )

        XCTAssertNil(reply)
        XCTAssertEqual(sink.enqueued.count, 0)
    }

    // MARK: - Reply delivery

    func testReplyScriptInvokesOnmessageWithTheReplyAsAStringPayload() {
        let script = BridgeScriptMessageHandler.replyScript(for: .ok("m-1"))

        XCTAssertTrue(script.contains("window.__metaRouterNativeChannel.onmessage"))
        // The reply rides as a JS string literal (Android parity: onmessage data is a
        // string), so its quotes must arrive escaped.
        XCTAssertTrue(script.contains(#"{ data: "{\"status\":\"ok\",\"messageId\":\"m-1\"}" }"#))
    }

    func testOriginStringOmitsDefaultPortAndKeepsExplicitPort() {
        XCTAssertEqual(
            BridgeScriptMessageHandler.originString(scheme: "https", host: "www.metarouter.com", port: 0),
            "https://www.metarouter.com"
        )
        XCTAssertEqual(
            BridgeScriptMessageHandler.originString(scheme: "http", host: "localhost", port: 8080),
            "http://localhost:8080"
        )
    }
}
