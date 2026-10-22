import XCTest
@testable import MetaRouter

/// ConsentManager state-machine tests. The clock and the callback dispatcher are
/// injected: subscriber deliveries land in a recorder the test drains explicitly,
/// so ordering is observable and nothing depends on the main run loop.
final class ConsentManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: ConsentStorage!
    private var dispatcher: RecordingDispatcher!
    private var clock: Clock!
    private var savedDebugAssert: (@Sendable (String) -> Void)!

    private final class Clock: @unchecked Sendable {
        var now: Int64
        init(_ now: Int64) { self.now = now }
    }

    /// Stands in for the main queue: FIFO, drained on demand, never inside the
    /// manager's lock — exactly the production shape minus the thread hop.
    private final class RecordingDispatcher: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [@Sendable () -> Void] = []

        func enqueue(_ block: @escaping @Sendable () -> Void) {
            lock.lock(); defer { lock.unlock() }
            pending.append(block)
        }

        var pendingCount: Int {
            lock.lock(); defer { lock.unlock() }
            return pending.count
        }

        /// Runs everything queued so far, including work enqueued by the handlers
        /// it runs, in FIFO order.
        func drain() {
            while true {
                lock.lock()
                guard !pending.isEmpty else { lock.unlock(); return }
                let block = pending.removeFirst()
                lock.unlock()
                block()
            }
        }
    }

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Consent] = []
        var values: [Consent] { lock.lock(); defer { lock.unlock() }; return _values }
        func append(_ c: Consent) { lock.lock(); defer { lock.unlock() }; _values.append(c) }
    }

    private static let registry = [
        ConsentCategory(key: "c0001", defaultOptOut: false),
        ConsentCategory(key: "c0002"),
        ConsentCategory(key: "c0004"),
    ]

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.consentManager.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = ConsentStorage(userDefaults: defaults)
        dispatcher = RecordingDispatcher()
        clock = Clock(1_757_400_000_000)
        savedDebugAssert = ConsentManager.debugAssert
    }

    override func tearDown() {
        ConsentManager.debugAssert = savedDebugAssert
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        storage = nil
        dispatcher = nil
        clock = nil
        super.tearDown()
    }

    private func makeManager() -> ConsentManager {
        let clock = self.clock!
        let dispatcher = self.dispatcher!
        return ConsentManager(
            storage: storage,
            clockMillis: { clock.now },
            dispatch: { dispatcher.enqueue($0) }
        )
    }

    /// Routes debug assertions into a counter so the release-degrade path can be
    /// exercised without trapping the test process.
    private func captureDebugAsserts() -> Received {
        let box = Received()
        ConsentManager.debugAssert = { message in box.append(Consent(explicit: false, optOut: [message: true])) }
        return box
    }

    private func subscribeRecording(_ manager: ConsentManager) -> (Received, ConsentUnsubscribe) {
        let received = Received()
        let unsubscribe = manager.subscribe { received.append($0) }
        return (received, unsubscribe)
    }

    // MARK: - Implicit default

    func testGetConsentBeforeAnythingIsEmptyImplicitDefault() {
        let manager = makeManager()

        XCTAssertEqual(manager.getConsent(), Consent(explicit: false, optOut: [:]))
    }

    func testGetConsentAfterRegistrationIsImplicitDefaultOverRegistry() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)

        let consent = manager.getConsent()

        XCTAssertFalse(consent.explicit)
        XCTAssertEqual(consent.optOut, ["c0001": false, "c0002": true, "c0004": true])
        XCTAssertNil(storage.get(), "the implicit default is served, never persisted")
    }

    // MARK: - setConsent

    func testSetConsentReconcilesAndPersists() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)

        let accepted = manager.setConsent(Consent(explicit: true, optOut: ["c0002": false, "junk": true]))

        XCTAssertTrue(accepted)
        let expected = ["c0001": false, "c0002": false, "c0004": true]
        XCTAssertEqual(manager.getConsent().optOut, expected)
        XCTAssertTrue(manager.getConsent().explicit)
        XCTAssertEqual(storage.get()?.consent.optOut, ["c0002": false, "junk": true],
                       "storage keeps the host's raw snapshot — reconciliation is a view, recomputed per registry")
    }

    func testSetConsentStampsClockWhenTimestampAbsent() {
        let manager = makeManager()
        clock.now = 123_456

        manager.setConsent(Consent(explicit: true, optOut: [:]))

        XCTAssertEqual(manager.getConsent().timestamp, 123_456)
        XCTAssertEqual(storage.get()?.consent.timestamp, 123_456)
        XCTAssertNil(storage.get()?.lastHostTimestamp)
    }

    func testSetConsentKeepsCallerTimestamp() {
        let manager = makeManager()

        manager.setConsent(Consent(explicit: true, optOut: [:], timestamp: 99))

        XCTAssertEqual(manager.getConsent().timestamp, 99)
    }

    func testSetConsentReplacesNotMerges() {
        let manager = makeManager()
        manager.setConsent(Consent(explicit: true, optOut: ["a": true, "b": true], timestamp: 1))

        manager.setConsent(Consent(explicit: true, optOut: ["a": false], timestamp: 2))

        XCTAssertEqual(manager.getConsent().optOut, ["a": false])
    }

    func testStaleSetConsentIsIgnored() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        manager.setConsent(Consent(explicit: true, optOut: ["c0004": false], timestamp: 2_000))
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()
        let before = manager.getConsent()

        let accepted = manager.setConsent(Consent(explicit: true, optOut: ["c0004": true], timestamp: 1_000))
        dispatcher.drain()

        XCTAssertFalse(accepted)
        XCTAssertEqual(manager.getConsent(), before, "older snapshot must not overwrite a newer one")
        XCTAssertEqual(storage.get()?.consent.optOut, ["c0004": false])
        XCTAssertEqual(storage.get()?.lastHostTimestamp, 2_000)
        XCTAssertEqual(received.values.count, 1, "only the initial emission — a rejected set never notifies")
    }

    func testEqualTimestampIsAccepted() {
        let manager = makeManager()
        manager.setConsent(Consent(explicit: true, optOut: ["a": true], timestamp: 5))

        let accepted = manager.setConsent(Consent(explicit: true, optOut: ["a": false], timestamp: 5))

        XCTAssertTrue(accepted)
        XCTAssertEqual(manager.getConsent().optOut, ["a": false])
    }

    /// Wall clock went backwards (NTP, user reset the date) after a host-timestamped
    /// snapshot was stored. A fresh untimestamped set is the user's current choice
    /// and must still win — rejecting it would drop an opt-out.
    func testUntimestampedSetIsNeverRejectedAsStaleWhenTheClockMovedBack() {
        let manager = makeManager()
        manager.setConsent(Consent(explicit: true, optOut: ["a": false], timestamp: 500))

        clock.now = 400
        XCTAssertTrue(manager.setConsent(Consent(explicit: true, optOut: ["a": true])))

        XCTAssertEqual(manager.getConsent().optOut, ["a": true])
        XCTAssertEqual(manager.getConsent().timestamp, 400, "device clock, informational — not clamped")
    }

    /// The host watermark survives an untimestamped set. Otherwise a host re-pushing
    /// the same decision without a timestamp (foreground refresh) would let an older
    /// CMP replay overwrite the user's newer explicit choice.
    func testUntimestampedRePushDoesNotResetTheHostWatermark() {
        let manager = makeManager()
        manager.setConsent(Consent(explicit: true, optOut: ["a": true], timestamp: 2_000))      // banner choice
        manager.setConsent(Consent(explicit: true, optOut: ["a": true]))                       // same decision, no timestamp
        XCTAssertEqual(storage.get()?.lastHostTimestamp, 2_000, "watermark carried forward")

        let accepted = manager.setConsent(Consent(explicit: true, optOut: ["a": false], timestamp: 1_000))  // cached replay

        XCTAssertFalse(accepted)
        XCTAssertEqual(manager.getConsent().optOut, ["a": true], "the newer explicit choice stands")
        XCTAssertTrue(manager.setConsent(Consent(explicit: true, optOut: ["a": false], timestamp: 2_001)), "a newer host snapshot still wins")
    }

    /// Equal is not older: a replay carrying the watermark's exact timestamp
    /// applies, even after an untimestamped choice. A newer host snapshot moves the
    /// watermark, after which only the older one is stale.
    func testWatermarkMovesWithEachNewerHostSnapshot() {
        let manager = makeManager()
        manager.setConsent(Consent(explicit: true, optOut: ["a": false], timestamp: 1_000))   // T1
        manager.setConsent(Consent(explicit: true, optOut: ["a": true]))                      // untimestamped
        XCTAssertTrue(manager.setConsent(Consent(explicit: true, optOut: ["a": true], timestamp: 2_000)))   // T2

        XCTAssertTrue(manager.setConsent(Consent(explicit: true, optOut: ["a": false], timestamp: 2_000)), "replay of T2")
        XCTAssertEqual(manager.getConsent().optOut, ["a": false])
        XCTAssertFalse(manager.setConsent(Consent(explicit: true, optOut: ["a": true], timestamp: 1_000)), "T1 is now stale")
        XCTAssertEqual(storage.get()?.lastHostTimestamp, 2_000)
    }

    /// The failure this rule exists for: the host applies an untimestamped regional
    /// default (stamped by a device clock running fast), then the banner callback
    /// arrives carrying the CMP's server time, which is behind the device. The
    /// explicit choice must win.
    func testBannerChoiceWithServerTimeIsNotRejectedAfterADeviceStampedDefault() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        clock.now = 1_757_400_600_000                                    // device clock, 10 min fast
        manager.setConsent(Consent(explicit: false, optOut: ["c0002": true, "c0004": true]))
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()

        let accepted = manager.setConsent(Consent(
            explicit: true, optOut: ["c0002": false, "c0004": false], timestamp: 1_757_400_000_000  // server time
        ))
        dispatcher.drain()

        XCTAssertTrue(accepted)
        XCTAssertTrue(manager.getConsent().explicit)
        XCTAssertEqual(manager.getConsent().optOut, ["c0001": false, "c0002": false, "c0004": false])
        XCTAssertEqual(received.values.count, 2, "subscribers hear the explicit choice")
    }

    // MARK: - Registry

    func testSetConsentBeforeRegistrationPassesThroughAndLaterRegistrationCompletesIt() {
        let manager = makeManager()
        manager.setConsent(Consent(explicit: true, optOut: ["c0002": false, "junk": true], timestamp: 1))
        XCTAssertEqual(manager.getConsent().optOut, ["c0002": false, "junk": true], "empty registry → as-is")
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()

        manager.registerConsentCategories(Self.registry)
        dispatcher.drain()

        let expected = ["c0001": false, "c0002": false, "c0004": true]
        XCTAssertEqual(manager.getConsent().optOut, expected)
        XCTAssertTrue(manager.getConsent().explicit, "explicit carried through")
        XCTAssertEqual(manager.getConsent().timestamp, 1, "re-reconciliation is not a new decision")
        XCTAssertEqual(storage.get()?.consent.optOut, ["c0002": false, "junk": true], "raw snapshot stays on disk")
        XCTAssertEqual(received.values.map(\.optOut), [["c0002": false, "junk": true], expected],
                       "subscribers learn the completed block")
    }

    func testReRegistrationReplacesNotMerges() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)

        manager.registerConsentCategories([ConsentCategory(key: "analytics", defaultOptOut: false)])

        XCTAssertEqual(manager.getConsent().optOut, ["analytics": false])
    }

    func testRegistrationThatChangesNothingDoesNotNotify() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        manager.setConsent(Consent(explicit: true, optOut: ["c0001": false, "c0002": false, "c0004": false]))
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()

        manager.registerConsentCategories(Self.registry)
        dispatcher.drain()

        XCTAssertEqual(received.values.count, 1)
    }

    func testRegistrationNormalizesKeysAndDegradesInRelease() {
        let asserts = captureDebugAsserts()
        let manager = makeManager()

        manager.registerConsentCategories([
            ConsentCategory(key: " C0001 ", defaultOptOut: false),
            ConsentCategory(key: ""),
            ConsentCategory(key: "c0002"),
            ConsentCategory(key: "C0002", defaultOptOut: false),
        ])

        XCTAssertEqual(manager.getConsent().optOut, ["c0001": false, "c0002": true],
                       "lowercased + trimmed, blank dropped, duplicate keeps first")
        XCTAssertEqual(asserts.values.count, 4, "one debug assertion per problem: casing ×2, blank, duplicate")
    }

    // MARK: - Persistence across relaunch

    func testConsentSurvivesRelaunch() {
        let first = makeManager()
        first.registerConsentCategories(Self.registry)
        first.setConsent(Consent(explicit: true, optOut: ["c0002": false], timestamp: 10))

        let relaunched = makeManager()
        relaunched.registerConsentCategories(Self.registry)

        XCTAssertEqual(relaunched.getConsent(), Consent(
            explicit: true, optOut: ["c0001": false, "c0002": false, "c0004": true], timestamp: 10
        ))
    }

    /// An app update that registers a new category must not ship events missing
    /// that key — a missing key is not read as blocked downstream. The stored
    /// decision stays intact for the categories it covered; the new one takes its
    /// registered default until the user is asked again.
    func testRelaunchWithNewCategoryCompletesStoredState() {
        let first = makeManager()
        first.registerConsentCategories(Self.registry)
        first.setConsent(Consent(explicit: true, optOut: ["c0001": false, "c0002": false, "c0004": false], timestamp: 10))

        let updated = makeManager()
        let (received, _) = subscribeRecording(updated)
        dispatcher.drain()
        updated.registerConsentCategories(Self.registry + [ConsentCategory(key: "c0005")])
        dispatcher.drain()

        let expected = ["c0001": false, "c0002": false, "c0004": false, "c0005": true]
        XCTAssertEqual(updated.getConsent().optOut, expected)
        XCTAssertEqual(received.values.last?.optOut, expected)
    }

    func testStaleRuleHoldsAcrossRelaunch() {
        let first = makeManager()
        first.setConsent(Consent(explicit: true, optOut: ["a": true], timestamp: 2_000))

        let relaunched = makeManager()

        XCTAssertFalse(relaunched.setConsent(Consent(explicit: true, optOut: ["a": false], timestamp: 1_000)))
        XCTAssertEqual(relaunched.getConsent().optOut, ["a": true])
    }

    // MARK: - clearConsent

    func testClearConsentResetsToImplicitDefaultAndWipesStorage() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        manager.setConsent(Consent(explicit: true, optOut: ["c0002": false]))
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()

        manager.clearConsent()
        dispatcher.drain()

        let implicitDefault = Consent(explicit: false, optOut: ["c0001": false, "c0002": true, "c0004": true])
        XCTAssertEqual(manager.getConsent(), implicitDefault)
        XCTAssertNil(storage.get())
        XCTAssertEqual(received.values.count, 2)
        XCTAssertEqual(received.values.last, implicitDefault)
    }

    func testClearConsentWhenNothingVisibleChangesDoesNotNotify() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()

        manager.clearConsent()
        dispatcher.drain()

        XCTAssertEqual(received.values.count, 1, "never set → clear is a visible no-op")
    }

    /// A logout clear followed by the CMP re-pushing its cached reject-all on the
    /// next launch, with an opt-in-default category registered. Were the watermark
    /// kept, the replay would be rejected and `c0001` would fall back to its
    /// opted-in default for a user who rejected everything.
    func testReplayAfterClearIsAppliedSoAnOptInDefaultCannotOptTheUserIn() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        let rejectAll = Consent(explicit: true, optOut: ["c0001": true, "c0002": true, "c0004": true], timestamp: 2_000)
        manager.setConsent(rejectAll)
        manager.clearConsent()
        XCTAssertNil(storage.get(), "clear wipes the watermark with the consent")
        XCTAssertEqual(manager.getConsent().optOut["c0001"], false, "implicit default: c0001 opted in")

        let relaunched = makeManager()
        relaunched.registerConsentCategories(Self.registry)

        XCTAssertTrue(relaunched.setConsent(rejectAll))
        XCTAssertEqual(relaunched.getConsent().optOut, ["c0001": true, "c0002": true, "c0004": true])
    }

    /// A wrong-unit timestamp (here microseconds) must not become the watermark —
    /// every later real timestamp would lose until the next clear.
    func testTimestampTooLargeForMillisecondsIsAppliedAsUntimestamped() {
        let asserts = captureDebugAsserts()
        let manager = makeManager()
        clock.now = 7_000
        XCTAssertTrue(manager.setConsent(Consent(explicit: true, optOut: ["a": true], timestamp: 1_757_400_000_000_000)))

        XCTAssertEqual(manager.getConsent().timestamp, 7_000, "stamped by the device clock, like an untimestamped call")
        XCTAssertNil(storage.get()?.lastHostTimestamp, "never became the watermark")
        XCTAssertEqual(asserts.values.count, 0, "vendor data: warns, never asserts")
        XCTAssertTrue(manager.setConsent(Consent(explicit: true, optOut: ["a": false], timestamp: 1_757_400_000_000)),
                      "a real millisecond timestamp still applies")
    }

    func testFreshChoiceAfterWithdrawalIsAccepted() {
        let manager = makeManager()
        manager.setConsent(Consent(explicit: true, optOut: ["a": false], timestamp: 2_000))
        manager.clearConsent()

        XCTAssertTrue(manager.setConsent(Consent(explicit: true, optOut: ["a": true], timestamp: 1_500)), "older than the cleared watermark")
        manager.clearConsent()
        XCTAssertTrue(manager.setConsent(Consent(explicit: true, optOut: ["a": false])), "untimestamped is never rejected")
        XCTAssertEqual(manager.getConsent().optOut, ["a": false])
    }

    // MARK: - subscribe

    func testSubscribeEmitsCurrentValueImmediately() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        manager.setConsent(Consent(explicit: true, optOut: ["c0002": false]))

        let (received, _) = subscribeRecording(manager)
        XCTAssertEqual(received.values.count, 0, "delivery is asynchronous, never inline on the subscribing thread")
        dispatcher.drain()

        XCTAssertEqual(received.values, [manager.getConsent()])
    }

    func testSubscribeFiresOnChangeNotOnNoOpSet() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()

        manager.setConsent(Consent(explicit: true, optOut: ["c0002": false], timestamp: 1))
        manager.setConsent(Consent(explicit: true, optOut: ["c0002": false], timestamp: 2))  // same decision, fresher clock
        manager.setConsent(Consent(explicit: true, optOut: ["c0002": true], timestamp: 3))
        dispatcher.drain()

        XCTAssertEqual(received.values.count, 3, "initial + two real changes")
        XCTAssertEqual(received.values[1].optOut["c0002"], false)
        XCTAssertEqual(received.values[2].optOut["c0002"], true)
        XCTAssertEqual(manager.getConsent().timestamp, 3)
    }

    func testFirstSetEqualToImplicitDefaultDoesNotFire() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()

        manager.setConsent(Consent(explicit: false, optOut: ["c0001": false, "c0002": true, "c0004": true]))
        dispatcher.drain()

        XCTAssertEqual(received.values.count, 1, "nothing a subscriber can see changed")
        XCTAssertNotNil(storage.get(), "but the host's set is still recorded")
    }

    func testUnsubscribeStopsDeliveryAndIsIdempotent() {
        let manager = makeManager()
        let (received, unsubscribe) = subscribeRecording(manager)
        dispatcher.drain()

        unsubscribe()
        unsubscribe()
        manager.setConsent(Consent(explicit: true, optOut: ["a": true]))
        dispatcher.drain()

        XCTAssertEqual(received.values.count, 1)
    }

    func testMultipleSubscribersEachReceiveChanges() {
        let manager = makeManager()
        let (a, _) = subscribeRecording(manager)
        let (b, _) = subscribeRecording(manager)
        dispatcher.drain()

        manager.setConsent(Consent(explicit: true, optOut: ["a": true]))
        dispatcher.drain()

        XCTAssertEqual(a.values.count, 2)
        XCTAssertEqual(b.values.count, 2)
    }

    /// Enqueue-inside-the-lock is the ordering guarantee: under concurrent sets a
    /// subscriber must see commits in commit order, and its last delivery must be
    /// the state `getConsent()` reports.
    func testDeliveryOrderMatchesCommitOrderUnderConcurrentSets() {
        let manager = makeManager()
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()

        DispatchQueue.concurrentPerform(iterations: 64) { i in
            manager.setConsent(Consent(explicit: true, optOut: ["n": i % 2 == 0], timestamp: Int64(i)))
        }
        dispatcher.drain()

        let timestamps = received.values.dropFirst().compactMap(\.timestamp)
        XCTAssertEqual(timestamps, timestamps.sorted(), "deliveries never go backwards in time")
        XCTAssertEqual(received.values.last, manager.getConsent())
        XCTAssertEqual(manager.getConsent().timestamp, 63)
    }

    /// The production dispatcher: handlers land on the main thread.
    func testDefaultDispatcherDeliversOnMainThread() {
        let manager = ConsentManager(storage: storage)
        let delivered = expectation(description: "handler ran")
        let onMain = Received()

        let unsubscribe = manager.subscribe { consent in
            onMain.append(Consent(explicit: Thread.isMainThread, optOut: consent.optOut))
            delivered.fulfill()
        }
        defer { unsubscribe() }

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(onMain.values.first?.explicit, true)
    }

    /// A handler may call back into the manager — it runs off the lock.
    func testHandlerMayReenterManager() {
        let manager = makeManager()
        let seen = Received()
        _ = manager.subscribe { _ in seen.append(manager.getConsent()) }

        manager.setConsent(Consent(explicit: true, optOut: ["a": true]))
        dispatcher.drain()

        XCTAssertEqual(seen.values.count, 2)
    }

    // MARK: - Review follow-ups

    /// A subscriber attached before registration (nothing stored) must hear the
    /// implicit default change when the registry arrives — registration is a commit
    /// like any other.
    func testRegistrationWithNothingStoredNotifiesSubscribersOfTheNewImplicitDefault() {
        let manager = makeManager()
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()
        XCTAssertEqual(received.values, [Consent(explicit: false, optOut: [:])])

        manager.registerConsentCategories(Self.registry)
        dispatcher.drain()

        XCTAssertEqual(received.values.last, Consent(explicit: false, optOut: ["c0001": false, "c0002": true, "c0004": true]))
        XCTAssertEqual(received.values.count, 2)
    }

    func testRegistrationAfterClearNotifiesWhenTheImplicitDefaultChanges() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        manager.setConsent(Consent(explicit: true, optOut: ["c0002": false]))
        manager.clearConsent()
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()

        manager.registerConsentCategories([ConsentCategory(key: "analytics", defaultOptOut: false)])
        dispatcher.drain()

        XCTAssertEqual(received.values.last?.optOut, ["analytics": false])
        XCTAssertEqual(received.values.count, 2)
    }

    /// Storage holds the raw snapshot, so a category one registration drops and a
    /// later one re-adds comes back with the user's decision — never a default the
    /// user did not choose.
    func testReRegistrationNeverLosesTheUsersDecisionForDroppedKeys() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        manager.setConsent(Consent(explicit: true, optOut: ["c0001": false, "c0002": false, "c0004": false], timestamp: 1))

        manager.registerConsentCategories([ConsentCategory(key: "c0001", defaultOptOut: false), ConsentCategory(key: "c0002")])
        XCTAssertEqual(manager.getConsent().optOut, ["c0001": false, "c0002": false], "view narrows")
        XCTAssertEqual(storage.get()?.consent.optOut, ["c0001": false, "c0002": false, "c0004": false],
                       "storage does not narrow")

        manager.registerConsentCategories(Self.registry)
        XCTAssertEqual(manager.getConsent().optOut["c0004"], false, "the user's opt-in survives the round trip")

        let relaunched = makeManager()
        relaunched.registerConsentCategories(Self.registry)
        XCTAssertEqual(relaunched.getConsent().optOut["c0004"], false, "and survives a relaunch")
    }

    /// Unsubscribing must also cancel deliveries that are already queued: a host that
    /// unsubscribes in deinit must not get one more callback on the next run-loop turn.
    func testUnsubscribeCancelsAlreadyQueuedDeliveries() {
        let manager = makeManager()
        let received = Received()

        let unsubscribe = manager.subscribe { received.append($0) }   // initial emission queued
        manager.setConsent(Consent(explicit: true, optOut: ["a": true]))  // change queued
        XCTAssertEqual(dispatcher.pendingCount, 2)
        unsubscribe()
        dispatcher.drain()

        XCTAssertEqual(received.values.count, 0, "nothing delivered after unsubscribe returned")
    }

    /// A handler that unsubscribes itself mid-delivery stops receiving, and the
    /// other subscribers are unaffected.
    func testHandlerMayUnsubscribeItselfDuringDelivery() {
        let manager = makeManager()
        let received = Received()
        let box = UnsubscribeBox()
        box.unsubscribe = manager.subscribe { consent in
            received.append(consent)
            if consent.optOut["a"] == true { box.unsubscribe?() }
        }
        let (other, _) = subscribeRecording(manager)
        dispatcher.drain()

        manager.setConsent(Consent(explicit: true, optOut: ["a": true]))
        dispatcher.drain()
        manager.setConsent(Consent(explicit: true, optOut: ["a": false]))
        dispatcher.drain()

        XCTAssertEqual(received.values.count, 2, "initial + the change it unsubscribed in")
        XCTAssertEqual(other.values.count, 3)
    }

    private final class UnsubscribeBox: @unchecked Sendable {
        var unsubscribe: ConsentUnsubscribe?
    }

    /// Registering an empty set after a non-empty one drops back to raw passthrough
    /// of the stored snapshot, and subscribers hear it.
    func testEmptyRegistrationAfterANonEmptyOneFallsBackToPassthrough() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        manager.setConsent(Consent(explicit: true, optOut: ["c0002": false, "junk": true]))
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()

        manager.registerConsentCategories([])
        dispatcher.drain()

        XCTAssertEqual(manager.getConsent().optOut, ["c0002": false, "junk": true])
        XCTAssertEqual(received.values.last?.optOut, ["c0002": false, "junk": true])
        XCTAssertEqual(received.values.count, 2)

        manager.clearConsent()
        XCTAssertEqual(manager.getConsent(), Consent(explicit: false, optOut: [:]), "empty implicit default")
    }

    func testReplaceStorageForTestingRebuildsStateAndDropsSubscribers() {
        let manager = makeManager()
        manager.registerConsentCategories(Self.registry)
        manager.setConsent(Consent(explicit: true, optOut: ["c0002": false]))
        let (received, _) = subscribeRecording(manager)
        dispatcher.drain()

        let otherSuite = "com.metarouter.test.consentManager.other.\(UUID().uuidString)"
        let other = UserDefaults(suiteName: otherSuite)!
        defer { other.removePersistentDomain(forName: otherSuite) }
        ConsentStorage(userDefaults: other).set(StoredConsent(consent: Consent(explicit: true, optOut: ["z": true], timestamp: 3), lastHostTimestamp: 3))

        manager._replaceStorageForTesting(ConsentStorage(userDefaults: other))
        manager.setConsent(Consent(explicit: true, optOut: ["y": true]))
        dispatcher.drain()

        XCTAssertEqual(manager.getConsent().optOut, ["y": true], "empty registry → raw passthrough from the new storage")
        XCTAssertEqual(received.values.count, 1, "old subscriber was dropped")
        XCTAssertNil(storage.get()?.consent.optOut["y"], "old storage untouched")
    }

    /// Persistence runs off the manager lock: a host observing UserDefaults changes
    /// and reading consent back from inside the notification must not deadlock, and
    /// a nested setConsent from there must persist in order (last commit wins on disk).
    func testUserDefaultsObserverMayReenterTheManagerDuringPersist() {
        let manager = makeManager()
        let observed = Received()
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in
            observed.append(manager.getConsent())
            if manager.getConsent().optOut["a"] == true {
                manager.setConsent(Consent(explicit: true, optOut: ["a": false], timestamp: 2))
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.setConsent(Consent(explicit: true, optOut: ["a": true], timestamp: 1))

        XCTAssertEqual(manager.getConsent().optOut, ["a": false])
        XCTAssertEqual(storage.get()?.consent.optOut, ["a": false], "disk ends on the latest commit")
        XCTAssertGreaterThanOrEqual(observed.values.count, 1)
    }
}
