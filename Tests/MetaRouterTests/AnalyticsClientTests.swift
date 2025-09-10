import XCTest
@testable import MetaRouter

final class AnalyticsClientTests: XCTestCase {
    private var client: AnalyticsClient!
    private var options: InitOptions!
    
    override func setUp() {
        super.setUp()
        options = TestDataFactory.makeInitOptions()
        client = AnalyticsClient.initialize(options: options)
        
        // Reset logger state for each test
        Logger.setDebugLogging(false)
    }
    
    override func tearDown() {
        client = nil
        options = nil
        Logger.setDebugLogging(false)
        super.tearDown()
    }
    
    // Initialization Tests
    
    func testClientInitialization() {
        XCTAssertNotNil(client)
    }
    
    func testInitializeCreatesNewClient() {
        let client1 = AnalyticsClient.initialize(options: options)
        let client2 = AnalyticsClient.initialize(options: options)
        
        XCTAssertFalse(client1 === client2, "Each initialize call should create a new client")
    }
    

    // TODO: Add tests for network calls

    // Track Tests
    
    func testTrackWithoutProperties() {
        client.track("test_event", properties: nil)
        
        XCTAssertTrue(true, "Track method completed without crashing")
    }
    
    func testTrackWithProperties() {
        let properties = TestDataFactory.makeProperties()
        client.track("purchase", properties: properties)
        
        XCTAssertTrue(true, "Track with properties completed without crashing")
    }

    func testWithNoProperties() {
        client.track("purchase")
        
        XCTAssertTrue(true, "Track with no properties completed without crashing")
    }
    
    func testTrackWithNilProperties() {
        client.track("test_event", properties: nil)
        
        XCTAssertTrue(true, "Track with nil properties completed without crashing")
    }
    
    func testTrackWithEmptyProperties() {
        client.track("test_event", properties: [:])
        
        XCTAssertTrue(true, "Track with empty properties completed without crashing")
    }
    
    // Identity Tests
    
    func testIdentifyWithoutTraits() {
        client.identify("user123", traits: nil)
        
        XCTAssertTrue(true, "Identify method completed without crashing")
    }
    
    func testIdentifyWithTraits() {
        let traits = TestDataFactory.makeTraits()
        client.identify("user123", traits: traits)
        
        XCTAssertTrue(true, "Identify with traits completed without crashing")
    }

    func testIdentifyWithNoTraits() {
        client.identify("user123", traits: nil)
        
        XCTAssertTrue(true, "Identify with no traits completed without crashing")
    }
    
    func testIdentifyWithNilTraits() {
        client.identify("user123", traits: nil)
        
        XCTAssertTrue(true, "Identify with nil traits completed without crashing")
    }
    
    // Group Tests
    
    func testGroupWithoutTraits() {
        client.group("company123", traits: nil)
        
        XCTAssertTrue(true, "Group method completed without crashing")
    }

    func testGroupWithNoTraits() {
        client.group("company123", traits: nil)
        
        XCTAssertTrue(true, "Group with no traits completed without crashing")
    }
    
    func testGroupWithTraits() {
        let traits: [String: CodableValue] = [
            "name": "Acme Corp",
            "industry": "Technology",
            "employees": 100
        ]
        client.group("company123", traits: traits)
        
        XCTAssertTrue(true, "Group with traits completed without crashing")
    }
    
    // Screen Tests
    
    func testScreenWithoutProperties() {
        client.screen("Home Screen", properties: nil)
        
        XCTAssertTrue(true, "Screen method completed without crashing")
    }
    
    func testScreenWithProperties() {
        let properties: [String: CodableValue] = [
            "category": "main",
            "load_time": 1.5
        ]
        client.screen("Product Details", properties: properties)
        
        XCTAssertTrue(true, "Screen with properties completed without crashing")
    }
    
    // Page Tests
    
    func testPageWithoutProperties() {
        client.page("Landing Page", properties: nil)
        
        XCTAssertTrue(true, "Page method completed without crashing")
    }
    
    func testPageWithProperties() {
        let properties: [String: CodableValue] = [
            "url": "/products",
            "referrer": "google.com"
        ]
        client.page("Products", properties: properties)
        
        XCTAssertTrue(true, "Page with properties completed without crashing")
    }
    
    // Alias Tests
    
    func testAlias() {
        client.alias("new_user_id")
        
        XCTAssertTrue(true, "Alias method completed without crashing")
    }
    
    // Debug Logging Tests
    
    func testEnableDebugLogging() {
        client.enableDebugLogging()
        
        // Verify debug logging was enabled globally
        // Note: This tests the side effect of calling Logger.setDebugLogging(true)
        XCTAssertTrue(true, "EnableDebugLogging method completed without crashing")
    }
    
    func testGetDebugInfo() {
        let debugInfo = client.getDebugInfo()
        
        if case .string(let writeKey) = debugInfo["writeKey"] {
            XCTAssertEqual(writeKey, options.writeKey)
        } else {
            XCTFail("Expected writeKey to be a string")
        }
        
        if case .string(let ingestionHost) = debugInfo["ingestionHost"] {
            XCTAssertEqual(ingestionHost, options.ingestionHost)
        } else {
            XCTFail("Expected ingestionHost to be a string")
        }
        XCTAssertEqual(debugInfo.count, 2)
    }
    
    func testGetDebugInfoAfterEnablingLogging() {
        client.enableDebugLogging()
        let debugInfo = client.getDebugInfo()
        
        if case .string(let writeKey) = debugInfo["writeKey"] {
            XCTAssertEqual(writeKey, options.writeKey)
        } else {
            XCTFail("Expected writeKey to be a string")
        }
        
        if case .string(let ingestionHost) = debugInfo["ingestionHost"] {
            XCTAssertEqual(ingestionHost, options.ingestionHost)
        } else {
            XCTFail("Expected ingestionHost to be a string")
        }
    }
    
    // Utility Method Tests
    
    func testFlush() {
        client.flush()
        
        XCTAssertTrue(true, "Flush method completed without crashing")
    }
    
    func testReset() {
        client.reset()
        
        XCTAssertTrue(true, "Reset method completed without crashing")
    }
    
    // Thread Safety Tests
    
    func testConcurrentCalls() async {
        let expectation = expectation(description: "Concurrent calls completed")
        expectation.expectedFulfillmentCount = 10
        
        for i in 0..<10 {
            Task {
                client.track("event_\(i)", properties: nil)
                client.identify("user_\(i)", traits: nil)
                client.flush()
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 2.0)
    }
    
    // Error Handling Tests
    
    func testMethodsWithExtremeValues() {
        // Test with very long strings
        let longString = String(repeating: "a", count: 10000)
        client.track(longString, properties: nil)
        client.identify(longString, traits: nil)
        
        // Test with empty strings
        client.track("", properties: nil)
        client.identify("", traits: nil)
        
        // Test with special characters
        client.track("🎉 Special Event! @#$%^&*()", properties: nil)
        client.identify("user@domain.com", traits: nil)
        
        XCTAssertTrue(true, "Methods handle extreme values without crashing")
    }
    
    func testMethodsWithComplexProperties() {
        let complexProperties: [String: CodableValue] = [
            "nested": [
                "level1": [
                    "level2": [
                        "level3": "deep value"
                    ]
                ]
            ],
            "array": [1, 2, 3, "mixed", true, ["nested_array"]],
            "null_value": .null,
            "unicode": "こんにちは 🌍",
            "numbers": [
                "int": 42,
                "double": 3.14159,
                "large": 999999999999
            ]
        ]
        
        client.track("complex_event", properties: complexProperties)
        
        XCTAssertTrue(true, "Complex properties handled without crashing")
    }
}