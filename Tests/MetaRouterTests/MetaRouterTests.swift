import XCTest
@testable import MetaRouter

/// Main test file for basic MetaRouter functionality and smoke tests
final class MetaRouterTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        MetaRouter.Analytics.reset()
    }
    
    override func tearDown() {
        MetaRouter.Analytics.reset()
        super.tearDown()
    }
    
    // Smoke Tests
    
    func testMetaRouterCanBeImported() {
        // Simple smoke test to verify the module can be imported
        XCTAssertTrue(true, "MetaRouter module imported successfully")
    }
    
    func testBasicInitialization() {
        let options = InitOptions(writeKey: "test-key", ingestionHost: "https://test.com")
        let client = MetaRouter.Analytics.initialize(with: options)
        
        XCTAssertNotNil(client)
    }
    
    func testBasicTrackingCall() {
        let options = InitOptions(writeKey: "test-key", ingestionHost: "https://test.com")
        let client = MetaRouter.Analytics.initialize(with: options)
        
        // Should not crash
        client.track("test_event", properties: nil)
        XCTAssertTrue(true, "Basic tracking call completed")
    }
    
    func testClientAndProxyAreConnected() {
        let options = InitOptions(writeKey: "test-key", ingestionHost: "https://test.com")
        
        let initialProxy = MetaRouter.Analytics.client()
        let afterInit = MetaRouter.Analytics.initialize(with: options)
        let againProxy = MetaRouter.Analytics.client()
        
        XCTAssertTrue(initialProxy === afterInit, "Initialize should return same proxy")
        XCTAssertTrue(afterInit === againProxy, "Client should return same proxy")
    }
    
    func testGlobalDebugLoggingSetting() {
        MetaRouter.Analytics.setDebugLogging(true)
        MetaRouter.Analytics.setDebugLogging(false)
        
        // Should not crash
        XCTAssertTrue(true, "Global debug logging setting works")
    }
}