import Foundation

public struct NetworkResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data?
}

public protocol Networking: Sendable {
    func postJSON(
        url: URL,
        body: Data,
        timeoutMs: Int
    ) async throws -> NetworkResponse

    func parseRetryAfterMs(from headers: [String: String]) -> Int?
}

public final class NetworkClient: Networking {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        // Per-request timeout is set on the URLRequest; keep reasonable session defaults
        session = URLSession(configuration: config)
    }

    public func postJSON(
        url: URL,
        body: Data,
        timeoutMs: Int
    ) async throws -> NetworkResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = TimeInterval(Double(timeoutMs) / 1000.0)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        // Normalize headers to [String: String]
        var headerStrings: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            let keyString = String(describing: k)
            let valueString = String(describing: v)
            headerStrings[keyString] = valueString
        }
        return NetworkResponse(statusCode: http.statusCode, headers: headerStrings, body: data)
    }

    public func parseRetryAfterMs(from headers: [String: String]) -> Int? {
        // Accepts either numeric seconds or HTTP-date
        guard let raw = headers.first(where: { (key, _) in
            key.lowercased() == "retry-after"
        })?.value else { return nil }

        if let seconds = Int(raw.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds * 1000)
        }
        // Try HTTP-date
        if let date = httpDateToDate(raw) {
            let ms = Int(date.timeIntervalSince(Date()) * 1000)
            return max(0, ms)
        }
        return nil
    }

    private func httpDateToDate(_ value: String) -> Date? {
        // RFC 7231 preferred format: Sun, 06 Nov 1994 08:49:37 GMT
        let fmts = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ]
        for fmt in fmts {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = fmt
            if let d = df.date(from: value) { return d }
        }
        return nil
    }
}


