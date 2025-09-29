import Foundation


internal final class AnalyticsClient: AnalyticsInterface, CustomStringConvertible,
    CustomDebugStringConvertible, @unchecked Sendable
{
    private let options: InitOptions
    private let contextProvider: ContextProvider
    private let enrichmentService: EventEnrichmentService
    private let dispatcher: Dispatcher
    private lazy var lifecycle: AppLifecycleObserver = {
        let observer = AppLifecycleObserver(
            onForeground: { [weak self] in
                guard let self else { return }
                Task { [weak self] in
                    guard let self else { return }
                    await self.dispatcher.startFlushLoop(intervalSeconds: 10)
                    await self.dispatcher.flush()
                }
            },
            onBackground: { [weak self] in
                guard let self else { return }
                Task { [weak self] in
                    guard let self else { return }
                    await self.dispatcher.flush()
                    await self.dispatcher.stopFlushLoop()
                    await self.dispatcher.cancelScheduledRetry()
                }
            }
        )
        return observer
    }()
    private var disabled = false

    private init(options: InitOptions, contextProvider: ContextProvider? = nil) {
        self.options = options
        self.contextProvider = contextProvider ?? IOSContextProvider()
        self.enrichmentService = EventEnrichmentService(
            contextProvider: self.contextProvider,
            writeKey: options.writeKey
        )

        // Set up dispatcher with fatal-config handler
        self.dispatcher = Dispatcher(
            options: options,
            http: NetworkClient(),
            breaker: CircuitBreaker(),
            queueCapacity: 2000,
            config: Dispatcher.Config(endpointPath: "/v1/batch", timeoutMs: 8000, autoFlushThreshold: 20, initialMaxBatchSize: 100)
        )

        // Set handler after init to avoid self-before-init capture
        Task { [weak self] in
            guard let self else { return }
            await self.dispatcher.setFatalConfigHandler({ [weak self] status in
                Logger.error("Fatal config error \(status). Disabling client.")
                self?.disabled = true
            })
        }

        _ = lifecycle

        // Start periodic flushing immediately
        Task { [weak self] in
            guard let self else { return }
            await self.dispatcher.startFlushLoop(intervalSeconds: 10)
        }
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

    public func track(_ event: String, properties: [String: CodableValue]?) {
        Task {
            guard !disabled else { return }
            let enrichedEvent = await enrichmentService.createTrackEvent(
                event: event,
                properties: properties
            )

            Logger.log(
                "track event='\(event)', props=\(properties ?? [:]), messageId=\(enrichedEvent.messageId)",
                writeKey: options.writeKey,
                host: options.ingestionHost.absoluteString)

            await dispatcher.offer(enrichedEvent)
        }
    }

    public func track(_ event: String) {
        track(event, properties: nil)
    }

    public func identify(_ userId: String, traits: [String: CodableValue]?) {
        Task {
            guard !disabled else { return }
            let enrichedEvent = await enrichmentService.createIdentifyEvent(
                userId: userId,
                traits: traits
            )

            Logger.log(
                "identify userId='\(userId)', traits=\(traits ?? [:]), messageId=\(enrichedEvent.messageId)",
                writeKey: options.writeKey,
                host: options.ingestionHost.absoluteString)

            await dispatcher.offer(enrichedEvent)
        }
    }

    public func identify(_ userId: String) {
        identify(userId, traits: nil)
    }

    public func group(_ groupId: String, traits: [String: CodableValue]?) {
        Task {
            guard !disabled else { return }
            let enrichedEvent = await enrichmentService.createGroupEvent(
                groupId: groupId,
                traits: traits
            )

            Logger.log(
                "group groupId='\(groupId)', traits=\(traits ?? [:]), messageId=\(enrichedEvent.messageId)",
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

    public func screen(_ name: String, properties: [String: CodableValue]?) {
        Task {
            guard !disabled else { return }
            let enrichedEvent = await enrichmentService.createScreenEvent(
                name: name,
                properties: properties
            )

            Logger.log(
                "screen name='\(name)', properties=\(properties ?? [:]), messageId=\(enrichedEvent.messageId)",
                writeKey: options.writeKey,
                host: options.ingestionHost.absoluteString)

            await dispatcher.offer(enrichedEvent)
        }
    }

    public func screen(_ name: String) {
        screen(name, properties: nil)
    }

    public func page(_ name: String, properties: [String: CodableValue]?) {
        Task {
            guard !disabled else { return }
            let enrichedEvent = await enrichmentService.createPageEvent(
                name: name,
                properties: properties
            )

            Logger.log(
                "page name='\(name)', properties=\(properties ?? [:]), messageId=\(enrichedEvent.messageId)",
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

    public func getDebugInfo() -> [String: CodableValue] {
        [
            "writeKey": .string(options.writeKey),
            "ingestionHost": .string(options.ingestionHost.absoluteString),
        ]
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
            await self.dispatcher.stopFlushLoop()
            await self.dispatcher.cancelScheduledRetry()
            await self.dispatcher.clearAll()
            self.disabled = false
        }
    }
}
