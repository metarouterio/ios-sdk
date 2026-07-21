import Foundation

/// A validated web→native bridge envelope (contract v1).
///
/// Instances are only produced by `BridgeEnvelopeParser.parse` — construction implies the
/// required-field, version, and type rules have already been enforced, so downstream code
/// (merge, dedup) never re-validates.
///
/// `version`, `sentAt`, and `source` are contract fields carried but not yet consumed:
/// `version` feeds the parser's compatibility gate, `sentAt` is the producer's untrusted
/// clock (native sets the real timestamp at merge), and `source` distinguishes the
/// injected wrapper from the future web-SDK producer.
internal struct BridgeEnvelope: Sendable {
    let version: Int
    let messageId: String
    /// Restricted to `EventType.track` and `EventType.page` in contract v1.
    let type: EventType
    let name: String
    let properties: [String: CodableValue]
    let sentAt: String?
    /// Point-in-time page facts stamped by the wrapper at call time.
    let page: PageContext?
    let source: BridgeSource?
}

/// Producer identification — distinguishes the injected wrapper from the future
/// web-SDK proxy mode (F2).
internal struct BridgeSource: Sendable, Equatable {
    let producer: String?
    let wrapperVersion: String?
}
