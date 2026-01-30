import XCTest
@testable import MetaRouter


private final class MockURLSession: URLSessionable, @unchecked Sendable {
    var responseStatusCode: Int = 200
    var responseBody: Data = Data()
    var responseHeaders: [String: String] = [:]
    var shouldThrow: Error?
    var lastRequest: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        if let error = shouldThrow {
            throw error
        }
        let headerFields = responseHeaders.isEmpty ? nil : responseHeaders
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: responseStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )!
        return (responseBody, response)
    }
}

final class NetworkClientTests: XCTestCase {


    func testParseRetryAfterSeconds() {
        let client = NetworkClient()
        let headers: [String: String] = ["Retry-After": "5"]
        XCTAssertEqual(client.parseRetryAfterMs(from: headers), 5000)
    }

    func testParseRetryAfterHTTPDate() {
        let client = NetworkClient()
        let future = Date().addingTimeInterval(3)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let dateStr = df.string(from: future)
        let headers: [String: String] = ["Retry-After": dateStr]
        let ms = client.parseRetryAfterMs(from: headers) ?? 0
        XCTAssert(ms <= 3000 && ms >= 0)
    }

    func testParseRetryAfterInvalid() {
        let client = NetworkClient()
        let headers: [String: String] = ["Retry-After": "not-a-date"]
        XCTAssertNil(client.parseRetryAfterMs(from: headers))
    }

    func testPostJSONWithMockSession() async throws {
        let mock = MockURLSession()
        mock.responseStatusCode = 200
        mock.responseBody = Data("{\"ok\":true}".utf8)

        let client = NetworkClient(session: mock)
        let url = URL(string: "https://example.com/v1/batch")!
        let body = Data("{\"batch\":[]}".utf8)

        let response = try await client.postJSON(url: url, body: body, timeoutMs: 5000)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNotNil(mock.lastRequest)
        XCTAssertEqual(mock.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(mock.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testPostJSONForwards500() async throws {
        let mock = MockURLSession()
        mock.responseStatusCode = 500

        let client = NetworkClient(session: mock)
        let url = URL(string: "https://example.com/v1/batch")!
        let body = Data("{\"batch\":[]}".utf8)

        let response = try await client.postJSON(url: url, body: body, timeoutMs: 5000)

        XCTAssertEqual(response.statusCode, 500)
    }

    func testPostJSONThrowsOnNetworkError() async {
        let mock = MockURLSession()
        mock.shouldThrow = URLError(.timedOut)

        let client = NetworkClient(session: mock)
        let url = URL(string: "https://example.com/v1/batch")!
        let body = Data("{\"batch\":[]}".utf8)

        do {
            _ = try await client.postJSON(url: url, body: body, timeoutMs: 5000)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    func testPostJSONSetsTimeout() async throws {
        let mock = MockURLSession()
        let client = NetworkClient(session: mock)
        let url = URL(string: "https://example.com/v1/batch")!
        let body = Data("{\"batch\":[]}".utf8)

        _ = try await client.postJSON(url: url, body: body, timeoutMs: 3000)

        XCTAssertEqual(mock.lastRequest!.timeoutInterval, 3.0, accuracy: 0.01)
    }

    func testPostJSONAddsCustomHeaders() async throws {
        let mock = MockURLSession()
        let client = NetworkClient(session: mock)
        let url = URL(string: "https://example.com/v1/batch")!
        let body = Data("{\"batch\":[]}".utf8)

        _ = try await client.postJSON(url: url, body: body, timeoutMs: 5000, additionalHeaders: ["Trace": "true"])

        XCTAssertEqual(mock.lastRequest?.value(forHTTPHeaderField: "Trace"), "true")
    }

    func testPostJSONReturnsResponseHeaders() async throws {
        let mock = MockURLSession()
        mock.responseHeaders = ["X-Request-Id": "abc123"]
        let client = NetworkClient(session: mock)
        let url = URL(string: "https://example.com/v1/batch")!
        let body = Data("{\"batch\":[]}".utf8)

        let response = try await client.postJSON(url: url, body: body, timeoutMs: 5000)

        XCTAssertEqual(response.headers["X-Request-Id"], "abc123")
    }
}
