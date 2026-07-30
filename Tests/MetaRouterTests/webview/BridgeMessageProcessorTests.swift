import XCTest
@testable import MetaRouter

final class BridgeMessageProcessorTests: XCTestCase {

    private final class RecordingSink: BridgeEventSink {
        var accept = true
        var enqueued: [BridgeEnvelope] = []

        func enqueue(_ envelope: BridgeEnvelope) -> Bool {
            if accept { enqueued.append(envelope) }
            return accept
        }
    }

    private func envelopeJson(messageId: String = "m-1", name: String = "product_viewed") -> String {
        #"{"version":1,"messageId":"\#(messageId)","type":"track","name":"\#(name)","properties":{"sku":"SKU-1"}}"#
    }

    func testValidEnvelopeIsEnqueuedAndAckedOk() {
        let sink = RecordingSink()
        let processor = BridgeMessageProcessor(sink: sink)

        let reply = processor.process(envelopeJson())

        XCTAssertEqual(sink.enqueued.count, 1)
        XCTAssertEqual(sink.enqueued[0].name, "product_viewed")
        XCTAssertEqual(reply.status, "ok")
        XCTAssertEqual(reply.messageId, "m-1")
    }

    func testInvalidEnvelopeIsRejectedAndNeverReachesTheSink() {
        let sink = RecordingSink()
        let processor = BridgeMessageProcessor(sink: sink)

        let reply = processor.process("{not json")

        XCTAssertEqual(sink.enqueued.count, 0)
        XCTAssertEqual(reply.status, "error")
        XCTAssertEqual(reply.code, "malformed_json")
    }

    func testValidationFailureCarriesTheSpecificErrorCode() {
        let sink = RecordingSink()
        let processor = BridgeMessageProcessor(sink: sink)

        let reply = processor.process(
            #"{"version":1,"messageId":"m-1","type":"identify","name":"x"}"#
        )

        XCTAssertEqual(sink.enqueued.count, 0)
        XCTAssertEqual(reply.code, "unknown_type")
        XCTAssertEqual(reply.messageId, "m-1")
    }

    func testDuplicateMessageIdIsDroppedButStillAckedOk() {
        let sink = RecordingSink()
        let processor = BridgeMessageProcessor(sink: sink)

        let first = processor.process(envelopeJson(messageId: "m-dup"))
        let second = processor.process(envelopeJson(messageId: "m-dup"))

        XCTAssertEqual(sink.enqueued.count, 1)
        XCTAssertEqual(first.status, "ok")
        XCTAssertEqual(second.status, "ok")
    }

    func testDistinctMessageIdsAreAllEnqueued() {
        let sink = RecordingSink()
        let processor = BridgeMessageProcessor(sink: sink)

        _ = processor.process(envelopeJson(messageId: "m-1"))
        _ = processor.process(envelopeJson(messageId: "m-2"))
        _ = processor.process(envelopeJson(messageId: "m-3"))

        XCTAssertEqual(sink.enqueued.map { $0.messageId }, ["m-1", "m-2", "m-3"])
    }

    func testRejectedMessageDoesNotPoisonTheDedupStore() {
        let sink = RecordingSink()
        let processor = BridgeMessageProcessor(sink: sink)

        // Same messageId, first with an invalid type: the rejection must not record
        // the id, or the corrected retry would be dropped as a duplicate.
        _ = processor.process(#"{"version":1,"messageId":"m-1","type":"bogus","name":"x"}"#)
        let retry = processor.process(envelopeJson(messageId: "m-1"))

        XCTAssertEqual(sink.enqueued.count, 1)
        XCTAssertEqual(retry.status, "ok")
    }

    func testRejectedEnqueueNAKsNotReadyAndAllowsARetry() {
        let sink = RecordingSink()
        let processor = BridgeMessageProcessor(sink: sink)
        sink.accept = false

        let first = processor.process(envelopeJson(messageId: "m-r"))

        XCTAssertEqual(first.status, "error")
        XCTAssertEqual(first.code, "not_ready")

        // The failed delivery must not poison dedup: the retry succeeds once the
        // sink accepts again.
        sink.accept = true
        let retry = processor.process(envelopeJson(messageId: "m-r"))

        XCTAssertEqual(retry.status, "ok")
        XCTAssertEqual(sink.enqueued.count, 1)
    }

    func testSinkReceivesTheParsedEnvelopeNotTheRawString() {
        let sink = RecordingSink()
        let processor = BridgeMessageProcessor(sink: sink)

        _ = processor.process(envelopeJson())

        let envelope = sink.enqueued[0]
        XCTAssertNotNil(envelope.properties["sku"])
        XCTAssertEqual(envelope.version, 1)
    }
}
