import Foundation

/// Base event structure before enrichment
public struct BaseEvent: Codable, Sendable {
    public let type: String
    public let event: String?
    public let userId: String?
    public let anonymousId: String?
    public let properties: [String: CodableValue]?
    public let traits: [String: CodableValue]?
    public let integrations: [String: CodableValue]?
    public let timestamp: String?

    public init(
        type: String,
        event: String? = nil,
        userId: String? = nil,
        anonymousId: String? = nil,
        properties: [String: CodableValue]? = nil,
        traits: [String: CodableValue]? = nil,
        integrations: [String: CodableValue]? = nil,
        timestamp: String? = nil
    ) {
        self.type = type
        self.event = event
        self.userId = userId
        self.anonymousId = anonymousId
        self.properties = properties
        self.traits = traits
        self.integrations = integrations
        self.timestamp = timestamp
    }
}

/// Event with identity information
public struct EventWithIdentity: Codable, Sendable {
    public let type: String
    public let event: String?
    public let userId: String?
    public let anonymousId: String
    public let properties: [String: CodableValue]?
    public let traits: [String: CodableValue]?
    public let integrations: [String: CodableValue]?
    public let timestamp: String

    public init(
        type: String,
        event: String? = nil,
        userId: String? = nil,
        anonymousId: String,
        properties: [String: CodableValue]? = nil,
        traits: [String: CodableValue]? = nil,
        integrations: [String: CodableValue]? = nil,
        timestamp: String
    ) {
        self.type = type
        self.event = event
        self.userId = userId
        self.anonymousId = anonymousId
        self.properties = properties
        self.traits = traits
        self.integrations = integrations
        self.timestamp = timestamp
    }
}

/// Fully enriched event payload ready for sending
public struct EnrichedEventPayload: Codable, Sendable {
    public let type: String
    public let event: String?
    public let userId: String?
    public let anonymousId: String
    public let properties: [String: CodableValue]?
    public let traits: [String: CodableValue]?
    public let integrations: [String: CodableValue]?
    public let timestamp: String
    public let writeKey: String
    public let messageId: String
    public let context: EventContext

    public init(
        type: String,
        event: String? = nil,
        userId: String? = nil,
        anonymousId: String,
        properties: [String: CodableValue]? = nil,
        traits: [String: CodableValue]? = nil,
        integrations: [String: CodableValue]? = nil,
        timestamp: String,
        writeKey: String,
        messageId: String,
        context: EventContext
    ) {
        self.type = type
        self.event = event
        self.userId = userId
        self.anonymousId = anonymousId
        self.properties = properties
        self.traits = traits
        self.integrations = integrations
        self.timestamp = timestamp
        self.writeKey = writeKey
        self.messageId = messageId
        self.context = context
    }
}

/// Event types enumeration
public enum EventType: String, CaseIterable, Codable, Sendable {
    case track
    case identify
    case group
    case screen
    case page
    case alias
}
