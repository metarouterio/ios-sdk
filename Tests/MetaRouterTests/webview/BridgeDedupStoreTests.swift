import XCTest
@testable import MetaRouter

final class BridgeDedupStoreTests: XCTestCase {

    private var now: Int64 = 1_000_000

    private func makeStore(
        maxEntries: Int = BridgeDedupStore.defaultMaxEntries,
        ttlMillis: Int64 = BridgeDedupStore.defaultTtlMillis
    ) -> BridgeDedupStore {
        BridgeDedupStore(maxEntries: maxEntries, ttlMillis: ttlMillis) { self.now }
    }

    func testFirstSightingIsNew() {
        XCTAssertTrue(makeStore().markIfNew("m-1"))
    }

    func testSecondSightingWithinTtlIsADuplicate() {
        let store = makeStore()

        XCTAssertTrue(store.markIfNew("m-1"))
        XCTAssertFalse(store.markIfNew("m-1"))
    }

    func testDistinctIdsDoNotCollide() {
        let store = makeStore()

        XCTAssertTrue(store.markIfNew("m-1"))
        XCTAssertTrue(store.markIfNew("m-2"))
        XCTAssertFalse(store.markIfNew("m-1"))
        XCTAssertFalse(store.markIfNew("m-2"))
    }

    func testSightingAfterTtlExpiryIsNewAgain() {
        let store = makeStore(ttlMillis: 1_000)

        XCTAssertTrue(store.markIfNew("m-1"))
        now += 1_001
        XCTAssertTrue(store.markIfNew("m-1"))
    }

    func testSightingAtExactlyTheTtlBoundaryCountsAsExpired() {
        // The window check is strict (<): elapsed == ttl is outside the window. A
        // flipped comparison would silently change this; one assertion pins it.
        let store = makeStore(ttlMillis: 1_000)

        XCTAssertTrue(store.markIfNew("m-1"))
        now += 1_000
        XCTAssertTrue(store.markIfNew("m-1"))
    }

    func testDuplicateDoesNotRefreshTheTtlWindow() {
        let store = makeStore(ttlMillis: 1_000)

        XCTAssertTrue(store.markIfNew("m-1"))
        now += 600
        XCTAssertFalse(store.markIfNew("m-1"))
        // 1_100ms after FIRST sighting: if the duplicate at 600ms had refreshed the
        // timestamp, this would still be inside the window and report a duplicate.
        now += 500
        XCTAssertTrue(store.markIfNew("m-1"))
    }

    func testOldestEntryIsEvictedWhenTheStoreIsFull() {
        let store = makeStore(maxEntries: 3)

        XCTAssertTrue(store.markIfNew("m-1"))
        XCTAssertTrue(store.markIfNew("m-2"))
        XCTAssertTrue(store.markIfNew("m-3"))
        XCTAssertTrue(store.markIfNew("m-4"))

        XCTAssertEqual(store.size(), 3)
        // m-1 was evicted, so it reads as new; m-4 is still live.
        XCTAssertTrue(store.markIfNew("m-1"))
        XCTAssertFalse(store.markIfNew("m-4"))
    }

    func testSizeNeverExceedsTheBound() {
        let store = makeStore(maxEntries: 10)

        for i in 0..<100 {
            XCTAssertTrue(store.markIfNew("m-\(i)"))
        }

        XCTAssertEqual(store.size(), 10)
    }

    func testExpiredEntryReSightingMovesItToTheBackOfTheEvictionOrder() {
        let store = makeStore(maxEntries: 2, ttlMillis: 1_000)

        XCTAssertTrue(store.markIfNew("m-1"))
        now += 1_001
        XCTAssertTrue(store.markIfNew("m-1")) // expired → re-recorded at `now`
        XCTAssertTrue(store.markIfNew("m-2"))
        XCTAssertTrue(store.markIfNew("m-3")) // store full — evicts the eldest entry

        // m-1 was re-recorded before m-2, so m-1 is the eviction victim; m-2 survives.
        // If the expired re-sighting had kept m-1's original slot position, m-2 would
        // have been evicted here instead.
        XCTAssertFalse(store.markIfNew("m-2"))
    }
}
