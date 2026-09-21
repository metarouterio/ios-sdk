import XCTest
@testable import MetaRouter

/// End-to-end session behavior through a real AnalyticsClient: the optional
/// `Session Started` event, its gating, and the `getSessionId()` surface.
/// Lifecycle events stay off so the only session activity is the explicit
/// calls each test makes.
final class SessionIntegrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Int64
        init(_ now: Int64) { self._now = now }
        var now: Int64 { lock.withLock { _now } }
        func advance(minutes: Int64) { lock.withLock { _now += minutes * 60_000 } }
    }

    override func setUp() {
        super.setUp()
        suiteName = "com.metarouter.test.sessionIntegration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private struct Harness {
        let client: AnalyticsClient
        let queue: PersistentEventQueue
        let recorder: SessionRecordingNetworking
        let wall: Clock
        let mono: Clock
        let tempDir: URL

        func collectEvents() async -> [EnrichedEventPayload] {
            let queued = await queue.drain(max: 100)
            return recorder.recorded + queued
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeHarness(fireSessionStarted: Bool) -> Harness {
        let options = InitOptions(
            writeKey: "wk",
            ingestionHost: URL(string: "https://example.com")!,
            flushIntervalSeconds: 999,
            fireSessionStarted: fireSessionStarted
        )

        let wall = Clock(1_757_400_000_000)
        let mono = Clock(50_000)
        let sessionManager = SessionManager(
            storage: SessionStorage(userDefaults: defaults),
            wallClockMillis: { wall.now },
            monotonicClockMillis: { mono.now }
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("metarouter-session-integration-\(UUID().uuidString)")
        let queue = PersistentEventQueue(diskStore: DiskStorage(baseDirectory: tempDir), maxEventCount: 1000)
        let recorder = SessionRecordingNetworking()

        var deps = AnalyticsDependencies()
        deps.persistentQueue = queue
        deps.networking = recorder
        deps.sessionManager = sessionManager
        deps.identityManager = IdentityManager(
            storage: IdentityStorage(userDefaults: defaults),
            writeKey: options.writeKey,
            host: options.ingestionHost.absoluteString
        )
        deps.identityStorage = IdentityStorage(userDefaults: defaults)
        deps.lifecycleStorage = LifecycleStorage(userDefaults: defaults)
        deps.appContext = AppContext(name: "test-app", version: "1.5.0", build: "42", namespace: "com.metarouter.test")
        deps.initialAppState = .active
        deps.dispatcherConfig = Dispatcher.Config(
            endpointPath: "/v1/batch",
            timeoutMs: 1000,
            autoFlushThreshold: 9999,
            initialMaxBatchSize: 100
        )

        let client = AnalyticsClient.initialize(options: options, deps: deps)
        return Harness(client: client, queue: queue, recorder: recorder, wall: wall, mono: mono, tempDir: tempDir)
    }

    private func sessionId(of payload: EnrichedEventPayload) -> String? {
        payload.context.providers?["metarouter"]?["sessionID"]?.stringValue
    }

    /// Async cousin of TestUtilities.waitFor — the conditions here drain an
    /// actor-held queue, which a sync closure cannot await.
    private func poll(timeout: TimeInterval = 2.0, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    // MARK: - Session Started emission

    func testFirstEventMintsAndFiresSessionStartedOnce() async {
        let harness = makeHarness(fireSessionStarted: true)
        defer { harness.cleanUp() }
        _ = await harness.client.getAnonymousId()

        harness.client.track("First Event")
        harness.client.track("Second Event")

        // Session Started rides its own fire-and-forget task; poll until all
        // three events (2 tracked + 1 session start) have been enriched.
        var events: [EnrichedEventPayload] = []
        _ = await poll {
            events += await harness.collectEvents()
            return events.count >= 3
        }

        let sessionStarts = events.filter { $0.event == "Session Started" }
        XCTAssertEqual(sessionStarts.count, 1, "one session, one Session Started")
        XCTAssertEqual(sessionId(of: sessionStarts[0]), "1757400000000",
                       "Session Started is stamped with the session it announces")
        XCTAssertTrue(events.allSatisfy { sessionId(of: $0) == "1757400000000" })
    }

    func testRolloverFiresSessionStartedForTheNewSession() async {
        let harness = makeHarness(fireSessionStarted: true)
        defer { harness.cleanUp() }
        _ = await harness.client.getAnonymousId()

        harness.client.track("Before Gap")
        var events: [EnrichedEventPayload] = []
        _ = await poll {
            events += await harness.collectEvents()
            return events.count >= 2
        }

        harness.wall.advance(minutes: 31)
        harness.mono.advance(minutes: 31)
        harness.client.track("After Gap")

        var laterEvents: [EnrichedEventPayload] = []
        _ = await poll {
            laterEvents += await harness.collectEvents()
            return laterEvents.count >= 2
        }

        let newId = String(harness.wall.now)
        let sessionStarts = laterEvents.filter { $0.event == "Session Started" }
        XCTAssertEqual(sessionStarts.count, 1, "rollover mints once, announces once")
        XCTAssertEqual(sessionId(of: sessionStarts[0]), newId)
        XCTAssertEqual(
            laterEvents.first { $0.event == "After Gap" }.flatMap { sessionId(of: $0) },
            newId
        )
    }

    func testNoSessionStartedWhenFlagOff() async {
        let harness = makeHarness(fireSessionStarted: false)
        defer { harness.cleanUp() }
        _ = await harness.client.getAnonymousId()

        harness.client.track("Only Event")

        var events: [EnrichedEventPayload] = []
        _ = await poll {
            events += await harness.collectEvents()
            return events.count >= 1
        }
        // Settle window: a stray Session Started would arrive on its own task.
        try? await Task.sleep(nanoseconds: 200_000_000)
        events += await harness.collectEvents()

        XCTAssertFalse(events.contains { $0.event == "Session Started" },
                       "default is off — upgrading must not change event volume")
        XCTAssertEqual(sessionId(of: events[0]), "1757400000000",
                       "the stamp itself is always on")
    }

    // MARK: - getSessionId

    func testGetSessionIdNilBeforeFirstEventThenMatchesStamp() async {
        let harness = makeHarness(fireSessionStarted: false)
        defer { harness.cleanUp() }
        _ = await harness.client.getAnonymousId()

        let before = await harness.client.getSessionId()
        XCTAssertNil(before, "reads do not start sessions")

        harness.client.track("First Event")
        var events: [EnrichedEventPayload] = []
        _ = await poll {
            events += await harness.collectEvents()
            return events.count >= 1
        }

        let after = await harness.client.getSessionId()
        XCTAssertEqual(after, "1757400000000")
        XCTAssertEqual(after, sessionId(of: events[0]),
                       "the getter reports the session events are stamped with")
    }

    func testDebugInfoCarriesSession() async {
        let harness = makeHarness(fireSessionStarted: false)
        defer { harness.cleanUp() }
        _ = await harness.client.getAnonymousId()

        harness.client.track("First Event")
        _ = await poll {
            await harness.client.getSessionId() != nil
        }

        let info = await harness.client.getDebugInfo()
        XCTAssertEqual(info["sessionId"], .string("1757400000000"))
        XCTAssertEqual(info["sessionCount"], .int(1))
    }
}

private final class SessionRecordingNetworking: Networking, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [EnrichedEventPayload] = []

    var recorded: [EnrichedEventPayload] {
        lock.withLock { _events }
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
