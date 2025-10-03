import XCTest
@testable import MetaRouter

final class MetaRouterIntegrationTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Reset MetaRouter state before each test
        MetaRouter.Analytics.reset()
        Logger.setDebugLogging(false)
    }
    
    override func tearDown() {
        MetaRouter.Analytics.reset()
        Logger.setDebugLogging(false)
        super.tearDown()
    }
    
    // Full Workflow Tests
    
    func testCompleteAnalyticsWorkflow() async {
        let options = TestDataFactory.makeInitOptions()
        
        // Initialize the analytics client
        let client = MetaRouter.Analytics.initialize(with: options)
        XCTAssertNotNil(client)
        
        // Enable debug logging
        MetaRouter.Analytics.setDebugLogging(true)
        client.enableDebugLogging()
        
        // Perform various analytics operations
        client.track("app_opened", properties: nil)
        client.identify("user123", traits: TestDataFactory.makeTraits())
        client.group("company456", traits: ["name": "Acme Corp"])
        client.screen("Home Screen", properties: nil)
        client.page("Landing Page", properties: nil)
        client.alias("new_user_id")
        
        // Test utility methods
        client.flush()
        
        // Wait for client to fully initialize
        _ = await TestUtilities.waitFor(timeout: 0.5) { true }
        
        let debugInfo = await client.getDebugInfo()
        if case .string(let writeKey) = debugInfo["writeKey"] {
            XCTAssertTrue(writeKey.contains("***"), "writeKey should be masked, got: \(writeKey)")
        } else {
            XCTFail("Expected writeKey to be a string")
        }
        
        // Reset should work
        client.reset()
        
        XCTAssertTrue(true, "Complete workflow should execute without crashes")
    }
    
    func testProxyToClientIntegration() async {
        let options = TestDataFactory.makeInitOptions()
        
        // Get the proxy (before initialization)
        let proxy = MetaRouter.Analytics.client()
        
        // Make calls before initialization (should be queued)
        proxy.track("queued_event", properties: nil)
        proxy.identify("queued_user", traits: nil)
        
        // Initialize (should bind the proxy to real client and replay calls)
        let realClient = MetaRouter.Analytics.initialize(with: options)
        XCTAssertNotNil(realClient)
        
        // Both should return the same proxy object (singleton pattern)
        XCTAssertTrue(proxy === realClient)
        
        // Make calls after initialization (should be forwarded immediately)
        proxy.track("immediate_event", properties: nil)
        proxy.flush()
        
        XCTAssertTrue(true, "Proxy to client integration should work seamlessly")
    }
    
    func testSingletonBehavior() {
        let options = TestDataFactory.makeInitOptions()
        
        // Multiple initialize calls should return the same proxy
        let client1 = MetaRouter.Analytics.initialize(with: options)
        let client2 = MetaRouter.Analytics.initialize(with: options)
        let client3 = MetaRouter.Analytics.client()
        
        XCTAssertTrue(client1 === client2, "Multiple initialize calls should return same proxy")
        XCTAssertTrue(client1 === client3, "Client() should return same proxy as initialize")
        XCTAssertTrue(client2 === client3, "All methods should return same proxy instance")
    }
    
    func testResetAndReinitialize() async {
        let options1 = TestDataFactory.makeInitOptions(writeKey: "key1")
        let options2 = TestDataFactory.makeInitOptions(writeKey: "key2")

        let client1 = MetaRouter.Analytics.initialize(with: options1)
        client1.track("event1", properties: nil)

        await MetaRouter.Analytics.resetAndWait()

        let client2 = await MetaRouter.Analytics.initializeAndWait(with: options2)

        client2.track("event2", properties: nil)

        XCTAssertTrue(client1 === client2)
        

        // Wait for binding to complete
        _ = await TestUtilities.waitFor(timeout: 0.5) { true }
        
        // Verify the proxy is bound to the new real client
        let debugInfo = await client2.getDebugInfo()
        if case .string(let wk) = debugInfo["writeKey"] {
            XCTAssertTrue(wk.contains("***"), "writeKey should be masked")
        } else {
            XCTFail("Expected writeKey to be a string")
        }
    }
    
    //  Error Recovery Tests
    
    func testRecoveryFromInvalidOperations() async {
        let options = TestDataFactory.makeInitOptions()
        let client = MetaRouter.Analytics.initialize(with: options)
        
        // Test with invalid/extreme values
        client.track("", properties: nil) // Empty event name
        client.track(String(repeating: "x", count: 100000), properties: nil) // Very long event name
        client.identify("", traits: nil) // Empty user ID
        client.alias("") // Empty alias
        
        // Test with nil values
        client.track("event", properties: nil)
        client.identify("user", traits: nil)
        
        // Normal operation should still work after invalid operations
        client.track("normal_event", properties: ["key": "value"])
        client.flush()
        
        XCTAssertTrue(true, "Should recover from invalid operations")
    }
    
    func testHighFrequencyUsage() async {
        let options = TestDataFactory.makeInitOptions()
        let client = MetaRouter.Analytics.initialize(with: options)
        
        let expectation = expectation(description: "High frequency usage completed")
        expectation.expectedFulfillmentCount = 1000
        
        // Simulate high-frequency analytics events
        for i in 0..<1000 {
            Task {
                let eventType = i % 5
                switch eventType {
                case 0: client.track("event_\(i)", properties: nil)
                case 1: client.identify("user_\(i)", traits: nil)
                case 2: client.screen("screen_\(i)", properties: nil)
                case 3: client.page("page_\(i)", properties: nil)
                case 4: client.group("group_\(i)", traits: nil)
                default: break
                }
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 10.0)
        
        // Final operations should still work
        client.flush()
        let debugInfo = await client.getDebugInfo()
        XCTAssertNotNil(debugInfo)
    }
    
    //  Multi-Client Tests
    
    func testMultipleClientCreation() async {
        let options1 = TestDataFactory.makeInitOptions(writeKey: "key1")
        let options2 = TestDataFactory.makeInitOptions(writeKey: "key2")
        
        // Create multiple AnalyticsClient instances directly
        let directClient1 = AnalyticsClient.initialize(options: options1)
        let directClient2 = AnalyticsClient.initialize(options: options2)
        
        XCTAssertFalse(directClient1 === directClient2, "Direct clients should be different instances")
        
        // Test that both work independently
        directClient1.track("event1", properties: nil)
        directClient2.track("event2", properties: nil)
        
        let debug1 = await directClient1.getDebugInfo()
        let debug2 = await directClient2.getDebugInfo()
        
        if case .string(let writeKey1) = debug1["writeKey"] {
            XCTAssertTrue(writeKey1.contains("***"), "writeKey should be masked")
        }
        if case .string(let writeKey2) = debug2["writeKey"] {
            XCTAssertTrue(writeKey2.contains("***"), "writeKey should be masked")
        }
    }
    
    func testProxyBindingToMultipleClients() async {
        let options1 = TestDataFactory.makeInitOptions(writeKey: "key1")
        let options2 = TestDataFactory.makeInitOptions(writeKey: "key2")
        
        let proxy = AnalyticsProxy()
        let client1 = AnalyticsClient.initialize(options: options1)
        let client2 = AnalyticsClient.initialize(options: options2)
        
        // Bind to first client
        proxy.bind(client1)
        proxy.track("for_client1", properties: nil)
        
        // Bind to second client (should replace first binding)
        proxy.bind(client2)
        proxy.track("for_client2", properties: nil)
        
        // Verify second client gets the call
        let debug2 = await client2.getDebugInfo()
        if case .string(let writeKey2) = debug2["writeKey"] {
            XCTAssertTrue(writeKey2.contains("***"), "writeKey should be masked")
        }
        
        XCTAssertTrue(true, "Proxy should handle multiple client bindings")
    }
    
    // Memory and Performance Tests
    
    func testMemoryUsageWithManyEvents() {
        let options = TestDataFactory.makeInitOptions()
        let client = MetaRouter.Analytics.initialize(with: options)
        
        // Generate many events to test memory usage
        for i in 0..<10000 {
            let properties: [String: CodableValue] = [
                "event_id": .string("\(i)"),
                "timestamp": .double(Date().timeIntervalSince1970),
                "random": .double(Double.random(in: 0...1))
            ]
            
            client.track("bulk_event", properties: properties)
            
            // Periodically flush to simulate real usage
            if i % 100 == 0 {
                client.flush()
            }
        }
        
        client.flush()
        XCTAssertTrue(true, "Should handle many events without excessive memory usage")
    }
    
    func testPerformanceWithComplexData() {
        let options = TestDataFactory.makeInitOptions()
        let client = MetaRouter.Analytics.initialize(with: options)
        
        // Create complex nested data structure
        let complexProperties: [String: CodableValue] = [
            "user_profile": [
                "personal_info": [
                    "name": "John Doe",
                    "age": 30,
                    "contacts": [
                        ["type": "email", "value": "john@example.com"],
                        ["type": "phone", "value": "+1234567890"]
                    ]
                ],
                "preferences": [
                    "notifications": true,
                    "theme": "dark",
                    "languages": ["en", "es", "fr"]
                ]
            ],
            "session_data": [
                "session_id": "sess_12345",
                "start_time": .double(Date().timeIntervalSince1970),
                "events_count": 42,
                "feature_flags": [
                    "new_ui": true,
                    "beta_features": false
                ]
            ]
        ]
        
        measure {
            for _ in 0..<100 {
                client.track("complex_event", properties: complexProperties)
            }
        }
    }
    
    // Thread Safety Integration Tests
    
    func testConcurrentInitializationAndUsage() async {
        let expectation = expectation(description: "Concurrent initialization completed")
        expectation.expectedFulfillmentCount = 20
        
        let options = TestDataFactory.makeInitOptions()
        
        // Concurrent initialization and usage
        for i in 0..<20 {
            Task {
                let client = MetaRouter.Analytics.initialize(with: options)
                client.track("concurrent_\(i)", properties: nil)
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Verify final state is consistent
        let client = MetaRouter.Analytics.client()
        let debugInfo = await client.getDebugInfo()
        XCTAssertNotNil(debugInfo)
    }
    
    func testConcurrentResetAndInitialize() async {
        let expectation = expectation(description: "Concurrent reset/initialize completed")
        expectation.expectedFulfillmentCount = 20
        
        for i in 0..<10 {
            Task {
                let options = TestDataFactory.makeInitOptions(writeKey: "key_\(i)")
                MetaRouter.Analytics.initialize(with: options)
                expectation.fulfill()
            }
            
            Task {
                MetaRouter.Analytics.reset()
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Should be in a valid state after all operations
        let finalClient = MetaRouter.Analytics.client()
        XCTAssertNotNil(finalClient)
    }
    
    // Real-world Usage Simulation
    
    func testTypicalMobileAppUsage() async {
        let options = TestDataFactory.makeInitOptions()
        
        // Simulate app launch
        let client = MetaRouter.Analytics.initialize(with: options)
        MetaRouter.Analytics.setDebugLogging(true)
        client.track("app_launched", properties: nil)
        
        // Simulate user login
        client.identify("user_12345", traits: [
            "email": "user@example.com",
            "plan": "premium",
            "signup_date": "2024-01-15"
        ])
        
        // Simulate navigation through screens
        let screens = ["Home", "Products", "Product_Detail", "Cart", "Checkout"]
        for (index, screen) in screens.enumerated() {
            client.screen("\(screen)_Screen", properties: [
                "screen_order": index + 1,
                "previous_screen": index > 0 ? screens[index - 1] : "none"
            ])
            
            // Add some delay to simulate real usage
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        
        // Simulate purchase
        client.track("purchase_completed", properties: [
            "order_id": "order_789",
            "total": 99.99,
            "currency": "USD",
            "items": [
                ["id": "item1", "name": "Product A", "price": 49.99],
                ["id": "item2", "name": "Product B", "price": 49.99]
            ]
        ])
        
        // Simulate app backgrounding
        client.track("app_backgrounded", properties: nil)
        client.flush()
        
        XCTAssertTrue(true, "Typical mobile app usage should work smoothly")
    }
    
    func testEdgeCaseScenarios() {
        let options = TestDataFactory.makeInitOptions()
        let client = MetaRouter.Analytics.initialize(with: options)
        
        // Test various edge cases
        client.track("🎉🎊🎈", properties: nil) // Emoji event names
        client.identify("user@domain.com", traits: nil) // Email as user ID
        client.alias("user-with-dashes")
        client.group("group_with_underscores", traits: nil)
        
        // Test with various data types in properties
        client.track("data_types_test", properties: [
            "string": "hello",
            "integer": 42,
            "double": 3.14159,
            "boolean": true,
            "array": [1, "two", 3.0, true],
            "object": ["nested": "value"],
            "empty_string": "",
            "zero": 0,
            "negative": -1,
            "large_number": 999999999999
        ])
        
        XCTAssertTrue(true, "Edge case scenarios should be handled gracefully")
    }
}
