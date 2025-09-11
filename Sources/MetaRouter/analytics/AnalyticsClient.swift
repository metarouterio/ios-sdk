import Foundation

internal final class AnalyticsClient: AnalyticsInterface, CustomStringConvertible, CustomDebugStringConvertible, @unchecked Sendable {
    private let options: InitOptions

    private init(options: InitOptions) { self.options = options }

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
        Logger.log("track event='\(event)', props=\(properties ?? [:])", writeKey: options.writeKey, host: options.ingestionHost.absoluteString)
    }

    public func track(_ event: String) {
        track(event, properties: nil)
    }

    public func identify(_ userId: String, traits: [String: CodableValue]?) {
        Logger.log("identify userId='\(userId)', traits=\(traits ?? [:])", writeKey: options.writeKey, host: options.ingestionHost.absoluteString)
    }

    public func identify(_ userId: String) {
        identify(userId, traits: nil)
    }

    public func group(_ groupId: String, traits: [String: CodableValue]?) {
        Logger.log("group groupId='\(groupId)', traits=\(traits ?? [:])", writeKey: options.writeKey, host: options.ingestionHost.absoluteString)
    }

    public func group(_ groupId: String) {
        group(groupId, traits: nil)
    }

    public func alias(_ newUserId: String) {
        Logger.log("alias newUserId='\(newUserId)'", writeKey: options.writeKey, host: options.ingestionHost.absoluteString)
    }

    public func screen(_ name: String, properties: [String: CodableValue]?) {
        Logger.log("screen name='\(name)', properties=\(properties ?? [:])", writeKey: options.writeKey, host: options.ingestionHost.absoluteString)
    }

    public func screen(_ name: String) {
        screen(name, properties: nil)
    }

    public func page(_ name: String, properties: [String: CodableValue]?) {
        Logger.log("page name='\(name)', properties=\(properties ?? [:])", writeKey: options.writeKey, host: options.ingestionHost.absoluteString)
    }

    public func page(_ name: String) {
        page(name, properties: nil)
    }

    public func enableDebugLogging() {
        Logger.setDebugLogging(true)
        Logger.log("debug logging enabled", writeKey: options.writeKey, host: options.ingestionHost.absoluteString)
    }

    public func getDebugInfo() -> [String: CodableValue] {
        [
            "writeKey": .string(options.writeKey),
            "ingestionHost": .string(options.ingestionHost.absoluteString)
        ]
    }

    public func flush() { Logger.log("flush (no-op)", writeKey: options.writeKey, host: options.ingestionHost.absoluteString) }
    public func reset() { Logger.log("reset (no-op)", writeKey: options.writeKey, host: options.ingestionHost.absoluteString) }
}
