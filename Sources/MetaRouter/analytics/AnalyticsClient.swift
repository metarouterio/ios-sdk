import Foundation

public struct InitOptions: Sendable {
    public let writeKey: String
    public let ingestionHost: String

    public init(writeKey: String, ingestionHost: String) {
        self.writeKey = writeKey
        self.ingestionHost = ingestionHost
    }
}

/// Actor-based analytics client for MetaRouter
/// @unchecked Sendable is safe here because actor isolation protects state
final actor AnalyticsClient: AnalyticsInterface, @unchecked Sendable {
    private let writeKey: String
    private let ingestionHost: String

    internal init(options: InitOptions) {
        self.writeKey = options.writeKey
        self.ingestionHost = options.ingestionHost
    }

    public static func initialize(options: InitOptions) throws -> AnalyticsClient {
        guard !options.writeKey.isEmpty else {
            throw InitializationError.missingWriteKey
        }

        guard let url = URL(string: options.ingestionHost),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw InitializationError.invalidIngestionHost
        }

        return AnalyticsClient(options: options)
    }


    public nonisolated func track(event: String, properties: [String: Any]? = nil) {
        let codableProps = MetaRouterCodableUtils.toCodableValueDict(properties ?? [:])
        Task { @Sendable [event, codableProps] in
            await self.track(event: event, properties: codableProps)
        }
    }

    public nonisolated func identify(userId: String, traits: [String: Any]? = nil) {
        let codableTraits = MetaRouterCodableUtils.toCodableValueDict(traits ?? [:])
        Task { @Sendable [userId, codableTraits] in
            await self.identify(userId: userId, traits: codableTraits)
        }
    }

    public nonisolated func group(groupId: String, traits: [String: Any]? = nil) {
        let codableTraits = MetaRouterCodableUtils.toCodableValueDict(traits ?? [:])
        Task { @Sendable [groupId, codableTraits] in
            await self.group(groupId: groupId, traits: codableTraits)
        }
    }

    public nonisolated func screen(name: String, properties: [String: Any]? = nil) {
        let codableProps = MetaRouterCodableUtils.toCodableValueDict(properties ?? [:])
        Task { @Sendable [name, codableProps] in
            await self.screen(name: name, properties: codableProps)
        }
    }

    public nonisolated func alias(newUserId: String) {
        Task { @Sendable [newUserId] in
            await self.alias(newUserId: newUserId)
        }
    }

    // MARK: - Internal actor-isolated methods (AnalyticsInterface conformance)

    public func track(event: String, properties: [String: CodableValue]?) async {
        print("🔧 [track] event: \(event), properties: \(properties ?? [:])")
    }

    public func identify(userId: String, traits: [String: CodableValue]?) async {
        print("🔧 [identify] userId: \(userId), traits: \(traits ?? [:])")
    }

    public func group(groupId: String, traits: [String: CodableValue]?) async {
        print("🔧 [group] groupId: \(groupId), traits: \(traits ?? [:])")
    }

    public func screen(name: String, properties: [String: CodableValue]?) async {
        print("🔧 [screen] name: \(name), properties: \(properties ?? [:])")
    }

    public func alias(newUserId: String) async {
        print("🔧 [alias] newUserId: \(newUserId)")
    }

    public func flush() async {
        print("🔧 [flush] called")
    }

    public func cleanup() async {
        print("🔧 [cleanup] called")
    }

    public func enableDebugLogging() async {
        print("🔧 [enableDebugLogging] called")
    }

    public func getDebugInfo() async -> [String: CodableValue] {
        print("🔧 [getDebugInfo] returning dummy values")
        return [
            "writeKey": .string("***" + writeKey.suffix(4)),
            "ingestionHost": .string(ingestionHost),
            "queueLength": .int(0),
            "debugEnabled": .bool(true)
        ]
    }
}
