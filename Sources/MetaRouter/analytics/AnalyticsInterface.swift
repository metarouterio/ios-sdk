import Foundation

public protocol AnalyticsInterface: AnyObject, Sendable {
    // Track methods - overloaded to allow calling without properties
    func track(_ event: String, properties: [String: CodableValue]?)
    func track(_ event: String)

    // Identify methods - overloaded to allow calling without traits
    func identify(_ userId: String, traits: [String: CodableValue]?)
    func identify(_ userId: String)

    // Group methods - overloaded to allow calling without traits
    func group(_ groupId: String, traits: [String: CodableValue]?)
    func group(_ groupId: String)

    // Screen methods - overloaded to allow calling without properties
    func screen(_ name: String, properties: [String: CodableValue]?)
    func screen(_ name: String)

    // Page methods - overloaded to allow calling without properties
    func page(_ name: String, properties: [String: CodableValue]?)
    func page(_ name: String)

    func alias(_ newUserId: String)
    func enableDebugLogging()
    func getDebugInfo() -> [String: CodableValue]
    func flush()
    func reset()
}
