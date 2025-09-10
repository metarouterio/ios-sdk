import Foundation

public struct InitOptions: Sendable {
    public let writeKey: String
    public let ingestionHost: URL

    public init(writeKey: String, ingestionHost: URL) {
           precondition(!writeKey.isEmpty, "writeKey must not be empty")

           // reject if it ends with /
           let raw = ingestionHost.absoluteString
           precondition(!raw.hasSuffix("/"), "ingestionHost must not end with a slash")

           self.writeKey = writeKey
           self.ingestionHost = ingestionHost
       }
}

extension InitOptions {
    public init(writeKey: String, ingestionHost: String) {
        var host = ingestionHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix("/") {
            host.removeLast()
        }
        guard let url = URL(string: host), url.scheme != nil else {
            preconditionFailure("Invalid ingestionHost: \(ingestionHost)")
        }
        self.init(writeKey: writeKey, ingestionHost: url)
    }
}
