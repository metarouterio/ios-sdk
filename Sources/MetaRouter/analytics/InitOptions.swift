import Foundation

/// Why construction was invalid. Recorded on the options rather than thrown: a throwing
/// initializer would leave the diagnostics callback nowhere to live, and an integrator
/// sourcing config from a remote system would `try!` straight back into the crash this
/// contract exists to prevent. `initialize(with:)` reads the verdict and degrades.
public enum ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyWriteKey
    case invalidIngestionHost(String)

    public var description: String {
        switch self {
        case .emptyWriteKey:
            return "writeKey must not be empty or whitespace-only"
        case .invalidIngestionHost(let raw):
            return "ingestionHost must be an http(s) URL, got \"\(raw)\""
        }
    }
}

public struct InitOptions: Sendable {
    public let writeKey: String
    public let ingestionHost: URL
    public let flushIntervalSeconds: Int
    public let debug: Bool
    public let maxQueueEvents: Int
    public let maxDiskEvents: Int
    public let trackLifecycleEvents: Bool

    /// Non-nil when construction received invalid config. The SDK never crashes the
    /// host over local config in release — `initialize(with:)` sees this, logs an
    /// always-on error, fires `onConfigError`, and leaves the SDK inert for the
    /// session, mirroring the 401/403/404 graceful-disable. Debug builds fail fast at
    /// the construction site instead.
    public let configError: ConfigError?

    /// Fired synchronously by `initialize(with:)` (caller's thread) when
    /// `configError` is non-nil — the programmatic complement to the error log, so a
    /// host can surface misconfiguration to its own diagnostics.
    public private(set) var onConfigError: (@Sendable (ConfigError) -> Void)?

    /// The callback only ever fires from the config gate, before a client exists —
    /// the client's copy of the options must not pin the closure (and whatever host
    /// state it captures) for the whole session.
    internal func discardingConfigCallback() -> InitOptions {
        var copy = self
        copy.onConfigError = nil
        return copy
    }

    /// Debug-only fail-fast, injectable: assertions are active in test builds too, so
    /// tests exercising the release-degrade path swap this to observe instead of trap.
    internal nonisolated(unsafe) static var debugAssert: @Sendable (String) -> Void = {
        assertionFailure($0)
    }

    // Stored on invalid-host construction so `ingestionHost` stays non-optional; the
    // SDK is inert in that state and never dereferences it.
    private static let unsetHost = URL(string: "invalid://unset")!

    public init(
        writeKey: String,
        ingestionHost: URL,
        flushIntervalSeconds: Int = 10,
        debug: Bool = false,
        maxQueueEvents: Int = 2000,
        maxDiskEvents: Int = 10000,
        trackLifecycleEvents: Bool = false,
        onConfigError: (@Sendable (ConfigError) -> Void)? = nil
    ) {
        // One normalization site: the String initializer owns trimming and the
        // trailing-slash rule; a URL is just its string form here.
        self.init(
            writeKey: writeKey,
            ingestionHost: ingestionHost.absoluteString,
            flushIntervalSeconds: flushIntervalSeconds,
            debug: debug,
            maxQueueEvents: maxQueueEvents,
            maxDiskEvents: maxDiskEvents,
            trackLifecycleEvents: trackLifecycleEvents,
            onConfigError: onConfigError
        )
    }

    public init(
        writeKey: String,
        ingestionHost: String,
        flushIntervalSeconds: Int = 10,
        debug: Bool = false,
        maxQueueEvents: Int = 2000,
        maxDiskEvents: Int = 10000,
        trackLifecycleEvents: Bool = false,
        onConfigError: (@Sendable (ConfigError) -> Void)? = nil
    ) {
        var host = ingestionHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix("/") {
            host.removeLast()
        }
        self.init(
            core: writeKey,
            host: URL(string: host),
            rawHost: ingestionHost,
            flushIntervalSeconds: flushIntervalSeconds,
            debug: debug,
            maxQueueEvents: maxQueueEvents,
            maxDiskEvents: maxDiskEvents,
            trackLifecycleEvents: trackLifecycleEvents,
            onConfigError: onConfigError
        )
    }

    /// Single validation funnel for both public initializers. Records the first
    /// error (writeKey, then host) instead of trapping; numeric bounds clamp with a
    /// warning — one policy for all three fields, where previously two clamped
    /// silently and one crashed the process.
    private init(
        core writeKey: String,
        host: URL?,
        rawHost: String,
        flushIntervalSeconds: Int,
        debug: Bool,
        maxQueueEvents: Int,
        maxDiskEvents: Int,
        trackLifecycleEvents: Bool,
        onConfigError: (@Sendable (ConfigError) -> Void)?
    ) {
        var error: ConfigError?

        let trimmedKey = writeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            error = .emptyWriteKey
        }

        let resolvedHost: URL
        // The scheme check alone is not enough: Foundation parses "https:/" (what a
        // bare "https://" becomes after the slash trim) as scheme with a nil host,
        // which would build a live client that fails every request at network time.
        if let host, let scheme = host.scheme?.lowercased(), scheme == "http" || scheme == "https",
           let hostName = host.host, !hostName.isEmpty {
            resolvedHost = host
            // A cleartext origin is spoofable in transit — legitimate for local
            // development, worth a warning anywhere else.
            if scheme == "http", !LoopbackHost.isLoopback(hostName) {
                Logger.warn(
                    "ingestionHost \(host.absoluteString) is cleartext http — use https "
                        + "outside local development."
                )
            }
        } else {
            if error == nil {
                error = .invalidIngestionHost(rawHost)
            }
            resolvedHost = host ?? Self.unsetHost
        }

        // One clamp-with-warning policy for every numeric bound — a silent override
        // and a loud one are two policies.
        if flushIntervalSeconds < 1 {
            Logger.warn("flushIntervalSeconds (\(flushIntervalSeconds)) clamped to 1")
        }
        if maxQueueEvents < 1 {
            Logger.warn("maxQueueEvents (\(maxQueueEvents)) clamped to 1")
        }
        if maxDiskEvents < 0 {
            Logger.warn("maxDiskEvents (\(maxDiskEvents)) clamped to 0 — use 0 to disable disk persistence")
        }

        if let error {
            InitOptions.debugAssert("Invalid InitOptions: \(error.description)")
        }

        self.writeKey = trimmedKey
        self.ingestionHost = resolvedHost
        self.flushIntervalSeconds = max(1, flushIntervalSeconds)
        self.debug = debug
        self.maxQueueEvents = max(1, maxQueueEvents)
        self.maxDiskEvents = max(0, maxDiskEvents)
        self.trackLifecycleEvents = trackLifecycleEvents
        self.configError = error
        self.onConfigError = onConfigError

        if self.maxDiskEvents > 0 && self.maxDiskEvents < self.maxQueueEvents {
            Logger.warn("maxDiskEvents (\(self.maxDiskEvents)) is less than maxQueueEvents (\(self.maxQueueEvents)) — memory can hold more events than disk can preserve; events may be dropped during background flush")
        }
    }
}
