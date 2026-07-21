import XCTest
@testable import MetaRouter

final class BridgeWrapperScriptTests: XCTestCase {

    private let origins = ["https://www.metarouter.com"]

    func testScriptDefinesTheDefaultBridgeObjectWithTrackAndPage() throws {
        let script = try BridgeWrapperScript.build(allowedOrigins: origins)

        XCTAssertTrue(script.contains("window.metarouterBridge = {"))
        XCTAssertTrue(script.contains("track: function(name, properties)"))
        XCTAssertTrue(script.contains("page: function(name, properties)"))
    }

    func testScriptEmbedsTheOriginAllowlistAsAJSONArray() throws {
        let script = try BridgeWrapperScript.build(
            allowedOrigins: ["https://www.metarouter.com", "https://booking.metarouter.com"]
        )

        XCTAssertTrue(
            script.contains(#"var ALLOWED_ORIGINS = ["https://www.metarouter.com","https://booking.metarouter.com"];"#)
        )
        XCTAssertTrue(script.contains("ALLOWED_ORIGINS.indexOf(location.origin) === -1"))
    }

    func testScriptPostsThroughTheNativeChannelObject() throws {
        let script = try BridgeWrapperScript.build(allowedOrigins: origins)

        XCTAssertTrue(script.contains("window.\(BridgeWrapperScript.nativeChannelName)"))
        XCTAssertTrue(script.contains("channel.postMessage(payload)"))
    }

    func testStringifyIsGuardedAndCoercesUnserializableProperties() throws {
        let script = try BridgeWrapperScript.build(allowedOrigins: origins)

        // A circular reference or BigInt in object properties would otherwise throw a
        // TypeError out of track()/page() into the page's own calling code.
        XCTAssertTrue(script.contains("payload = JSON.stringify(envelope);"))
        XCTAssertTrue(script.contains("envelope.properties = String(props);"))
        XCTAssertFalse(script.contains("channel.postMessage(JSON.stringify(envelope))"))
    }

    func testCoercedStringPropertiesAreRejectedByTheParserAsMalformedPayload() throws {
        // The wrapper's stringify fallback sends properties as a coerced string; this
        // pins the native half of that contract — a coded error reply, id echoed.
        let result = BridgeEnvelopeParser.parse(
            #"{"version":1,"messageId":"m-1","type":"track","name":"x","properties":"[object Object]"}"#
        )

        guard case .invalid(let invalid) = result else {
            XCTFail("expected Invalid, got \(result)")
            return
        }
        XCTAssertEqual(invalid.code, .malformedPayload)
        XCTAssertEqual(invalid.messageId, "m-1")
    }

    /// The one transport line that differs from Android: the shim posts through
    /// `webkit.messageHandlers` instead of a platform-injected channel object.
    func testScriptShimPostsThroughWebkitMessageHandlers() throws {
        let script = try BridgeWrapperScript.build(allowedOrigins: origins)

        XCTAssertTrue(
            script.contains("window.webkit.messageHandlers.\(BridgeWrapperScript.nativeChannelName).postMessage(data)")
        )
        XCTAssertTrue(script.contains("onmessage: null"))
    }

    func testScriptStampsTheFullPageBlockIncludingPathAndSearch() throws {
        let script = try BridgeWrapperScript.build(allowedOrigins: origins)

        XCTAssertTrue(script.contains("url: location.href"))
        XCTAssertTrue(script.contains("path: location.pathname"))
        XCTAssertTrue(script.contains("search: location.search"))
        XCTAssertTrue(script.contains("title: document.title"))
        XCTAssertTrue(script.contains("referrer: document.referrer"))
    }

    func testScriptStampsEnvelopeVersionAndWrapperVersion() throws {
        let script = try BridgeWrapperScript.build(allowedOrigins: origins)

        XCTAssertTrue(script.contains("version: 1,"))
        XCTAssertTrue(script.contains("wrapperVersion: '\(BridgeWrapperScript.wrapperVersion)'"))
    }

    func testScriptGuardsAgainstDoubleDefinition() throws {
        let script = try BridgeWrapperScript.build(allowedOrigins: origins)

        XCTAssertTrue(script.contains("if (window.metarouterBridge) { return; }"))
    }

    func testCustomBridgeObjectNameIsHonoredEverywhere() throws {
        let script = try BridgeWrapperScript.build(allowedOrigins: origins, bridgeObjectName: "customBridge")

        XCTAssertTrue(script.contains("window.customBridge = {"))
        XCTAssertTrue(script.contains("if (window.customBridge) { return; }"))
        XCTAssertFalse(script.contains("metarouterBridge"))
    }

    func testOriginsContainingQuotesAreEscapedSafely() throws {
        // A hostile origin string must not be able to break out of the JS string literal:
        // the embedded quote must appear escaped (\"), never as a bare closing quote.
        let script = try BridgeWrapperScript.build(allowedOrigins: [#"https://x.com/"};alert(1);//"#])

        XCTAssertTrue(script.contains(#"/\"};alert(1);//"#), "quote must be escaped")
        XCTAssertFalse(script.contains(#"/"};alert(1);//"#), "bare quote would terminate the JS string")
    }

    func testEmptyOriginListIsRejected() {
        XCTAssertThrowsError(try BridgeWrapperScript.build(allowedOrigins: [])) { error in
            XCTAssertEqual(error as? BridgeWrapperScript.BuildError, .emptyAllowedOrigins)
        }
    }

    func testInvalidJSIdentifierForBridgeObjectNameIsRejected() {
        XCTAssertThrowsError(
            try BridgeWrapperScript.build(allowedOrigins: origins, bridgeObjectName: "bad-name;alert(1)")
        ) { error in
            XCTAssertEqual(error as? BridgeWrapperScript.BuildError, .invalidBridgeObjectName)
        }
    }

    func testWrapperEnvelopeRoundTripsThroughTheNativeParser() throws {
        // Build the envelope shape the wrapper's post() constructs and confirm the
        // native parser accepts it — keeps script and parser from drifting apart.
        let envelope = #"""
        {"version":1,"messageId":"11111111-2222-4333-8444-555555555555","type":"track",
         "name":"product_viewed","properties":{"sku":"SKU-1"},
         "sentAt":"2026-07-09T14:03:22.114Z",
         "page":{"url":"https://www.metarouter.com/products","title":"Search","referrer":""},
         "source":{"producer":"wrapper","wrapperVersion":"\#(BridgeWrapperScript.wrapperVersion)"}}
        """#

        let result = BridgeEnvelopeParser.parse(envelope)

        guard case .valid(let parsed) = result else {
            XCTFail("wrapper-shaped envelope must parse, got \(result)")
            return
        }
        XCTAssertEqual(parsed.source?.wrapperVersion, BridgeWrapperScript.wrapperVersion)
    }
}
