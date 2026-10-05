import XCTest
@testable import MetaRouter

final class ConsentReconcilerTests: XCTestCase {

    private let registry = [
        ConsentCategory(key: "c0001", defaultOptOut: false),
        ConsentCategory(key: "c0002"),
        ConsentCategory(key: "c0004"),
    ]

    func testEmptyRegistryPassesIncomingThrough() {
        let incoming = Consent(explicit: true, optOut: ["anything": true, "goes": false], timestamp: 7)

        let result = ConsentReconciler.reconcile(incoming, against: [])

        XCTAssertEqual(result, incoming, "nothing to reconcile against — dropping keys would lose the host's signal")
    }

    func testFullOverlapKeepsIncomingValues() {
        let incoming = Consent(explicit: true, optOut: ["c0001": true, "c0002": false, "c0004": false])

        let result = ConsentReconciler.reconcile(incoming, against: registry)

        XCTAssertEqual(result.optOut, ["c0001": true, "c0002": false, "c0004": false])
    }

    func testPartialOverlapFillsMissingWithRegisteredDefault() {
        let incoming = Consent(explicit: true, optOut: ["c0002": false])

        let result = ConsentReconciler.reconcile(incoming, against: registry)

        XCTAssertEqual(result.optOut, ["c0001": false, "c0002": false, "c0004": true])
    }

    func testUnknownKeysAreDropped() {
        let incoming = Consent(explicit: true, optOut: ["c0001": false, "c0002": false, "c0004": false, "c9999": false])

        let result = ConsentReconciler.reconcile(incoming, against: registry)

        XCTAssertNil(result.optOut["c9999"])
        XCTAssertEqual(result.optOut.count, 3)
    }

    func testExplicitAndTimestampPassThroughUnchanged() {
        let explicitIn = Consent(explicit: true, optOut: [:], timestamp: 42)
        let implicitIn = Consent(explicit: false, optOut: [:], timestamp: nil)

        XCTAssertTrue(ConsentReconciler.reconcile(explicitIn, against: registry).explicit)
        XCTAssertEqual(ConsentReconciler.reconcile(explicitIn, against: registry).timestamp, 42)
        XCTAssertFalse(ConsentReconciler.reconcile(implicitIn, against: registry).explicit)
        XCTAssertNil(ConsentReconciler.reconcile(implicitIn, against: registry).timestamp)
    }

    /// Key matching is exact: an uppercase incoming key is "unknown" and the
    /// category takes its default. Adapters lowercase before handing over.
    func testKeyMatchingIsCaseSensitive() {
        let incoming = Consent(explicit: true, optOut: ["C0002": false])

        let result = ConsentReconciler.reconcile(incoming, against: registry)

        XCTAssertEqual(result.optOut["c0002"], true, "unmatched → registered default (blocked)")
        XCTAssertNil(result.optOut["C0002"])
    }

    func testImplicitDefaultIsExplicitFalseWithRegisteredDefaults() {
        let result = ConsentReconciler.implicitDefault(for: registry)

        XCTAssertFalse(result.explicit)
        XCTAssertEqual(result.optOut, ["c0001": false, "c0002": true, "c0004": true])
        XCTAssertNil(result.timestamp)
    }

    func testImplicitDefaultForEmptyRegistryIsEmptyMap() {
        let result = ConsentReconciler.implicitDefault(for: [])

        XCTAssertFalse(result.explicit)
        XCTAssertEqual(result.optOut, [:])
    }

    /// Reconciliation is a projection onto the registry: applying it twice yields
    /// the same block, which is what lets the manager re-reconcile stored state on
    /// every registration without drift.
    func testReconcileIsIdempotent() {
        let incoming = Consent(explicit: true, optOut: ["c0002": false, "junk": true], timestamp: 1)

        let once = ConsentReconciler.reconcile(incoming, against: registry)
        let twice = ConsentReconciler.reconcile(once, against: registry)

        XCTAssertEqual(once, twice)
    }
}
