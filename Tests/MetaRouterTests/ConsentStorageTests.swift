import XCTest
@testable import MetaRouter

final class ConsentStorageTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.consentStorage.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRoundTripWithTimestamp() {
        let storage = ConsentStorage(userDefaults: defaults)
        XCTAssertNil(storage.get())

        let stored = StoredConsent(
            consent: Consent(explicit: true, optOut: ["c0001": false, "c0004": true], timestamp: 1_757_400_000_000),
            lastHostTimestamp: 1_757_400_000_000
        )
        storage.set(stored)

        XCTAssertEqual(storage.get(), stored)
    }

    func testRoundTripWithoutTimestamp() {
        let storage = ConsentStorage(userDefaults: defaults)
        let stored = StoredConsent(consent: Consent(explicit: false, optOut: [:]), lastHostTimestamp: nil)
        storage.set(stored)

        let read = storage.get()
        XCTAssertEqual(read, stored)
        XCTAssertNil(read?.consent.timestamp)
    }

    func testSetReplacesPriorState() {
        let storage = ConsentStorage(userDefaults: defaults)
        storage.set(StoredConsent(consent: Consent(explicit: true, optOut: ["c0001": false, "c0002": false]), lastHostTimestamp: nil))
        storage.set(StoredConsent(consent: Consent(explicit: true, optOut: ["c0001": true]), lastHostTimestamp: nil))

        XCTAssertEqual(storage.get()?.consent.optOut, ["c0001": true], "replace, not merge")
    }

    func testClearRemovesState() {
        let storage = ConsentStorage(userDefaults: defaults)
        storage.set(StoredConsent(consent: Consent(explicit: true, optOut: ["c0001": false]), lastHostTimestamp: nil))
        storage.clear()

        XCTAssertNil(storage.get())
        XCTAssertNil(defaults.object(forKey: ConsentStorageKey.state.rawValue))
    }

    /// Corrupt persisted state must read as never-set, not crash and not throw:
    /// the implicit default is wrong-but-safe, and the next setConsent heals it.
    func testCorruptStateReadsAsNeverSet() {
        defaults.set(Data("not json".utf8), forKey: ConsentStorageKey.state.rawValue)
        let storage = ConsentStorage(userDefaults: defaults)

        XCTAssertNil(storage.get())
    }

    func testWrongTypeUnderKeyReadsAsNeverSet() {
        defaults.set("a string, not data", forKey: ConsentStorageKey.state.rawValue)
        let storage = ConsentStorage(userDefaults: defaults)

        XCTAssertNil(storage.get())
    }

    /// A build that adds a field to the stored blob must not strand the previous
    /// build's users on the implicit default after a downgrade.
    func testUnknownFieldsAreTolerated() {
        let json = #"{"consent":{"explicit":true,"optOut":{"c0001":false},"timestamp":5,"future":1},"lastHostTimestamp":5,"futureField":"x"}"#
        defaults.set(Data(json.utf8), forKey: ConsentStorageKey.state.rawValue)
        let storage = ConsentStorage(userDefaults: defaults)

        XCTAssertEqual(storage.get(), StoredConsent(
            consent: Consent(explicit: true, optOut: ["c0001": false], timestamp: 5), lastHostTimestamp: 5
        ))
    }

    /// Consent lives outside the identity namespace so that `reset()` — which
    /// clears identity — can never resurrect tracking the user opted out of.
    func testIdentityStorageClearDoesNotTouchConsent() {
        let identityStorage = IdentityStorage(userDefaults: defaults)
        identityStorage.set(.anonymousId, value: "abc")
        identityStorage.set(.userId, value: "user-1")

        let consentStorage = ConsentStorage(userDefaults: defaults)
        let stored = StoredConsent(consent: Consent(explicit: true, optOut: ["c0004": true], timestamp: 1), lastHostTimestamp: 1)
        consentStorage.set(stored)

        identityStorage.clear()

        XCTAssertNil(identityStorage.get(.anonymousId), "identity cleared")
        XCTAssertNil(identityStorage.get(.userId), "identity cleared")
        XCTAssertEqual(consentStorage.get(), stored, "consent must survive IdentityStorage.clear()")
    }

    func testKeyUsesExpectedNamespace() {
        XCTAssertEqual(ConsentStorageKey.state.rawValue, "metarouter:consent:state")
    }
}
