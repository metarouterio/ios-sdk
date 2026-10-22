import Foundation

/// Translates a OneTrust consent payload into the canonical `Consent` shape.
///
/// Pure translation: no state, no dependency on the OneTrust SDK, no I/O beyond a
/// diagnostic log when a cookie value yields nothing. The host
/// reads OneTrust however it likes — the native SDK's category-status API, or the
/// `OptanonConsent` cookie's `groups` parameter out of a WebView — and hands the
/// raw statuses here, then passes the result to `setConsent`. Reconciliation
/// against the registered categories happens there, not here: this adapter never
/// adds a missing category or drops an unknown one, so the host can register the
/// set it gates on once and feed whatever OneTrust emits.
///
/// OneTrust reports opt-IN status (1 / true = consented); the canonical shape is
/// opt-OUT. The inversion happens here, once, so no other layer ever reasons about
/// vendor semantics. Keys are lowercased (`C0004` → `c0004`) to match the web
/// SDK's `optOut` keys.
public enum OneTrustAdapter {

    /// - Parameters:
    ///   - raw: OneTrust category statuses keyed by category ID, e.g.
    ///     `["C0001": 1, "C0002": 0]`. Values may be `Bool`, any number
    ///     (`1` = consented), or a string (`"1"` / `"true"`, case-insensitive). A
    ///     value that cannot be read as a consent status counts as opted out —
    ///     an unreadable signal never opts a user in.
    ///   - explicit: whether this snapshot reflects an explicit user interaction
    ///     (a banner choice) or a regional default. The payload cannot tell the
    ///     two apart; the host knows which OneTrust callback fired.
    public static func normalize(_ raw: [String: Any], explicit: Bool) -> Consent {
        var optOut: [String: Bool] = [:]
        optOut.reserveCapacity(raw.count)
        for (key, value) in raw {
            optOut[key] = !isOptedIn(value)
        }
        return Consent(explicit: explicit, optOut: ConsentKey.canonicalize(optOut))
    }

    /// Convenience for the `OptanonConsent` cookie's `groups` parameter, e.g.
    /// `"C0001:1,C0002:0,C0004:1"`.
    ///
    /// Accepts the value as it actually comes out of a cookie store: still
    /// percent-encoded (`C0001%3A1%2CC0002%3A0` — what `HTTPCookie.value` and a
    /// WebView's `document.cookie` hand back), the whole `OptanonConsent` value with
    /// the `groups=` parameter somewhere inside it, or a full `document.cookie`
    /// string. The `groups` token is isolated FIRST (on `&` and `;`) and only its
    /// value is percent-decoded: decoding the whole string would let one stray `%`
    /// in an unrelated cookie fail the decode and leave `groups` encoded, and would
    /// turn an encoded `&` or `groups=` inside another parameter into a live
    /// delimiter. An encoded value that parses to zero segments would make
    /// reconciliation fill every category with its opt-out default — a user who
    /// accepted everything stamped as explicitly rejecting everything.
    ///
    /// Segments without a `key:value` shape, or whose key contains `=` (a
    /// `name=` prefix that is not a group ID), are skipped — a malformed value
    /// degrades to fewer categories (which reconciliation fills with their opt-out
    /// defaults), never to a crash or to a consented category. Input that yields no
    /// categories at all is logged (the one side effect of this otherwise pure
    /// function), since that is almost certainly the wrong field.
    public static func normalize(groups: String, explicit: Bool) -> Consent {
        guard let list = groupsList(in: groups) else {
            if !groups.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Logger.warn("OneTrustAdapter: no `groups` parameter found — expected the OptanonConsent `groups` value, e.g. \"C0001:1,C0002:0\"")
            }
            return normalize([:], explicit: explicit)
        }

        var raw: [String: Any] = [:]
        for segment in list.split(separator: ",") {
            let parts = segment.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty || key.contains("=") { continue }
            raw[key] = value
        }

        if raw.isEmpty && !list.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Logger.warn("OneTrustAdapter: no category statuses found in groups value — expected the OptanonConsent `groups` parameter, e.g. \"C0001:1,C0002:0\"")
        }
        return normalize(raw, explicit: explicit)
    }

    /// The decoded `groups` list out of whatever the host passed: a bare list, a
    /// cookie value, or a cookie jar. Tokens are split on both `&` (query-style
    /// parameters inside the cookie value) and `;` (cookie separators), so a
    /// `groups` that is the last parameter of its cookie does not swallow the next
    /// cookie into its last category. Nil when the input is parameterized but
    /// carries no usable `groups` token.
    ///
    /// - A `groups=` token whose value holds no `key:value` pair is skipped, so an
    ///   unrelated cookie named `groups` in the jar cannot shadow OptanonConsent's.
    /// - `&`-joined input without a usable `groups` token is never parsed whole:
    ///   other OneTrust parameters (`hosts=H1:1,H2:0`) share the `key:value` shape
    ///   and would otherwise come out as phantom categories.
    /// - Anything else is a bare list — or a whole value encoded once more
    ///   (`groups%3DC0001%253A1`), which is decoded and searched again.
    private static func groupsList(in input: String, depth: Int = 0) -> String? {
        let tokens = input.split(whereSeparator: { $0 == "&" || $0 == ";" })
        for token in tokens {
            var trimmed = Substring(token.trimmingCharacters(in: .whitespacesAndNewlines))
            // In a cookie jar, `groups` can be the first parameter of the cookie's
            // value: `OptanonConsent=groups=…`. Look past one `name=` prefix.
            if !trimmed.hasPrefix("groups="),
               let eq = trimmed.firstIndex(of: "="),
               trimmed[trimmed.index(after: eq)...].hasPrefix("groups=") {
                trimmed = trimmed[trimmed.index(after: eq)...]
            }
            guard trimmed.hasPrefix("groups=") else { continue }
            let encoded = String(trimmed.dropFirst("groups=".count))
            let decoded = encoded.removingPercentEncoding ?? encoded
            if decoded.contains(":") { return decoded }
        }
        if input.contains("&") { return nil }
        let decoded = input.removingPercentEncoding ?? input
        if depth == 0, decoded.contains("groups=") {
            return groupsList(in: decoded, depth: 1)
        }
        return decoded
    }

    /// `Bool` is checked first on purpose: a JSON-sourced `NSNumber` holding 0 or 1
    /// bridges to `Bool`, and a `Bool` must never fall through to the numeric
    /// branch where `true` would read as 1 by accident of representation.
    private static func isOptedIn(_ value: Any) -> Bool {
        switch value {
        case let flag as Bool:
            return flag
        case let number as Int:
            return number == 1
        case let number as Double:
            return number == 1
        case let number as NSNumber:
            // doubleValue, not intValue: Float/CGFloat land here, and 1.5 must not
            // truncate into "consented" while the same value as Double does not.
            return number.doubleValue == 1
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "1" || trimmed.caseInsensitiveCompare("true") == .orderedSame
        default:
            return false
        }
    }
}
