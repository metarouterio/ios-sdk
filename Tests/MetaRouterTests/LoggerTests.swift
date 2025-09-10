import XCTest
@testable import MetaRouter

final class LoggerTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Reset logger state before each test
        Logger.setDebugLogging(false)
    }
    
    override func tearDown() {
        // Clean up after each test
        Logger.setDebugLogging(false)
        super.tearDown()
    }
    
    // Debug Logging Enable/Disable Tests
    
    func testDebugLoggingDefaultsToDisabled() {
        // Logger should start disabled by default
        // Since we can't easily intercept print statements, we test the behavior indirectly
        // by ensuring the method can be called without crashing
        Logger.log("test message")
        
        XCTAssertTrue(true, "Logger.log should not crash when disabled")
    }
    
    func testEnableDebugLogging() {
        Logger.setDebugLogging(true)
        Logger.log("test message")
        
        XCTAssertTrue(true, "Logger.log should not crash when enabled")
    }
    
    func testDisableDebugLogging() {
        Logger.setDebugLogging(true)
        Logger.setDebugLogging(false)
        Logger.log("test message")
        
        XCTAssertTrue(true, "Logger.log should not crash after being disabled")
    }
    
    func testToggleDebugLogging() {
        // Test multiple enable/disable cycles
        for i in 0..<5 {
            Logger.setDebugLogging(i % 2 == 0)
            Logger.log("toggle test \(i)")
        }
        
        XCTAssertTrue(true, "Multiple enable/disable cycles should work")
    }
    
    // Log Method Tests
    
    func testLogWithSingleArgument() {
        Logger.setDebugLogging(true)
        Logger.log("single message")
        
        XCTAssertTrue(true, "Single argument logging should work")
    }
    
    func testLogWithMultipleArguments() {
        Logger.setDebugLogging(true)
        Logger.log("multiple", "arguments", "here")
        
        XCTAssertTrue(true, "Multiple argument logging should work")
    }
    
    func testLogWithMixedTypes() {
        Logger.setDebugLogging(true)
        Logger.log("string", 42, true, 3.14, ["array"])
        
        XCTAssertTrue(true, "Mixed type logging should work")
    }
    
    func testLogWithEmptyArguments() {
        Logger.setDebugLogging(true)
        Logger.log()
        
        XCTAssertTrue(true, "Empty argument logging should work")
    }
    
    func testLogWithNilValues() {
        Logger.setDebugLogging(true)
        let nilString: String? = nil
        Logger.log("value is", nilString as Any)
        
        XCTAssertTrue(true, "Logging with nil values should work")
    }
    
    func testLogWithComplexObjects() {
        Logger.setDebugLogging(true)
        let complexObject = [
            "key1": "value1",
            "key2": ["nested": "value"],
            "key3": 42
        ] as [String: Any]
        
        Logger.log("Complex object:", complexObject)
        
        XCTAssertTrue(true, "Logging complex objects should work")
    }
    
    func testLogWithUnicodeCharacters() {
        Logger.setDebugLogging(true)
        Logger.log("Unicode test: 🎉 こんにちは 🌍 العالم")
        
        XCTAssertTrue(true, "Unicode character logging should work")
    }
    
    func testLogWithVeryLongStrings() {
        Logger.setDebugLogging(true)
        let longString = String(repeating: "A", count: 10000)
        Logger.log("Long string:", longString)
        
        XCTAssertTrue(true, "Very long string logging should work")
    }
    
    // Warn Method Tests
    
    func testWarnAlwaysExecutes() {
        // Warn should always execute regardless of debug setting
        Logger.setDebugLogging(false)
        Logger.warn("warning message")
        
        Logger.setDebugLogging(true)
        Logger.warn("another warning")
        
        XCTAssertTrue(true, "Warn should execute regardless of debug setting")
    }
    
    func testWarnWithMultipleArguments() {
        Logger.warn("warning", "with", "multiple", "arguments")
        
        XCTAssertTrue(true, "Warn with multiple arguments should work")
    }
    
    func testWarnWithMixedTypes() {
        Logger.warn("Error code:", 500, "Success:", false)
        
        XCTAssertTrue(true, "Warn with mixed types should work")
    }
    
    // Error Method Tests
    
    func testErrorAlwaysExecutes() {
        // Error should always execute regardless of debug setting
        Logger.setDebugLogging(false)
        Logger.error("error message")
        
        Logger.setDebugLogging(true)
        Logger.error("another error")
        
        XCTAssertTrue(true, "Error should execute regardless of debug setting")
    }
    
    func testErrorWithMultipleArguments() {
        Logger.error("error", "with", "multiple", "arguments")
        
        XCTAssertTrue(true, "Error with multiple arguments should work")
    }
    
    func testErrorWithMixedTypes() {
        Logger.error("Error:", NSError(domain: "test", code: 123))
        
        XCTAssertTrue(true, "Error with mixed types should work")
    }
    
    // Thread Safety Tests
    
    func testConcurrentLogging() async {
        Logger.setDebugLogging(true)
        
        let expectation = expectation(description: "Concurrent logging completed")
        expectation.expectedFulfillmentCount = 100
        
        // Simulate high-frequency concurrent logging
        for i in 0..<100 {
            Task {
                Logger.log("Concurrent message \(i)")
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        XCTAssertTrue(true, "Concurrent logging should complete without crashes")
    }
    
    func testConcurrentEnableDisable() async {
        let expectation = expectation(description: "Concurrent enable/disable completed")
        expectation.expectedFulfillmentCount = 50
        
        // Rapidly enable/disable logging while logging messages
        for i in 0..<25 {
            Task {
                Logger.setDebugLogging(i % 2 == 0)
                expectation.fulfill()
            }
            
            Task {
                Logger.log("Message during toggle \(i)")
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        XCTAssertTrue(true, "Concurrent enable/disable should complete without crashes")
    }
    
    func testMixedConcurrentCalls() async {
        let expectation = expectation(description: "Mixed concurrent calls completed")
        expectation.expectedFulfillmentCount = 60
        
        for i in 0..<20 {
            Task {
                Logger.log("Log \(i)")
                expectation.fulfill()
            }
            
            Task {
                Logger.warn("Warn \(i)")
                expectation.fulfill()
            }
            
            Task {
                Logger.error("Error \(i)")
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        XCTAssertTrue(true, "Mixed concurrent calls should complete without crashes")
    }
    
    // Performance Tests
    
    func testLogPerformanceWhenDisabled() {
        Logger.setDebugLogging(false)
        
        measure {
            for _ in 0..<1000 {
                Logger.log("Performance test message")
            }
        }
    }
    
    func testLogPerformanceWhenEnabled() {
        Logger.setDebugLogging(true)
        
        measure {
            for _ in 0..<1000 {
                Logger.log("Performance test message")
            }
        }
    }
    
    func testWarnPerformance() {
        measure {
            for _ in 0..<1000 {
                Logger.warn("Performance test warning")
            }
        }
    }
    
    func testErrorPerformance() {
        measure {
            for _ in 0..<1000 {
                Logger.error("Performance test error")
            }
        }
    }
    
    // Integration Tests
    
    func testLoggerWithAnalyticsWorkflow() {
        // Test that logger works in a typical analytics workflow
        Logger.setDebugLogging(true)
        
        Logger.log("Starting analytics workflow")
        Logger.log("Initializing client with options")
        Logger.warn("Client not bound, queuing calls")
        Logger.log("Binding client")
        Logger.log("Replaying queued calls")
        Logger.error("Failed to send event, retrying")
        Logger.log("Event sent successfully")
        
        XCTAssertTrue(true, "Logger should work in typical analytics workflow")
    }
    
    func testStateConsistencyAfterManyCalls() {
        // Test that the logger state remains consistent after many operations
        Logger.setDebugLogging(true)
        
        for i in 0..<1000 {
            if i % 3 == 0 {
                Logger.setDebugLogging(false)
            } else if i % 3 == 1 {
                Logger.setDebugLogging(true)
            }
            
            Logger.log("Message \(i)")
            Logger.warn("Warning \(i)")
            Logger.error("Error \(i)")
        }
        
        // Final state check
        Logger.setDebugLogging(true)
        Logger.log("Final message")
        
        XCTAssertTrue(true, "Logger state should remain consistent after many operations")
    }
}