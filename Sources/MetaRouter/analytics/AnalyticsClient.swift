import Foundation


internal final class AnalyticsClient: AnalyticsInterface, CustomStringConvertible,
    CustomDebugStringConvertible, @unchecked Sendable
{
    private let options: InitOptions
    private let contextProvider: ContextProvider
    private let identityManager: IdentityManager
    private let enrichmentService: EventEnrichmentService
    private let dispatcher: Dispatcher
    private var lifecycle: AppLifecycleObserver!
    private var lifecycleState: LifecycleState = .idle
    private var disabled = false

    private init(options: InitOptions, contextProvider: ContextProvider? = nil) {
        self.lifecycleState = .initializing
        
        Logger.log("Starting analytics client initialization...", 
                   writeKey: options.writeKey, 
                   host: options.ingestionHost.absoluteString)
        
        self.options = options
        self.contextProvider = contextProvider ?? DeviceContextProvider(advertisingId: options.advertisingId)
        self.identityManager = IdentityManager(
            writeKey: options.writeKey,
            host: options.ingestionHost.absoluteString
        )
        self.enrichmentService = EventEnrichmentService(
            contextProvider: self.contextProvider,
            identityManager: self.identityManager,
            writeKey: options.writeKey
        )

        self.dispatcher = Dispatcher(
            options: options,
            http: NetworkClient(),
            breaker: CircuitBreaker(),
            queueCapacity: options.maxQueueEvents,
            config: Dispatcher.Config(endpointPath: "/v1/batch", timeoutMs: 8000, autoFlushThreshold: 20, initialMaxBatchSize: 100)
        )
        
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
        }

        self.lifecycle = AppLifecycleObserver(
            onForeground: { [weak self] in
                guard let self else { return }
                Task { [weak self] in
                    guard let self else { return }
                    await self.dispatcher.startFlushLoop(intervalSeconds: self.options.flushIntervalSeconds)
                    await self.dispatcher.flush()
                }
            },
            onBackgroundAsync: { [weak self] in
                guard let self else { return }
                await self.dispatcher.flush()
                await self.dispatcher.stopFlushLoop()
                await self.dispatcher.cancelScheduledRetry()
            }
        )
        
        Logger.log("App state listener setup completed", 
                   writeKey: options.writeKey, 
                   host: options.ingestionHost.absoluteString)

        Task { [weak self] in
            guard let self else { return }
            await self.identityManager.initialize()
            Logger.log("IdentityManager initialized successfully", 
                       writeKey: self.options.writeKey, 
                       host: self.options.ingestionHost.absoluteString)
            await self.dispatcher.startFlushLoop(intervalSeconds: self.options.flushIntervalSeconds)
            self.lifecycleState = .ready
            Logger.log("Analytics client initialization completed successfully", 
                       writeKey: self.options.writeKey, 
                       host: self.options.ingestionHost.absoluteString)
        }
        
        Logger.log("Analytics client constructor completed, initialization in progress...", 
                   writeKey: options.writeKey, 
                   host: options.ingestionHost.absoluteString)
    }

    internal static func initialize(options: InitOptions) -> AnalyticsClient {
        AnalyticsClient(options: options)
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
            "circuitRemainingMs": .int(circuitRemainingMs)
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
            await self.dispatcher.stopFlushLoop()
            await self.dispatcher.cancelScheduledRetry()
            await self.dispatcher.clearAll()
            self.disabled = false
            self.lifecycleState = .idle
        }
    }
}
