import Foundation

/// Service responsible for enriching events with context and metadata
public final class EventEnrichmentService: Sendable {

    private let contextProvider: ContextProvider
    private let identityManager: IdentityManager
    private let writeKey: String
    private let sessionManager: SessionManager
    private let consentManager: ConsentManager

    /// The only initializer. Construction requires the client's own session and
    /// consent managers: a second session manager races the same persisted
    /// `metarouter:session:*` keys (independent mints, a double-incremented
    /// sessionCount), and a second consent manager never hears the host's
    /// `setConsent` / `clearConsent` — it would stamp a consent the user has since
    /// withdrawn. A public standalone initializer existed before consent and was
    /// removed for exactly that reason; the class stays public only so its
    /// `EnrichedEventPayload` factories remain callable on the client's instance.
    internal init(
        contextProvider: ContextProvider,
        identityManager: IdentityManager,
        writeKey: String,
        sessionManager: SessionManager,
        consentManager: ConsentManager
    ) {
        self.contextProvider = contextProvider
        self.identityManager = identityManager
        self.writeKey = writeKey
        self.sessionManager = sessionManager
        self.consentManager = consentManager
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

        // Consent is read here, per event, for the same reason: this funnel is
        // shared by every source. The stamp is the state at ENRICHMENT time — the
        // same moment identity and session are read — not at the track() call:
        // track() only schedules enrichment, so `track(); setConsent()` on adjacent
        // lines can stamp the new state, and a pre-initialize call replayed at bind
        // is stamped with whatever consent holds at replay. Once enriched, a payload
        // is immutable; a later setConsent never rewrites it. Before the host's first
        // setConsent this is the implicit default (`explicit: false`, registered
        // categories at their defaults) — a complete block the server gates like
        // implicit-consent web traffic, never an absent field. The path and shape
        // are the web SDK's `context.consent`; the server's per-integration gating
        // reads one block from both platforms, so moving or renaming this forks
        // every consent rule downstream.
        context.consent = ConsentContext(consentManager.getConsent())

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

