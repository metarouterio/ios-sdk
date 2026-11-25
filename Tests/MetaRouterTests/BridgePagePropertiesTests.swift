import XCTest
@testable import MetaRouter

/// A WebView page event carries the page facts and its name in `properties`, as the
/// web SDK sends them; the page's own properties win over the facts.
final class BridgePagePropertiesTests: XCTestCase {
    private func envelope(
        type: EventType = .page,
        properties: [String: CodableValue],
        page: PageContext?
    ) -> BridgeEnvelope {
        BridgeEnvelope(
            version: 1, messageId: "m", type: type, name: "Product",
            properties: properties, sentAt: nil, page: page, source: nil
        )
    }

    func testPageFactsAndNameGoInPropertiesUnderTheHosts() {
        let page = PageContext(
            url: "https://shop.example.com/p?q=1", path: "/p", search: "?q=1",
            title: "Product", referrer: "https://shop.example.com/"
        )

        let properties = AnalyticsClient.pageProperties(envelope(properties: ["title": "Host title"], page: page))

        XCTAssertEqual(properties, [
            "url": "https://shop.example.com/p?q=1",
            "path": "/p",
            "search": "?q=1",
            "title": "Host title",
            "referrer": "https://shop.example.com/",
            "name": "Product",
        ])
    }

    func testMissingFactsAreLeftOut() {
        let properties = AnalyticsClient.pageProperties(envelope(properties: [:], page: PageContext(url: "https://x.example/")))

        XCTAssertEqual(properties, ["url": "https://x.example/", "name": "Product"])
    }

    func testTheNameArgumentWinsOverANameProperty() {
        let properties = AnalyticsClient.pageProperties(envelope(properties: ["name": "other"], page: nil))

        XCTAssertEqual(properties, ["name": "Product"])
    }
}
