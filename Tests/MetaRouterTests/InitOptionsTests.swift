import XCTest
@testable import MetaRouter

final class InitOptionsTests: XCTestCase {
    func testInitOptionsFromStringRemovesTrailingSlash() {
        let options = InitOptions(writeKey: "wk", ingestionHost: "https://example.com/")
        XCTAssertEqual(options.writeKey, "wk")
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://example.com")
    }

    func testInitOptionsFromStringTrimsWhitespace() {
        let options = InitOptions(writeKey: "wk", ingestionHost: "  https://example.com  ")
        XCTAssertEqual(options.ingestionHost.scheme, "https")
        XCTAssertEqual(options.ingestionHost.host, "example.com")
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://example.com")
    }

    func testInitOptionsFromURLStoresExactly() {
        let url = URL(string: "https://api.metarouter.io")!
        let options = InitOptions(writeKey: "wk", ingestionHost: url)
        XCTAssertEqual(options.ingestionHost, url)
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://api.metarouter.io")
    }

    func testInitOptionsFromStringWithPathPreserved() {
        let options = InitOptions(writeKey: "wk", ingestionHost: "https://host.tld/base")
        XCTAssertEqual(options.ingestionHost.path, "/base")
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://host.tld/base")
    }

    func testInitOptionsWithAdvertisingId() {
        let testId = "TEST-IDFA-12345"
        let options = InitOptions(
            writeKey: "wk",
            ingestionHost: "https://example.com",
            advertisingId: testId
        )

        XCTAssertEqual(options.advertisingId, testId)
    }

    func testInitOptionsWithoutAdvertisingId() {
        let options = InitOptions(writeKey: "wk", ingestionHost: "https://example.com")
        XCTAssertNil(options.advertisingId)
    }

    func testInitOptionsWithNilAdvertisingId() {
        let options = InitOptions(
            writeKey: "wk",
            ingestionHost: "https://example.com",
            advertisingId: nil
        )

        XCTAssertNil(options.advertisingId)
    }
}


