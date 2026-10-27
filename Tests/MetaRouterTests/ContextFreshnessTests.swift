import XCTest
@testable import MetaRouter

/// The context freshness contract: static fields are cached once, `network` is read
/// live per event, and `device.advertisingId` is overlaid per event. Pins the
/// behaviour Android matches so the two SDKs cannot drift on it silently.
final class ContextFreshnessTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var identity: IdentityManager!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.metarouter.test.contextFreshness.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        identity = IdentityManager(
            storage: IdentityStorage(userDefaults: defaults),
            writeKey: "wk", host: "https://test.com"
        )
        await identity.initialize()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeService(
        provider: ContextProvider = StaticContextProvider(),
        monitor: NetworkReachability?
    ) -> EventEnrichmentService {
        EventEnrichmentService(
            contextProvider: provider,
            identityManager: identity,
            writeKey: "wk",
            sessionManager: SessionManager(storage: SessionStorage(userDefaults: defaults)),
            consentManager: ConsentManager(storage: ConsentStorage(userDefaults: defaults)),
            providerContextManager: ProviderContextManager(storage: ProviderContextStorage(userDefaults: defaults)),
            networkMonitor: monitor
        )
    }

    private func contextJSON(_ payload: EnrichedEventPayload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["context"] as? [String: Any])
    }

    // MARK: network

    func testNetworkWifiTracksInterfaceSwitchOnNextEvent() async {
        let monitor = StubNetworkMonitor(isWifi: true)
        let service = makeService(monitor: monitor)

        let first = await service.createTrackEvent(event: "a")
        XCTAssertEqual(first.context.network?.wifi, true)

        monitor.setWifi(false)
        let second = await service.createTrackEvent(event: "b")
        XCTAssertEqual(second.context.network?.wifi, false)

        monitor.setWifi(true)
        let third = await service.createTrackEvent(event: "c")
        XCTAssertEqual(third.context.network?.wifi, true)
    }

    func testUnknownInterfaceOmitsNetworkObjectOnTheWire() async throws {
        let service = makeService(monitor: StubNetworkMonitor(isWifi: nil))
        let payload = await service.createTrackEvent(event: "a")
        let context = try contextJSON(payload)
        XCTAssertNil(context["network"], "spec: wifi must be a boolean when network is present — omit, never null")
    }

    func testUnknownInterfaceKeepsCustomProviderNetwork() async {
        let provider = StaticContextProvider(network: NetworkContext(wifi: true))
        let service = makeService(provider: provider, monitor: StubNetworkMonitor(isWifi: nil))
        let payload = await service.createTrackEvent(event: "a")
        XCTAssertEqual(payload.context.network?.wifi, true)
    }

    func testDeviceContextProviderNoLongerCarriesNetwork() async {
        let context = await DeviceContextProvider().getContext()
        XCTAssertNil(context.network)
    }

    func testDebouncedMonitorPassesWifiThroughWithoutDebounce() {
        let inner = StubNetworkMonitor(isWifi: true)
        let debounced = DebouncedNetworkMonitor(inner: inner, debounceSeconds: 60)
        XCTAssertEqual(debounced.isWifi, true)
        inner.setWifi(false)
        XCTAssertEqual(debounced.isWifi, false)
    }

    func testStoppedMonitorReportsUnknownWifi() {
        let monitor = NetworkMonitor()
        monitor.stop()
        XCTAssertNil(monitor.isWifi, "a stopped monitor must not keep stamping its last interface")
    }

    func testColdLaunchEventWaitsForFirstPathInsteadOfOmittingNetwork() async {
        let service = makeService(monitor: LateFirstPathReachability(deliverAfter: 0.05, isWifi: true))
        let payload = await service.createTrackEvent(event: "Application Opened")
        XCTAssertEqual(payload.context.network?.wifi, true)
    }

    func testRealMonitorDeliversFirstPathWithinTheBound() async {
        let monitor = NetworkMonitor()
        defer { monitor.stop() }
        let wifi = await monitor.awaitIsWifi(timeout: 2)
        XCTAssertNotNil(wifi, "NWPathMonitor delivers its first path promptly after start")
    }

    func testStoppedMonitorDoesNotMakeEventsWait() async {
        let monitor = NetworkMonitor()
        monitor.stop()
        let start = Date()
        let wifi = await monitor.awaitIsWifi(timeout: 5)
        XCTAssertNil(wifi)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testInvalidTimeoutsDoNotTrap() async {
        let monitor = NetworkMonitor()
        defer { monitor.stop() }
        _ = await monitor.awaitIsWifi(timeout: -1)
        _ = await monitor.awaitIsWifi(timeout: .nan)
        _ = await monitor.awaitIsWifi(timeout: .infinity)
    }

    func testLegacyConformerDefaultsToUnknownWifi() {
        XCTAssertNil(LegacyReachability().isWifi)
    }

    // MARK: advertisingId

    func testAdvertisingIdSetChangeClearReflectOnNextEvent() async throws {
        let service = makeService(monitor: nil)
        let first = "550E8400-E29B-41D4-A716-446655440000"
        let second = "6D92078A-8246-4BA4-AE5B-76104861E7DC"

        let before = await service.createTrackEvent(event: "a")
        XCTAssertNil(before.context.device.advertisingId)

        await identity.setAdvertisingId(first)
        let afterSet = await service.createTrackEvent(event: "b")
        XCTAssertEqual(afterSet.context.device.advertisingId, first)

        await identity.setAdvertisingId(second)
        let afterChange = await service.createTrackEvent(event: "c")
        XCTAssertEqual(afterChange.context.device.advertisingId, second)

        await identity.clearAdvertisingId()
        let afterClear = await service.createTrackEvent(event: "d")
        XCTAssertNil(afterClear.context.device.advertisingId)
        XCTAssertNil(try contextJSON(afterClear)["device"].flatMap { ($0 as? [String: Any])?["advertisingId"] })
    }

    func testAdvertisingIdOverlayKeepsStaticDeviceFields() async {
        let service = makeService(monitor: nil)
        await identity.setAdvertisingId("550E8400-E29B-41D4-A716-446655440000")
        let payload = await service.createTrackEvent(event: "a")
        XCTAssertEqual(payload.context.device.manufacturer, "Apple")
        XCTAssertEqual(payload.context.device.model, "iPhone15,2")
        XCTAssertEqual(payload.context.device.type, "ios")
    }

    func testProviderAdvertisingIdOverlaysWithoutClearingCache() async {
        let provider = DeviceContextProvider()
        _ = await provider.getContext()
        await provider.setAdvertisingId("550E8400-E29B-41D4-A716-446655440000")
        let withId = await provider.getContext()
        XCTAssertEqual(withId.device.advertisingId, "550E8400-E29B-41D4-A716-446655440000")
        await provider.setAdvertisingId(nil)
        let cleared = await provider.getContext()
        XCTAssertNil(cleared.device.advertisingId)
    }
}

/// Delivers its first path only after a delay, like NWPathMonitor at cold launch.
private final class LateFirstPathReachability: NetworkReachability, @unchecked Sendable {
    private let deliverAfter: TimeInterval
    private let wifi: Bool

    init(deliverAfter: TimeInterval, isWifi: Bool) {
        self.deliverAfter = deliverAfter
        self.wifi = isWifi
    }

    var currentStatus: NetworkStatus { .connected }
    var isWifi: Bool? { nil }
    func onStatusChange(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {}
    func stop() {}

    func awaitIsWifi(timeout: TimeInterval) async -> Bool? {
        guard deliverAfter <= timeout else { return nil }
        try? await Task.sleep(nanoseconds: UInt64(deliverAfter * 1_000_000_000))
        return wifi
    }
}

private final class LegacyReachability: NetworkReachability, @unchecked Sendable {
    var currentStatus: NetworkStatus { .connected }
    func onStatusChange(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {}
    func stop() {}
}

private final class StaticContextProvider: ContextProvider, @unchecked Sendable {
    private let network: NetworkContext?

    init(network: NetworkContext? = nil) {
        self.network = network
    }

    func getContext() async -> EventContext {
        EventContext(
            app: AppContext(name: "T", version: "1", build: "1", namespace: "t"),
            device: DeviceContext(manufacturer: "Apple", model: "iPhone15,2", type: "ios"),
            library: LibraryContext(name: "t", version: "1"),
            os: OSContext(name: "iOS", version: "17.0"),
            screen: ScreenContext(density: 3.0, width: 1, height: 1),
            network: network,
            locale: "en_US",
            timezone: "UTC"
        )
    }

    func clearCache() {}
}
