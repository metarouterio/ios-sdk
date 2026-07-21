import XCTest
@testable import MetaRouter

final class BridgeReplyTests: XCTestCase {

    func testOkReplySerializesToContractShape() {
        let json = BridgeReply.ok("m-1").toJson()

        XCTAssertEqual(json, #"{"status":"ok","messageId":"m-1"}"#)
    }

    func testErrorReplyFromInvalidCarriesCodeMessageAndSupportedVersion() {
        let invalid = BridgeParseResult.Invalid(
            code: .unsupportedVersion,
            message: "envelope version 2 > supported 1",
            messageId: "m-1",
            supportedVersion: 1
        )

        let json = BridgeReply.error(invalid).toJson()

        XCTAssertEqual(
            json,
            #"{"status":"error","messageId":"m-1","code":"unsupported_version","message":"envelope version 2 > supported 1","supportedVersion":1}"#
        )
    }

    func testErrorReplyOmitsNullFields() {
        let invalid = BridgeParseResult.Invalid(
            code: .malformedJson,
            message: "envelope is not valid JSON"
        )

        let json = BridgeReply.error(invalid).toJson()

        XCTAssertFalse(json.contains("messageId"), "messageId should be omitted")
        XCTAssertFalse(json.contains("supportedVersion"), "supportedVersion should be omitted")
        XCTAssertTrue(json.contains(#""code":"malformed_json""#))
    }

    func testStandaloneErrorFactoryUsesWireCodeStrings() {
        let json = BridgeReply.error(code: .notReady, message: "SDK not initialized").toJson()

        XCTAssertTrue(json.contains(#""code":"not_ready""#))
        XCTAssertTrue(json.contains(#"status":"error"#))
    }

    func testEveryErrorCodeHasAStableWireString() {
        let expected: [BridgeErrorCode: String] = [
            .malformedJson: "malformed_json",
            .malformedPayload: "malformed_payload",
            .missingField: "missing_field",
            .unknownType: "unknown_type",
            .unsupportedVersion: "unsupported_version",
            .payloadTooLarge: "payload_too_large",
            .notReady: "not_ready",
        ]

        XCTAssertEqual(expected.count, BridgeErrorCode.allCases.count)
        for (code, wire) in expected {
            XCTAssertEqual(code.rawValue, wire)
        }
    }
}
