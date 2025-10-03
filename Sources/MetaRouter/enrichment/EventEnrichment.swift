import Foundation

/// Service responsible for enriching events with context and metadata
public final class EventEnrichmentService: Sendable {

    private let contextProvider: ContextProvider
    private let identityManager: IdentityManager
    private let writeKey: String

    public init(contextProvider: ContextProvider, identityManager: IdentityManager, writeKey: String) {
        self.contextProvider = contextProvider
        self.identityManager = identityManager
        self.writeKey = writeKey
    }

    /// Enrich an event with identity, context, and metadata
    /// Equivalent to the React Native enrichEvent function
    public func enrichEvent(
        _ event: EventWithIdentity
    ) async -> EnrichedEventPayload {
        let context = await contextProvider.getContext()
        let messageId = MessageIdGenerator.generate()

        return EnrichedEventPayload(
            type: event.type,
            event: event.event,
            userId: event.userId,
            anonymousId: event.anonymousId,
            properties: event.properties,
            traits: event.traits,
            integrations: event.integrations,
            timestamp: event.timestamp,
            writeKey: writeKey,
            messageId: messageId,
            context: context
        )
    }

    /// Convenience method to enrich an event with custom message ID
    public func enrichEvent(
        _ event: EventWithIdentity,
        messageId: String
    ) async -> EnrichedEventPayload {
        let context = await contextProvider.getContext()

        return EnrichedEventPayload(
            type: event.type,
            event: event.event,
            userId: event.userId,
            anonymousId: event.anonymousId,
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
        let timestamp = baseEvent.timestamp ?? ISO8601DateFormatter().string(from: Date())

        let eventWithIdentity = EventWithIdentity(
            type: baseEvent.type,
            event: baseEvent.event,
            userId: baseEvent.userId ?? identity.userId,
            anonymousId: identity.anonymousId,
            properties: baseEvent.properties,
            traits: baseEvent.traits,
            integrations: baseEvent.integrations,
            timestamp: timestamp
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

/// Extension for JSON serialization
extension EnrichedEventPayload {

    /// Convert the enriched event to JSON data for network transmission
    public func toJsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Convert the enriched event to a JSON string for debugging
    public func toJsonString() throws -> String {
        let data = try toJsonData()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Create a pretty-printed JSON string for debugging
    public func toPrettyJsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
