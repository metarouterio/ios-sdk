import XCTest
@testable import MetaRouter

final class BridgeEnvelopeParserTests: XCTestCase {

    // Full envelopes exactly as the injected wrapper produces them, every field populated.
    private let validTrack = #"{"version":1,"messageId":"9b2f2c4e-8b1a-4d7e-9c3f-2e6a1d5b8f01","type":"track","name":"product_viewed","properties":{"sku":"SKU-123","qty":2,"price":19.99,"flag":true},"sentAt":"2026-07-09T14:03:22.114Z","page":{"url":"https://www.metarouter.com/products","title":"Products","referrer":"https://www.metarouter.com/"},"source":{"producer":"wrapper","wrapperVersion":"1.0.0"}}"#

    private let validPage = #"{"version":1,"messageId":"c41d09aa-3e02-4f4b-b0d7-77f21c9d54c2","type":"page","name":"page_view","properties":{"language":"en"},"sentAt":"2026-07-09T14:02:59.801Z","page":{"url":"https://www.metarouter.com/detail","title":"Product details","referrer":"https://www.metarouter.com/products"},"source":{"producer":"wrapper","wrapperVersion":"1.0.0"}}"#

    private func valid(_ result: BridgeParseResult) -> BridgeEnvelope? {
        guard case .valid(let envelope) = result else { return nil }
        return envelope
    }

    private func invalid(_ result: BridgeParseResult) -> BridgeParseResult.Invalid? {
        guard case .invalid(let invalid) = result else { return nil }
        return invalid
    }

    // MARK: - Valid envelopes

    func testValidTrackEnvelopeParsesWithAllFields() throws {
        let envelope = try XCTUnwrap(valid(BridgeEnvelopeParser.parse(validTrack)), "expected Valid")

        XCTAssertEqual(envelope.version, 1)
        XCTAssertEqual(envelope.messageId, "9b2f2c4e-8b1a-4d7e-9c3f-2e6a1d5b8f01")
        XCTAssertEqual(envelope.type, .track)
        XCTAssertEqual(envelope.name, "product_viewed")
        XCTAssertEqual(envelope.properties["sku"]?.stringValue, "SKU-123")
        // Bools stay bools — the JSONDecoder-over-JSONSerialization choice exists for
        // this line (NSNumber bridging would silently turn true into 1).
        XCTAssertEqual(envelope.properties["flag"]?.boolValue, true)
        XCTAssertEqual(envelope.sentAt, "2026-07-09T14:03:22.114Z")
        XCTAssertEqual(envelope.page?.url, "https://www.metarouter.com/products")
        XCTAssertEqual(envelope.page?.title, "Products")
        XCTAssertEqual(envelope.page?.referrer, "https://www.metarouter.com/")
        XCTAssertEqual(envelope.source?.producer, "wrapper")
        XCTAssertEqual(envelope.source?.wrapperVersion, "1.0.0")
    }

    func testValidPageEnvelopeParsesWithPageType() throws {
        let envelope = try XCTUnwrap(valid(BridgeEnvelopeParser.parse(validPage)), "expected Valid")

        XCTAssertEqual(envelope.type, .page)
        XCTAssertEqual(envelope.name, "page_view")
    }

    func testMinimalEnvelopeWithOnlyRequiredFieldsParses() throws {
        let envelope = try XCTUnwrap(
            valid(BridgeEnvelopeParser.parse(#"{"version":1,"messageId":"m-1","type":"track","name":"x"}"#)),
            "expected Valid"
        )

        XCTAssertTrue(envelope.properties.isEmpty)
        XCTAssertNil(envelope.sentAt)
        XCTAssertNil(envelope.page)
        XCTAssertNil(envelope.source)
    }

    func testUnknownFieldsAreIgnoredForwardCompatibility() throws {
        let envelope = try XCTUnwrap(
            valid(BridgeEnvelopeParser.parse(
                #"{"version":1,"messageId":"m-1","type":"track","name":"x","futureField":{"a":1},"another":true}"#
            )),
            "expected Valid"
        )

        XCTAssertEqual(envelope.name, "x")
    }

    func testOptionalFieldsWithWrongJSONTypeAreTreatedAsAbsent() throws {
        let envelope = try XCTUnwrap(
            valid(BridgeEnvelopeParser.parse(
                #"{"version":1,"messageId":"m-1","type":"track","name":"x","page":"not-an-object","source":42,"sentAt":123}"#
            )),
            "expected Valid"
        )

        XCTAssertNil(envelope.page)
        XCTAssertNil(envelope.source)
        XCTAssertNil(envelope.sentAt)
    }

    // MARK: - Malformed input

    func testInvalidJSONIsRejectedWithMalformedJsonAndNoMessageId() throws {
        let error = try XCTUnwrap(invalid(BridgeEnvelopeParser.parse("{not json")), "expected Invalid")

        XCTAssertEqual(error.code, .malformedJson)
        XCTAssertNil(error.messageId)
    }

    func testNonObjectJSONIsRejectedWithMalformedPayload() throws {
        let error = try XCTUnwrap(invalid(BridgeEnvelopeParser.parse(#"["an","array"]"#)), "expected Invalid")

        XCTAssertEqual(error.code, .malformedPayload)
    }

    func testNonObjectPropertiesIsRejectedWithMalformedPayloadAndEchoesMessageId() throws {
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(
                #"{"version":1,"messageId":"m-1","type":"track","name":"x","properties":"oops"}"#
            )),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .malformedPayload)
        XCTAssertEqual(error.messageId, "m-1")
    }

    func testNonIntegerVersionIsRejectedWithMalformedPayload() throws {
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(
                #"{"version":"one","messageId":"m-1","type":"track","name":"x"}"#
            )),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .malformedPayload)
    }

    func testVersionBelowOneIsRejectedWithMalformedPayload() throws {
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(
                #"{"version":0,"messageId":"m-1","type":"track","name":"x"}"#
            )),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .malformedPayload)
    }

    // MARK: - Partial input (missing required fields)

    func testMissingMessageIdIsRejectedWithMissingField() throws {
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(#"{"version":1,"type":"track","name":"x"}"#)),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .missingField)
    }

    func testOversizedMessageIdIsRejectedWithoutEchoingItBack() throws {
        let hugeId = String(repeating: "x", count: BridgeEnvelopeParser.maxMessageIdBytes + 1)
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(
                #"{"version":1,"messageId":"\#(hugeId)","type":"track","name":"x"}"#
            )),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .malformedPayload)
        // The reply must not amplify the oversized bytes back to the page.
        XCTAssertNil(error.messageId)
        XCTAssertFalse(error.message.contains(hugeId))
    }

    func testMessageIdAtExactlyTheCapIsAccepted() throws {
        let maxId = String(repeating: "x", count: BridgeEnvelopeParser.maxMessageIdBytes)
        let envelope = try XCTUnwrap(
            valid(BridgeEnvelopeParser.parse(
                #"{"version":1,"messageId":"\#(maxId)","type":"track","name":"x"}"#
            )),
            "expected Valid"
        )

        XCTAssertEqual(envelope.messageId, maxId)
    }

    func testMessageIdCapIsMeasuredInBytesNotCharacters() throws {
        // 100 characters of 3-byte "€" = 300 UTF-8 bytes: under the cap by character
        // count, over it by bytes. A character count bounds nothing — one grapheme
        // cluster can carry hundreds of combining marks — and the dedup store's memory
        // ceiling depends on the byte bound being real.
        let id = String(repeating: "€", count: 100)
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(
                #"{"version":1,"messageId":"\#(id)","type":"track","name":"x"}"#
            )),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .malformedPayload)
        XCTAssertNil(error.messageId)
        XCTAssertFalse(error.message.contains(id))
    }

    func testPagePathAndSearchAreParsed() throws {
        let envelope = try XCTUnwrap(
            valid(BridgeEnvelopeParser.parse(
                #"{"version":1,"messageId":"m-1","type":"page","name":"page_view","page":{"url":"https://www.metarouter.com/products?q=fern","path":"/products","search":"?q=fern"}}"#
            )),
            "expected Valid"
        )

        XCTAssertEqual(envelope.page?.path, "/products")
        XCTAssertEqual(envelope.page?.search, "?q=fern")
    }

    func testBlankMessageIdIsRejectedWithMissingField() throws {
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(
                #"{"version":1,"messageId":"  ","type":"track","name":"x"}"#
            )),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .missingField)
    }

    func testMissingVersionIsRejectedWithMissingFieldAndEchoesMessageId() throws {
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(#"{"messageId":"m-1","type":"track","name":"x"}"#)),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .missingField)
        XCTAssertEqual(error.messageId, "m-1")
    }

    func testMissingTypeIsRejectedWithMissingField() throws {
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(#"{"version":1,"messageId":"m-1","name":"x"}"#)),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .missingField)
    }

    func testMissingNameIsRejectedWithMissingField() throws {
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(#"{"version":1,"messageId":"m-1","type":"track"}"#)),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .missingField)
    }

    func testEmptyNameIsRejectedWithMissingField() throws {
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(
                #"{"version":1,"messageId":"m-1","type":"track","name":""}"#
            )),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .missingField)
    }

    // MARK: - Type rule

    func testUnknownTypeIsRejectedWithUnknownType() throws {
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(
                #"{"version":1,"messageId":"m-1","type":"identify","name":"x"}"#
            )),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .unknownType)
        XCTAssertEqual(error.messageId, "m-1")
    }

    func testScreenTypeIsRejectedInContractV1() throws {
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(
                #"{"version":1,"messageId":"m-1","type":"screen","name":"x"}"#
            )),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .unknownType)
    }

    // MARK: - Version rule

    func testNewerVersionIsRejectedWithUnsupportedVersionAndSupportedVersion() throws {
        let error = try XCTUnwrap(
            invalid(BridgeEnvelopeParser.parse(
                #"{"version":2,"messageId":"m-1","type":"track","name":"x"}"#
            )),
            "expected Invalid"
        )

        XCTAssertEqual(error.code, .unsupportedVersion)
        XCTAssertEqual(error.messageId, "m-1")
        XCTAssertEqual(error.supportedVersion, BridgeEnvelopeParser.supportedVersion)
    }

    // MARK: - Oversized input

    func testEnvelopeOver64KBIsRejectedWithPayloadTooLarge() throws {
        let padding = String(repeating: "a", count: BridgeEnvelopeParser.maxEnvelopeBytes)
        let oversized = #"{"version":1,"messageId":"m-1","type":"track","name":"x","properties":{"p":"\#(padding)"}}"#

        let error = try XCTUnwrap(invalid(BridgeEnvelopeParser.parse(oversized)), "expected Invalid")

        XCTAssertEqual(error.code, .payloadTooLarge)
    }

    func testSizeLimitIsMeasuredInUTF8BytesNotChars() throws {
        // Multi-byte characters: 22000 × 3-byte chars ≈ 66KB > 64KB limit, but only 22k chars.
        let padding = String(repeating: "€", count: 22_000)
        let oversized = #"{"version":1,"messageId":"m-1","type":"track","name":"x","properties":{"p":"\#(padding)"}}"#

        let error = try XCTUnwrap(invalid(BridgeEnvelopeParser.parse(oversized)), "expected Invalid")

        XCTAssertEqual(error.code, .payloadTooLarge)
    }
}
