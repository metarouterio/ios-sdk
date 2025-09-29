import XCTest
@testable import MetaRouter

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
}


