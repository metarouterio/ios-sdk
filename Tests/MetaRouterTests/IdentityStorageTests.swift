import XCTest
@testable import MetaRouter

final class IdentityStorageTests: XCTestCase {
    
    var storage: IdentityStorage!
    var testDefaults: UserDefaults!
    var suiteName: String!
    
    override func setUp() {
        super.setUp()
        // Use a test-specific UserDefaults suite to avoid polluting real app defaults
        suiteName = "com.metarouter.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        storage = IdentityStorage(userDefaults: testDefaults)
    }
    
    override func tearDown() {
        // Clean up test suite
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        storage = nil
        suiteName = nil
        super.tearDown()
    }
    
    
    func testSetAndGetAnonymousId() {
        let testId = "test-anonymous-id"
        storage.set(.anonymousId, value: testId)
        
        let retrieved = storage.get(.anonymousId)
        XCTAssertEqual(retrieved, testId)
    }
    
    func testSetAndGetUserId() {
        let testId = "user-123"
        storage.set(.userId, value: testId)
        
        let retrieved = storage.get(.userId)
        XCTAssertEqual(retrieved, testId)
    }
    
    func testSetAndGetGroupId() {
        let testId = "group-456"
        storage.set(.groupId, value: testId)
        
        let retrieved = storage.get(.groupId)
        XCTAssertEqual(retrieved, testId)
    }
    
    func testGetNonExistentReturnsNil() {
        let retrieved = storage.get(.anonymousId)
        XCTAssertNil(retrieved)
    }
    
    func testRemoveAnonymousId() {
        storage.set(.anonymousId, value: "test-id")
        XCTAssertNotNil(storage.get(.anonymousId))
        
        storage.remove(.anonymousId)
        XCTAssertNil(storage.get(.anonymousId))
    }
    
    func testRemoveUserId() {
        storage.set(.userId, value: "user-123")
        XCTAssertNotNil(storage.get(.userId))
        
        storage.remove(.userId)
        XCTAssertNil(storage.get(.userId))
    }
    
    func testRemoveGroupId() {
        storage.set(.groupId, value: "group-456")
        XCTAssertNotNil(storage.get(.groupId))
        
        storage.remove(.groupId)
        XCTAssertNil(storage.get(.groupId))
    }
    
    
    func testClearRemovesAllIdentityFields() {
        // Set all fields
        storage.set(.anonymousId, value: "anon-123")
        storage.set(.userId, value: "user-456")
        storage.set(.groupId, value: "group-789")
        
        // Verify all are set
        XCTAssertNotNil(storage.get(.anonymousId))
        XCTAssertNotNil(storage.get(.userId))
        XCTAssertNotNil(storage.get(.groupId))
        
        // Clear
        storage.clear()
        
        // Verify all are removed
        XCTAssertNil(storage.get(.anonymousId))
        XCTAssertNil(storage.get(.userId))
        XCTAssertNil(storage.get(.groupId))
    }
    
    func testClearIsIdempotent() {
        storage.set(.anonymousId, value: "test-id")
        
        // Clear multiple times
        storage.clear()
        storage.clear()
        storage.clear()
        
        // Should still be nil
        XCTAssertNil(storage.get(.anonymousId))
    }
    
    
    func testStoragePersistsAcrossInstances() {
        let suiteName = "com.metarouter.tests.persistence"
        let defaults1 = UserDefaults(suiteName: suiteName)!
        let storage1 = IdentityStorage(userDefaults: defaults1)
        
        // Set value in first instance
        storage1.set(.anonymousId, value: "persistent-id")
        
        // Create new instance with same suite
        let defaults2 = UserDefaults(suiteName: suiteName)!
        let storage2 = IdentityStorage(userDefaults: defaults2)
        
        // Verify value persists
        XCTAssertEqual(storage2.get(.anonymousId), "persistent-id")
        
        // Cleanup
        defaults1.removePersistentDomain(forName: suiteName)
    }
    
    func testOverwriteExistingValue() {
        storage.set(.anonymousId, value: "old-id")
        XCTAssertEqual(storage.get(.anonymousId), "old-id")
        
        storage.set(.anonymousId, value: "new-id")
        XCTAssertEqual(storage.get(.anonymousId), "new-id")
    }
    
    
    func testStorageKeysAreCorrect() {
        XCTAssertEqual(IdentityStorageKey.anonymousId.rawValue, "metarouter:anonymous_id")
        XCTAssertEqual(IdentityStorageKey.userId.rawValue, "metarouter:user_id")
        XCTAssertEqual(IdentityStorageKey.groupId.rawValue, "metarouter:group_id")
    }
    
    func testStorageUsesCorrectKeys() {
        storage.set(.anonymousId, value: "test-value")
        
        // Verify it's stored under the correct key
        let directValue = testDefaults.string(forKey: "metarouter:anonymous_id")
        XCTAssertEqual(directValue, "test-value")
    }
    
    
    func testSetEmptyString() {
        storage.set(.anonymousId, value: "")
        XCTAssertEqual(storage.get(.anonymousId), "")
    }
    
    func testSetVeryLongString() {
        let longString = String(repeating: "a", count: 10000)
        storage.set(.anonymousId, value: longString)
        
        XCTAssertEqual(storage.get(.anonymousId), longString)
    }
    
    func testSetSpecialCharacters() {
        let specialString = "user@example.com!#$%^&*()"
        storage.set(.userId, value: specialString)
        
        XCTAssertEqual(storage.get(.userId), specialString)
    }
    
    func testSetUnicodeCharacters() {
        let unicodeString = "用户-123-🎉"
        storage.set(.userId, value: unicodeString)
        
        XCTAssertEqual(storage.get(.userId), unicodeString)
    }
}

