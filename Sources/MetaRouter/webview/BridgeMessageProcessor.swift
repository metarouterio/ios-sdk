import Foundation

/// Receives validated, deduplicated envelopes for merge + enqueue. Implemented by the
/// client wiring; kept as a single-method seam so the processing pipeline is testable
/// without a real SDK instance.
///
/// Returns whether the event actually entered the delivery path — an `ok` ack for an
/// event that was silently dropped (SDK resetting, channel full) would lie to the
/// producer, so the reply must reflect this result.
internal protocol BridgeEventSink {
    func enqueue(_ envelope: BridgeEnvelope) -> Bool
}

/// The receive pipeline for one attached webview: raw message → parse/validate → dedup →
/// sink, producing the reply to send back to the wrapper.
///
/// Rejections are logged natively as well as replied — page JS consoles are rarely
/// watched in production, so the native log is the primary debugging surface for a
/// misbehaving integration.
internal final class BridgeMessageProcessor {

    private let sink: BridgeEventSink
    private let dedupStore: BridgeDedupStore

    init(sink: BridgeEventSink, dedupStore: BridgeDedupStore = BridgeDedupStore()) {
        self.sink = sink
        self.dedupStore = dedupStore
    }

    /// Synchronous; the caller chooses the thread. NOT safe to call concurrently for the
    /// same processor — `markIfNew → enqueue → forget` is a check-then-act across two lock
    /// regions, so a concurrent duplicate could be acked `ok` and dropped while the
    /// original's enqueue fails, losing the event. Invoke from a single confined thread.
    func process(_ raw: String) -> BridgeReply {
        switch BridgeEnvelopeParser.parse(raw) {
        case .invalid(let invalid):
            // The reply must stay complete — that is the contract — but the log need
            // not: for unknown_type the message embeds page-controlled text bounded
            // only by the envelope cap, and a hostile page should not get to write
            // 64KB lines into a customer's device log.
            Logger.warn(
                "WebView bridge message rejected (\(invalid.code.rawValue)): \(String(invalid.message.prefix(200)))"
            )
            return BridgeReply.error(invalid)

        case .valid(let envelope):
            if !dedupStore.markIfNew(envelope.messageId) {
                // Duplicates are acked ok, not errored: the producer's goal —
                // exactly-once enqueue — was already met by the first delivery.
                Logger.log(
                    "WebView bridge duplicate dropped (messageId=\(envelope.messageId))"
                )
                return BridgeReply.ok(envelope.messageId)
            }
            if sink.enqueue(envelope) {
                return BridgeReply.ok(envelope.messageId)
            }
            // The event never entered the delivery path — un-record the id so
            // a producer retry is not misread as a duplicate of a message that
            // was in fact lost.
            dedupStore.forget(envelope.messageId)
            Logger.warn(
                "WebView bridge event not accepted (messageId=\(envelope.messageId))"
            )
            return BridgeReply.error(
                code: .notReady,
                message: "SDK not ready to accept events",
                messageId: envelope.messageId
            )
        }
    }
}
