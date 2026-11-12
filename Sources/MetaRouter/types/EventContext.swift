import Foundation

/// App-specific context information. Cached once at SDK init from the bundle
/// (see `fromBundle`) — `Bundle.main.infoDictionary` is OS-loaded at process
/// start and immutable, so the cached value is stable for the SDK lifetime.
public struct AppContext: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let build: String
    public let namespace: String

    public init(name: String, version: String, build: String, namespace: String) {
        self.name = name
        self.version = version
        self.build = build
        self.namespace = namespace
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> AppContext {
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? "Unknown"
        return AppContext(
            name: name,
            version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            namespace: bundle.bundleIdentifier ?? "unknown"
        )
    }
}

/// Device-specific context information
public struct DeviceContext: Codable, Sendable {
    public let manufacturer: String
    public let model: String
    public let type: String
    public let advertisingId: String?

    public init(manufacturer: String, model: String, type: String, advertisingId: String? = nil) {
        self.manufacturer = manufacturer
        self.model = model
        self.type = type
        self.advertisingId = advertisingId
    }

    func with(advertisingId: String?) -> DeviceContext {
        DeviceContext(manufacturer: manufacturer, model: model, type: type, advertisingId: advertisingId)
    }
}

/// Library-specific context information
public struct LibraryContext: Codable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// Operating system context information
public struct OSContext: Codable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// Screen/display context information
public struct ScreenContext: Codable, Sendable {
    public let density: Double
    public let width: Int
    public let height: Int

    public init(density: Double, width: Int, height: Int) {
        self.density = density
        self.width = width
        self.height = height
    }
}

/// Network context information (optional)
public struct NetworkContext: Codable, Sendable {
    public let wifi: Bool

    public init(wifi: Bool) {
        self.wifi = wifi
    }
}

/// Complete event context information
public struct EventContext: Codable, Sendable {
    public let app: AppContext
    /// `var` so enrichment can overlay `advertisingId` per event on the cached
    /// static context without rebuilding it.
    public var device: DeviceContext
    public let library: LibraryContext
    public let os: OSContext
    public let screen: ScreenContext
    /// Volatile: set per event by enrichment from the live network monitor, never
    /// captured in the provider's cached context — the interface changes over the
    /// app's lifetime, and a cached value reports wifi for a user now on cellular.
    public var network: NetworkContext?
    public let locale: String
    public let timezone: String
    public let additional: [String: CodableValue]
    /// Present only on bridge-sourced events — set by enrichment from the event's
    /// page facts; native events have no page to describe and omit the key entirely.
    public var page: PageContext?
    /// Session (and future provider) values keyed by provider name, set per event
    /// by enrichment — the mobile counterpart of the web SDK's `context.providers`
    /// block, so pipeline mappings read one path from both platforms. Session
    /// values change over the app's lifetime, so this is `var` and assigned at
    /// enrichment time like `page`, never captured in the provider's cached
    /// context. Optional is load-bearing: enriched events are JSON-persisted to
    /// disk, and a decoder that requires this key would silently discard every
    /// event queued by a build that predates it.
    public var providers: [String: [String: CodableValue]]?
    /// The consent block, set per event by enrichment from the consent manager's
    /// current state — never captured in the provider's cached context, because
    /// consent changes over the app's lifetime and the stamp must be point-in-time.
    /// Optional for the same disk-compatibility reason as `providers`: events
    /// persisted by a build that predates this key must still decode.
    public var consent: ConsentContext?

    public init(
        app: AppContext,
        device: DeviceContext,
        library: LibraryContext,
        os: OSContext,
        screen: ScreenContext,
        network: NetworkContext? = nil,
        locale: String,
        timezone: String,
        additional: [String: CodableValue] = [:],
        page: PageContext? = nil,
        providers: [String: [String: CodableValue]]? = nil,
        consent: ConsentContext? = nil
    ) {
        self.app = app
        self.device = device
        self.library = library
        self.os = os
        self.screen = screen
        self.network = network
        self.locale = locale
        self.timezone = timezone
        self.additional = additional
        self.page = page
        self.providers = providers
        self.consent = consent
    }
}

/// Consent block stamped on every outbound event at `context.consent`. Mirrors
/// the web SDK's output exactly — the server gates per integration on this shape,
/// so web and mobile traffic must be indistinguishable to downstream config. The
/// internal `Consent.timestamp` deliberately stays off the wire: this type has no
/// field for it, so no encoder path can leak it.
public struct ConsentContext: Codable, Sendable, Equatable {
    public let explicit: Bool
    public let optOut: [String: Bool]

    public init(explicit: Bool, optOut: [String: Bool]) {
        self.explicit = explicit
        self.optOut = optOut
    }

    public init(_ consent: Consent) {
        self.explicit = consent.explicit
        self.optOut = consent.optOut
    }
}

/// Web page facts for events that originate inside a webview. Only present on
/// bridge-sourced events — native events have no page to describe. Matches the
/// web SDK's context.page block so downstream config treats webview traffic the
/// same as browser traffic.
public struct PageContext: Codable, Sendable, Equatable {
    public let url: String?
    public let path: String?
    public let search: String?
    public let title: String?
    public let referrer: String?

    public init(
        url: String? = nil,
        path: String? = nil,
        search: String? = nil,
        title: String? = nil,
        referrer: String? = nil
    ) {
        self.url = url
        self.path = path
        self.search = search
        self.title = title
        self.referrer = referrer
    }
}

/// Protocol for context collection
public protocol ContextProvider: Sendable {
    /// Collects and returns the current event context
    func getContext() async -> EventContext

    /// Clears any cached context data
    func clearCache()
}
