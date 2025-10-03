import XCTest
@testable import MetaRouter

final class IdentityManagerTests: XCTestCase {
    
    var identityManager: IdentityManager!
    var testStorage: IdentityStorage!
    var testDefaults: UserDefaults!
    var suiteName: String!
    
    override func setUp() async throws {
        try await super.setUp()
        // Use a test-specific UserDefaults suite
        suiteName = "com.metarouter.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        testStorage = IdentityStorage(userDefaults: testDefaults)
        identityManager = IdentityManager(
            storage: testStorage,
            writeKey: "test-key",
            host: "https://test.com"
        )
    }
    
    override func tearDown() {
        // Clean up
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        testStorage = nil
        identityManager = nil
        suiteName = nil
        super.tearDown()
    }
    
    
    func testInitializeGeneratesAnonymousIdIfNoneExists() async {
        await identityManager.initialize()
        
        let anonymousId = await identityManager.getAnonymousId()
        XCTAssertNotNil(anonymousId)
        XCTAssertFalse(anonymousId!.isEmpty)
    }
    
    func testInitializeGeneratesValidUUID() async {
        await identityManager.initialize()
        
        let anonymousId = await identityManager.getAnonymousId()
        XCTAssertNotNil(anonymousId)
        
        // UUID should be lowercase and valid format
        let uuid = UUID(uuidString: anonymousId!.uppercased())
        XCTAssertNotNil(uuid, "Anonymous ID should be a valid UUID")
    }
    
    func testInitializeLoadsExistingAnonymousId() async {
        // Pre-populate storage
        let existingId = "existing-anon-id"
        testStorage.set(.anonymousId, value: existingId)
        
        await identityManager.initialize()
        
        let loadedId = await identityManager.getAnonymousId()
        XCTAssertEqual(loadedId, existingId)
    }
    
    func testInitializeLoadsExistingUserId() async {
        // Pre-populate storage
        testStorage.set(.anonymousId, value: "anon-123")
        testStorage.set(.userId, value: "user-456")
        
        await identityManager.initialize()
        
        let userId = await identityManager.getUserId()
        XCTAssertEqual(userId, "user-456")
    }
    
    func testInitializeLoadsExistingGroupId() async {
        // Pre-populate storage
        testStorage.set(.anonymousId, value: "anon-123")
        testStorage.set(.groupId, value: "group-789")
        
        await identityManager.initialize()
        
        let groupId = await identityManager.getGroupId()
        XCTAssertEqual(groupId, "group-789")
    }
    
    func testInitializePersistsGeneratedAnonymousId() async {
        await identityManager.initialize()
        
        let anonymousId = await identityManager.getAnonymousId()
        
        // Verify it's persisted in storage
        let storedId = testStorage.get(.anonymousId)
        XCTAssertEqual(storedId, anonymousId)
    }
    
    
    func testIdentifySetsUserId() async {
        await identityManager.initialize()
        
        await identityManager.identify("user-123")
        
        let userId = await identityManager.getUserId()
        XCTAssertEqual(userId, "user-123")
    }
    
    func testIdentifyPersistsUserId() async {
        await identityManager.initialize()
        
        await identityManager.identify("user-456")
        
        // Verify persistence
        let storedUserId = testStorage.get(.userId)
        XCTAssertEqual(storedUserId, "user-456")
    }
    
    func testIdentifyOverwritesPreviousUserId() async {
        await identityManager.initialize()
        
        await identityManager.identify("user-old")
        await identityManager.identify("user-new")
        
        let userId = await identityManager.getUserId()
        XCTAssertEqual(userId, "user-new")
    }
    
    func testIdentifyWithEmptyString() async {
        await identityManager.initialize()
        
        await identityManager.identify("")
        
        let userId = await identityManager.getUserId()
        XCTAssertEqual(userId, "")
    }
    
    
    func testGroupSetsGroupId() async {
        await identityManager.initialize()
        
        await identityManager.group("group-abc")
        
        let groupId = await identityManager.getGroupId()
        XCTAssertEqual(groupId, "group-abc")
    }
    
    func testGroupPersistsGroupId() async {
        await identityManager.initialize()
        
        await identityManager.group("group-xyz")
        
        // Verify persistence
        let storedGroupId = testStorage.get(.groupId)
        XCTAssertEqual(storedGroupId, "group-xyz")
    }
    
    func testGroupOverwritesPreviousGroupId() async {
        await identityManager.initialize()
        
        await identityManager.group("group-old")
        await identityManager.group("group-new")
        
        let groupId = await identityManager.getGroupId()
        XCTAssertEqual(groupId, "group-new")
    }
    
    
    func testGetIdentityInfoReturnsAllFields() async {
        await identityManager.initialize()
        await identityManager.identify("user-123")
        await identityManager.group("group-456")
        
        let identity = await identityManager.getIdentityInfo()
        
        XCTAssertFalse(identity.anonymousId.isEmpty)
        XCTAssertEqual(identity.userId, "user-123")
        XCTAssertEqual(identity.groupId, "group-456")
    }
    
    func testGetIdentityInfoWithOnlyAnonymousId() async {
        await identityManager.initialize()
        
        let identity = await identityManager.getIdentityInfo()
        
        XCTAssertFalse(identity.anonymousId.isEmpty)
        XCTAssertNil(identity.userId)
        XCTAssertNil(identity.groupId)
    }
    
    func testGetIdentityInfoBeforeInitialize() async {
        // Don't call initialize()
        let identity = await identityManager.getIdentityInfo()
        
        // Should return "unknown" for anonymousId if not initialized
        XCTAssertEqual(identity.anonymousId, "unknown")
        XCTAssertNil(identity.userId)
        XCTAssertNil(identity.groupId)
    }
    
    
    func testResetClearsAnonymousId() async {
        await identityManager.initialize()
        
        let beforeReset = await identityManager.getAnonymousId()
        XCTAssertNotNil(beforeReset)
        
        await identityManager.reset()
        
        let afterReset = await identityManager.getAnonymousId()
        XCTAssertNil(afterReset)
    }
    
    func testResetClearsUserId() async {
        await identityManager.initialize()
        await identityManager.identify("user-123")
        
        let beforeReset = await identityManager.getUserId()
        XCTAssertNotNil(beforeReset)
        
        await identityManager.reset()
        
        let afterReset = await identityManager.getUserId()
        XCTAssertNil(afterReset)
    }
    
    func testResetClearsGroupId() async {
        await identityManager.initialize()
        await identityManager.group("group-456")
        
        let beforeReset = await identityManager.getGroupId()
        XCTAssertNotNil(beforeReset)
        
        await identityManager.reset()
        
        let afterReset = await identityManager.getGroupId()
        XCTAssertNil(afterReset)
    }
    
    func testResetClearsPersistentStorage() async {
        await identityManager.initialize()
        await identityManager.identify("user-123")
        await identityManager.group("group-456")
        
        await identityManager.reset()
        
        // Verify storage is cleared
        XCTAssertNil(testStorage.get(.anonymousId))
        XCTAssertNil(testStorage.get(.userId))
        XCTAssertNil(testStorage.get(.groupId))
    }
    
    func testResetIsIdempotent() async {
        await identityManager.initialize()
        
        // Reset multiple times
        await identityManager.reset()
        await identityManager.reset()
        await identityManager.reset()
        
        // Should all be nil
        let anonymousId = await identityManager.getAnonymousId()
        let userId = await identityManager.getUserId()
        let groupId = await identityManager.getGroupId()
        
        XCTAssertNil(anonymousId)
        XCTAssertNil(userId)
        XCTAssertNil(groupId)
    }
    
    func testGetIdentityInfoAfterReset() async {
        await identityManager.initialize()
        await identityManager.identify("user-123")
        
        await identityManager.reset()
        
        let identity = await identityManager.getIdentityInfo()
        
        // Should return "unknown" after reset
        XCTAssertEqual(identity.anonymousId, "unknown")
        XCTAssertNil(identity.userId)
        XCTAssertNil(identity.groupId)
    }
    
    
    func testReinitializeAfterResetGeneratesNewAnonymousId() async {
        await identityManager.initialize()
        
        let firstId = await identityManager.getAnonymousId()
        
        await identityManager.reset()
        await identityManager.initialize()
        
        let secondId = await identityManager.getAnonymousId()
        
        XCTAssertNotNil(secondId)
        XCTAssertNotEqual(firstId, secondId, "Should generate new anonymous ID after reset")
    }
    
    func testReinitializeDoesNotRestoreOldIdentities() async {
        await identityManager.initialize()
        await identityManager.identify("user-old")
        await identityManager.group("group-old")
        
        await identityManager.reset()
        await identityManager.initialize()
        
        // Should not restore old userId/groupId
        let userId = await identityManager.getUserId()
        let groupId = await identityManager.getGroupId()
        
        XCTAssertNil(userId)
        XCTAssertNil(groupId)
    }
    
    
    func testConcurrentIdentifyCalls() async {
        await identityManager.initialize()
        
        // Make multiple concurrent identify calls
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await self.identityManager.identify("user-\(i)")
                }
            }
        }
        
        // Should have one of the userIds
        let userId = await identityManager.getUserId()
        XCTAssertNotNil(userId)
        XCTAssertTrue(userId!.starts(with: "user-"))
    }
    
    func testConcurrentGroupCalls() async {
        await identityManager.initialize()
        
        // Make multiple concurrent group calls
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await self.identityManager.group("group-\(i)")
                }
            }
        }
        
        // Should have one of the groupIds
        let groupId = await identityManager.getGroupId()
        XCTAssertNotNil(groupId)
        XCTAssertTrue(groupId!.starts(with: "group-"))
    }
    
    func testConcurrentGetIdentityInfoCalls() async {
        await identityManager.initialize()
        await identityManager.identify("user-123")
        
        // Make multiple concurrent reads
        let results = await withTaskGroup(of: (String, String?, String?).self) { group in
            for _ in 0..<10 {
                group.addTask {
                    return await self.identityManager.getIdentityInfo()
                }
            }
            
            var allResults: [(String, String?, String?)] = []
            for await result in group {
                allResults.append(result)
            }
            return allResults
        }
        
        // All reads should return same values
        XCTAssertEqual(results.count, 10)
        for result in results {
            XCTAssertEqual(result.1, "user-123")
        }
    }
    
    
    func testIdentifyWithSpecialCharacters() async {
        await identityManager.initialize()
        
        let specialUserId = "user@example.com!#$%"
        await identityManager.identify(specialUserId)
        
        let userId = await identityManager.getUserId()
        XCTAssertEqual(userId, specialUserId)
    }
    
    func testGroupWithUnicodeCharacters() async {
        await identityManager.initialize()
        
        let unicodeGroupId = "团队-123-🎉"
        await identityManager.group(unicodeGroupId)
        
        let groupId = await identityManager.getGroupId()
        XCTAssertEqual(groupId, unicodeGroupId)
    }
    
    func testMultipleInitializeCalls() async {
        // Initialize multiple times
        await identityManager.initialize()
        let firstId = await identityManager.getAnonymousId()
        
        await identityManager.initialize()
        let secondId = await identityManager.getAnonymousId()
        
        await identityManager.initialize()
        let thirdId = await identityManager.getAnonymousId()
        
        // Should keep the same ID (don't regenerate on re-initialize)
        XCTAssertEqual(firstId, secondId)
        XCTAssertEqual(secondId, thirdId)
    }
    
    
    func testIdentityPersistsAcrossManagerInstances() async {
        // Initialize first manager
        await identityManager.initialize()
        await identityManager.identify("user-persistent")
        
        let firstAnonymousId = await identityManager.getAnonymousId()
        
        // Create new manager with same storage
        let newManager = IdentityManager(
            storage: testStorage,
            writeKey: "test-key",
            host: "https://test.com"
        )
        
        await newManager.initialize()
        
        // Should load same identity
        let newAnonymousId = await newManager.getAnonymousId()
        let newUserId = await newManager.getUserId()
        
        XCTAssertEqual(newAnonymousId, firstAnonymousId)
        XCTAssertEqual(newUserId, "user-persistent")
    }
}

