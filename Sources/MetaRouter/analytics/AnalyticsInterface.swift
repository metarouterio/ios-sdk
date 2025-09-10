import Foundation

public protocol AnalyticsInterface: AnyObject, Sendable {
    func track(_ event: String, properties: [String: CodableValue]?)
    func identify(_ userId: String, traits: [String: CodableValue]?)
    func group(_ groupId: String, traits: [String: CodableValue]?)
    func screen(_ name: String, properties: [String: CodableValue]?)
    func page(_ name: String, properties: [String: CodableValue]?)
    func alias(_ newUserId: String)
    func enableDebugLogging()
    func getDebugInfo() -> [String: CodableValue]
    func flush()
    func reset()
}
