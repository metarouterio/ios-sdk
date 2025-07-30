import Foundation

public protocol AnalyticsInterface {
    func track(event: String, properties: [String: Any]?)
    func identify(userId: String, traits: [String: Any]?)
    func group(groupId: String, traits: [String: Any]?)
    func screen(name: String, properties: [String: Any]?)
    func alias(newUserId: String)
    func flush()
    func cleanup()
    func enableDebugLogging()
    func getDebugInfo() -> [String: Any]
}