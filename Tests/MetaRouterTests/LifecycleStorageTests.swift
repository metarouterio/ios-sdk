import XCTest
@testable import MetaRouter

final class LifecycleStorageTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.lifecycleStorage.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRoundTripVersionAndBuild() {
        let storage = LifecycleStorage(userDefaults: defaults)

        XCTAssertNil(storage.getVersion())
        XCTAssertNil(storage.getBuild())

        storage.setVersion("1.5.0")
        storage.setBuild("42")

        XCTAssertEqual(storage.getVersion(), "1.5.0")
        XCTAssertEqual(storage.getBuild(), "42")
    }

    func testSetVersionBuildHelperSetsBoth() {
        let storage = LifecycleStorage(userDefaults: defaults)
        storage.setVersionBuild(version: "2.0.0", build: "100")

        XCTAssertEqual(storage.getVersion(), "2.0.0")
        XCTAssertEqual(storage.getBuild(), "100")
    }

    func testClearRemovesBothKeys() {
        let storage = LifecycleStorage(userDefaults: defaults)
        storage.setVersionBuild(version: "1.0", build: "1")
        storage.clear()

        XCTAssertNil(storage.getVersion())
        XCTAssertNil(storage.getBuild())
    }

    /// Lifecycle storage uses the `metarouter:lifecycle:*` key prefix and is
    /// NOT enumerated by `IdentityStorage.clear()`. This is the structural
    /// guarantee that `reset()` cannot wipe install/update state.
    func testIdentityStorageClearDoesNotTouchLifecycleKeys() {
        // Seed both stores on the same backing UserDefaults
        let identityStorage = IdentityStorage(userDefaults: defaults)
        identityStorage.set(.anonymousId, value: "abc")
        identityStorage.set(.userId, value: "user-1")

        let lifecycleStorage = LifecycleStorage(userDefaults: defaults)
        lifecycleStorage.setVersionBuild(version: "1.5.0", build: "42")

        // Clearing identity must not touch lifecycle
        identityStorage.clear()

        XCTAssertNil(identityStorage.get(.anonymousId), "identity cleared")
        XCTAssertNil(identityStorage.get(.userId), "identity cleared")
        XCTAssertEqual(lifecycleStorage.getVersion(), "1.5.0",
                       "lifecycle storage must survive IdentityStorage.clear()")
        XCTAssertEqual(lifecycleStorage.getBuild(), "42",
                       "lifecycle storage must survive IdentityStorage.clear()")
    }

    func testKeysUseExpectedNamespace() {
        XCTAssertEqual(LifecycleStorageKey.version.rawValue, "metarouter:lifecycle:version")
        XCTAssertEqual(LifecycleStorageKey.build.rawValue, "metarouter:lifecycle:build")
    }

    func testIdentityStorageHasAnyValueDetectsAnyKey() {
        let storage = IdentityStorage(userDefaults: defaults)
        XCTAssertFalse(storage.hasAnyValue())

        storage.set(.anonymousId, value: "abc")
        XCTAssertTrue(storage.hasAnyValue())

        storage.clear()
        XCTAssertFalse(storage.hasAnyValue())

        storage.set(.userId, value: "u")
        XCTAssertTrue(storage.hasAnyValue())
    }
}
