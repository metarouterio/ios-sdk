import Foundation

/// Error codes returned to the web producer. Closed set — the web side may branch on
/// these, so adding a code is a contract change. The raw value is the exact string that
/// appears in the reply payload.
internal enum BridgeErrorCode: String, CaseIterable, Sendable {
    case malformedJson = "malformed_json"
    case malformedPayload = "malformed_payload"
    case missingField = "missing_field"
    case unknownType = "unknown_type"
    case unsupportedVersion = "unsupported_version"
    case payloadTooLarge = "payload_too_large"
    case notReady = "not_ready"
}

internal enum BridgeParseResult {
    case valid(BridgeEnvelope)
    case invalid(Invalid)

    struct Invalid: Sendable {
        let code: BridgeErrorCode
        let message: String
        /// Echoed when it could be extracted — absent for unparseable input.
        let messageId: String?
        /// Populated only for `BridgeErrorCode.unsupportedVersion`.
        let supportedVersion: Int?

        init(
            code: BridgeErrorCode,
            message: String,
            messageId: String? = nil,
            supportedVersion: Int? = nil
        ) {
            self.code = code
            self.message = message
            self.messageId = messageId
            self.supportedVersion = supportedVersion
        }
    }
}

/// Parses and validates a raw bridge message into a `BridgeEnvelope`.
///
/// Validation order: size limit (checked before parsing, so an oversized payload is
/// never deserialized) → JSON well-formedness → required fields → version rule → type
/// rule. Unknown fields are ignored so the web side can add optional fields without a
/// version bump; optional fields with an unexpected JSON type are treated as absent
/// rather than rejected — only `properties` (which downstream merge depends on) is
/// strict.
internal enum BridgeEnvelopeParser {

    static let supportedVersion = 1

    /// Max envelope size accepted at the untrusted JS→native boundary. A policy cap that
    /// bounds parse cost — not receive memory (the platform materializes the full String
    /// before we ever see it).
    ///
    /// 64 KiB sits well under the cluster's single-event ingest cap (StreamingLimitBytes =
    /// 250 KiB; ingestor/limits.go:3-14), leaving headroom for native enrichment before the
    /// event is sent. The cluster enforces size per HTTP request body, so batch totals
    /// (BatchLimitBytes = 500 KiB) are the dispatcher's concern, absorbed by its 413 backoff.
    static let maxEnvelopeBytes = 64 * 1024

    // UUIDs are 36 chars; a generous ceiling keeps the dedup store's aggregate memory
    // bounded in bytes, not just entry count — 1000 retained near-64KB ids would be ~64MB.
    static let maxMessageIdChars = 256

    static func parse(_ raw: String) -> BridgeParseResult {
        // The cap is a UTF-8 *byte* budget, not a char budget.
        // Fast path: a String's UTF-8 length is always >= its character count, so an
        // over-length string is definitely oversized and short-circuits before the full
        // UTF-8 walk. Precise path: exact UTF-8 wire size for the plausible range, where
        // one character may be several bytes.
        if raw.count > maxEnvelopeBytes || raw.utf8.count > maxEnvelopeBytes {
            return .invalid(.init(
                code: .payloadTooLarge,
                message: "envelope exceeds \(maxEnvelopeBytes) bytes"
            ))
        }

        let rootValue: CodableValue
        do {
            rootValue = try JSONDecoder().decode(CodableValue.self, from: Data(raw.utf8))
        } catch {
            return .invalid(.init(
                code: .malformedJson,
                message: "envelope is not valid JSON"
            ))
        }
        guard case .object(let root) = rootValue else {
            return .invalid(.init(
                code: .malformedPayload,
                message: "envelope must be a JSON object"
            ))
        }

        // Extract messageId first so later rejections can echo it in the error reply.
        guard let messageId = root["messageId"]?.stringValue,
              !messageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .invalid(.init(
                code: .missingField,
                message: "messageId is required"
            ))
        }
        if messageId.count > maxMessageIdChars {
            // Deliberately not echoing the oversized id back — the reply would amplify
            // the same bytes straight back to the page.
            return .invalid(.init(
                code: .malformedPayload,
                message: "messageId exceeds \(maxMessageIdChars) chars"
            ))
        }

        guard let versionValue = root["version"] else {
            return missing("version", messageId)
        }
        guard case .int(let version) = versionValue else {
            return .invalid(.init(
                code: .malformedPayload,
                message: "version must be an integer",
                messageId: messageId
            ))
        }
        if version < 1 {
            return .invalid(.init(
                code: .malformedPayload,
                message: "version must be >= 1",
                messageId: messageId
            ))
        }
        if version > supportedVersion {
            return .invalid(.init(
                code: .unsupportedVersion,
                message: "envelope version \(version) > supported \(supportedVersion)",
                messageId: messageId,
                supportedVersion: supportedVersion
            ))
        }

        guard let typeString = root["type"]?.stringValue else {
            return missing("type", messageId)
        }
        let type: EventType
        switch typeString {
        case "track": type = .track
        case "page": type = .page
        default:
            return .invalid(.init(
                code: .unknownType,
                message: "type must be \"track\" or \"page\", got \"\(typeString)\"",
                messageId: messageId
            ))
        }

        guard let name = root["name"]?.stringValue,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return missing("name", messageId)
        }

        let properties: [String: CodableValue]
        switch root["properties"] {
        case nil:
            properties = [:]
        case .object(let object)?:
            properties = object
        default:
            return .invalid(.init(
                code: .malformedPayload,
                message: "properties must be a JSON object",
                messageId: messageId
            ))
        }

        let page = root["page"]?.objectValue.map {
            PageContext(
                url: $0["url"]?.stringValue,
                path: $0["path"]?.stringValue,
                search: $0["search"]?.stringValue,
                title: $0["title"]?.stringValue,
                referrer: $0["referrer"]?.stringValue
            )
        }

        let source = root["source"]?.objectValue.map {
            BridgeSource(
                producer: $0["producer"]?.stringValue,
                wrapperVersion: $0["wrapperVersion"]?.stringValue
            )
        }

        return .valid(BridgeEnvelope(
            version: version,
            messageId: messageId,
            type: type,
            name: name,
            properties: properties,
            sentAt: root["sentAt"]?.stringValue,
            page: page,
            source: source
        ))
    }

    private static func missing(_ field: String, _ messageId: String?) -> BridgeParseResult {
        return .invalid(.init(
            code: .missingField,
            message: "\(field) is required",
            messageId: messageId
        ))
    }
}
