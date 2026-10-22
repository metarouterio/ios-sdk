import XCTest
@testable import MetaRouter

/// Provider context through the proxy acts on the shared manager directly — never
/// queued, never dependent on a bind, never forwarded to the bound client (which
/// stamps from that same manager). The queue bypass is what these pin: `ProxyState`
/// drops its OLDEST entry at capacity, so a queued set would be the first casualty
/// of a pre-initialize burst.
final class ProviderContextProxyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: ProviderContextStorage!
    private var manager: ProviderContextManager!
    private var proxy: AnalyticsProxy!
    private var mockClient: MockAnalyticsInterface!

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.providerContextProxy.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = ProviderContextStorage(userDefaults: defaults)
        manager = ProviderContextManager(storage: storage)
        proxy = AnalyticsProxy(providerContextManager: manager)
        mockClient = MockAnalyticsInterface()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        storage = nil
        manager = nil
        proxy = nil
        mockClient = nil
        super.tearDown()
    }

    // MARK: - Through MetaRouter: one manager for proxy and client

    /// The public entry point, end to end: set on `MetaRouter.Analytics.shared`
    /// before `initialize`, read through the bound client, then `reset()` and
    /// re-initialize. The process-wide manager is pointed at this test's suite for
    /// the duration, so nothing lands in `UserDefaults.standard`.
    func testSetBeforeInitializeThroughMetaRouterSurvivesResetAndReinitialize() async {
        await MetaRouter.Analytics.resetAndWait()
        MetaRouter._providerContextManagerForTesting._replaceStorageForTesting(storage)
        addTeardownBlock {
            await MetaRouter.Analytics.resetAndWait()
            MetaRouter._providerContextManagerForTesting._replaceStorageForTesting(ProviderContextStorage())
        }
        let expected: [String: [String: CodableValue]] = ["googleFirebase": ["appInstanceId": .string("abc123")]]

        XCTAssertTrue(MetaRouter.Analytics.shared.setProviderContext("googleFirebase", key: "appInstanceId", value: "abc123"))
        XCTAssertFalse(MetaRouter.Analytics.shared.setProviderContext("Meta_Router", key: "sessionID", value: "x"))

        let client = await MetaRouter.Analytics.initializeAndWait(with: TestDataFactory.makeInitOptions())
        XCTAssertEqual(client.getProviderContext(), expected)
        let debug = await client.getDebugInfo()
        XCTAssertEqual(debug["providerContext"], .object(["googleFirebase": .array([.string("appInstanceId")])]))

        await MetaRouter.Analytics.resetAndWait()
        XCTAssertEqual(MetaRouter.Analytics.shared.getProviderContext(), expected, "reset() leaves provider context")
        XCTAssertEqual(storage.get(), expected)

        let reinitialized = await MetaRouter.Analytics.initializeAndWait(with: TestDataFactory.makeInitOptions())
        XCTAssertEqual(reinitialized.getProviderContext(), expected)
    }

    // MARK: - Before any bind

    func testProviderContextIsFullyUsableBeforeBind() {
        proxy.setProviderContext("googleFirebase", key: "appInstanceId", value: "abc123")

        XCTAssertEqual(proxy.getProviderContext(), ["googleFirebase": ["appInstanceId": .string("abc123")]])
        XCTAssertEqual(storage.get(), ["googleFirebase": ["appInstanceId": .string("abc123")]],
                       "persisted immediately — nothing waits for a bind")
    }

    /// A proxy on a later launch must see the previous launch's values at once:
    /// cold-launch events are enriched during initialize(), with no later fix-up.
    func testPreBindReadSeesValuesPersistedByAPriorLaunch() {
        storage.set(["googleFirebase": ["appInstanceId": .string("from-last-launch")]])
        let relaunched = AnalyticsProxy(
            providerContextManager: ProviderContextManager(storage: storage)
        )

        XCTAssertEqual(
            relaunched.getProviderContext(),
            ["googleFirebase": ["appInstanceId": .string("from-last-launch")]]
        )
    }

    func testClearWorksBeforeBind() {
        proxy.setProviderContext("googleFirebase", key: "appInstanceId", value: "abc123")
        proxy.clearProviderContext("googleFirebase")

        XCTAssertEqual(proxy.getProviderContext(), [:])
        XCTAssertNil(storage.get())
    }

    func testClearAllWorksBeforeBind() {
        proxy.setProviderContext("a", key: "k", value: "1")
        proxy.setProviderContext("b", key: "k", value: "2")
        proxy.clearAllProviderContext()

        XCTAssertEqual(proxy.getProviderContext(), [:])
    }

    // MARK: - Queue bypass

    /// The regression the design exists to avoid: `ProxyState` holds 20 pending
    /// calls and evicts the OLDEST, so a queued set would lose precisely the value
    /// every subsequent event needs.
    func testSetSurvivesAPreBindBurstThatWouldOverflowTheCallQueue() async {
        proxy.setProviderContext("googleFirebase", key: "appInstanceId", value: "abc123")
        for i in 0..<60 {
            proxy.track("filler-\(i)")
        }

        XCTAssertEqual(proxy.getProviderContext(), ["googleFirebase": ["appInstanceId": .string("abc123")]])

        await proxy._bindAndReplay(mockClient)

        XCTAssertEqual(
            proxy.getProviderContext(),
            ["googleFirebase": ["appInstanceId": .string("abc123")]],
            "the value must still be there after the queue replayed and dropped events"
        )
    }

    func testSetIsNeverForwardedToTheBoundClient() async {
        await proxy._bindAndReplay(mockClient)
        mockClient.resetMock()

        proxy.setProviderContext("googleFirebase", key: "appInstanceId", value: "abc123")
        _ = proxy.getProviderContext()
        proxy.clearProviderContext("googleFirebase")
        proxy.clearAllProviderContext()

        // The client stamps from this same manager; forwarding would be a second,
        // queue-racing write of the same state.
        XCTAssertEqual(mockClient.calls, [])
    }

    func testValuesSetBeforeBindRemainVisibleAfterUnbind() async {
        proxy.setProviderContext("googleFirebase", key: "appInstanceId", value: "abc123")
        await proxy._bindAndReplay(mockClient)
        await proxy._unbindAndClear()

        // reset() tears the client down; this is install-scoped and outlives it,
        // exactly like consent.
        XCTAssertEqual(proxy.getProviderContext(), ["googleFirebase": ["appInstanceId": .string("abc123")]])
    }

    // MARK: - Debug info

    func testPreBindDebugInfoReportsTheShapeTheSdkIsHolding() async {
        proxy.setProviderContext("googleFirebase", key: "appInstanceId", value: "abc123")

        let info = await proxy.getDebugInfo()

        XCTAssertEqual(
            info["providerContext"],
            .object(["googleFirebase": .array([.string("appInstanceId")])])
        )
    }
}
