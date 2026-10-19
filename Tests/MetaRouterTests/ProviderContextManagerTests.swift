import XCTest
@testable import MetaRouter

/// ProviderContextManager: the host-set map, its bounds, and persistence.
/// `debugAssert` is swapped for a recorder so the release-degrade path is what gets
/// exercised — assertions are live in test builds and would otherwise trap.
final class ProviderContextManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: ProviderContextStorage!
    private var savedDebugAssert: (@Sendable (String) -> Void)!
    private var asserted: Recorder!

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [String] = []
        func record(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            _messages.append(message)
        }
        var messages: [String] {
            lock.lock(); defer { lock.unlock() }
            return _messages
        }
    }

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.providerContext.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = ProviderContextStorage(userDefaults: defaults)
        asserted = Recorder()
        savedDebugAssert = ProviderContextManager.debugAssert
        let recorder = asserted!
        ProviderContextManager.debugAssert = { recorder.record($0) }
    }

    override func tearDown() {
        ProviderContextManager.debugAssert = savedDebugAssert
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        storage = nil
        suiteName = nil
        asserted = nil
        savedDebugAssert = nil
        super.tearDown()
    }

    private func makeManager() -> ProviderContextManager {
        ProviderContextManager(storage: storage)
    }

    // MARK: - Basic set / get

    func testSetStoresUnderProviderAndKey() {
        let manager = makeManager()
        manager.setValue(provider: "googleFirebase", key: "appInstanceId", value: "abc123")

        XCTAssertEqual(
            manager.getAll(),
            ["googleFirebase": ["appInstanceId": .string("abc123")]]
        )
        XCTAssertTrue(asserted.messages.isEmpty)
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
        manager.setValue(provider: "p", key: "a", value: nil)

        XCTAssertEqual(manager.getAll(), ["p": ["b": .string("2")]])
        XCTAssertTrue(asserted.messages.isEmpty, "removal is not misuse")
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

    func testClearOfUnknownProviderIsANoOp() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: "1")
        manager.clear(provider: "absent")

        XCTAssertEqual(manager.getAll(), ["p": ["a": .string("1")]])
    }

    // MARK: - Reserved namespace

    func testReservedMetarouterProviderIsRejected() {
        let manager = makeManager()
        manager.setValue(provider: "metarouter", key: "sessionID", value: "hijacked")

        XCTAssertEqual(manager.getAll(), [:])
        XCTAssertEqual(asserted.messages.count, 1)
        XCTAssertTrue(asserted.messages[0].contains("reserved"))
    }

    func testReservedCheckAppliesAfterTrimming() {
        let manager = makeManager()
        manager.setValue(provider: "  metarouter ", key: "sessionID", value: "hijacked")

        XCTAssertEqual(manager.getAll(), [:])
        XCTAssertEqual(asserted.messages.count, 1)
    }

    // MARK: - Bounds

    func testBlankNamesAreRejected() {
        let manager = makeManager()
        manager.setValue(provider: "   ", key: "a", value: "1")
        manager.setValue(provider: "p", key: "  ", value: "1")

        XCTAssertEqual(manager.getAll(), [:])
        XCTAssertEqual(asserted.messages.count, 2)
    }

    func testOverlongNamesAreRejected() {
        let manager = makeManager()
        let longName = String(repeating: "a", count: ProviderContextManager.maxNameBytes + 1)
        manager.setValue(provider: longName, key: "a", value: "1")
        manager.setValue(provider: "p", key: longName, value: "1")

        XCTAssertEqual(manager.getAll(), [:])
        XCTAssertEqual(asserted.messages.count, 2)
    }

    func testNameLimitIsMeasuredInUtf8BytesNotCharacters() {
        let manager = makeManager()
        // 32 emoji = 32 characters but 128 UTF-8 bytes, over a 64-byte budget.
        let name = String(repeating: "🙂", count: 32)
        XCTAssertEqual(name.count, 32)
        XCTAssertGreaterThan(name.utf8.count, ProviderContextManager.maxNameBytes)

        manager.setValue(provider: name, key: "a", value: "1")

        XCTAssertEqual(manager.getAll(), [:], "a char-count budget would have accepted this")
        XCTAssertEqual(asserted.messages.count, 1)
    }

    func testNameExactlyAtTheByteLimitIsAccepted() {
        let manager = makeManager()
        let name = String(repeating: "a", count: ProviderContextManager.maxNameBytes)
        manager.setValue(provider: name, key: "a", value: "1")

        XCTAssertEqual(manager.getAll()[name], ["a": .string("1")])
        XCTAssertTrue(asserted.messages.isEmpty)
    }

    func testOversizeValueIsRejectedAndLeavesPriorValueIntact() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: "keep-me")
        let big = String(repeating: "x", count: ProviderContextManager.maxValueBytes + 1)
        manager.setValue(provider: "p", key: "a", value: big)

        // Rejected, never truncated: a trimmed vendor id looks valid and matches
        // nothing.
        XCTAssertEqual(manager.getAll(), ["p": ["a": .string("keep-me")]])
        XCTAssertEqual(asserted.messages.count, 1)
    }

    func testValueExactlyAtTheByteLimitIsAccepted() {
        let manager = makeManager()
        // Two of the encoded bytes are the JSON quotes, which the budget counts.
        let value = String(repeating: "x", count: ProviderContextManager.maxValueBytes - 2)
        manager.setValue(provider: "p", key: "a", value: value)

        XCTAssertEqual(manager.getAll(), ["p": ["a": .string(value)]])
        XCTAssertTrue(asserted.messages.isEmpty)
    }

    func testProviderCountIsCapped() {
        let manager = makeManager()
        for i in 0..<ProviderContextManager.maxProviders {
            manager.setValue(provider: "p\(i)", key: "a", value: "1")
        }
        XCTAssertEqual(manager.getAll().count, ProviderContextManager.maxProviders)

        manager.setValue(provider: "overflow", key: "a", value: "1")

        XCTAssertEqual(manager.getAll().count, ProviderContextManager.maxProviders)
        XCTAssertNil(manager.getAll()["overflow"])
        XCTAssertEqual(asserted.messages.count, 1)
    }

    func testProviderCapDoesNotBlockWritesToProvidersAlreadyPresent() {
        let manager = makeManager()
        for i in 0..<ProviderContextManager.maxProviders {
            manager.setValue(provider: "p\(i)", key: "a", value: "1")
        }
        manager.setValue(provider: "p0", key: "b", value: "2")

        XCTAssertEqual(manager.getAll()["p0"], ["a": .string("1"), "b": .string("2")])
        XCTAssertTrue(asserted.messages.isEmpty)
    }

    func testKeysPerProviderAreCapped() {
        let manager = makeManager()
        for i in 0..<ProviderContextManager.maxKeysPerProvider {
            manager.setValue(provider: "p", key: "k\(i)", value: "1")
        }
        XCTAssertEqual(manager.getAll()["p"]?.count, ProviderContextManager.maxKeysPerProvider)

        manager.setValue(provider: "p", key: "overflow", value: "1")

        XCTAssertEqual(manager.getAll()["p"]?.count, ProviderContextManager.maxKeysPerProvider)
        XCTAssertNil(manager.getAll()["p"]?["overflow"])
        XCTAssertEqual(asserted.messages.count, 1)
    }

    func testKeyCapDoesNotBlockOverwritingAnExistingKey() {
        let manager = makeManager()
        for i in 0..<ProviderContextManager.maxKeysPerProvider {
            manager.setValue(provider: "p", key: "k\(i)", value: "1")
        }
        manager.setValue(provider: "p", key: "k0", value: "updated")

        XCTAssertEqual(manager.getAll()["p"]?["k0"], .string("updated"))
        XCTAssertTrue(asserted.messages.isEmpty)
    }

    func testRemovalIsNotBlockedByAFullMap() {
        let manager = makeManager()
        for i in 0..<ProviderContextManager.maxKeysPerProvider {
            manager.setValue(provider: "p", key: "k\(i)", value: "1")
        }
        manager.setValue(provider: "p", key: "k0", value: nil)

        XCTAssertEqual(manager.getAll()["p"]?.count, ProviderContextManager.maxKeysPerProvider - 1)
        XCTAssertTrue(asserted.messages.isEmpty)
    }

    /// `CodableValue.from` drops bad container elements and keeps the rest; here
    /// that would stamp a value the host never set on every event.
    func testContainerWithAnUnrepresentableElementIsRejectedWhole() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: "keep-me")
        manager.setValue(provider: "p", key: "a", value: ["id": "abc", "ts": Date()])
        manager.setValue(provider: "p", key: "b", value: ["ok", Date()])

        XCTAssertEqual(manager.getAll(), ["p": ["a": .string("keep-me")]])
        XCTAssertEqual(asserted.messages.count, 2)
    }

    func testFullyRepresentableContainersAreAccepted() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: ["id": "abc", "n": 2])

        XCTAssertEqual(manager.getAll()["p"]?["a"], .object(["id": .string("abc"), "n": .int(2)]))
        XCTAssertTrue(asserted.messages.isEmpty)
    }

    func testUnrepresentableValueIsRejected() {
        let manager = makeManager()
        manager.setValue(provider: "p", key: "a", value: Date())

        XCTAssertEqual(manager.getAll(), [:])
        XCTAssertEqual(asserted.messages.count, 1)
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
