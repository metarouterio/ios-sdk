import Foundation

/// Ack / error reply sent back over the bridge's reply channel.
///
/// Serialized shape:
/// - ok:    `{"status":"ok","messageId":"…"}`
/// - error: `{"status":"error","messageId":"…","code":"…","message":"…","supportedVersion":1}`
///
/// Null fields are omitted from the wire form (e.g. `messageId` is absent when the
/// incoming message was unparseable).
internal struct BridgeReply: Sendable, Equatable {
    let status: String
    let messageId: String?
    let code: String?
    let message: String?
    let supportedVersion: Int?

    init(
        status: String,
        messageId: String? = nil,
        code: String? = nil,
        message: String? = nil,
        supportedVersion: Int? = nil
    ) {
        self.status = status
        self.messageId = messageId
        self.code = code
        self.message = message
        self.supportedVersion = supportedVersion
    }

    /// Hand-serialized rather than JSONEncoder: the reply's field order is pinned so the
    /// wire form is byte-identical to the other platform SDKs (JSONEncoder's key order is
    /// unspecified), keeping page-side debugging output and contract tests stable.
    ///
    /// Cheap by construction, not by algorithm: every input is bounded upstream —
    /// `messageId` ≤ 256 chars by the parser, and the one page-controlled string that
    /// reaches `message` (the unknown-type echo) is capped by the 64 KiB envelope limit —
    /// so the per-scalar escaping loop never sees unbounded bytes and the transient
    /// allocations stay in the hundreds-of-bytes range. If a future contract change
    /// echoes arbitrary payload content into replies, that bound is gone: revisit with
    /// `reserveCapacity` and a cap at the echo site, not here.
    func toJson() -> String {
        var fields: [(String, String)] = [("status", Self.jsonString(status))]
        if let messageId { fields.append(("messageId", Self.jsonString(messageId))) }
        if let code { fields.append(("code", Self.jsonString(code))) }
        if let message { fields.append(("message", Self.jsonString(message))) }
        if let supportedVersion { fields.append(("supportedVersion", String(supportedVersion))) }
        return "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }

    static func ok(_ messageId: String) -> BridgeReply {
        return BridgeReply(status: "ok", messageId: messageId)
    }

    static func error(_ invalid: BridgeParseResult.Invalid) -> BridgeReply {
        return BridgeReply(
            status: "error",
            messageId: invalid.messageId,
            code: invalid.code.rawValue,
            message: invalid.message,
            supportedVersion: invalid.supportedVersion
        )
    }

    static func error(
        code: BridgeErrorCode,
        message: String,
        messageId: String? = nil
    ) -> BridgeReply {
        return BridgeReply(
            status: "error",
            messageId: messageId,
            code: code.rawValue,
            message: message
        )
    }

    /// Internal because the reply-delivery script embeds the serialized reply as a JS
    /// string literal, and JSON string escaping is exactly the escaping JS needs.
    static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
