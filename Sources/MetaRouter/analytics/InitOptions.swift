import Foundation

public struct InitOptions: Sendable {
    public let writeKey: String
    public let ingestionHost: URL
    public let flushIntervalSeconds: Int
    public let debug: Bool
    public let maxQueueEvents: Int
    public let advertisingId: String?

    public init(
        writeKey: String,
        ingestionHost: URL,
        flushIntervalSeconds: Int = 10,
        debug: Bool = false,
        maxQueueEvents: Int = 2000,
        advertisingId: String? = nil
    ) {
        precondition(!writeKey.isEmpty, "writeKey must not be empty")

        // reject if it ends with /
        let raw = ingestionHost.absoluteString
        precondition(!raw.hasSuffix("/"), "ingestionHost must not end with a slash")

        self.writeKey = writeKey
        self.ingestionHost = ingestionHost
        self.flushIntervalSeconds = max(1, flushIntervalSeconds)
        self.debug = debug
        self.maxQueueEvents = max(1, maxQueueEvents)
        self.advertisingId = advertisingId
    }
}

extension InitOptions {
    public init(
        writeKey: String,
        ingestionHost: String,
        flushIntervalSeconds: Int = 10,
        debug: Bool = false,
        maxQueueEvents: Int = 2000,
        advertisingId: String? = nil
    ) {
        var host = ingestionHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix("/") {
            host.removeLast()
        }
        guard let url = URL(string: host), url.scheme != nil else {
            preconditionFailure("Invalid ingestionHost: \(ingestionHost)")
        }
        self.init(
            writeKey: writeKey,
            ingestionHost: url,
            flushIntervalSeconds: flushIntervalSeconds,
            debug: debug,
            maxQueueEvents: maxQueueEvents,
            advertisingId: advertisingId
        )
    }
}
