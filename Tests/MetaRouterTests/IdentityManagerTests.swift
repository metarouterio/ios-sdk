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
        
        // Mints and persists one rather than stamping a placeholder
        XCTAssertNotNil(UUID(uuidString: identity.anonymousId))
        XCTAssertEqual(testStorage.get(.anonymousId), identity.anonymousId)
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
    
    /// The first event after reset() mints and persists a new id; it never goes
    /// out as a placeholder.
    func testGetIdentityInfoAfterReset() async {
        await identityManager.initialize()
        await identityManager.identify("user-123")
        let before = await identityManager.getAnonymousId()
        
        await identityManager.reset()
        
        let identity = await identityManager.getIdentityInfo()
        
        XCTAssertNotEqual(identity.anonymousId, before)
        XCTAssertNotNil(UUID(uuidString: identity.anonymousId))
        XCTAssertEqual(testStorage.get(.anonymousId), identity.anonymousId)
        let next = await identityManager.getIdentityInfo()
        XCTAssertEqual(next.anonymousId, identity.anonymousId, "stable from then on")
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
        let manager = identityManager!
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await manager.identify("user-\(i)")
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
        let manager = identityManager!
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await manager.group("group-\(i)")
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
        let manager = identityManager!
        let results = await withTaskGroup(of: (String, String?, String?).self) { group in
            for _ in 0..<10 {
                group.addTask {
                    return await manager.getIdentityInfo()
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


    func testSetAdvertisingId() async {
        await identityManager.initialize()

        await identityManager.setAdvertisingId("TEST-ADVERTISING-ID")

        let advertisingId = await identityManager.getAdvertisingId()
        XCTAssertEqual(advertisingId, "TEST-ADVERTISING-ID")
    }

    func testSetAdvertisingIdPersistsToStorage() async {
        await identityManager.initialize()

        await identityManager.setAdvertisingId("PERSISTED-IDFA")

        // Verify persistence
        let storedId = testStorage.get(.advertisingId)
        XCTAssertEqual(storedId, "PERSISTED-IDFA")
    }

    func testSetAdvertisingIdToNilClearsValue() async {
        await identityManager.initialize()

        // First set a value
        await identityManager.setAdvertisingId("INITIAL-IDFA")
        let initialId = await identityManager.getAdvertisingId()
        XCTAssertNotNil(initialId)

        // Clear by setting to nil
        await identityManager.setAdvertisingId(nil)

        let advertisingId = await identityManager.getAdvertisingId()
        XCTAssertNil(advertisingId)

        // Verify storage is also cleared
        let storedId = testStorage.get(.advertisingId)
        XCTAssertNil(storedId)
    }

    func testClearAdvertisingId() async {
        await identityManager.initialize()

        // Set advertising ID
        await identityManager.setAdvertisingId("IDFA-TO-CLEAR")
        let initialId = await identityManager.getAdvertisingId()
        XCTAssertNotNil(initialId)

        // Clear it
        await identityManager.clearAdvertisingId()

        let advertisingId = await identityManager.getAdvertisingId()
        XCTAssertNil(advertisingId)
    }

    func testClearAdvertisingIdRemovesFromStorage() async {
        await identityManager.initialize()

        // Set and verify storage
        await identityManager.setAdvertisingId("STORED-IDFA")
        let storedIdBefore = testStorage.get(.advertisingId)
        XCTAssertNotNil(storedIdBefore)

        // Clear and verify removed from storage
        await identityManager.clearAdvertisingId()

        let storedId = testStorage.get(.advertisingId)
        XCTAssertNil(storedId)
    }

    func testClearAdvertisingIdForGDPRCompliance() async {
        await identityManager.initialize()

        // Simulate user consent
        await identityManager.setAdvertisingId("USER-CONSENTED-IDFA")
        let consentedId = await identityManager.getAdvertisingId()
        XCTAssertEqual(consentedId, "USER-CONSENTED-IDFA")

        // User withdraws consent - clear for GDPR compliance
        await identityManager.clearAdvertisingId()

        let advertisingId = await identityManager.getAdvertisingId()
        XCTAssertNil(advertisingId, "Advertising ID should be cleared for GDPR compliance")

        // Future events should not include advertising ID
        let identity = await identityManager.getIdentityInfo()
        XCTAssertNotNil(identity.anonymousId)
        let finalAdvertisingId = await identityManager.getAdvertisingId()
        XCTAssertNil(finalAdvertisingId)
    }

    func testClearAdvertisingIdIsIdempotent() async {
        await identityManager.initialize()

        await identityManager.setAdvertisingId("IDFA-VALUE")

        // Clear multiple times
        await identityManager.clearAdvertisingId()
        await identityManager.clearAdvertisingId()
        await identityManager.clearAdvertisingId()

        // Should remain nil
        let advertisingId = await identityManager.getAdvertisingId()
        XCTAssertNil(advertisingId)
    }

    func testClearAdvertisingIdDoesNotAffectOtherIdentities() async {
        await identityManager.initialize()
        await identityManager.identify("user-123")
        await identityManager.group("group-456")
        await identityManager.setAdvertisingId("IDFA-789")

        let anonymousIdBefore = await identityManager.getAnonymousId()

        // Clear advertising ID
        await identityManager.clearAdvertisingId()

        // Other identities should be unaffected
        let anonymousIdAfter = await identityManager.getAnonymousId()
        let userIdAfter = await identityManager.getUserId()
        let groupIdAfter = await identityManager.getGroupId()
        let advertisingIdAfter = await identityManager.getAdvertisingId()

        XCTAssertEqual(anonymousIdAfter, anonymousIdBefore)
        XCTAssertEqual(userIdAfter, "user-123")
        XCTAssertEqual(groupIdAfter, "group-456")
        XCTAssertNil(advertisingIdAfter)
    }

    func testInitializeLoadsExistingAdvertisingId() async {
        // Pre-populate storage with advertising ID
        testStorage.set(.anonymousId, value: "anon-123")
        testStorage.set(.advertisingId, value: "stored-idfa-456")

        await identityManager.initialize()

        let advertisingId = await identityManager.getAdvertisingId()
        XCTAssertEqual(advertisingId, "stored-idfa-456")
    }

    func testResetClearsAdvertisingId() async {
        await identityManager.initialize()
        await identityManager.setAdvertisingId("IDFA-TO-RESET")

        let beforeReset = await identityManager.getAdvertisingId()
        XCTAssertNotNil(beforeReset)

        await identityManager.reset()

        let afterReset = await identityManager.getAdvertisingId()
        XCTAssertNil(afterReset)

        // Verify storage is cleared
        XCTAssertNil(testStorage.get(.advertisingId))
    }

    // MARK: - setAnonymousId

    func testSetAnonymousIdIsReadYourWrites() async {
        await identityManager.initialize()

        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))

        let current = await identityManager.getAnonymousId()
        let info = await identityManager.getIdentityInfo()
        let created = await identityManager.getOrCreateAnonymousId()
        XCTAssertEqual(current, "web-anon-1")
        XCTAssertEqual(info.anonymousId, "web-anon-1")
        XCTAssertEqual(created, "web-anon-1")
        XCTAssertEqual(testStorage.get(.anonymousId), "web-anon-1")
    }

    func testSetAnonymousIdTrims() async {
        XCTAssertTrue(identityManager.setAnonymousId("  web-anon-1\n"))
        let current = await identityManager.getAnonymousId()
        XCTAssertEqual(current, "web-anon-1")
    }

    func testSetAnonymousIdRejectsBlankAndOversizeLeavingIdUnchanged() async {
        await identityManager.initialize()
        let before = await identityManager.getAnonymousId()

        XCTAssertFalse(identityManager.setAnonymousId(""))
        XCTAssertFalse(identityManager.setAnonymousId(" \t\n"))
        XCTAssertFalse(identityManager.setAnonymousId(String(repeating: "a", count: 257)))
        XCTAssertTrue(identityManager.setAnonymousId(String(repeating: "a", count: 256)), "the limit itself is accepted")

        XCTAssertNotNil(before)
        XCTAssertFalse(testStorage.hasHostSetMarker, "rejections never mark the device")
    }

    func testSetAnonymousIdSameValueIsANoOpReturningTrue() async {
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))
        testStorage.clearHostSetMarker()

        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))
        XCTAssertFalse(testStorage.hasHostSetMarker, "an unchanged id writes nothing")
    }

    /// Before `initialize`, the host id must win over minting: the launch's first
    /// events would otherwise carry a throwaway id.
    func testInitializeAdoptsHostAnonymousIdSetBeforehand() async {
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))

        await identityManager.initialize()

        let current = await identityManager.getAnonymousId()
        XCTAssertEqual(current, "web-anon-1")
    }

    /// The proxy writes through its own storage instance while a client's manager
    /// may already hold an id in memory (created, not yet bound). The manager must
    /// pick the write up on its next read.
    func testWriteThroughAnotherStorageInstanceReachesAnInitializedManager() async {
        await identityManager.initialize()

        let proxySide = IdentityStorage(userDefaults: testDefaults)
        XCTAssertTrue(IdentityManager.apply(hostAnonymousId: "web-anon-1", to: proxySide))

        let info = await identityManager.getIdentityInfo()
        XCTAssertEqual(info.anonymousId, "web-anon-1")
    }

    func testMarkerWrittenOnlyWhenNoAnonymousIdExisted() async {
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))
        XCTAssertTrue(testStorage.hasHostSetMarker)
        XCTAssertFalse(testStorage.hasAnyValue(), "a host id on a fresh device is not prior identity")

        let other = IdentityStorage(userDefaults: UserDefaults(suiteName: suiteName + ".existing")!)
        defer { UserDefaults().removePersistentDomain(forName: suiteName + ".existing") }
        other.set(.anonymousId, value: "sdk-anon")
        XCTAssertTrue(IdentityManager.apply(hostAnonymousId: "web-anon-1", to: other))
        XCTAssertFalse(other.hasHostSetMarker)
        XCTAssertTrue(other.hasAnyValue())
    }

    /// The marker only has to survive until install detection has read it, which
    /// happens before initialize. Left in place, a later launch that first enables
    /// lifecycle tracking would report a long-standing device as a new install.
    func testInitializeEndsTheHostSetMarkerWindow() async {
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))
        XCTAssertFalse(testStorage.hasAnyValue())

        await identityManager.initialize()

        XCTAssertFalse(testStorage.hasHostSetMarker)
        XCTAssertTrue(testStorage.hasAnyValue())
        let current = await identityManager.getAnonymousId()
        XCTAssertEqual(current, "web-anon-1")
    }

    func testHostSetMarkerDoesNotHideOtherIdentity() async {
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))
        await identityManager.identify("user-1")
        XCTAssertTrue(testStorage.hasAnyValue())
    }

    func testResetDiscardsHostAnonymousIdAndMintsANewOne() async {
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))
        await identityManager.initialize()

        identityManager.noteResetRequested()
        await identityManager.reset()

        XCTAssertFalse(testStorage.hasHostSetMarker)
        let fresh = await identityManager.getOrCreateAnonymousId()
        XCTAssertNotEqual(fresh, "web-anon-1")
        XCTAssertNotNil(UUID(uuidString: fresh))
    }

    /// Storage is authoritative, but if something outside the SDK wipes it the
    /// in-memory id is restored rather than replaced.
    func testExternallyWipedStorageIsReseededFromMemory() async {
        await identityManager.initialize()
        let original = await identityManager.getAnonymousId()

        testStorage.remove(.anonymousId)

        let after = await identityManager.getOrCreateAnonymousId()
        XCTAssertEqual(after, original)
        XCTAssertEqual(testStorage.get(.anonymousId), original)
    }

    // MARK: - reset() ordering
    // The host's reset() notes the request synchronously; the clear runs later.
    // These drive the two halves separately, with the clear delayed past the set.

    func testHostIdSetAfterResetRequestSurvivesTheDelayedClear() async {
        await identityManager.initialize()
        await identityManager.identify("user-1")

        identityManager.noteResetRequested()
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-2"))
        await identityManager.reset()

        let current = await identityManager.getOrCreateAnonymousId()
        let userId = await identityManager.getUserId()
        XCTAssertEqual(current, "web-anon-2")
        XCTAssertNil(userId, "the rest of identity is still cleared")
        XCTAssertNil(testStorage.get(.userId))
    }

    func testHostIdSetBeforeResetRequestIsCleared() async {
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))

        identityManager.noteResetRequested()
        await identityManager.reset()

        let current = await identityManager.getOrCreateAnonymousId()
        XCTAssertNotEqual(current, "web-anon-1")
    }

    /// Re-setting the id the device already has after reset() must keep it: the
    /// unchanged-value shortcut cannot skip the bookkeeping.
    func testResettingTheCurrentIdAfterResetRequestKeepsIt() async {
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))

        identityManager.noteResetRequested()
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))
        await identityManager.reset()

        let current = await identityManager.getOrCreateAnonymousId()
        XCTAssertEqual(current, "web-anon-1")
    }

    func testTwoResetsThenSetKeepsTheIdThroughBothClears() async {
        identityManager.noteResetRequested()
        identityManager.noteResetRequested()
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))
        await identityManager.reset()
        await identityManager.reset()

        let current = await identityManager.getOrCreateAnonymousId()
        XCTAssertEqual(current, "web-anon-1")
    }

    /// set A, reset, set B, reset: the second request discards B like any id set
    /// before a reset.
    func testSetResetSetResetClearsTheLastId() async {
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))
        identityManager.noteResetRequested()
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-2"))
        identityManager.noteResetRequested()
        await identityManager.reset()
        await identityManager.reset()

        let current = await identityManager.getOrCreateAnonymousId()
        XCTAssertNotEqual(current, "web-anon-1")
        XCTAssertNotEqual(current, "web-anon-2")
    }

    /// A clear that no reset() requested (nothing pending) is an ordinary clear,
    /// however recently the host set the id.
    func testUnrequestedClearStillClearsAHostId() async {
        XCTAssertTrue(identityManager.setAnonymousId("web-anon-1"))

        await identityManager.reset()

        XCTAssertNil(testStorage.get(.anonymousId))
    }
}
