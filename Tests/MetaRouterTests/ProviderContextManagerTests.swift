import XCTest
@testable import MetaRouter

/// ProviderContextManager: the host-set map, its bounds, and persistence. A rejected
/// write returns false and leaves prior state alone; nothing asserts.
final class ProviderContextManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: ProviderContextStorage!
    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.providerContext.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = ProviderContextStorage(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        storage = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeManager() -> ProviderContextManager {
        ProviderContextManager(storage: storage)
    }

    // MARK: - Basic set / get

    func testSetStoresUnderProviderAndKey() {
        let manager = makeManager()
        XCTAssertTrue(manager.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123"))

        XCTAssertEqual(
            manager.getAll(),
            ["googleFirebase": ["appInstanceId": .string("abc123")]]
        )
    }

    func testMultipleProvidersAndKeysCoexist() {
        let manager = makeManager()
        manager.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123")
        manager.setValue(provider: "googleFirebase", key: "nonPersonalizedAds", value: true)
        manager.setValue(provider: "adjust", key: "adid", value: "adj-1")

        XCTAssertEqual(manager.getAll(), [
            "googleFirebase": [
                "appInstanceId": .string("abc123"),
                "nonPersonalizedAds": .bool(true),
            ],
            "adjust": ["adid": .string("adj-1")],
        ])
    }

    func testSetReplacesExistingKeyWithoutDisturbingSiblings() {
        let manager = makeManager()
        manager.setValue(provider: "googleFirebase", key: "appInstanceId", value: "first")
        manager.setValue(provider: "googleFirebase", key: "nonPersonalizedAds", value: false)
        manager.setValue(provider: "googleFirebase", key: "appInstanceId", value: "second")

        XCTAssertEqual(manager.getAll(), [
            "googleFirebase": [
                "appInstanceId": .string("second"),
                "nonPersonalizedAds": .bool(false),
            ]
        ])
    }

    func testNamesAreTrimmedButNeverRecased() {
        let manager = makeManager()
        manager.setValue(provider: "  googleFirebase  ", key: " appInstanceId ", value: "x")

        // Casing is load-bearing: the Firebase kit matches
        // context.providers.googleFirebase.appInstanceId verbatim.
        XCTAssertEqual(manager.getAll(), ["googleFirebase": ["appInstanceId": .string("x")]])
    }

    func testNonStringScalarsRoundTrip() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "int", value: 7)
        manager.setValue(provider: "p", key: "double", value: 1.5)
        manager.setValue(provider: "p", key: "bool", value: true)

        XCTAssertEqual(manager.getAll()["p"], [
            "int": .int(7),
            "double": .double(1.5),
            "bool": .bool(true),
        ])
    }

    // MARK: - Removal

    func testNilValueRemovesKey() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: "1")
        manager.setValue(provider: "p", key: "b", value: "2")
        XCTAssertTrue(manager.setValue(provider: "p", key: "a", value: nil))

        XCTAssertEqual(manager.getAll(), ["p": ["b": .string("2")]])
    }

    func testRemovingLastKeyRemovesProviderEntirely() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: "1")
        manager.setValue(provider: "p", key: "a", value: nil)

        // Not `["p": [:]]` — an empty block would ship forever, indistinguishable
        // from a misconfigured one.
        XCTAssertEqual(manager.getAll(), [:])
    }

    func testExplicitNullValueRemovesRatherThanStampingNull() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: "1")
        manager.setValue(provider: "p", key: "a", value: CodableValue.null)

        XCTAssertEqual(manager.getAll(), [:])
    }

    func testClearProviderRemovesOnlyThatBlock() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: "1")
        manager.setValue(provider: "q", key: "b", value: "2")
        manager.clear(provider: "p")

        XCTAssertEqual(manager.getAll(), ["q": ["b": .string("2")]])
    }

    func testClearAllRemovesEverything() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: "1")
        manager.setValue(provider: "q", key: "b", value: "2")
        manager.clearAll()

        XCTAssertEqual(manager.getAll(), [:])
    }

    /// Same as `clear(provider:)`: removing what is not there writes nothing.
    func testRemovingAnAbsentKeyIsANoOpThatDoesNotPersist() {
        let manager = makeManager()

        XCTAssertTrue(manager.setValue(provider: "p", key: "absent", value: nil))

        XCTAssertNil(storage.get(), "nothing was ever written")
    }

    /// Removal never asserts — a blank name just has nothing to remove.
    func testRemovalWithABlankNameIsRejectedQuietly() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: "1")

        XCTAssertFalse(manager.setValue(provider: "  ", key: "a", value: nil))

        XCTAssertEqual(manager.getAll(), ["p": ["a": .string("1")]])
    }

    func testClearOfUnknownProviderIsANoOp() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: "1")
        manager.clear(provider: "absent")

        XCTAssertEqual(manager.getAll(), ["p": ["a": .string("1")]])
    }

    // MARK: - Reserved namespace

    func testReservedMetarouterProviderIsRejected() {
        let manager = makeManager()
        XCTAssertFalse(manager.setValue(provider: "metarouter", key: "sessionID", value: "hijacked"))

        XCTAssertEqual(manager.getAll(), [:])
    }

    func testReservedCheckAppliesAfterTrimming() {
        let manager = makeManager()
        XCTAssertFalse(manager.setValue(provider: "  metarouter ", key: "sessionID", value: "hijacked"))

        XCTAssertEqual(manager.getAll(), [:])
    }

    /// Lookalikes would sit next to the SDK's block and read as ours downstream.
    func testReservedCheckIgnoresCaseAndSeparators() {
        let manager = makeManager()
        for name in ["Metarouter", "METAROUTER", "meta router", "meta_router", "Meta-Router"] {
            XCTAssertFalse(manager.setValue(provider: name, key: "sessionID", value: "x"), name)
        }
        XCTAssertTrue(manager.setValue(provider: "metarouterPartner", key: "id", value: "x"), "only the reserved name itself")
        XCTAssertEqual(manager.getAll().keys.sorted(), ["metarouterPartner"])
    }

    // MARK: - Bounds

    func testBlankNamesAreRejected() {
        let manager = makeManager()
        XCTAssertFalse(manager.setValue(provider: "   ", key: "a", value: "1"))
        XCTAssertFalse(manager.setValue(provider: "p", key: "  ", value: "1"))

        XCTAssertEqual(manager.getAll(), [:])
    }

    func testOverlongNamesAreRejected() {
        let manager = makeManager()
        let longName = String(repeating: "a", count: ProviderContextManager.maxNameBytes + 1)
        XCTAssertFalse(manager.setValue(provider: longName, key: "a", value: "1"))
        XCTAssertFalse(manager.setValue(provider: "p", key: longName, value: "1"))

        XCTAssertEqual(manager.getAll(), [:])
    }

    func testNameLimitIsMeasuredInUtf8BytesNotCharacters() {
        let manager = makeManager()
        // 32 emoji = 32 characters but 128 UTF-8 bytes, over a 64-byte budget.
        let name = String(repeating: "🙂", count: 32)
        XCTAssertEqual(name.count, 32)
        XCTAssertGreaterThan(name.utf8.count, ProviderContextManager.maxNameBytes)

        XCTAssertFalse(manager.setValue(provider: name, key: "a", value: "1"))

        XCTAssertEqual(manager.getAll(), [:], "a char-count budget would have accepted this")
    }

    func testNameExactlyAtTheByteLimitIsAccepted() {
        let manager = makeManager()
        let name = String(repeating: "a", count: ProviderContextManager.maxNameBytes)
        manager.setValue(provider: name, key: "a", value: "1")

        XCTAssertEqual(manager.getAll()[name], ["a": .string("1")])
    }

    func testOversizeValueIsRejectedAndLeavesPriorValueIntact() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: "keep-me")
        let big = String(repeating: "x", count: ProviderContextManager.maxValueBytes + 1)
        XCTAssertFalse(manager.setValue(provider: "p", key: "a", value: big))

        // Rejected, never truncated: a trimmed vendor id looks valid and matches
        // nothing.
        XCTAssertEqual(manager.getAll(), ["p": ["a": .string("keep-me")]])
    }

    func testValueExactlyAtTheByteLimitIsAccepted() {
        let manager = makeManager()
        // Two of the encoded bytes are the JSON quotes, which the budget counts.
        let value = String(repeating: "x", count: ProviderContextManager.maxValueBytes - 2)
        manager.setValue(provider: "p", key: "a", value: value)

        XCTAssertEqual(manager.getAll(), ["p": ["a": .string(value)]])
    }

    func testProviderCountIsCapped() {
        let manager = makeManager()
        for i in 0..<ProviderContextManager.maxProviders {
            manager.setValue(provider: "p\(i)", key: "a", value: "1")
        }
        XCTAssertEqual(manager.getAll().count, ProviderContextManager.maxProviders)

        XCTAssertFalse(manager.setValue(provider: "overflow", key: "a", value: "1"))

        XCTAssertEqual(manager.getAll().count, ProviderContextManager.maxProviders)
        XCTAssertNil(manager.getAll()["overflow"])
    }

    func testProviderCapDoesNotBlockWritesToProvidersAlreadyPresent() {
        let manager = makeManager()
        for i in 0..<ProviderContextManager.maxProviders {
            manager.setValue(provider: "p\(i)", key: "a", value: "1")
        }
        manager.setValue(provider: "p0", key: "b", value: "2")

        XCTAssertEqual(manager.getAll()["p0"], ["a": .string("1"), "b": .string("2")])
    }

    func testKeysPerProviderAreCapped() {
        let manager = makeManager()
        for i in 0..<ProviderContextManager.maxKeysPerProvider {
            manager.setValue(provider: "p", key: "k\(i)", value: "1")
        }
        XCTAssertEqual(manager.getAll()["p"]?.count, ProviderContextManager.maxKeysPerProvider)

        XCTAssertFalse(manager.setValue(provider: "p", key: "overflow", value: "1"))

        XCTAssertEqual(manager.getAll()["p"]?.count, ProviderContextManager.maxKeysPerProvider)
        XCTAssertNil(manager.getAll()["p"]?["overflow"])
    }

    func testKeyCapDoesNotBlockOverwritingAnExistingKey() {
        let manager = makeManager()
        for i in 0..<ProviderContextManager.maxKeysPerProvider {
            manager.setValue(provider: "p", key: "k\(i)", value: "1")
        }
        manager.setValue(provider: "p", key: "k0", value: "updated")

        XCTAssertEqual(manager.getAll()["p"]?["k0"], .string("updated"))
    }

    func testRemovalIsNotBlockedByAFullMap() {
        let manager = makeManager()
        for i in 0..<ProviderContextManager.maxKeysPerProvider {
            manager.setValue(provider: "p", key: "k\(i)", value: "1")
        }
        manager.setValue(provider: "p", key: "k0", value: nil)

        XCTAssertEqual(manager.getAll()["p"]?.count, ProviderContextManager.maxKeysPerProvider - 1)
    }

    /// `CodableValue.from` drops bad container elements and keeps the rest; here
    /// that would stamp a value the host never set on every event.
    func testContainerWithAnUnrepresentableElementIsRejectedWhole() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: "keep-me")
        XCTAssertFalse(manager.setValue(provider: "p", key: "a", value: ["id": "abc", "ts": Date()]))
        XCTAssertFalse(manager.setValue(provider: "p", key: "b", value: ["ok", Date()]))

        XCTAssertEqual(manager.getAll(), ["p": ["a": .string("keep-me")]])
    }

    func testFullyRepresentableContainersAreAccepted() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: ["id": "abc", "n": 2])

        XCTAssertEqual(manager.getAll()["p"]?["a"], .object(["id": .string("abc"), "n": .int(2)]))
    }

    func testUnrepresentableValueIsRejected() {
        let manager = makeManager()
        XCTAssertFalse(manager.setValue(provider: "p", key: "a", value: Date()))

        XCTAssertEqual(manager.getAll(), [:])
    }

    // MARK: - Persistence

    func testValuesSurviveANewManagerOverTheSameStorage() {
        let first = makeManager()
        first.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123")

        // A fresh manager over the same storage stands in for the next launch.
        let second = ProviderContextManager(storage: storage)

        XCTAssertEqual(second.getAll(), ["googleFirebase": ["appInstanceId": .string("abc123")]])
    }

    func testRemovalSurvivesANewManager() {
        let first = makeManager()
        first.setValue(provider: "p", key: "a", value: "1")
        first.setValue(provider: "q", key: "b", value: "2")
        first.clear(provider: "p")

        XCTAssertEqual(ProviderContextManager(storage: storage).getAll(), ["q": ["b": .string("2")]])
    }

    func testClearAllWipesPersistedState() {
        let first = makeManager()
        first.setValue(provider: "p", key: "a", value: "1")
        first.clearAll()

        XCTAssertNil(storage.get())
        XCTAssertEqual(ProviderContextManager(storage: storage).getAll(), [:])
    }

    func testRejectedWriteIsNotPersisted() {
        let manager = makeManager()
        manager.setValue(provider: "metarouter", key: "sessionID", value: "x")

        XCTAssertNil(storage.get())
        XCTAssertEqual(ProviderContextManager(storage: storage).getAll(), [:])
    }

    func testCorruptStoredStateReadsAsUnset() {
        defaults.set(Data("not json".utf8), forKey: ProviderContextStorageKey.context.rawValue)

        // Wrong-but-safe beats unusable; the host's next set heals the blob.
        XCTAssertEqual(ProviderContextManager(storage: storage).getAll(), [:])
    }

    func testStorageUsesItsOwnNamespaceSoIdentityClearCannotTouchIt() {
        let manager = makeManager()
        manager.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123")

        IdentityStorage(userDefaults: defaults).clear()

        // reset() clears identity; these are install-scoped, so a logout must not
        // stop events being forwardable.
        XCTAssertEqual(manager.getAll(), ["googleFirebase": ["appInstanceId": .string("abc123")]])
        XCTAssertNotNil(storage.get())
    }

    // MARK: - Concurrency

    func testConcurrentWritesAllLandAndDiskEndsMatchingMemory() {
        let manager = makeManager()
        let count = 8
        let group = DispatchGroup()
        for i in 0..<count {
            group.enter()
            DispatchQueue.global().async {
                manager.setValue(provider: "p", key: "k\(i)", value: "v\(i)")
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let inMemory = manager.getAll()
        XCTAssertEqual(inMemory["p"]?.count, count)
        // The persist sequence stops two threads leaving the lock out of order from
        // leaving disk on an older map than memory.
        XCTAssertEqual(storage.get(), inMemory)
    }

    // MARK: - Debug info

    func testDebugInfoReportsShapeWithoutValues() {
        let manager = makeManager()
        manager.setValue(provider: "googleFirebase", key: "appInstanceId", value: "secret-id")
        manager.setValue(provider: "googleFirebase", key: "nonPersonalizedAds", value: true)

        // Vendor device identifiers, and getDebugInfo is printed into host logs.
        XCTAssertEqual(
            manager.debugInfoValue,
            .object([
                "googleFirebase": .array([.string("appInstanceId"), .string("nonPersonalizedAds")])
            ])
        )
    }
}
