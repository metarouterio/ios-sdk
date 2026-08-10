import XCTest
@testable import MetaRouter

/// Collects debug-assert messages: assertions are active in test builds, so the
/// release-degrade path is only testable with the fail-fast hook swapped out.
private final class AssertCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []
    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return _messages
    }
    func append(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        _messages.append(message)
    }
}

final class InitOptionsTests: XCTestCase {

    private func withCapturedAsserts(_ body: () -> InitOptions) -> (options: InitOptions, asserts: [String]) {
        let capture = AssertCapture()
        let original = InitOptions.debugAssert
        InitOptions.debugAssert = { capture.append($0) }
        defer { InitOptions.debugAssert = original }
        let options = body()
        return (options, capture.messages)
    }

    func testInitOptionsFromStringRemovesTrailingSlash() {
        let options = InitOptions(writeKey: "wk", ingestionHost: "https://example.com/")
        XCTAssertEqual(options.writeKey, "wk")
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://example.com")
    }

    func testInitOptionsFromStringTrimsWhitespace() {
        let options = InitOptions(writeKey: "wk", ingestionHost: "  https://example.com  ")
        XCTAssertEqual(options.ingestionHost.scheme, "https")
        XCTAssertEqual(options.ingestionHost.host, "example.com")
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://example.com")
    }

    func testInitOptionsFromURLStoresExactly() {
        let url = URL(string: "https://api.metarouter.io")!
        let options = InitOptions(writeKey: "wk", ingestionHost: url)
        XCTAssertEqual(options.ingestionHost, url)
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://api.metarouter.io")
    }

    func testInitOptionsFromStringWithPathPreserved() {
        let options = InitOptions(writeKey: "wk", ingestionHost: "https://host.tld/base")
        XCTAssertEqual(options.ingestionHost.path, "/base")
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://host.tld/base")
    }

    func testInversionWarningEmittedWhenDiskSmallerThanMemory() {
        let output = captureStderrAndStdout {
            _ = InitOptions(
                writeKey: "wk",
                ingestionHost: URL(string: "https://example.com")!,
                maxQueueEvents: 2000,
                maxDiskEvents: 500
            )
        }
        XCTAssertTrue(output.contains("maxDiskEvents"), "warning should mention maxDiskEvents, got: \(output)")
        XCTAssertTrue(output.contains("maxQueueEvents"), "warning should mention maxQueueEvents")
        XCTAssertTrue(output.contains("500") && output.contains("2000"), "warning should include both values")
    }

    func testNoInversionWarningWhenDiskLargerThanMemory() {
        let output = captureStderrAndStdout {
            _ = InitOptions(
                writeKey: "wk",
                ingestionHost: URL(string: "https://example.com")!,
                maxQueueEvents: 2000,
                maxDiskEvents: 10_000
            )
        }
        XCTAssertFalse(output.contains("maxDiskEvents") && output.contains("less than"),
                       "no inversion warning should fire when disk >= memory")
    }

    func testNoInversionWarningWhenDiskDisabled() {
        let output = captureStderrAndStdout {
            _ = InitOptions(
                writeKey: "wk",
                ingestionHost: URL(string: "https://example.com")!,
                maxQueueEvents: 2000,
                maxDiskEvents: 0
            )
        }
        XCTAssertFalse(output.contains("less than"),
                       "disk=0 is the 'disable persistence' case, not an inversion")
    }

    func testNoInversionWarningWhenEqual() {
        let output = captureStderrAndStdout {
            _ = InitOptions(
                writeKey: "wk",
                ingestionHost: URL(string: "https://example.com")!,
                maxQueueEvents: 2000,
                maxDiskEvents: 2000
            )
        }
        XCTAssertFalse(output.contains("less than"),
                       "equal values are not an inversion")
    }

    func testTrackLifecycleEventsDefaultsToFalse() {
        let urlOptions = InitOptions(
            writeKey: "wk",
            ingestionHost: URL(string: "https://example.com")!
        )
        XCTAssertFalse(urlOptions.trackLifecycleEvents,
                       "trackLifecycleEvents should default to false (URL initializer) — opt-in feature")

        let stringOptions = InitOptions(
            writeKey: "wk",
            ingestionHost: "https://example.com"
        )
        XCTAssertFalse(stringOptions.trackLifecycleEvents,
                       "trackLifecycleEvents should default to false (String initializer) — opt-in feature")
    }

    func testTrackLifecycleEventsCanBeEnabled() {
        let urlOptions = InitOptions(
            writeKey: "wk",
            ingestionHost: URL(string: "https://example.com")!,
            trackLifecycleEvents: true
        )
        XCTAssertTrue(urlOptions.trackLifecycleEvents)

        let stringOptions = InitOptions(
            writeKey: "wk",
            ingestionHost: "https://example.com",
            trackLifecycleEvents: true
        )
        XCTAssertTrue(stringOptions.trackLifecycleEvents)
    }

    // MARK: - Invalid-config contract: assert in debug, record + degrade in release

    func testEmptyWriteKeyRecordsConfigErrorInsteadOfTrapping() {
        let (options, asserts) = withCapturedAsserts {
            InitOptions(writeKey: "", ingestionHost: "https://example.com")
        }

        XCTAssertEqual(options.configError, .emptyWriteKey)
        XCTAssertEqual(asserts.count, 1, "debug builds fail fast at the construction site")
    }

    func testWhitespaceOnlyWriteKeyIsRejected() {
        // Heals the platform divergence: iOS accepted " " while Android rejected it.
        let (options, _) = withCapturedAsserts {
            InitOptions(writeKey: "   ", ingestionHost: "https://example.com")
        }

        XCTAssertEqual(options.configError, .emptyWriteKey)
    }

    func testWriteKeyIsStoredTrimmed() {
        let options = InitOptions(writeKey: "  wk  ", ingestionHost: "https://example.com")

        XCTAssertEqual(options.writeKey, "wk")
        XCTAssertNil(options.configError)
    }

    func testNonHTTPSchemeRecordsInvalidIngestionHost() {
        // Unified scheme policy (Android's): http/https only.
        let (options, asserts) = withCapturedAsserts {
            InitOptions(writeKey: "wk", ingestionHost: "ftp://example.com")
        }

        XCTAssertEqual(options.configError, .invalidIngestionHost("ftp://example.com"))
        XCTAssertEqual(asserts.count, 1)
    }

    func testUnparseableHostRecordsInvalidIngestionHostWithOriginalString() {
        let (options, _) = withCapturedAsserts {
            InitOptions(writeKey: "wk", ingestionHost: "not a url")
        }

        XCTAssertEqual(options.configError, .invalidIngestionHost("not a url"))
    }

    func testTrailingSlashOnURLInitIsTrimmedNotRejected() {
        // Previously a release trap; a cosmetic slash must never disable analytics.
        let options = InitOptions(writeKey: "wk", ingestionHost: URL(string: "https://example.com/")!)

        XCTAssertNil(options.configError)
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://example.com")
    }

    func testNegativeMaxDiskEventsClampsToZeroWithWarning() {
        // Previously a release trap; now the same clamp-with-warn policy as the
        // other numeric fields.
        var options: InitOptions?
        let output = captureStderrAndStdout {
            options = InitOptions(
                writeKey: "wk",
                ingestionHost: URL(string: "https://example.com")!,
                maxDiskEvents: -5
            )
        }

        XCTAssertNil(options?.configError)
        XCTAssertEqual(options?.maxDiskEvents, 0)
        XCTAssertTrue(output.contains("clamped"), "clamp should warn, got: \(output)")
    }

    func testCleartextHTTPWarnsButIsAccepted() {
        var options: InitOptions?
        let output = captureStderrAndStdout {
            options = InitOptions(writeKey: "wk", ingestionHost: "http://api.example.com")
        }

        XCTAssertNil(options?.configError)
        XCTAssertTrue(output.contains("cleartext"), "non-loopback http should warn, got: \(output)")

        let local = captureStderrAndStdout {
            options = InitOptions(writeKey: "wk", ingestionHost: "http://localhost:9999")
        }
        XCTAssertNil(options?.configError)
        XCTAssertFalse(local.contains("cleartext"), "loopback http is a dev setup, no warning")
    }

    func testHostlessURLRecordsInvalidIngestionHost() {
        // Foundation parses "https:/" (what a bare "https://" becomes after the slash
        // trim) as a valid scheme with a nil host — the scheme check alone would build
        // a live client that fails every request at network time.
        let (options, _) = withCapturedAsserts {
            InitOptions(writeKey: "wk", ingestionHost: "https://")
        }

        XCTAssertEqual(options.configError, .invalidIngestionHost("https://"))
    }

    func testAllNumericBoundsClampWithAWarning() {
        // One policy for every numeric field — previously two clamped silently.
        let output = captureStderrAndStdout {
            _ = InitOptions(
                writeKey: "wk",
                ingestionHost: URL(string: "https://example.com")!,
                flushIntervalSeconds: 0,
                maxQueueEvents: 0
            )
        }

        XCTAssertTrue(output.contains("flushIntervalSeconds"), "got: \(output)")
        XCTAssertTrue(output.contains("maxQueueEvents"), "got: \(output)")
    }

    func testIPv6LoopbackHTTPDoesNotWarn() {
        var options: InitOptions?
        let output = captureStderrAndStdout {
            options = InitOptions(writeKey: "wk", ingestionHost: "http://[::1]:9999")
        }

        XCTAssertNil(options?.configError)
        XCTAssertFalse(output.contains("cleartext"), "IPv6 loopback is a dev setup, no warning")
    }

    func testSchemeCheckIsCaseInsensitive() {
        let (options, asserts) = withCapturedAsserts {
            InitOptions(writeKey: "wk", ingestionHost: "HTTPS://example.com")
        }

        XCTAssertNil(options.configError)
        XCTAssertTrue(asserts.isEmpty)
    }

    func testValidConfigFiresNoAssertAndRecordsNoError() {
        let (options, asserts) = withCapturedAsserts {
            InitOptions(writeKey: "wk", ingestionHost: "https://example.com")
        }

        XCTAssertNil(options.configError)
        XCTAssertTrue(asserts.isEmpty)
    }

    func testInvalidConfigLeavesSDKInertAndSignals() async {
        await MetaRouter.Analytics.resetAndWait()
        let callbackCapture = AssertCapture()
        let (options, _) = withCapturedAsserts {
            InitOptions(
                writeKey: "",
                ingestionHost: "https://example.com",
                onConfigError: { callbackCapture.append($0.description) }
            )
        }

        let analytics = await MetaRouter.Analytics.initializeAndWait(with: options)
        // The one behavior this epic exists for: calls on a misconfigured SDK are
        // inert, never fatal.
        analytics.track("must_not_crash")

        XCTAssertEqual(callbackCapture.messages.count, 1)
        // No client was created: debug info stays in bootstrap (proxy) form and
        // carries the config error for the session. Polled: the proxy seeds its
        // bootstrap info from a fire-and-forget Task.
        var sawError = false
        for _ in 0..<50 where !sawError {
            let info = await analytics.getDebugInfo()
            sawError = info["configError"] != nil && info["proxy"]?.boolValue == true
            if !sawError { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(sawError, "getDebugInfo should report the config error on the unbound proxy")

        // Awaiting APIs resolve degraded instead of suspending on a bind that will
        // never come — a permanent hang would be worse than the crash this replaces.
        let anonymousId = await analytics.getAnonymousId()
        XCTAssertEqual(anonymousId, "", "config-disabled session returns empty, promptly")

        await MetaRouter.Analytics.resetAndWait()
    }

    func testInvalidReInitDisablesThePreviousSessionInsteadOfMaskingTheError() async {
        await MetaRouter.Analytics.resetAndWait()
        let valid = InitOptions(writeKey: "wk", ingestionHost: "https://example.com")
        _ = await MetaRouter.Analytics.initializeAndWait(with: valid)

        let (invalid, _) = withCapturedAsserts {
            InitOptions(writeKey: "", ingestionHost: "https://example.com")
        }
        let analytics = await MetaRouter.Analytics.initializeAndWait(with: invalid)

        // The stale valid client must not keep running past an explicit re-init with
        // bad config — that would silently mask the error (a bound client also
        // shadows the bootstrap debug info that reports it). Polled: the proxy seeds
        // bootstrap info from a fire-and-forget Task.
        var observed = false
        for _ in 0..<50 where !observed {
            let info = await analytics.getDebugInfo()
            observed = info["proxy"]?.boolValue == true && info["configError"] != nil
            if !observed { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(observed, "previous client unbound and config error observable")

        await MetaRouter.Analytics.resetAndWait()
    }

    func testResetClearsTheConfigRefusalSoTheNextSessionCanBind() async {
        await MetaRouter.Analytics.resetAndWait()
        let (invalid, _) = withCapturedAsserts {
            InitOptions(writeKey: "", ingestionHost: "https://example.com")
        }
        _ = await MetaRouter.Analytics.initializeAndWait(with: invalid)

        // reset() ends the refused session. The refusal must not survive it: a
        // following valid init has to produce a live client, and awaiting APIs must
        // resolve against that client rather than the previous session's verdict.
        await MetaRouter.Analytics.resetAndWait()

        let valid = InitOptions(writeKey: "wk", ingestionHost: "https://example.com")
        let analytics = await MetaRouter.Analytics.initializeAndWait(with: valid)

        let anonymousId = await analytics.getAnonymousId()
        XCTAssertFalse(anonymousId.isEmpty, "recovered session must resolve a real anonymousId, not the degraded empty string")

        let info = await analytics.getDebugInfo()
        XCTAssertNil(info["configError"], "stale config error must not follow a reset into a healthy session")

        await MetaRouter.Analytics.resetAndWait()
    }
}
