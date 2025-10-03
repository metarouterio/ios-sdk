import Foundation

public protocol AnalyticsInterface: AnyObject, Sendable {
    func track(_ event: String, properties: [String: Any]?)
    func track(_ event: String)

    func identify(_ userId: String, traits: [String: Any]?)
    func identify(_ userId: String)

    func group(_ groupId: String, traits: [String: Any]?)
    func group(_ groupId: String)

    func screen(_ name: String, properties: [String: Any]?)
    func screen(_ name: String)

    func page(_ name: String, properties: [String: Any]?)
    func page(_ name: String)

    func alias(_ newUserId: String)
    func enableDebugLogging()
    func getDebugInfo() -> [String: CodableValue]
    func flush()
    func reset()
}
