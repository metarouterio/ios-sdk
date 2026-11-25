import XCTest
@testable import MetaRouter

/// A user identified on a previous launch: every event of the next cold launch must
/// carry the stored userId, however early the host calls track. Review claim (PR #73):
/// "tracks don't wait for stored identity to load". The rounds vary timing.
final class ColdLaunchIdentityTests: XCTestCase {
    private let storedUserId = "stored-user"

    private struct Launch {
        let suiteName: String
        let defaults: UserDefaults
        let tempDir: URL
        let recorder = BodyRecordingNetworking()

        init() {
            suiteName = "com.metarouter.test.coldLaunchIdentity.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("metarouter-cold-launch-\(UUID().uuidString)")
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempDir)
        }

        /// Same wiring as `MetaRouter.clientDependencies`: proxy and client share one IdentityStorage.
        func makeClient() -> AnalyticsClient {
            let options = InitOptions(
                writeKey: "wk", ingestionHost: URL(string: "https://example.com")!,
                flushIntervalSeconds: 999, trackLifecycleEvents: true, fireSessionStarted: true
            )
            var deps = AnalyticsDependencies()
            deps.persistentQueue = PersistentEventQueue(diskStore: DiskStorage(baseDirectory: tempDir), maxEventCount: 1000)
            deps.networking = recorder
            deps.networkMonitor = StubNetworkMonitor(status: .connected)
            deps.identityStorage = IdentityStorage(userDefaults: defaults)
            deps.sessionStorage = SessionStorage(userDefaults: defaults)
            deps.consentStorage = ConsentStorage(userDefaults: defaults)
            deps.providerContextStorage = ProviderContextStorage(userDefaults: defaults)
            deps.lifecycleStorage = LifecycleStorage(userDefaults: defaults)
            deps.initialAppState = .active
            deps.dispatcherConfig = Dispatcher.Config(
                endpointPath: "/v1/batch", timeoutMs: 1000, autoFlushThreshold: 9999, initialMaxBatchSize: 1000
            )
            return AnalyticsClient.initialize(options: options, deps: deps)
        }

        func makeProxy() -> AnalyticsProxy {
            AnalyticsProxy(
                consentManager: ConsentManager(storage: ConsentStorage(userDefaults: defaults)),
                providerContextManager: ProviderContextManager(storage: ProviderContextStorage(userDefaults: defaults)),
                identityStorage: IdentityStorage(userDefaults: defaults)
            )
        }

        var events: [[String: Any]] {
            recorder.bodies.flatMap { body -> [[String: Any]] in
                let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                return object?["batch"] as? [[String: Any]] ?? []
            }
        }
    }

    private func seededLaunch() -> Launch {
        let launch = Launch()
        IdentityStorage(userDefaults: launch.defaults).set(.userId, value: storedUserId)
        return launch
    }

    private func jitter(_ round: Int) async {
        switch round % 4 {
        case 0: break
        case 1: await Task.yield()
        case 2: try? await Task.sleep(nanoseconds: UInt64.random(in: 0...2_000_000))
        default: for _ in 0..<Int.random(in: 1...5) { await Task.yield() }
        }
    }

    /// Flushes until the host's "first" track is posted, then returns every event posted.
    private func shipped(_ launch: Launch, flush: @escaping () -> Void) async -> [[String: Any]] {
        var events: [[String: Any]] = []
        let posted = await TestUtilities.waitFor(timeout: 5) {
            flush()
            events = launch.events
            return events.contains { $0["event"] as? String == "first" }
        }
        XCTAssertTrue(posted, "the track never shipped")
        return events
    }

    private enum Shape: String, CaseIterable {
        case trackRightAfterInitialize   // client built, track before its initTask runs
        case trackBeforeBind             // proxy buffers the track, replays at bind
        case trackRightAfterBind
    }

    private func run(_ shape: Shape, rounds: Int) async -> (events: Int, missing: Int, missingNames: [String: Int]) {
        var total = 0, missing = 0
        var names: [String: Int] = [:]
        for round in 0..<rounds {
            let launch = seededLaunch()
            defer { launch.cleanUp() }
            var client: AnalyticsClient!
            let flush: () -> Void
            switch shape {
            case .trackRightAfterInitialize:
                client = launch.makeClient()
                await jitter(round)
                client.track("first")
                client.track("second")
                flush = { client.flush() }
            case .trackBeforeBind:
                let proxy = launch.makeProxy()
                proxy.track("first")
                proxy.track("second")
                await jitter(round)
                client = launch.makeClient()
                await proxy._bindAndReplay(client)
                flush = { proxy.flush() }
            case .trackRightAfterBind:
                let proxy = launch.makeProxy()
                client = launch.makeClient()
                await proxy._bindAndReplay(client)
                await jitter(round)
                proxy.track("first")
                proxy.track("second")
                flush = { proxy.flush() }
            }
            let events = await shipped(launch, flush: flush)
            total += events.count
            for event in events where event["userId"] as? String != storedUserId {
                missing += 1
                names[(event["event"] as? String) ?? (event["type"] as? String ?? "?"), default: 0] += 1
            }
            client.shutdown()
        }
        return (total, missing, names)
    }

    func testEveryColdLaunchEventCarriesTheStoredUserId() async {
        for shape in Shape.allCases {
            let result = await run(shape, rounds: 200)
            print("[ColdLaunchIdentity] \(shape.rawValue): \(result.missing)/\(result.events) events without the stored userId \(result.missingNames)")
            XCTAssertEqual(result.missing, 0, "\(shape.rawValue): \(result.missingNames)")
        }
    }

    /// The guard, without timing: enrichment reads stored identity even when
    /// `initialize()` has not run yet (and never does).
    func testEnrichmentBeforeIdentityInitializeCarriesTheStoredUserId() async {
        let launch = seededLaunch()
        defer { launch.cleanUp() }
        IdentityStorage(userDefaults: launch.defaults).set(.groupId, value: "stored-group")
        let identity = IdentityManager(storage: IdentityStorage(userDefaults: launch.defaults), writeKey: "wk", host: "h")
        let enrichment = EventEnrichmentService(
            contextProvider: DeviceContextProvider(appContext: .fromBundle()),
            identityManager: identity,
            writeKey: "wk",
            sessionManager: SessionManager(storage: SessionStorage(userDefaults: launch.defaults), timeoutMinutes: 30),
            consentManager: ConsentManager(storage: ConsentStorage(userDefaults: launch.defaults)),
            providerContextManager: ProviderContextManager(storage: ProviderContextStorage(userDefaults: launch.defaults)),
            networkMonitor: StubNetworkMonitor(status: .connected)
        )
        let event = await enrichment.createTrackEvent(event: "first")
        XCTAssertEqual(event.userId, storedUserId)
        XCTAssertEqual(event.groupId, "stored-group")
    }
}
