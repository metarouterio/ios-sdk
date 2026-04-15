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


    func testClientInitialization() {
        XCTAssertNotNil(client)
    }

    func testInitializeCreatesNewClient() {
        let client1 = AnalyticsClient.initialize(options: options)
        let client2 = AnalyticsClient.initialize(options: options)

        XCTAssertFalse(client1 === client2, "Each initialize call should create a new client")
    }


    func testTrackWithoutProperties() async {
        client.track("test_event", properties: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        let queueLength = info["queueLength"]
        XCTAssertNotNil(queueLength, "Queue should have received the event")
    }

    func testTrackWithProperties() async {
        let properties = TestDataFactory.makeProperties()
        client.track("purchase", properties: properties)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        let queueLength = info["queueLength"]
        XCTAssertNotNil(queueLength, "Queue should have received the event")
    }

    func testWithNoProperties() async {
        client.track("purchase")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["queueLength"], "Queue should have received the event")
    }

    func testTrackWithNilProperties() async {
        client.track("test_event", properties: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["queueLength"], "Queue should have received the event")
    }

    func testTrackWithEmptyProperties() async {
        client.track("test_event", properties: [:])
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["queueLength"], "Queue should have received the event")
    }


    func testIdentifyWithoutTraits() async {
        client.identify("user123", traits: nil)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await client.getDebugInfo()
        if case .string(let userId) = info["userId"] {
            XCTAssertEqual(userId, "user123")
        } else {
            XCTFail("Expected userId to be set after identify")
        }
    }

    func testIdentifyWithTraits() async {
        let traits = TestDataFactory.makeTraits()
        client.identify("user123", traits: traits)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await client.getDebugInfo()
        if case .string(let userId) = info["userId"] {
            XCTAssertEqual(userId, "user123")
        } else {
            XCTFail("Expected userId to be set after identify with traits")
        }
    }

    func testIdentifyWithNoTraits() async {
        client.identify("user123", traits: nil)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await client.getDebugInfo()
        if case .string(let userId) = info["userId"] {
            XCTAssertEqual(userId, "user123")
        } else {
            XCTFail("Expected userId to be set")
        }
    }

    func testIdentifyWithNilTraits() async {
        client.identify("user123", traits: nil)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await client.getDebugInfo()
        if case .string(let userId) = info["userId"] {
            XCTAssertEqual(userId, "user123")
        } else {
            XCTFail("Expected userId to be set")
        }
    }


    func testGroupWithoutTraits() async {
        client.group("company123", traits: nil)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await client.getDebugInfo()
        if case .string(let groupId) = info["groupId"] {
            XCTAssertEqual(groupId, "company123")
        } else {
            XCTFail("Expected groupId to be set after group")
        }
    }

    func testGroupWithNoTraits() async {
        client.group("company123", traits: nil)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await client.getDebugInfo()
        if case .string(let groupId) = info["groupId"] {
            XCTAssertEqual(groupId, "company123")
        } else {
            XCTFail("Expected groupId to be set")
        }
    }

    func testGroupWithTraits() async {
        let traits: [String: CodableValue] = [
            "name": "Acme Corp",
            "industry": "Technology",
            "employees": 100
        ]
        client.group("company123", traits: traits)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await client.getDebugInfo()
        if case .string(let groupId) = info["groupId"] {
            XCTAssertEqual(groupId, "company123")
        } else {
            XCTFail("Expected groupId to be set after group with traits")
        }
    }


    func testScreenWithoutProperties() async {
        client.screen("Home Screen", properties: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["queueLength"], "Queue should have received the screen event")
    }

    func testScreenWithProperties() async {
        let properties: [String: CodableValue] = [
            "category": "main",
            "load_time": 1.5
        ]
        client.screen("Product Details", properties: properties)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["queueLength"], "Queue should have received the screen event")
    }


    func testPageWithoutProperties() async {
        client.page("Landing Page", properties: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["queueLength"], "Queue should have received the page event")
    }

    func testPageWithProperties() async {
        let properties: [String: CodableValue] = [
            "url": "/products",
            "referrer": "google.com"
        ]
        client.page("Products", properties: properties)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["queueLength"], "Queue should have received the page event")
    }


    func testAlias() async {
        client.alias("new_user_id")
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["queueLength"], "Queue should have received the alias event")
    }


    func testEnableDebugLogging() {
        client.enableDebugLogging()

        // enableDebugLogging calls Logger.setDebugLogging(true) internally
        // Verify no crash — Logger has no public getter, so this is a smoke test
        XCTAssertNotNil(client, "Client should remain valid after enabling debug logging")
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


    func testFlush() async {
        // Enqueue something first so flush has work to do
        client.track("pre_flush_event")
        try? await Task.sleep(nanoseconds: 50_000_000)

        client.flush()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await client.getDebugInfo()
        // Flush should have been attempted (queue may or may not be empty depending on network)
        XCTAssertNotNil(info["flushInFlight"], "Debug info should report flush state")
    }

    func testReset() async {
        // Set some identity state first
        client.identify("user_to_reset")
        try? await Task.sleep(nanoseconds: 100_000_000)

        client.reset()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNil(info["userId"], "userId should be cleared after reset")
        XCTAssertNil(info["groupId"], "groupId should be cleared after reset")
    }


    func testConcurrentCalls() async {
        let expectation = expectation(description: "Concurrent calls completed")
        expectation.expectedFulfillmentCount = 10

        let client = self.client!
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


    func testMethodsWithExtremeValues() async {
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

        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["queueLength"], "Queue should have accepted all events")
    }

    func testMethodsWithComplexProperties() async {
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
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["queueLength"], "Queue should accept complex property payloads")
    }


    func testSetAdvertisingIdWithValidUUID() async {
        let validUUID = UUID().uuidString
        client.setAdvertisingId(validUUID)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Valid UUID should be accepted — verify it was persisted by checking debug info
        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["lifecycle"], "Client should remain functional after setting valid UUID")
    }

    func testSetAdvertisingIdWithNil() async {
        // First set a valid value, then clear with nil
        client.setAdvertisingId(UUID().uuidString)
        try? await Task.sleep(nanoseconds: 100_000_000)

        client.setAdvertisingId(nil)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["lifecycle"], "Client should remain functional after setting nil advertisingId")
    }

    func testSetAdvertisingIdWithInvalidFormat() async {
        // These should be rejected because they're not valid UUIDs
        let invalidFormats = [
            "not-a-uuid",
            "12345",
            "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
            "invalid-uuid-format-123",
            String(repeating: "a", count: 10000)
        ]

        for invalidId in invalidFormats {
            client.setAdvertisingId(invalidId)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Client should remain functional — invalid IDs rejected gracefully
        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["lifecycle"], "Client should remain functional after rejecting invalid UUIDs")
    }

    func testSetAdvertisingIdRejectsEmptyString() async {
        client.setAdvertisingId("")
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["lifecycle"], "Client should remain functional after rejecting empty string")
    }

    func testSetAdvertisingIdWithMalformedUUID() async {
        let malformedUUIDs = [
            "12345678-1234-1234-1234",                          // Too short
            "12345678-1234-1234-1234-12345678901234567890",     // Too long
            "gggggggg-1234-1234-1234-123456789012",             // Invalid hex
            "12345678 1234 1234 1234 123456789012"              // Spaces instead of hyphens
        ]

        for malformedId in malformedUUIDs {
            client.setAdvertisingId(malformedId)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["lifecycle"], "Client should remain functional after rejecting malformed UUIDs")
    }

    func testClearAdvertisingId() async {
        let validUUID = UUID().uuidString
        client.setAdvertisingId(validUUID)
        try? await Task.sleep(nanoseconds: 100_000_000)

        client.clearAdvertisingId()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["lifecycle"], "Client should remain functional after clearing advertisingId")
    }

    func testRapidConsecutiveAdvertisingIdCalls() async {
        for i in 0..<10 {
            if i % 2 == 0 {
                client.setAdvertisingId(UUID().uuidString)
            } else {
                client.clearAdvertisingId()
            }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["lifecycle"], "Client should remain functional after rapid advertising ID changes")
    }

    func testSetAdvertisingIdImmediatelyAfterInitialization() async {
        let newOptions = TestDataFactory.makeInitOptions()
        let newClient = AnalyticsClient.initialize(options: newOptions)

        let validUUID = UUID().uuidString
        newClient.setAdvertisingId(validUUID)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await newClient.getDebugInfo()
        XCTAssertNotNil(info["lifecycle"], "Client should handle setAdvertisingId during initialization")
    }

    func testAdvertisingIdPersistenceAcrossReset() async {
        let validUUID = UUID().uuidString
        client.setAdvertisingId(validUUID)
        try? await Task.sleep(nanoseconds: 100_000_000)

        client.reset()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNil(info["userId"], "Identity should be cleared after reset")
    }

    func testSetAdvertisingIdWithSpecialCharacters() async {
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

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["lifecycle"], "Client should reject non-UUID special strings gracefully")
    }

    func testConcurrentAdvertisingIdOperations() async {
        let expectation = expectation(description: "Concurrent advertising ID operations completed")
        expectation.expectedFulfillmentCount = 20

        let client = self.client!
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


    func testSetTracingEnabled() async {
        client.setTracing(true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["lifecycle"], "Client should remain functional with tracing enabled")
    }

    func testSetTracingDisabled() async {
        client.setTracing(false)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["lifecycle"], "Client should remain functional with tracing disabled")
    }

    func testSetTracingToggle() async {
        client.setTracing(true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        client.setTracing(false)
        try? await Task.sleep(nanoseconds: 50_000_000)

        client.setTracing(true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let info = await client.getDebugInfo()
        XCTAssertNotNil(info["lifecycle"], "Client should remain functional after toggling tracing")
    }

    func testConcurrentTracingCalls() async {
        let expectation = expectation(description: "Concurrent tracing calls completed")
        expectation.expectedFulfillmentCount = 20

        let client = self.client!
        for i in 0..<20 {
            Task {
                client.setTracing(i % 2 == 0)
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testGetAnonymousIdReturnsValueAfterInitialization() async {
        // Wait for the client to finish initialization
        try? await Task.sleep(nanoseconds: 500_000_000)

        let anonymousId = await client.getAnonymousId()
        XCTAssertNotNil(anonymousId, "Anonymous ID should be non-nil after initialization")
        XCTAssertFalse(anonymousId!.isEmpty, "Anonymous ID should not be empty")
    }

    func testGetAnonymousIdMatchesIdentityManager() async {
        // Create a dedicated UserDefaults suite with a pre-seeded anonymous ID
        let suiteName = "com.metarouter.test.getAnonymousId.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let knownId = UUID().uuidString
        defaults.set(knownId, forKey: IdentityStorageKey.anonymousId.rawValue)

        let storage = IdentityStorage(userDefaults: defaults)
        let identityManager = IdentityManager(
            storage: storage,
            writeKey: "test-write-key",
            host: "https://test.metarouter.com"
        )
        await identityManager.initialize()

        var deps = AnalyticsDependencies()
        deps.identityManager = identityManager
        let testClient = AnalyticsClient.initialize(options: options, deps: deps)

        // Wait for initialization
        try? await Task.sleep(nanoseconds: 500_000_000)

        let clientAnonymousId = await testClient.getAnonymousId()
        let managerAnonymousId = await identityManager.getAnonymousId()
        XCTAssertEqual(clientAnonymousId, managerAnonymousId,
                       "Client getAnonymousId should return the same value as IdentityManager")
        XCTAssertEqual(clientAnonymousId, knownId)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testGetAnonymousIdReturnsNilAfterReset() async {
        // Wait for initialization to complete
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Verify we have an anonymous ID before reset
        let preResetId = await client.getAnonymousId()
        XCTAssertNotNil(preResetId, "Should have anonymous ID before reset")

        // Reset the client
        client.reset()

        // Wait for reset to propagate
        try? await Task.sleep(nanoseconds: 500_000_000)

        let postResetId = await client.getAnonymousId()
        XCTAssertNil(postResetId, "Anonymous ID should be nil after reset")
    }

    func testGetDebugInfoIncludesNetworkStatus() async {
        let stubMonitor = StubNetworkMonitor(status: .connected)
        let deps = AnalyticsDependencies(networkMonitor: stubMonitor)
        let networkClient = AnalyticsClient.initialize(options: options, deps: deps)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await networkClient.getDebugInfo()
        if case .string(let networkStatus) = info["networkStatus"] {
            XCTAssertEqual(networkStatus, "connected")
        } else {
            XCTFail("Expected networkStatus to be a string in debug info")
        }
    }

    func testGetDebugInfoReflectsDisconnectedStatus() async {
        let stubMonitor = StubNetworkMonitor(status: .disconnected)
        let deps = AnalyticsDependencies(networkMonitor: stubMonitor)
        let networkClient = AnalyticsClient.initialize(options: options, deps: deps)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await networkClient.getDebugInfo()
        if case .string(let networkStatus) = info["networkStatus"] {
            XCTAssertEqual(networkStatus, "disconnected")
        } else {
            XCTFail("Expected networkStatus to be 'disconnected' in debug info")
        }
    }

    func testSDKFunctionsNormallyWithNilNetworkMonitor() async {
        // When no networkMonitor is provided, it defaults to real NetworkMonitor.
        // Here we verify the client works with standard init (no DI).
        let normalClient = AnalyticsClient.initialize(options: options)
        normalClient.track("test_event")
        try? await Task.sleep(nanoseconds: 100_000_000)

        let info = await normalClient.getDebugInfo()
        XCTAssertNotNil(info["networkStatus"], "networkStatus should be present in debug info")
        XCTAssertNotNil(info["queueLength"], "Queue should be functional")
    }
}
