import Foundation

public final class AnalyticsClient: AnalyticsInterface, @unchecked Sendable {
    private let options: InitOptions

    private init(options: InitOptions) { self.options = options }

    public static func initialize(options: InitOptions) -> AnalyticsClient {
        AnalyticsClient(options: options)
    }

    public func track(_ event: String, properties: [String: CodableValue]? = nil) {
        Logger.log("track event='\(event)', props=\(properties ?? [:])", writeKey: options.writeKey, host: options.ingestionHost)
    }

    public func identify(_ userId: String, traits: [String: CodableValue]? = nil) {
        Logger.log("identify userId='\(userId)', traits=\(traits ?? [:])", writeKey: options.writeKey, host: options.ingestionHost)
    }

    public func group(_ groupId: String, traits: [String: CodableValue]? = nil) {
        Logger.log("group groupId='\(groupId)', traits=\(traits ?? [:])", writeKey: options.writeKey, host: options.ingestionHost)
    }

    public func alias(_ newUserId: String) {
        Logger.log("alias newUserId='\(newUserId)'", writeKey: options.writeKey, host: options.ingestionHost)
    }

    public func screen(_ name: String, properties: [String: CodableValue]? = nil) {
        Logger.log("screen name='\(name)', properties=\(properties ?? [:])", writeKey: options.writeKey, host: options.ingestionHost)
    }

    public func page(_ name: String, properties: [String: CodableValue]? = nil) {
        Logger.log("page name='\(name)', properties=\(properties ?? [:])", writeKey: options.writeKey, host: options.ingestionHost)
    }

    public func enableDebugLogging() {
        Logger.setDebugLogging(true)
        Logger.log("debug logging enabled", writeKey: options.writeKey, host: options.ingestionHost)
    }

    public func getDebugInfo() -> [String: CodableValue] {
        [
            "writeKey": .string(options.writeKey),
            "ingestionHost": .string(options.ingestionHost)
        ]
    }

    public func flush() { Logger.log("flush (no-op)", writeKey: options.writeKey, host: options.ingestionHost) }
    public func reset() { Logger.log("reset (no-op)", writeKey: options.writeKey, host: options.ingestionHost) }
}
