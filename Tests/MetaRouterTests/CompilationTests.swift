import XCTest
@testable import MetaRouter

final class CompilationTests: XCTestCase {

    func testTrackWithoutPropertiesCompiles() {
        // This test verifies that the overloaded methods work correctly
        // and that you can call track() without properties

        let options = InitOptions(writeKey: "test-key", ingestionHost: "https://test.example.com")
        let client = AnalyticsClient.initialize(options: options)

        // This should compile without any issues
        client.track("event_name")
        client.identify("user_id")
        client.group("group_id")
        client.screen("screen_name")
        client.page("page_name")

        // And the full versions should still work
        client.track("event_with_props", properties: ["key": "value"])
        client.identify("user_with_traits", traits: ["name": "John"])
        client.group("group_with_traits", traits: ["company": "Acme"])
        client.screen("screen_with_props", properties: ["category": "onboarding"])
        client.page("page_with_props", properties: ["section": "docs"])
    }

    func testProxyTrackWithoutPropertiesCompiles() {
        // Test that the proxy also supports the simplified interface
        let proxy = AnalyticsProxy()

        // These should all compile without issues
        proxy.track("event_name")
        proxy.identify("user_id")
        proxy.group("group_id")
        proxy.screen("screen_name")
        proxy.page("page_name")

        // And the full versions should still work
        proxy.track("event_with_props", properties: ["key": "value"])
        proxy.identify("user_with_traits", traits: ["name": "John"])
        proxy.group("group_with_traits", traits: ["company": "Acme"])
        proxy.screen("screen_with_props", properties: ["category": "onboarding"])
        proxy.page("page_with_props", properties: ["section": "docs"])
    }

    func testAnalyticsInterfaceUsagePattern() {
        // Test the intended usage pattern through the main API
        let options = InitOptions(writeKey: "test-key", ingestionHost: "https://test.example.com")
        let client: AnalyticsInterface = MetaRouter.Analytics.initialize(with: options)

        // The goal: simple usage without properties
        client.track("button_clicked")
        client.track("page_viewed")
        client.identify("user123")
        client.screen("HomeScreen")
        client.page("LandingPage")
        client.group("team_alpha")

        // But still support full usage
        client.track("purchase_completed", properties: [
            "amount": 99.99,
            "currency": "USD",
            "item_count": 3
        ])
    }
}
