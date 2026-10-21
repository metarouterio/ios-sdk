import XCTest
import WebKit
@testable import MetaRouter

/// A host type conforming to `AnalyticsInterface` that implements none of the
/// requirements added for the WebView bridge or consent. It
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
        let unsubscribe = host.subscribeToConsent { _ in }
        unsubscribe()

        XCTAssertEqual(host.getConsent(), Consent(explicit: false, optOut: [:]))
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
        let unsubscribe = target.subscribeToConsent { _ in }
        unsubscribe()
        target.clearConsent()
    }

    /// The defaults removed the compiler's witness check, so this is what catches an
    /// SDK method whose signature drifted off the requirement: the call would land on
    /// the warn-and-ignore default instead — a consent withdrawal silently dropped.
    @MainActor
    func testSdkTypesNeverFallThroughToADefault() {
        let iso = SessionIsolatedDefaults(label: "protocolDefaults")
        defer { iso.cleanUp() }
        var deps = iso.deps
        deps.consentManager = ConsentManager(storage: iso.consentStorage, dispatch: { $0() })
        let client = AnalyticsClient.initialize(options: TestDataFactory.makeInitOptions(), deps: deps)
        let proxy = AnalyticsProxy(consentManager: deps.consentManager!)
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

        XCTAssertEqual(ProtocolDefaultProbe.hits.count, 6)
    }
}
