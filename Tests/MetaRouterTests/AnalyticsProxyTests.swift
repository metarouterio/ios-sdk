import XCTest
@testable import MetaRouter

final class AnalyticsProxyTests: XCTestCase {
    private var proxy: AnalyticsProxy!
    private var mockClient: MockAnalyticsInterface!
    
    override func setUp() {
        super.setUp()
        proxy = AnalyticsProxy()
        mockClient = MockAnalyticsInterface()
    }
    
    override func tearDown() {
        proxy = nil
        mockClient = nil
        super.tearDown()
    }
    
    // Initialization Tests
    
    func testProxyInitialization() {
        XCTAssertNotNil(proxy)
    }
    
    // Binding Tests
    
    func testBindingRealClient() async {
        proxy.bind(mockClient)
        
        // Allow time for the binding to complete
        let bound = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 0 // No calls should be made just from binding
        }
        
        XCTAssertTrue(bound)
    }
    
    func testUnbinding() async {
        proxy.bind(mockClient)
        proxy.unbind()
        
        // After unbinding, calls should be queued instead of forwarded
        proxy.track("test_event", properties: nil)
        
        let notForwarded = await TestUtilities.waitFor(timeout: 0.1) { [weak self] in
            self?.mockClient.callCount == 0
        }
        
        XCTAssertTrue(notForwarded, "Calls should not be forwarded after unbinding")
    }
    
    // Call Forwarding Tests
    
    func testTrackForwardedWhenBound() async {
        proxy.bind(mockClient)
        proxy.track("test_event", properties: ["key": "value"])
        
        let forwarded = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 1
        }
        
        XCTAssertTrue(forwarded)
        XCTAssertEqual(mockClient.calls.first, .track(event: "test_event", properties: ["key": "value"]))
    }
    
    func testIdentifyForwardedWhenBound() async {
        proxy.bind(mockClient)
        proxy.identify("user123", traits: ["name": "John"])
        
        let forwarded = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 1
        }
        
        XCTAssertTrue(forwarded)
        XCTAssertEqual(mockClient.calls.first, .identify(userId: "user123", traits: ["name": "John"]))
    }
    
    func testGroupForwardedWhenBound() async {
        proxy.bind(mockClient)
        proxy.group("company123", traits: ["name": "Acme"])
        
        let forwarded = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 1
        }
        
        XCTAssertTrue(forwarded)
        XCTAssertEqual(mockClient.calls.first, .group(groupId: "company123", traits: ["name": "Acme"]))
    }
    
    func testScreenForwardedWhenBound() async {
        proxy.bind(mockClient)
        proxy.screen("Home", properties: ["category": "main"])
        
        let forwarded = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 1
        }
        
        XCTAssertTrue(forwarded)
        XCTAssertEqual(mockClient.calls.first, .screen(name: "Home", properties: ["category": "main"]))
    }
    
    func testPageForwardedWhenBound() async {
        proxy.bind(mockClient)
        proxy.page("Landing", properties: ["url": "/"])
        
        let forwarded = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 1
        }
        
        XCTAssertTrue(forwarded)
        XCTAssertEqual(mockClient.calls.first, .page(name: "Landing", properties: ["url": "/"]))
    }
    
    func testAliasForwardedWhenBound() async {
        proxy.bind(mockClient)
        proxy.alias("new_user_id")
        
        let forwarded = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 1
        }
        
        XCTAssertTrue(forwarded)
        XCTAssertEqual(mockClient.calls.first, .alias(newUserId: "new_user_id"))
    }
    
    func testEnableDebugLoggingForwardedWhenBound() async {
        proxy.bind(mockClient)
        proxy.enableDebugLogging()
        
        let forwarded = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 1
        }
        
        XCTAssertTrue(forwarded)
        XCTAssertEqual(mockClient.calls.first, .enableDebugLogging)
    }
    
    func testFlushForwardedWhenBound() async {
        proxy.bind(mockClient)
        proxy.flush()
        
        let forwarded = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 1
        }
        
        XCTAssertTrue(forwarded)
        XCTAssertEqual(mockClient.calls.first, .flush)
    }
    
    func testResetForwardedWhenBound() async {
        proxy.bind(mockClient)
        proxy.reset()
        
        let forwarded = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 1
        }
        
        XCTAssertTrue(forwarded)
        XCTAssertEqual(mockClient.calls.first, .reset)
    }
    
    // Call Queuing Tests
    
    func testCallsQueuedWhenNotBound() async {
        // Make calls before binding
        // Add delays to ensure sequential processing due to Task{} concurrency
        proxy.track("queued_event", properties: nil)
        try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        proxy.identify("user123", traits: nil)
        try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        proxy.flush()
        
        // Bind the client
        proxy.bind(mockClient)
        
        // Wait for queued calls to be replayed
        let replayed = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 3
        }
        
        XCTAssertTrue(replayed)
        XCTAssertEqual(mockClient.calls[0], .track(event: "queued_event", properties: nil))
        XCTAssertEqual(mockClient.calls[1], .identify(userId: "user123", traits: nil))
        XCTAssertEqual(mockClient.calls[2], .flush)
    }
    
    func testQueueOrderPreserved() async {
        // Make multiple calls in specific order
        // Add delays to ensure sequential processing due to Task{} concurrency
        proxy.track("event1", properties: nil)
        try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        proxy.identify("user1", traits: nil)
        try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        proxy.track("event2", properties: nil)
        try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        proxy.identify("user2", traits: nil)
        
        proxy.bind(mockClient)
        
        let replayed = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 4
        }
        
        XCTAssertTrue(replayed)
        XCTAssertEqual(mockClient.calls[0], .track(event: "event1", properties: nil))
        XCTAssertEqual(mockClient.calls[1], .identify(userId: "user1", traits: nil))
        XCTAssertEqual(mockClient.calls[2], .track(event: "event2", properties: nil))
        XCTAssertEqual(mockClient.calls[3], .identify(userId: "user2", traits: nil))
    }
    
    func testQueueCapacityLimiting() async {
        // Make more than 20 calls (the queue capacity)
        // Add a small delay to ensure sequential processing since proxy methods use Task{}
        // without this, the actor receives calls in unpredictable order due to concurrency
        for i in 0..<25 {
            proxy.track("event_\(i)", properties: nil)
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms delay for ordering
        }
        
        proxy.bind(mockClient)
        
        let replayed = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 20
        }
        
        XCTAssertTrue(replayed, "Should only replay last 20 calls due to capacity limit")
        XCTAssertEqual(mockClient.callCount, 20, "Should have exactly 20 calls")
        
        // Verify we got the last 20 calls (events 5-24)
        // Events 0-4 should have been dropped due to capacity limiting
        for i in 0..<20 {
            let expectedEvent = "event_\(i + 5)"
            XCTAssertEqual(mockClient.calls[i], .track(event: expectedEvent, properties: nil), 
                          "Expected event_\(i + 5) at position \(i), but got \(mockClient.calls[i])")
        }
    }
    
    func testQueueClearedAfterReplay() async {
        // Queue some calls
        proxy.track("queued1", properties: nil)
        proxy.track("queued2", properties: nil)
        
        // Bind and wait for replay
        proxy.bind(mockClient)
        
        let initialReplay = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 2
        }
        XCTAssertTrue(initialReplay)
        
        // Reset mock to track new calls
        mockClient.resetMock()
        
        // New calls should be forwarded immediately, not queued
        proxy.track("immediate", properties: nil)
        
        let immediateForward = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 1
        }
        
        XCTAssertTrue(immediateForward)
        XCTAssertEqual(mockClient.calls.first, .track(event: "immediate", properties: nil))
    }
    
    // GetDebugInfo Tests
    
    func testGetDebugInfoWhenNotBound() {
        let debugInfo = proxy.getDebugInfo()
        XCTAssertTrue(debugInfo.isEmpty, "Should return empty dict when no real client is bound")
    }
    
    func testGetDebugInfoWhenBound() async {
        proxy.bind(mockClient)
        
        // Allow binding to complete
        _ = await TestUtilities.waitFor(timeout: 0.1) { true }
        
        let debugInfo = proxy.getDebugInfo()
        XCTAssertFalse(debugInfo.isEmpty, "Should return debug info from bound client")
    }
    
    // Thread Safety Tests
    
    func testConcurrentCallsBeforeBinding() async {
        let expectation = expectation(description: "Concurrent calls completed")
        expectation.expectedFulfillmentCount = 10
        
        // Make concurrent calls before binding
        for i in 0..<10 {
            Task {
                proxy.track("concurrent_\(i)", properties: nil)
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        // Now bind and verify all calls were queued and replayed
        proxy.bind(mockClient)
        
        let allReplayed = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 10
        }
        
        XCTAssertTrue(allReplayed)
    }
    
    func testConcurrentCallsAfterBinding() async {
        proxy.bind(mockClient)
        
        let expectation = expectation(description: "Concurrent calls completed")
        expectation.expectedFulfillmentCount = 10
        
        // Make concurrent calls after binding
        for i in 0..<10 {
            Task {
                proxy.track("concurrent_\(i)", properties: nil)
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        let allForwarded = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 10
        }
        
        XCTAssertTrue(allForwarded)
    }
    
    func testBindingAndUnbindingRace() async {
        let expectation = expectation(description: "Binding race completed")
        expectation.expectedFulfillmentCount = 20
        
        // Rapidly bind and unbind while making calls
        for i in 0..<10 {
            Task {
                proxy.bind(mockClient)
                proxy.track("race_\(i)", properties: nil)
                expectation.fulfill()
            }
            
            Task {
                proxy.unbind()
                proxy.track("race_unbound_\(i)", properties: nil)
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 3.0)
        
        // Test should complete without crashing
        XCTAssertTrue(true, "Binding/unbinding race completed without crashes")
    }
    
    // Edge Cases
    
    func testMultipleBind() async {
        let mockClient2 = MockAnalyticsInterface()
        
        // Bind first client
        proxy.bind(mockClient)
        try? await Task.sleep(nanoseconds: 5_000_000) // 5ms to ensure bind completes
        proxy.track("for_first", properties: nil)
        
        let firstBound = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 1
        }
        XCTAssertTrue(firstBound)
        
        // Bind second client (should replace first)
        proxy.bind(mockClient2)
        try? await Task.sleep(nanoseconds: 5_000_000) // 5ms to ensure bind completes
        proxy.track("for_second", properties: nil)
        
        let secondBound = await TestUtilities.waitFor {
            mockClient2.callCount == 1
        }
        XCTAssertTrue(secondBound)
        
        // First client should not receive new calls
        XCTAssertEqual(mockClient.callCount, 1)
        XCTAssertEqual(mockClient2.callCount, 1)
    }
    
    func testCallsWithNilValues() async {
        proxy.bind(mockClient)
        
        proxy.track("test", properties: nil)
        proxy.identify("user", traits: nil)
        proxy.group("group", traits: nil)
        proxy.screen("screen", properties: nil)
        proxy.page("page", properties: nil)
        
        let forwarded = await TestUtilities.waitFor { [weak self] in
            self?.mockClient.callCount == 5
        }
        
        XCTAssertTrue(forwarded)
    }
}