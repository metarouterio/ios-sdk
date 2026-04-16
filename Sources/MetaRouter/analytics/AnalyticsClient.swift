import Foundation


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

    private init(options: InitOptions, deps: AnalyticsDependencies = .production) {
        self.lifecycleState = .initializing

        self.options = options
        self.contextProvider = deps.contextProvider ?? DeviceContextProvider()
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
            onForeground: { [weak self] in
                guard let self, self.lifecycleState == .ready else { return }
                Task { [weak self] in
                    guard let self else { return }
                    await self.dispatcher.startFlushLoop(intervalSeconds: self.options.flushIntervalSeconds)
                    await self.dispatcher.flush()
                }
            },
            onBackgroundAsync: { [weak self] in
                guard let self else { return }
                await self.dispatcher.flush()
                await self.dispatcher.flushToDisk()
                await self.dispatcher.stopFlushLoop()
                await self.dispatcher.cancelScheduledRetry()
            }
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

        // Periodic network reconciliation — only active while the dispatcher thinks
        // we're offline. Catches transitions that NWPathMonitor's pathUpdateHandler
        // misses (known issue on simulator, rare edge cases on device).
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                guard let self else { return }
                guard await self.dispatcher.getIsOffline() else { continue }
                monitor.reconcile()
            }
        }

        Task { [weak self] in
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

            // Drain any persisted events from a previous session
            if monitor.currentStatus == .connected {
                await self.dispatcher.drainDiskStoreToNetwork()
            }
        }
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
}
