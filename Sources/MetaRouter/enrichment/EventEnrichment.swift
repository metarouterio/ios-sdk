import Foundation

/// Service responsible for enriching events with context and metadata. Internal:
/// it is only correct when built with the client's own session, consent and
/// provider-context managers, so nothing outside the SDK constructs one.
internal final class EventEnrichmentService: Sendable {

    private let contextProvider: ContextProvider
    private let identityManager: IdentityManager
    private let writeKey: String
    private let sessionManager: SessionManager
    private let consentManager: ConsentManager
    private let providerContextManager: ProviderContextManager
    private let networkMonitor: NetworkReachability?

    /// Longest an event waits for the network monitor's first path at cold launch.
    /// The one-shot probe this replaced waited up to 2s per context build.
    static let firstPathTimeout: TimeInterval = 0.5

    /// The only initializer. Construction requires the client's own session,
    /// consent and provider-context managers: a second session manager races the
    /// same persisted `metarouter:session:*` keys (independent mints, a
    /// double-incremented sessionCount), a second consent manager never hears the
    /// host's `setConsent` / `clearConsent` — it would stamp a consent the user has
    /// since withdrawn — and a second provider-context manager never hears
    /// `setProviderContext`. The type and a standalone initializer were public before
    /// consent, and both were withdrawn for exactly that reason. The network monitor
    /// is required too, though nil is allowed: a default would let a construction
    /// silently ship every event without `context.network`.
    internal init(
        contextProvider: ContextProvider,
        identityManager: IdentityManager,
        writeKey: String,
        sessionManager: SessionManager,
        consentManager: ConsentManager,
        providerContextManager: ProviderContextManager,
        networkMonitor: NetworkReachability?
    ) {
        self.contextProvider = contextProvider
        self.identityManager = identityManager
        self.writeKey = writeKey
        self.sessionManager = sessionManager
        self.consentManager = consentManager
        self.providerContextManager = providerContextManager
        self.networkMonitor = networkMonitor
    }

    /// Enrich an event with identity, context, and metadata
    /// Equivalent to the React Native enrichEvent function
    func enrichEvent(
        _ event: EventWithIdentity
    ) async -> EnrichedEventPayload {
        var context = await contextProvider.getContext()
        let messageId = MessageIdGenerator.generate()

        // Ad ID is overlaid per event from IdentityManager, the value the host's
        // setAdvertisingId persists, instead of living in the provider's cached
        // context — that coupling forced a full context rebuild on every change.
        // Present-only, as on Android: a cleared ID leaves the provider's device
        // block as is, and the SDK's own provider never carries one.
        if let advertisingId = await identityManager.getAdvertisingId() {
            context.device = context.device.with(advertisingId: advertisingId)
        }

        // Network is read live from the persistent monitor at enrichment, so
        // `network.wifi` is the interface at event time, not at the first event.
        // Cold-launch events (Installed / Opened, replayed pre-bind calls) can be
        // enriched before the monitor's first path, usually milliseconds away; the
        // bounded wait keeps them from shipping without `network`, which Android's
        // synchronous read always has. Only events enriched before the first path wait,
        // each at most `firstPathTimeout` (a cold-launch burst waits in parallel); once
        // the path arrives or one wait times out, no event waits again.
        // Still unknown keeps the provider's value — nil for the SDK's own provider,
        // which omits the object: the spec requires `wifi` to be a boolean whenever
        // `network` is present, so there is no null form.
        if let wifi = await networkMonitor?.awaitIsWifi(timeout: Self.firstPathTimeout) {
            context.network = NetworkContext(wifi: wifi)
        }

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
        // Host values first, the SDK's block last, so the session stamp wins any
        // collision. The API already refuses `metarouter`; this ordering is what
        // still holds for a value that reached the map another way. Flipping it —
        // one merge with the host map last — hands a customer sessionID, and
        // nothing downstream would flag it.
        var providers = providerContextManager.getAll()
        providers["metarouter"] = [
            "sessionID": .string(session.sessionId),
            "sessionCount": .int(session.sessionCount),
        ]
        context.providers = providers

        // Consent is read here, per event, for the same reason: this funnel is
        // shared by every source. The stamp is the state at ENRICHMENT time — not
        // atomically with identity and session, which were read before the awaits
        // above, but never as early as the track() call:
        // track() only schedules enrichment, so `track(); setConsent()` on adjacent
        // lines can stamp the new state, and a pre-initialize call replayed at bind
        // is stamped with whatever consent holds at replay. Once enriched, a payload
        // is immutable; a later setConsent never rewrites it. Before the host's first
        // setConsent this is the implicit default (`explicit: false`, registered
        // categories at their defaults) — a complete block the server gates like
        // implicit-consent web traffic, never an absent field. (Events a
        // pre-consent build enriched and left on disk drain without one; they were
        // never consent-stamped, and stamping today's consent onto them would
        // misattribute it.) The path and shape
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
    func enrichEvent(
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
    func createTrackEvent(
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
    func createIdentifyEvent(
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
    func createGroupEvent(
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
    func createScreenEvent(
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
    func createPageEvent(
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
    func createAliasEvent(
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

