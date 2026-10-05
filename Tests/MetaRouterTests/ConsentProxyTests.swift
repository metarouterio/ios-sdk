import XCTest
@testable import MetaRouter

/// Consent through the proxy acts on the shared manager directly — never queued,
/// never dependent on a bind, never forwarded to the bound client (which stamps
/// from that same manager).
///
/// Main-actor isolated because the manager's inline test dispatcher runs handlers
/// on the calling thread and delivery asserts main-actor isolation; async XCTest
/// methods otherwise run off the main actor.
@MainActor
final class ConsentProxyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var manager: ConsentManager!
    private var proxy: AnalyticsProxy!
    private var mockClient: MockAnalyticsInterface!

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Consent] = []
        var values: [Consent] { lock.withLock { _values } }
        func append(_ c: Consent) { lock.withLock { _values.append(c) } }
    }

    private static let registry = [
        ConsentCategory(key: "c0001", defaultOptOut: false),
        ConsentCategory(key: "c0002"),
    ]

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.consentProxy.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        manager = ConsentManager(storage: ConsentStorage(userDefaults: defaults), dispatch: { $0() })
        proxy = AnalyticsProxy(consentManager: manager)
        mockClient = MockAnalyticsInterface()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        manager = nil
        proxy = nil
        mockClient = nil
        super.tearDown()
    }

    // MARK: - Before any bind

    func testConsentIsFullyUsableBeforeBind() {
        proxy.registerConsentCategories(Self.registry)
        XCTAssertEqual(proxy.getConsent(), Consent(explicit: false, optOut: ["c0001": false, "c0002": true]))

        proxy.setConsent(Consent(explicit: true, optOut: ["c0002": false], timestamp: 1))

        XCTAssertEqual(proxy.getConsent(), Consent(explicit: true, optOut: ["c0001": false, "c0002": false], timestamp: 1))
        XCTAssertEqual(ConsentStorage(userDefaults: defaults).get()?.consent.optOut, ["c0002": false],
                       "persisted immediately — nothing waits for a bind")
    }

    /// A proxy created on a later launch must see the previous launch's consent at
    /// once; a pre-bind read that answered "implicit default" would be a lie.
    func testPreBindReadSeesConsentPersistedByAPriorLaunch() {
        ConsentStorage(userDefaults: defaults).set(StoredConsent(
            consent: Consent(explicit: true, optOut: ["c0002": true], timestamp: 5), lastHostTimestamp: 5
        ))
        let relaunched = AnalyticsProxy(consentManager: ConsentManager(storage: ConsentStorage(userDefaults: defaults)))

        XCTAssertEqual(relaunched.getConsent().optOut, ["c0002": true])
        XCTAssertTrue(relaunched.getConsent().explicit)
    }

    func testSubscribeBeforeBindEmitsCurrentAndThenChanges() {
        proxy.registerConsentCategories(Self.registry)
        let received = Received()

        let unsubscribe = proxy.subscribeToConsent { received.append($0) }
        proxy.setConsent(Consent(explicit: true, optOut: ["c0001": true]))
        unsubscribe()
        proxy.setConsent(Consent(explicit: true, optOut: ["c0001": false]))

        XCTAssertEqual(received.values.map(\.optOut), [["c0001": false, "c0002": true], ["c0001": true, "c0002": true]])
    }

    func testClearConsentBeforeBind() {
        proxy.registerConsentCategories(Self.registry)
        proxy.setConsent(Consent(explicit: true, optOut: ["c0001": true]))

        proxy.clearConsent()

        XCTAssertEqual(proxy.getConsent(), Consent(explicit: false, optOut: ["c0001": false, "c0002": true]))
        XCTAssertNil(ConsentStorage(userDefaults: defaults).get())
    }

    // MARK: - Across bind

    /// Consent is never replayed or forwarded: the bound client reads the same
    /// manager, so forwarding would be a second write of the same state at best
    /// and, through the queue, a lost or reordered one at worst.
    func testBoundProxyStillActsOnTheManagerAndNeverForwardsToTheClient() async {
        await proxy._bindAndReplay(mockClient)

        proxy.registerConsentCategories(Self.registry)
        proxy.setConsent(Consent(explicit: true, optOut: ["c0002": false]))
        _ = proxy.getConsent()
        proxy.subscribeToConsent { _ in }
        proxy.clearConsent()

        XCTAssertEqual(mockClient.callCount, 0, "consent must not reach the client: \(mockClient.calls)")
        XCTAssertEqual(manager.getConsent(), Consent(explicit: false, optOut: ["c0001": false, "c0002": true]))
    }

    func testConsentSetBeforeBindIsStillThereAfterBindAndAfterUnbind() async {
        proxy.setConsent(Consent(explicit: true, optOut: ["a": true], timestamp: 9))

        await proxy._bindAndReplay(mockClient)
        XCTAssertEqual(proxy.getConsent().optOut, ["a": true])

        await proxy._unbindAndClear()
        XCTAssertEqual(proxy.getConsent().optOut, ["a": true], "unbind (reset) must not touch consent")
    }

    /// Unlike the queued calls, consent does not have to fit in the pending-call cap.
    func testConsentIsNotSubjectToThePendingQueueCap() {
        for i in 0..<40 { proxy.track("filler \(i)") }

        proxy.setConsent(Consent(explicit: true, optOut: ["a": true]))

        XCTAssertEqual(proxy.getConsent().optOut, ["a": true])
    }
}
