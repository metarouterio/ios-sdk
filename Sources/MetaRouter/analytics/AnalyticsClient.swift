import Foundation
import WebKit


/// Injectable dependencies for testing. All fields optional — defaults to production implementations.
internal struct AnalyticsDependencies: Sendable {
    var identityManager: IdentityManager?
    var contextProvider: ContextProvider?
    var enrichmentService: EventEnrichmentService?
    var networking: Networking?
    var circuitBreaker: CircuitBreaker?
    var dispatcherConfig: Dispatcher.Config?
    var dispatcher: Dispatcher?
    var persistentQueue: PersistentEventQueue?
    var networkMonitor: NetworkReachability?
    var lifecycleStorage: LifecycleStorage?
    var identityStorage: IdentityStorage?
    var appContext: AppContext?
    /// Override the initial app foreground state read at cold launch.
    /// Tests pass `.active` / `.background` directly to skip the UIKit probe.
    var initialAppState: AppForegroundState?

    static let production = AnalyticsDependencies()
}

internal final class AnalyticsClient: AnalyticsInterface, CustomStringConvertible,
    CustomDebugStringConvertible, @unchecked Sendable
{
    private let options: InitOptions
    private let contextProvider: ContextProvider
    private let identityManager: IdentityManager
    private let enrichmentService: EventEnrichmentService
    private let dispatcher: Dispatcher
    private let networkMonitor: NetworkReachability?
    private var lifecycle: AppLifecycleObserver?
    private var lifecycleState: LifecycleState = .idle
    private var disabled = false
    private var initTask: Task<Void, Never>?
    private let lifecycleCoordinator: LifecycleCoordinator?

    // One processor for all attached webviews: bridge messageIds are UUIDs, so a
    // shared dedup store cannot cross-drop between webviews, and sharing keeps the
    // memory bound per client rather than per webview.
    private let bridgeSink = ClientBridgeSink()
    private let bridgeProcessor: BridgeMessageProcessor

    private init(options: InitOptions, deps: AnalyticsDependencies = .production) {
        self.lifecycleState = .initializing
        self.bridgeProcessor = BridgeMessageProcessor(sink: bridgeSink)

        self.options = options
        // Snapshot bundle metadata once — used by both DeviceContextProvider (per-event
        // app context) and LifecycleEventEmitter (install/update detection). Bundle
        // is OS-loaded at process start and immutable, so caching is safe.
        let appContext = deps.appContext ?? .fromBundle()
        self.contextProvider = deps.contextProvider
            ?? DeviceContextProvider(appContext: appContext)
        self.identityManager = deps.identityManager ?? IdentityManager(
            writeKey: options.writeKey,
            host: options.ingestionHost.absoluteString
        )
        self.enrichmentService = deps.enrichmentService ?? EventEnrichmentService(
            contextProvider: self.contextProvider,
            identityManager: self.identityManager,
            writeKey: options.writeKey
        )

        let diskStore = DiskStorage()
        let persistentQueue = deps.persistentQueue ?? PersistentEventQueue(
            diskStore: diskStore,
            maxEventCount: options.maxQueueEvents,
            maxDiskEvents: options.maxDiskEvents
        )

        self.dispatcher = deps.dispatcher ?? Dispatcher(
            options: options,
            http: deps.networking ?? NetworkClient(),
            breaker: deps.circuitBreaker ?? CircuitBreaker(),
            persistentQueue: persistentQueue,
            config: deps.dispatcherConfig ?? Dispatcher.Config(endpointPath: "/v1/batch", timeoutMs: 8000, autoFlushThreshold: 20, initialMaxBatchSize: 100)
        )

        // Build the lifecycle coordinator only when the feature is enabled. Construction
        // happens BEFORE identityManager.initialize() runs (in initTask), so the
        // emitter's snapshot of "did identity exist before this launch?" is honest.
        if options.trackLifecycleEvents {
            let emitter = LifecycleEventEmitter(
                enrichmentService: self.enrichmentService,
                dispatcher: self.dispatcher,
                storage: deps.lifecycleStorage ?? LifecycleStorage(),
                identityStorage: deps.identityStorage ?? IdentityStorage(),
                appContext: appContext
            )
            self.lifecycleCoordinator = LifecycleCoordinator(
                emitter: emitter,
                initialStateOverride: deps.initialAppState
            )
        } else {
            self.lifecycleCoordinator = nil
        }

        let rawMonitor = deps.networkMonitor ?? NetworkMonitor()
        let monitor = DebouncedNetworkMonitor(inner: rawMonitor)
        
        self.networkMonitor = monitor

        // Enable debug logging if requested
        if options.debug {
            Logger.setDebugLogging(true)
        }

        Task { [weak self] in
            guard let self else { return }
            await self.dispatcher.setFatalConfigHandler({ [weak self] status in
                Logger.error("Fatal config error \(status). Disabling client.")
                self?.disabled = true
                self?.lifecycleState = .disabled
            })
            // Wire onFlushComplete to trigger disk drain when online
            await self.dispatcher.setFlushCompleteHandler({ [weak self] in
                guard let self else { return }
                await self.dispatcher.drainDiskStoreToNetwork()
            })
        }

        self.lifecycle = AppLifecycleObserver(
            onForeground: { [weak self] in self?.handleForeground() },
            onBackgroundAsync: { [weak self] in await self?.handleBackground() }
        )
        
        // Wire network monitor: set initial state and subscribe to changes
        Task { [weak self] in
            guard let self else { return }
            let initialOffline = monitor.currentStatus == .disconnected
            if initialOffline {
                await self.dispatcher.setOffline(true)
            }
            monitor.onStatusChange { [weak self] status in
                guard let self else { return }
                Task {
                    await self.dispatcher.setOffline(status == .disconnected)
                }
            }
        }

        self.initTask = Task { [weak self] in
            guard let self else { return }
            await self.identityManager.initialize()

            // Check disk for persisted events (cheap existence check, no parse).
            // Actual drain happens below once we confirm we're online.
            let hasPersisted = await self.dispatcher.checkForPersistedEvents()
            if hasPersisted {
                Logger.log("Persisted events detected on disk — will drain once online",
                           writeKey: self.options.writeKey,
                           host: self.options.ingestionHost.absoluteString)
            }

            // Load advertisingId from IdentityManager and set it on DeviceContextProvider
            if let deviceProvider = self.contextProvider as? DeviceContextProvider,
               let advertisingId = await self.identityManager.getAdvertisingId() {
                await deviceProvider.setAdvertisingId(advertisingId)
                let redactedId = "\(advertisingId.prefix(8))***"
                Logger.log("Loaded advertisingId from storage: \(redactedId)",
                           writeKey: self.options.writeKey,
                           host: self.options.ingestionHost.absoluteString)
            }

            await self.dispatcher.startFlushLoop(intervalSeconds: self.options.flushIntervalSeconds)
            self.lifecycleState = .ready
            Logger.log("MetaRouter SDK initialized",
                       writeKey: self.options.writeKey,
                       host: self.options.ingestionHost.absoluteString)

            // Emit cold-launch lifecycle sequence (Installed/Updated then Opened).
            // Runs after .ready so events flow through the standard track path.
            await self.lifecycleCoordinator?.onReady()

            // Drain any persisted events from a previous session
            if monitor.currentStatus == .connected {
                await self.dispatcher.drainDiskStoreToNetwork()
            }
        }

        // Last: the sink needs self, and self is only safe to hand out once every
        // stored property above is initialized.
        self.bridgeSink.client = self
    }

    private func handleForeground() {
        guard lifecycleState == .ready else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.dispatcher.startFlushLoop(intervalSeconds: self.options.flushIntervalSeconds)
            await self.dispatcher.flush()
            await self.lifecycleCoordinator?.onForeground()
        }
    }

    /// Emit `Application Backgrounded` BEFORE flush/disk-flush so the event
    /// is captured by the same drain that ships pending events to disk.
    private func handleBackground() async {
        await lifecycleCoordinator?.onBackground()
        await dispatcher.flush()
        await dispatcher.flushToDisk()
        await dispatcher.stopFlushLoop()
        await dispatcher.cancelScheduledRetry()
    }

    internal static func initialize(options: InitOptions, deps: AnalyticsDependencies = .production) -> AnalyticsClient {
        AnalyticsClient(options: options, deps: deps)
    }

    public var description: String {
        return "MetaRouter.Analytics"
    }

    public var debugDescription: String {
        return "MetaRouter.Analytics(internal)"
    }

    public func track(_ event: String, properties: [String: Any]?) {
        // Convert [String: Any] to [String: CodableValue] before crossing Task boundary
        let convertedProps = properties.flatMap { CodableValue.convert($0) }
        
        Task {
            guard !disabled else { return }
            
            // Log the tracking event with properties
            if let props = convertedProps, !props.isEmpty {
                Logger.log(
                    "Tracking event: \(event) with properties: \(props.cleanDescription)",
                    writeKey: options.writeKey,
                    host: options.ingestionHost.absoluteString)
            } else {
                Logger.log(
                    "Tracking event: \(event)",
                    writeKey: options.writeKey,
                    host: options.ingestionHost.absoluteString)
            }
            
            let enrichedEvent = await enrichmentService.createTrackEvent(
                event: event,
                properties: convertedProps
            )

            await dispatcher.offer(enrichedEvent)
        }
    }

    public func track(_ event: String) {
        track(event, properties: nil)
    }

    public func identify(_ userId: String, traits: [String: Any]?) {
        // Convert [String: Any] to [String: CodableValue] before crossing Task boundary
        let convertedTraits = traits.flatMap { CodableValue.convert($0) }
        
        Task {
            guard !disabled else { return }
            
            // Update identity manager with the new userId
            await identityManager.identify(userId)
            
            let enrichedEvent = await enrichmentService.createIdentifyEvent(
                userId: userId,
                traits: convertedTraits
            )

            Logger.log(
                "identify userId='\(userId)', traits=\((convertedTraits ?? [:]).cleanDescription), messageId=\(enrichedEvent.messageId)",
                writeKey: options.writeKey,
                host: options.ingestionHost.absoluteString)

            await dispatcher.offer(enrichedEvent)
        }
    }

    public func identify(_ userId: String) {
        identify(userId, traits: nil)
    }

    public func group(_ groupId: String, traits: [String: Any]?) {
        // Convert [String: Any] to [String: CodableValue] before crossing Task boundary
        let convertedTraits = traits.flatMap { CodableValue.convert($0) }
        
        Task {
            guard !disabled else { return }
            
            // Update identity manager with the new groupId
            await identityManager.group(groupId)
            
            let enrichedEvent = await enrichmentService.createGroupEvent(
                groupId: groupId,
                traits: convertedTraits
            )

            Logger.log(
                "group groupId='\(groupId)', traits=\((convertedTraits ?? [:]).cleanDescription), messageId=\(enrichedEvent.messageId)",
                writeKey: options.writeKey,
                host: options.ingestionHost.absoluteString)

            await dispatcher.offer(enrichedEvent)
        }
    }

    public func group(_ groupId: String) {
        group(groupId, traits: nil)
    }

    public func alias(_ newUserId: String) {
        Task {
            guard !disabled else { return }
            let enrichedEvent = await enrichmentService.createAliasEvent(
                newUserId: newUserId
            )

            Logger.log(
                "alias newUserId='\(newUserId)', messageId=\(enrichedEvent.messageId)",
                writeKey: options.writeKey,
                host: options.ingestionHost.absoluteString)

            await dispatcher.offer(enrichedEvent)
        }
    }

    public func screen(_ name: String, properties: [String: Any]?) {
        // Convert [String: Any] to [String: CodableValue] before crossing Task boundary
        let convertedProps = properties.flatMap { CodableValue.convert($0) }
        
        Task {
            guard !disabled else { return }
            
            let enrichedEvent = await enrichmentService.createScreenEvent(
                name: name,
                properties: convertedProps
            )

            Logger.log(
                "screen name='\(name)', properties=\((convertedProps ?? [:]).cleanDescription), messageId=\(enrichedEvent.messageId)",
                writeKey: options.writeKey,
                host: options.ingestionHost.absoluteString)

            await dispatcher.offer(enrichedEvent)
        }
    }

    public func screen(_ name: String) {
        screen(name, properties: nil)
    }

    public func page(_ name: String, properties: [String: Any]?) {
        // Convert [String: Any] to [String: CodableValue] before crossing Task boundary
        let convertedProps = properties.flatMap { CodableValue.convert($0) }
        
        Task {
            guard !disabled else { return }
            
            let enrichedEvent = await enrichmentService.createPageEvent(
                name: name,
                properties: convertedProps
            )

            Logger.log(
                "page name='\(name)', properties=\((convertedProps ?? [:]).cleanDescription), messageId=\(enrichedEvent.messageId)",
                writeKey: options.writeKey,
                host: options.ingestionHost.absoluteString)

            await dispatcher.offer(enrichedEvent)
        }
    }

    public func page(_ name: String) {
        page(name, properties: nil)
    }

    public func enableDebugLogging() {
        Logger.setDebugLogging(true)
        Logger.log(
            "debug logging enabled", writeKey: options.writeKey,
            host: options.ingestionHost.absoluteString)
    }

    public func getAnonymousId() async -> String {
        await initTask?.value
        return await identityManager.getOrCreateAnonymousId()
    }

    public func getDebugInfo() async -> [String: CodableValue] {
        // Mask writeKey to show only last 4 characters
        let maskedKey = options.writeKey.count > 4 
            ? "***" + options.writeKey.suffix(4) 
            : "***"
        
        // Get async values
        let queueLength = await dispatcher.getQueueLength()
        let flushInFlight = await dispatcher.isFlushInProgress()
        let circuitState = await dispatcher.getCircuitState()
        let circuitRemainingMs = await dispatcher.getCircuitRemainingMs()
        let anonymousId = await identityManager.getAnonymousId()
        let userId = await identityManager.getUserId()
        let groupId = await identityManager.getGroupId()
        
        let networkStatus = networkMonitor?.currentStatus ?? .connected

        var info: [String: CodableValue] = [
            "lifecycle": .string(lifecycleState.rawValue),
            "queueLength": .int(queueLength),
            "ingestionHost": .string(options.ingestionHost.absoluteString),
            "writeKey": .string(maskedKey),
            "flushIntervalSeconds": .int(options.flushIntervalSeconds),
            "maxQueueEvents": .int(options.maxQueueEvents),
            "proxy": .bool(false),
            "flushInFlight": .bool(flushInFlight),
            "circuitState": .string(String(describing: circuitState)),
            "circuitRemainingMs": .int(circuitRemainingMs),
            "networkStatus": .string(networkStatus.rawValue)
        ]
        
        // Add optional identity fields
        if let anonId = anonymousId {
            info["anonymousId"] = .string(anonId)
        }
        if let uid = userId {
            info["userId"] = .string(uid)
        }
        if let gid = groupId {
            info["groupId"] = .string(gid)
        }
        
        return info
    }

    public func flush() {
        Task { [weak self] in
            guard let self else { return }
            await self.dispatcher.flush()
        }
    }
    public func reset() {
        Task { [weak self] in
            guard let self else { return }
            self.lifecycleState = .resetting
            await self.identityManager.reset()

            // Clear advertisingId from DeviceContextProvider
            if let deviceProvider = self.contextProvider as? DeviceContextProvider {
                await deviceProvider.setAdvertisingId(nil)
            }

            // Stop network monitoring and cancel pending debounce
            self.networkMonitor?.stop()

            await self.dispatcher.stopFlushLoop()
            await self.dispatcher.cancelScheduledRetry()
            await self.dispatcher.clearAll()
            self.initTask = nil
            self.disabled = false
            self.lifecycleState = .idle
        }
    }

    public func setAdvertisingId(_ advertisingId: String?) {
        Task { [weak self] in
            guard let self else { return }

            // Check lifecycle state
            guard lifecycleState == .ready || lifecycleState == .initializing else {
                Logger.log(
                    "Cannot set advertisingId - client not ready (state: \(lifecycleState.rawValue))",
                    writeKey: self.options.writeKey,
                    host: self.options.ingestionHost.absoluteString)
                return
            }

            // Validate UUID format if not nil
            if let id = advertisingId {
                guard UUID(uuidString: id) != nil else {
                    Logger.warn(
                        "Invalid advertisingId '\(id.prefix(20))' — must be a valid UUID (e.g. '550E8400-E29B-41D4-A716-446655440000')")
                    return
                }
            }


            await self.identityManager.setAdvertisingId(advertisingId)


            if let deviceProvider = self.contextProvider as? DeviceContextProvider {
                await deviceProvider.setAdvertisingId(advertisingId)
            }

            Logger.log(
                "Advertising ID updated, persisted, and context refreshed",
                writeKey: self.options.writeKey,
                host: self.options.ingestionHost.absoluteString)
        }
    }

    public func clearAdvertisingId() {
        Task { [weak self] in
            guard let self else { return }

            // Check lifecycle state
            guard lifecycleState == .ready || lifecycleState == .initializing else {
                Logger.log(
                    "Cannot clear advertisingId - client not ready (state: \(lifecycleState.rawValue))",
                    writeKey: self.options.writeKey,
                    host: self.options.ingestionHost.absoluteString)
                return
            }

            // Clear from IdentityManager first
            await self.identityManager.clearAdvertisingId()

            // Clear from DeviceContextProvider
            if let deviceProvider = self.contextProvider as? DeviceContextProvider {
                await deviceProvider.setAdvertisingId(nil)
            }

            Logger.log(
                "advertisingId cleared for GDPR compliance",
                writeKey: self.options.writeKey,
                host: self.options.ingestionHost.absoluteString)
        }
    }

    public func setTracing(_ enabled: Bool) {
        Task { [weak self] in
            guard let self else { return }
            await self.dispatcher.setTracing(enabled)
        }
    }

    public func recordOpenedURL(_ url: URL, sourceApplication: String?) {
        guard let coordinator = lifecycleCoordinator else {
            Logger.warn("recordOpenedURL called but trackLifecycleEvents is disabled — ignoring")
            return
        }
        Task {
            await coordinator.recordOpenedURL(url, sourceApplication: sourceApplication)
        }
    }

    /// Bridge sink: a validated, deduplicated webview envelope enters the normal event
    /// path here. The native messageId, timestamp, identity, and device context are all
    /// applied by the existing enrichment — the envelope only contributes what native
    /// cannot know: the event itself and the page it happened on.
    ///
    /// Returns whether the event entered the delivery path — the same path native
    /// events take, including its downstream queue-capacity policy — so the bridge's
    /// ack never claims delivery for an event the client refused.
    internal func enqueueBridgeEvent(_ envelope: BridgeEnvelope) -> Bool {
        guard lifecycleState == .ready, !disabled else {
            Logger.warn("Cannot enqueue bridge event - SDK not ready (state: \(lifecycleState.rawValue))")
            return false
        }
        Task {
            let enriched = await enrichmentService.enrichEvent(BaseEvent(
                type: envelope.type.rawValue,
                event: envelope.name,
                properties: envelope.properties,
                page: envelope.page
            ))
            await dispatcher.offer(enriched)
        }
        return true
    }

    /// Bridge attach for direct-client usage (`AnalyticsClient.initialize()`). The
    /// sink enqueues to THIS client instance, which is correct here: a directly
    /// created client is caller-owned and is never swapped by `reset()` (that only
    /// replaces the proxy's client). Do NOT mirror this in the proxy path — there the
    /// handler must resolve the live client at delivery, since it outlives client
    /// swaps.
    @MainActor
    public func attachWebView(_ webView: WKWebView, allowedOrigins: [String]) {
        // No lifecycle gate: attach needs nothing from initialized state (the sink's
        // enqueue has its own READY check), and gating would silently drop attaches
        // during init — breaking the attach-before-load contract.
        WebViewBridge.attach(webView, allowedOrigins: allowedOrigins, processor: bridgeProcessor)
    }
}

/// Bridge sink for direct-client usage. Holds the client weakly: WebKit retains the
/// message handler (→ processor → sink) for the WebView's lifetime, and a strong
/// client reference here would pin a discarded client in memory. A dead client reads
/// as nil and the message NAKs not_ready — never a silent drop.
private final class ClientBridgeSink: BridgeEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private weak var _client: AnalyticsClient?

    var client: AnalyticsClient? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _client
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _client = newValue
        }
    }

    func enqueue(_ envelope: BridgeEnvelope) -> Bool {
        client?.enqueueBridgeEvent(envelope) ?? false
    }
}
