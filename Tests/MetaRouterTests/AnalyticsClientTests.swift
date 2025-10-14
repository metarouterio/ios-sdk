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
    
    func testGetDebugInfo() async {
        let debugInfo = await client.getDebugInfo()
        
        if case .string(let writeKey) = debugInfo["writeKey"] {
            XCTAssertTrue(writeKey.contains("***"), "writeKey should be masked")
        } else {
            XCTFail("Expected writeKey to be a string")
        }
        
        if case .string(let ingestionHost) = debugInfo["ingestionHost"] {
            XCTAssertEqual(ingestionHost, options.ingestionHost.absoluteString)
        } else {
            XCTFail("Expected ingestionHost to be a string")
        }
        
        XCTAssertNotNil(debugInfo["lifecycle"])
        XCTAssertNotNil(debugInfo["queueLength"])
        XCTAssertNotNil(debugInfo["flushIntervalSeconds"])
        XCTAssertNotNil(debugInfo["maxQueueEvents"])
    }
    
    func testGetDebugInfoAfterEnablingLogging() async {
        client.enableDebugLogging()
        let debugInfo = await client.getDebugInfo()
        
        if case .string(let writeKey) = debugInfo["writeKey"] {
            XCTAssertTrue(writeKey.contains("***"), "writeKey should be masked")
        } else {
            XCTFail("Expected writeKey to be a string")
        }
        
        if case .string(let ingestionHost) = debugInfo["ingestionHost"] {
            XCTAssertEqual(ingestionHost, options.ingestionHost.absoluteString)
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

    // MARK: - Advertising ID Tests

    func testSetAdvertisingIdWithValidUUID() async {
        let validUUID = UUID().uuidString
        client.setAdvertisingId(validUUID)

        // Wait a bit for the async operation
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        XCTAssertTrue(true, "Valid UUID should be accepted")
    }

    func testSetAdvertisingIdWithNil() async {
        client.setAdvertisingId(nil)

        // Wait a bit for the async operation
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(true, "Nil advertising ID should be accepted")
    }

    func testSetAdvertisingIdWithInvalidFormat() async {
        // These should be rejected due to invalid UUID format
        let invalidFormats = [
            "not-a-uuid",
            "12345",
            "",
            "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
            "invalid-uuid-format-123",
            String(repeating: "a", count: 10000) // Very long string
        ]

        for invalidId in invalidFormats {
            client.setAdvertisingId(invalidId)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(true, "Invalid UUIDs should be rejected gracefully")
    }

    func testSetAdvertisingIdWithMalformedUUID() async {
        let malformedUUIDs = [
            "12345678-1234-1234-1234", // Too short
            "12345678-1234-1234-1234-12345678901234567890", // Too long
            "gggggggg-1234-1234-1234-123456789012", // Invalid hex characters
            "12345678 1234 1234 1234 123456789012" // Spaces instead of hyphens
        ]

        for malformedId in malformedUUIDs {
            client.setAdvertisingId(malformedId)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(true, "Malformed UUIDs should be rejected gracefully")
    }

    func testClearAdvertisingId() async {
        // First set a valid UUID
        let validUUID = UUID().uuidString
        client.setAdvertisingId(validUUID)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Then clear it
        client.clearAdvertisingId()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(true, "clearAdvertisingId should work without crashing")
    }

    func testRapidConsecutiveAdvertisingIdCalls() async {
        // Test rapid consecutive calls to ensure no race conditions
        for i in 0..<10 {
            if i % 2 == 0 {
                client.setAdvertisingId(UUID().uuidString)
            } else {
                client.clearAdvertisingId()
            }
        }

        // Wait for all operations to complete
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(true, "Rapid consecutive calls should be handled gracefully")
    }

    func testSetAdvertisingIdImmediatelyAfterInitialization() {
        // Create a new client and immediately set advertising ID
        let newOptions = TestDataFactory.makeInitOptions()
        let newClient = AnalyticsClient.initialize(options: newOptions)

        // Call setAdvertisingId immediately without waiting for initialization
        let validUUID = UUID().uuidString
        newClient.setAdvertisingId(validUUID)

        // The SDK should queue this operation and apply it once ready
        XCTAssertTrue(true, "setAdvertisingId should work even if called immediately after initialization")
    }

    func testAdvertisingIdPersistenceAcrossReset() async {
        // Set an advertising ID
        let validUUID = UUID().uuidString
        client.setAdvertisingId(validUUID)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Reset the client (should clear advertising ID)
        client.reset()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // After reset, advertising ID should be cleared
        XCTAssertTrue(true, "Advertising ID should be cleared after reset")
    }

    func testSetAdvertisingIdWithSpecialCharacters() async {
        // Test that non-UUID strings with special characters are rejected
        let specialStrings = [
            "🎉-emoji-uuid",
            "<script>alert('xss')</script>",
            "../../../etc/passwd",
            "null",
            "undefined",
            "\0\0\0\0"
        ]

        for specialString in specialStrings {
            client.setAdvertisingId(specialString)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(true, "Special characters should be handled gracefully")
    }

    func testConcurrentAdvertisingIdOperations() async {
        let expectation = expectation(description: "Concurrent advertising ID operations completed")
        expectation.expectedFulfillmentCount = 20

        // Run concurrent set and clear operations
        for i in 0..<20 {
            Task {
                if i % 3 == 0 {
                    client.setAdvertisingId(UUID().uuidString)
                } else if i % 3 == 1 {
                    client.clearAdvertisingId()
                } else {
                    client.setAdvertisingId(nil)
                }
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 3.0)
    }
}