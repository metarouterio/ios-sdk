import Foundation

public protocol AnalyticsInterface: AnyObject, Sendable {
    func track(_ event: String, properties: [String: CodableValue]? = nil)
    func identify(_ userId: String, traits: [String: CodableValue]? = nil)
    func group(_ groupId: String, traits: [String: CodableValue]? = nil)
    func screen(_ name: String, properties: [String: CodableValue]? = nil)
    func page(_ name: String, properties: [String: CodableValue]? = nil)
    func alias(_ newUserId: String)
    func enableDebugLogging()
    func getDebugInfo() -> [String: CodableValue]
    func flush()
    func reset()
}
