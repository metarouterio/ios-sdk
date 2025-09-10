import Foundation

public struct InitOptions: Sendable {
    public let writeKey: String
    public let ingestionHost: String

    public init(writeKey: String, ingestionHost: String) {
        self.writeKey = writeKey
        self.ingestionHost = ingestionHost
    }
}