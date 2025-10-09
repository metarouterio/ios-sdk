import Foundation

/// App-specific context information
public struct AppContext: Codable, Equatable, Sendable {
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
}

/// Device-specific context information
public struct DeviceContext: Codable, Equatable, Sendable {
    public let manufacturer: String
    public let model: String
    public let name: String
    public let type: String
    public let advertisingId: String?

    public init(manufacturer: String, model: String, name: String, type: String, advertisingId: String? = nil) {
        self.manufacturer = manufacturer
        self.model = model
        self.name = name
        self.type = type
        self.advertisingId = advertisingId
    }
}

/// Library-specific context information
public struct LibraryContext: Codable, Equatable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// Operating system context information
public struct OSContext: Codable, Equatable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// Screen/display context information
public struct ScreenContext: Codable, Equatable, Sendable {
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
public struct NetworkContext: Codable, Equatable, Sendable {
    public let wifi: Bool

    public init(wifi: Bool) {
        self.wifi = wifi
    }
}

/// Complete event context information
public struct EventContext: Codable, Sendable {
    public let app: AppContext
    public let device: DeviceContext
    public let library: LibraryContext
    public let os: OSContext
    public let screen: ScreenContext
    public let network: NetworkContext?
    public let locale: String
    public let timezone: String
    public let additional: [String: CodableValue]

    public init(
        app: AppContext,
        device: DeviceContext,
        library: LibraryContext,
        os: OSContext,
        screen: ScreenContext,
        network: NetworkContext? = nil,
        locale: String,
        timezone: String,
        additional: [String: CodableValue] = [:]
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
    }
}

/// Protocol for context collection
public protocol ContextProvider: Sendable {
    /// Collects and returns the current event context
    func getContext() async -> EventContext

    /// Clears any cached context data
    func clearCache()
}
