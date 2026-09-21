import Foundation

/// Service responsible for enriching events with context and metadata
public final class EventEnrichmentService: Sendable {

    private let contextProvider: ContextProvider
    private let identityManager: IdentityManager
    private let writeKey: String
    private let sessionManager: SessionManager

    /// Standalone construction only. This creates its OWN session manager over
    /// `UserDefaults.standard` with the default timeout — running one of these
    /// beside a live `AnalyticsClient` means two managers racing the same
    /// persisted `metarouter:session:*` keys: independent mints, a
    /// double-incremented sessionCount, and events inside one real session
    /// stamped with different sessionIDs. Anything with access to the client's
    /// session manager must pass it via the internal initializer instead.
    public convenience init(contextProvider: ContextProvider, identityManager: IdentityManager, writeKey: String) {
        self.init(
            contextProvider: contextProvider,
            identityManager: identityManager,
            writeKey: writeKey,
            sessionManager: SessionManager(storage: SessionStorage())
        )
    }

    internal init(
        contextProvider: ContextProvider,
        identityManager: IdentityManager,
        writeKey: String,
        sessionManager: SessionManager
    ) {
        self.contextProvider = contextProvider
        self.identityManager = identityManager
        self.writeKey = writeKey
        self.sessionManager = sessionManager
    }

    /// Enrich an event with identity, context, and metadata
    /// Equivalent to the React Native enrichEvent function
    public func enrichEvent(
        _ event: EventWithIdentity
    ) async -> EnrichedEventPayload {
        var context = await contextProvider.getContext()
        let messageId = MessageIdGenerator.generate()

        // Bridge-sourced events carry their page facts on the event; native events
        // leave it nil and context.page stays absent, matching web SDK output.
        if let page = event.page {
            context.page = page
        }

        // Every enriched event is session activity, and this is the one funnel all
        // event sources share (native calls, lifecycle events, the webview bridge),
        // so touching here is what makes the session stamp universal. The key names
        // and the epoch-ms string mirror the web SDK's generic MetaRouter session
        // (`context.providers.metarouter`), so pipeline mappings read one shape
        // from both platforms — renaming either side forks them.
        let session = await sessionManager.touch()
        context.providers = [
            "metarouter": [
                "sessionID": .string(session.sessionId),
                "sessionCount": .int(session.sessionCount),
            ]
        ]

        return EnrichedEventPayload(
            type: event.type,
            event: event.event,
            userId: event.userId,
            anonymousId: event.anonymousId,
            groupId: event.groupId,
            properties: event.properties,
            traits: event.traits,
            integrations: event.integrations,
            timestamp: event.timestamp,
            writeKey: writeKey,
            messageId: messageId,
            context: context
        )
    }

    /// Enrich a base event by first adding identity information, then enriching
    public func enrichEvent(
        _ baseEvent: BaseEvent
    ) async -> EnrichedEventPayload {
        let identity = await identityManager.getIdentityInfo()
        let timestamp = baseEvent.timestamp ?? DateFormatters.iso8601.string(from: Date())

        let eventWithIdentity = EventWithIdentity(
            type: baseEvent.type,
            event: baseEvent.event,
            userId: baseEvent.userId ?? identity.userId,
            anonymousId: baseEvent.anonymousId ?? identity.anonymousId,
            groupId: baseEvent.groupId ?? identity.groupId,
            properties: baseEvent.properties,
            traits: baseEvent.traits,
            integrations: baseEvent.integrations,
            timestamp: timestamp,
            page: baseEvent.page
        )

        return await enrichEvent(eventWithIdentity)
    }


    /// Create and enrich a track event
    public func createTrackEvent(
        event: String,
        properties: [String: CodableValue]? = nil
    ) async -> EnrichedEventPayload {
        let baseEvent = BaseEvent(
            type: EventType.track.rawValue,
            event: event,
            properties: properties
        )

        return await enrichEvent(baseEvent)
    }

    /// Create and enrich an identify event
    public func createIdentifyEvent(
        userId: String,
        traits: [String: CodableValue]? = nil
    ) async -> EnrichedEventPayload {
        let baseEvent = BaseEvent(
            type: EventType.identify.rawValue,
            userId: userId,
            traits: traits
        )

        return await enrichEvent(baseEvent)
    }

    /// Create and enrich a group event
    public func createGroupEvent(
        groupId: String,
        traits: [String: CodableValue]? = nil
    ) async -> EnrichedEventPayload {
        let baseEvent = BaseEvent(
            type: EventType.group.rawValue,
            properties: groupId.isEmpty ? nil : ["groupId": .string(groupId)],
            traits: traits
        )

        return await enrichEvent(baseEvent)
    }

    /// Create and enrich a screen event
    public func createScreenEvent(
        name: String,
        properties: [String: CodableValue]? = nil
    ) async -> EnrichedEventPayload {
        var screenProperties = properties ?? [:]
        screenProperties["name"] = .string(name)

        let baseEvent = BaseEvent(
            type: EventType.screen.rawValue,
            properties: screenProperties
        )

        return await enrichEvent(baseEvent)
    }

    /// Create and enrich a page event
    public func createPageEvent(
        name: String,
        properties: [String: CodableValue]? = nil
    ) async -> EnrichedEventPayload {
        var pageProperties = properties ?? [:]
        pageProperties["name"] = .string(name)

        let baseEvent = BaseEvent(
            type: EventType.page.rawValue,
            properties: pageProperties
        )

        return await enrichEvent(baseEvent)
    }

    /// Create and enrich an alias event
    public func createAliasEvent(
        newUserId: String,
        previousUserId: String? = nil
    ) async -> EnrichedEventPayload {
        let baseEvent = BaseEvent(
            type: EventType.alias.rawValue,
            userId: newUserId,
            properties: previousUserId.map { ["previousId": .string($0)] }
        )

        return await enrichEvent(baseEvent)
    }
}

