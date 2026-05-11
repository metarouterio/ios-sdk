import XCTest
@testable import MetaRouter

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

/// End-to-end coverage that exercises a real `AnalyticsClient` wired with
/// dependency injection. Posts `NotificationCenter` notifications to drive the
/// lifecycle observer, and asserts events flow through the standard track path.
///
/// Events may end up in either the dispatcher's memory queue (no flush yet) or
/// in the network stub (already flushed). Test assertions consult both.
final class AppLifecycleEventIntegrationTests: XCTestCase {

    private static var foregroundNotificationName: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        return NSApplication.didBecomeActiveNotification
        #else
        return Notification.Name("metarouter.test.foreground")
        #endif
    }

    private static var backgroundNotificationName: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didEnterBackgroundNotification
        #elseif canImport(AppKit)
        return NSApplication.didResignActiveNotification
        #else
        return Notification.Name("metarouter.test.background")
        #endif
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.lifecycleIntegration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testColdLaunchEmitsInstalledThenOpenedThroughClient() async {
        let bundle = Setup(defaults: defaults, trackLifecycleEvents: true)
        await bundle.waitForInit()

        let events = await bundle.collectEvents()
        XCTAssertGreaterThanOrEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "Application Installed")
        XCTAssertEqual(events[1].event, "Application Opened")
        XCTAssertEqual(events[1].properties?["from_background"], .bool(false))

        XCTAssertEqual(bundle.lifecycleStorage.getVersion(), "1.5.0")
        XCTAssertEqual(bundle.lifecycleStorage.getBuild(), "42")
    }

    func testFlagDisabledEmitsNoLifecycleEvents() async {
        let bundle = Setup(defaults: defaults, trackLifecycleEvents: false)
        await bundle.waitForInit()

        let events = await bundle.collectEvents()
        XCTAssertTrue(events.isEmpty,
                      "trackLifecycleEvents=false must produce zero lifecycle events on init")

        // Sanity: regular track() still works
        bundle.client.track("user_event")
        let found = await TestUtilities.waitForAsync(timeout: 1.0) {
            let events = await bundle.collectEvents()
            return events.contains { $0.event == "user_event" }
        }
        XCTAssertTrue(found, "expected user_event to be enqueued")
    }

    /// Calling `openURL` while `trackLifecycleEvents == false` is a silent no-op
    /// for event emission, but logs a debug warning so misconfiguration ("I'm
    /// calling openURL but no events fire!") is diagnosable from logs.
    func testOpenURLWithFeatureDisabledLogsWarning() async {
        Logger.setDebugLogging(true)
        defer { Logger.setDebugLogging(false) }

        let bundle = Setup(defaults: defaults, trackLifecycleEvents: false)
        await bundle.waitForInit()
        await bundle.consumeAll()

        let output = await captureStderrAndStdout(settle: 0.1) {
            bundle.client.openURL(URL(string: "myapp://x")!, sourceApplication: nil)
        }

        XCTAssertTrue(output.contains("openURL called but trackLifecycleEvents is disabled"),
                      "Expected disabled-flag warning, got: \(output)")

        // Absence wait: we're verifying NO event fires, so a fixed sleep is
        // required — `waitFor` would just early-exit on the first empty poll.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await bundle.collectEvents()
        XCTAssertTrue(events.isEmpty,
                      "openURL with feature disabled must not emit any event")
    }

    /// `reset()` must NOT clear lifecycle storage — install/update state survives
    /// because lifecycle keys live in a separate UserDefaults namespace.
    func testResetPreservesLifecycleStorage() async {
        let bundle = Setup(defaults: defaults, trackLifecycleEvents: true)
        await bundle.waitForInit()
        XCTAssertEqual(bundle.lifecycleStorage.getVersion(), "1.5.0")

        bundle.client.reset()
        // Absence wait: verifying lifecycle storage is NOT cleared by reset(),
        // so we need the full duration to be confident no async clear runs.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(bundle.lifecycleStorage.getVersion(), "1.5.0",
                       "reset() must not clear lifecycle storage")
        XCTAssertEqual(bundle.lifecycleStorage.getBuild(), "42",
                       "reset() must not clear lifecycle storage")
    }

    /// Re-init with persisted same version must NOT emit Installed/Updated —
    /// only Opened.
    func testReinitWithSameVersionEmitsOnlyOpened() async {
        // Pre-seed lifecycle storage to simulate a previous successful run
        LifecycleStorage(userDefaults: defaults)
            .setVersionBuild(version: "1.5.0", build: "42")

        let bundle = Setup(defaults: defaults, trackLifecycleEvents: true)
        await bundle.waitForInit()

        let events = await bundle.collectEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "Application Opened")
        XCTAssertEqual(events[0].properties?["from_background"], .bool(false))
    }

    func testBackgroundNotificationEnqueuesApplicationBackgrounded() async {
        let bundle = Setup(defaults: defaults, trackLifecycleEvents: true)
        await bundle.waitForInit()
        await bundle.consumeAll() // drop cold-launch events

        await MainActor.run {
            NotificationCenter.default.post(
                name: Self.backgroundNotificationName,
                object: nil
            )
        }

        // `handleBackground` runs `flush()` after emitting, so Backgrounded
        // lands in the recorder (network sink) — sync, no drain needed.
        let found = await TestUtilities.waitFor(timeout: 1.0) {
            bundle.recorder.recorded.contains { $0.event == "Application Backgrounded" }
        }
        XCTAssertTrue(found,
                      "expected Application Backgrounded after background notification, got \(bundle.recorder.recorded.map { $0.event ?? "?" })")
    }

    func testForegroundAfterBackgroundEmitsOpenedFromBackground() async {
        let bundle = Setup(defaults: defaults, trackLifecycleEvents: true)
        await bundle.waitForInit()
        await bundle.consumeAll()

        await MainActor.run {
            NotificationCenter.default.post(name: Self.backgroundNotificationName, object: nil)
        }
        // Backgrounded lands in the recorder via `handleBackground`'s flush.
        let bgFound = await TestUtilities.waitFor(timeout: 1.0) {
            bundle.recorder.recorded.contains { $0.event == "Application Backgrounded" }
        }
        XCTAssertTrue(bgFound, "expected Application Backgrounded before foregrounding")

        await MainActor.run {
            NotificationCenter.default.post(name: Self.foregroundNotificationName, object: nil)
        }
        // Opened is emitted AFTER `handleForeground`'s flush, so it sits in
        // the queue — drain into a collector each poll, then assert on the
        // accumulated snapshot.
        let collector = EventCollector()
        let fgFound = await TestUtilities.waitForAsync(timeout: 1.0) {
            let batch = await bundle.queue.drain(max: 100)
            await collector.add(batch)
            return await collector.contains { $0.event == "Application Opened" }
        }
        let captured = await collector.snapshot()
        XCTAssertTrue(fgFound, "expected Application Opened after foreground, got \(captured.map { $0.event ?? "?" })")
        let opened = captured.first(where: { $0.event == "Application Opened" })
        XCTAssertEqual(opened?.properties?["from_background"], .bool(true))
    }
}

/// Thread-safe event accumulator for tests that need to assert across multiple
/// poll iterations of an async-drained queue.
private actor EventCollector {
    private var events: [EnrichedEventPayload] = []
    func add(_ batch: [EnrichedEventPayload]) { events.append(contentsOf: batch) }
    func snapshot() -> [EnrichedEventPayload] { events }
    func contains(where predicate: (EnrichedEventPayload) -> Bool) -> Bool {
        events.contains(where: predicate)
    }
}

/// Bundles all dependencies needed to drive an `AnalyticsClient` with a
/// drainable queue + a recording network sink that captures flushed batches.
private final class Setup {
    let client: AnalyticsClient
    let queue: PersistentEventQueue
    let lifecycleStorage: LifecycleStorage
    let recorder: RecordingNetworking
    let tempDir: URL

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    init(defaults: UserDefaults, trackLifecycleEvents: Bool) {
        let options = InitOptions(
            writeKey: "wk",
            ingestionHost: URL(string: "https://example.com")!,
            flushIntervalSeconds: 999, // effectively never auto-flush during tests
            trackLifecycleEvents: trackLifecycleEvents
        )

        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metarouter-integration-\(UUID().uuidString)")
        let diskStore = DiskStorage(baseDirectory: tempDir)
        self.queue = PersistentEventQueue(diskStore: diskStore, maxEventCount: 1000)
        self.lifecycleStorage = LifecycleStorage(userDefaults: defaults)
        self.recorder = RecordingNetworking()

        let identityStorage = IdentityStorage(userDefaults: defaults)
        let identityManager = IdentityManager(
            storage: identityStorage,
            writeKey: options.writeKey,
            host: options.ingestionHost.absoluteString
        )

        var deps = AnalyticsDependencies()
        deps.persistentQueue = self.queue
        deps.networking = self.recorder
        // Connected so flush() actually POSTs (offline writes to disk instead).
        // No persisted data exists on a fresh test, so drainDiskStore is a no-op.
        deps.networkMonitor = StubNetworkMonitor(status: .connected)
        deps.identityManager = identityManager
        deps.lifecycleStorage = self.lifecycleStorage
        deps.identityStorage = identityStorage
        deps.appContext = AppContext(name: "test-app", version: "1.5.0", build: "42", namespace: "com.metarouter.test")
        // Force "active" on cold launch so we can assert the Opened event regardless of platform.
        deps.initialAppState = .active
        deps.dispatcherConfig = Dispatcher.Config(
            endpointPath: "/v1/batch",
            timeoutMs: 1000,
            autoFlushThreshold: 9999,  // don't auto-flush during tests
            initialMaxBatchSize: 100
        )

        self.client = AnalyticsClient.initialize(options: options, deps: deps)
    }

    /// Block until init's task chain has settled (cold-launch sequence emitted).
    func waitForInit() async {
        _ = await client.getAnonymousId()
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Returns the union of queue-pending events and network-flushed events
    /// in roughly chronological order. Drains the queue side-effectfully.
    func collectEvents() async -> [EnrichedEventPayload] {
        let queued = await queue.drain(max: 100)
        let flushed = recorder.recorded
        return flushed + queued
    }

    /// Drops every captured/queued event, used to clear cold-launch noise.
    func consumeAll() async {
        _ = await queue.drain(max: 100)
        recorder.clear()
    }
}

private final class RecordingNetworking: Networking, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [EnrichedEventPayload] = []

    var recorded: [EnrichedEventPayload] {
        lock.withLock { _events }
    }

    func clear() {
        lock.withLock { _events.removeAll() }
    }

    private struct Batch: Decodable {
        let batch: [EnrichedEventPayload]
    }

    func postJSON(url: URL, body: Data, timeoutMs: Int, additionalHeaders: [String: String]?) async throws -> NetworkResponse {
        if let decoded = try? JSONDecoder().decode(Batch.self, from: body) {
            lock.withLock { _events.append(contentsOf: decoded.batch) }
        }
        return NetworkResponse(statusCode: 200, headers: [:], body: nil)
    }

    func parseRetryAfterMs(from headers: [String: String]) -> Int? { nil }
}
