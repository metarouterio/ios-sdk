import XCTest
import WebKit
@testable import MetaRouter

/// A host type conforming to `AnalyticsInterface` that implements none of the
/// requirements added for the WebView bridge, consent, or provider context. It
/// compiling at all is the main assertion: without the protocol-extension defaults,
/// every minor release that grows the protocol breaks hosts' builds.
private final class LegacyHostFake: AnalyticsInterface, @unchecked Sendable {
    func track(_ event: String, properties: [String: Any]?) {}
    func track(_ event: String) {}
    func identify(_ userId: String, traits: [String: Any]?) {}
    func identify(_ userId: String) {}
    func group(_ groupId: String, traits: [String: Any]?) {}
    func group(_ groupId: String) {}
    func screen(_ name: String, properties: [String: Any]?) {}
    func screen(_ name: String) {}
    func page(_ name: String, properties: [String: Any]?) {}
    func page(_ name: String) {}
    func alias(_ newUserId: String) {}
    func enableDebugLogging() {}
    func getAnonymousId() async -> String { "" }
    func getSessionId() async -> String? { nil }
    func getDebugInfo() async -> [String: CodableValue] { [:] }
    func flush() {}
    func reset() {}
    func setAdvertisingId(_ advertisingId: String?) {}
    func clearAdvertisingId() {}
    func setTracing(_ enabled: Bool) {}
    func recordOpenedURL(_ url: URL, sourceApplication: String?) {}
}

final class ProtocolDefaultsTests: XCTestCase {

    func testDefaultsAreSafeNoOps() {
        let host: AnalyticsInterface = LegacyHostFake()

        host.registerConsentCategories([ConsentCategory(key: "c0001")])
        host.setConsent(Consent(explicit: true, optOut: ["c0001": true]))
        host.clearConsent()
        XCTAssertFalse(host.setConsent(Consent(explicit: true, optOut: ["c0001": true])), "nothing was applied")
        let subscription = host.subscribeToConsent { _ in }
        subscription.cancel()
        XCTAssertTrue(subscription.isCancelled)
        host.setProviderContext("googleFirebase", key: "appInstanceId", value: "x")
        host.clearProviderContext("googleFirebase")
        host.clearAllProviderContext()

        XCTAssertEqual(host.getConsent(), Consent(explicit: false, optOut: [:]))
        XCTAssertEqual(host.getProviderContext(), [:])
    }

    @MainActor
    func testAttachWebViewDefaultIsANoOp() {
        let host: AnalyticsInterface = LegacyHostFake()
        host.attachWebView(WKWebView(), allowedOrigins: ["https://example.com"])
    }

    /// Every defaulted requirement, driven through the protocol. A host holding
    /// `AnalyticsInterface` dispatches exactly this way.
    @MainActor
    private func driveEveryDefaultedRequirement(_ target: AnalyticsInterface) {
        target.attachWebView(WKWebView(), allowedOrigins: ["https://example.com"])
        target.registerConsentCategories([ConsentCategory(key: "c0001")])
        target.setConsent(Consent(explicit: true, optOut: ["c0001": true]))
        _ = target.getConsent()
        target.subscribeToConsent { _ in }.cancel()
        target.clearConsent()
        target.setProviderContext("googleFirebase", key: "appInstanceId", value: "x")
        _ = target.getProviderContext()
        target.clearProviderContext("googleFirebase")
        target.clearAllProviderContext()
    }

    /// The defaults removed the compiler's witness check, so this is what catches an
    /// SDK method whose signature drifted off the requirement: the call would land on
    /// the warn-and-ignore default instead — a consent withdrawal silently dropped.
    @MainActor
    func testSdkTypesNeverFallThroughToADefault() {
        let iso = SessionIsolatedDefaults(label: "protocolDefaults")
        defer { iso.cleanUp() }
        var deps = iso.deps
        deps.consentManager = ConsentManager(storage: iso.consentStorage)
        deps.providerContextManager = ProviderContextManager(storage: iso.providerContextStorage)
        let client = AnalyticsClient.initialize(options: TestDataFactory.makeInitOptions(), deps: deps)
        let proxy = AnalyticsProxy(
            consentManager: deps.consentManager!,
            providerContextManager: deps.providerContextManager!
        )
        ProtocolDefaultProbe.reset()

        driveEveryDefaultedRequirement(client)
        driveEveryDefaultedRequirement(proxy)

        XCTAssertEqual(ProtocolDefaultProbe.hits, [], "an SDK type fell through to a protocol default")
    }

    /// The probe itself must see a real fall-through, or the test above proves nothing.
    @MainActor
    func testProbeRecordsAHostConformerFallingThrough() {
        ProtocolDefaultProbe.reset()

        driveEveryDefaultedRequirement(LegacyHostFake())

        XCTAssertEqual(ProtocolDefaultProbe.hits.count, 10)
    }

    /// A wrapper that forwards `track` but not `getConsent` must not log per event.
    @MainActor
    func testDefaultWarnsOncePerTypeAndMethod() {
        ProtocolDefaultProbe.reset()
        let host: AnalyticsInterface = LegacyHostFake()

        let output = captureStderrAndStdout {
            for _ in 0..<5 { _ = host.getConsent() }
            host.clearConsent()
        }

        XCTAssertEqual(output.components(separatedBy: "getConsent is not implemented").count - 1, 1)
        XCTAssertEqual(output.components(separatedBy: "clearConsent is not implemented").count - 1, 1)
        XCTAssertEqual(ProtocolDefaultProbe.hits, ["LegacyHostFake.getConsent", "LegacyHostFake.clearConsent"])
    }
}
