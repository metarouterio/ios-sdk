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

    func testConcurrentMarkForgetAndSizeKeepTheStoreCoherent() {
        // The lock exists because messages arrive on the WebView's thread while the
        // SDK may probe from background workers — every other test here is
        // single-threaded, so this is the one that actually exercises it (and gives
        // TSan something to chew on). Assertions are invariants, not outcomes: the
        // interleaving is nondeterministic by design.
        let store = BridgeDedupStore(maxEntries: 64, ttlMillis: 1_000_000, clock: { 0 })

        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            let id = "m-\(i % 100)"
            _ = store.markIfNew(id)
            if i % 3 == 0 {
                store.forget(id)
            }
            _ = store.size()
        }

        XCTAssertLessThanOrEqual(store.size(), 64)
        // The store still functions after the hammering: a fresh id is new exactly once.
        XCTAssertTrue(store.markIfNew("post-hammer"))
        XCTAssertFalse(store.markIfNew("post-hammer"))
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
