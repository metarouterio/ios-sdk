import Foundation
import WebKit

internal final class AnalyticsProxy: AnalyticsInterface, CustomStringConvertible,
    CustomDebugStringConvertible, Sendable
{
    private let state = ProxyState()

    // The bridge is owned here, not by a client: clients are disposable (reset()
    // creates a new one) while attached WebViews live on, and WebKit retains their
    // message handlers for the WebView's lifetime. The sink resolves "the current
    // client" at delivery time — a webview attached before init, or surviving a
    // reset/re-init cycle, delivers to whichever client is bound when its events
    // arrive, and events arriving with no ready client are NAKed not_ready instead
    // of silently lost.
    private let bridgeClient = BridgeClientBox()
    private let bridgeProcessor: BridgeMessageProcessor

    init() {
        bridgeProcessor = BridgeMessageProcessor(
            sink: ProxyBridgeSink(box: bridgeClient)
        )
    }

    public var description: String {
        return "MetaRouter.Analytics"
    }

    public var debugDescription: String {
        return "MetaRouter.Analytics(proxy)"
    }

    // bind/unbind publish the client to the bridge's synchronous mirror BEFORE the
    // actor call, so bridge events racing a bind resolve the new client rather than
    // NAKing not_ready after the SDK is in fact ready.
    internal func bind(_ real: AnalyticsInterface) {
        bridgeClient.set(real)
        Task { await state.bind(real) }
    }

    internal func unbind() {
        bridgeClient.clear()
        Task { await state.unbind() }
    }

    // Awaitable helpers for barrier APIs
    func _bindAndReplay(_ real: any AnalyticsInterface) async {
        bridgeClient.set(real)
        await state.bind(real)
    }

    func _unbindAndClear() async {
        bridgeClient.clear()
        await state.unbind()
    }

    /// Invalid-config refusal: no bind is coming this session, so waiters must
    /// resolve degraded rather than suspend forever.
    func _markConfigDisabled() async {
        await state.markConfigDisabled()
    }

    func _clearConfigDisabled() async {
        await state.clearConfigDisabled()
    }

    @MainActor
    public func attachWebView(_ webView: WKWebView, allowedOrigins: [String]) {
        // Registers immediately regardless of bind state — the WebView registrations
        // only apply to page loads that start afterwards, so deferring to bind-replay
        // would lose the wrapper on the host's first load.
        WebViewBridge.attach(webView, allowedOrigins: allowedOrigins, processor: bridgeProcessor)
    }

    public func track(_ event: String, properties: [String: Any]?) {
        let converted = properties.flatMap { CodableValue.convert($0) }
        Task { await state.enqueue(.track(event, converted)) }
    }

    public func track(_ event: String) {
        Task { await state.enqueue(.track(event, nil)) }
    }

    public func identify(_ userId: String, traits: [String: Any]?) {
        let converted = traits.flatMap { CodableValue.convert($0) }
        Task { await state.enqueue(.identify(userId, converted)) }
    }

    public func identify(_ userId: String) {
        Task { await state.enqueue(.identify(userId, nil)) }
    }

    public func group(_ groupId: String, traits: [String: Any]?) {
        let converted = traits.flatMap { CodableValue.convert($0) }
        Task { await state.enqueue(.group(groupId, converted)) }
    }

    public func group(_ groupId: String) {
        Task { await state.enqueue(.group(groupId, nil)) }
    }

    public func screen(_ name: String, properties: [String: Any]?) {
        let converted = properties.flatMap { CodableValue.convert($0) }
        Task { await state.enqueue(.screen(name, converted)) }
    }

    public func screen(_ name: String) {
        Task { await state.enqueue(.screen(name, nil)) }
    }

    public func page(_ name: String, properties: [String: Any]?) {
        let converted = properties.flatMap { CodableValue.convert($0) }
        Task { await state.enqueue(.page(name, converted)) }
    }

    public func page(_ name: String) {
        Task { await state.enqueue(.page(name, nil)) }
    }

    public func alias(_ newUserId: String) {
        Task { await state.enqueue(.alias(newUserId)) }
    }

    public func enableDebugLogging() {
        Task { await state.enqueue(.enableDebugLogging) }
    }

    public func getAnonymousId() async -> String {
        return await state.getAnonymousId()
    }

    public func getDebugInfo() async -> [String: CodableValue] {
        return await state.getDebugInfo()
    }

    public func flush() { Task { await state.enqueue(.flush) } }
    public func reset() { Task { await state.enqueue(.reset) } }

    public func setAdvertisingId(_ advertisingId: String?) {
        Task { await state.enqueue(.setAdvertisingId(advertisingId)) }
    }

    public func clearAdvertisingId() {
        Task { await state.enqueue(.clearAdvertisingId) }
    }

    public func setTracing(_ enabled: Bool) {
        Task { await state.enqueue(.setTracing(enabled)) }
    }

    public func recordOpenedURL(_ url: URL, sourceApplication: String?) {
        Task { await state.enqueue(.recordOpenedURL(url, sourceApplication)) }
    }
}

extension AnalyticsProxy {
    // Internal helper to seed debug info prior to binding
    internal func setBootstrapDebugInfo(writeKey: String, host: String, configError: String? = nil) {
        Task { await state.setBootstrapDebugInfo(writeKey: writeKey, host: host, configError: configError) }
    }
}

/// Synchronous mirror of the actor-held bound client. The bridge sink answers on the
/// main thread in the middle of a message delivery and cannot await actor isolation,
/// so bind/unbind also publish the client here — the same role Android's
/// AtomicReference read fills.
private final class BridgeClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var client: (any AnalyticsInterface)?

    func set(_ c: any AnalyticsInterface) {
        lock.lock()
        defer { lock.unlock() }
        client = c
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        client = nil
    }

    func get() -> (any AnalyticsInterface)? {
        lock.lock()
        defer { lock.unlock() }
        return client
    }
}

private struct ProxyBridgeSink: BridgeEventSink {
    let box: BridgeClientBox

    func enqueue(_ envelope: BridgeEnvelope) -> Bool {
        (box.get() as? AnalyticsClient)?.enqueueBridgeEvent(envelope) ?? false
    }
}

private enum Call {
    case track(String, [String: CodableValue]?)
    case identify(String, [String: CodableValue]?)
    case group(String, [String: CodableValue]?)
    case screen(String, [String: CodableValue]?)
    case page(String, [String: CodableValue]?)
    case alias(String)
    case enableDebugLogging

    case flush
    case reset
    case setAdvertisingId(String?)
    case clearAdvertisingId
    case setTracing(Bool)
    case recordOpenedURL(URL, String?)
}

private actor ProxyState {
    private var real: AnalyticsInterface?
    private var queue: [Call] = []
    private let cap = 20
    private var bootstrapDebugInfo: [String: CodableValue] = [:]
    private var bindContinuations: [CheckedContinuation<AnalyticsInterface?, Never>] = []
    // Set when initialize() was refused over invalid config: no bind is coming this
    // session, so awaiting APIs must resolve (degraded) instead of suspending forever
    // — a permanent hang would be a worse outcome than the crash this replaces.
    private var configDisabled = false

    func bind(_ client: AnalyticsInterface) {
        real = client
        // A successful (re)initialize supersedes an earlier config refusal.
        configDisabled = false
        // Replay queued calls
        for call in queue { forward(call) }
        queue.removeAll()
        // Resume any callers waiting for binding
        for continuation in bindContinuations {
            continuation.resume(returning: client)
        }
        bindContinuations.removeAll()
    }

    func unbind() {
        real = nil
        queue.removeAll()
        // reset() tears down a session without refusing one. Leaving the flag set
        // would make every later awaiting call resolve degraded for a session that
        // was never gated. disableSession() marks it again after this returns.
        configDisabled = false
    }

    /// Clears the refusal ahead of a bind that is still being built, so callers
    /// awaiting in the pre-bind window suspend for the incoming client instead of
    /// resolving degraded against the previous session's verdict.
    func clearConfigDisabled() {
        configDisabled = false
    }

    func markConfigDisabled() {
        configDisabled = true
        // Anyone already suspended is waiting for a bind that will never come.
        for continuation in bindContinuations {
            continuation.resume(returning: nil)
        }
        bindContinuations.removeAll()
    }

    private func awaitClient() async -> AnalyticsInterface? {
        if let client = real { return client }
        if configDisabled { return nil }
        return await withCheckedContinuation { continuation in
            bindContinuations.append(continuation)
        }
    }

    func enqueue(_ call: Call) {
        if real != nil {
            forward(call)
        } else {
            if queue.count >= cap { _ = queue.removeFirst() }
            queue.append(call)
        }
    }

    func setBootstrapDebugInfo(writeKey: String, host: String, configError: String? = nil) {
        let maskedKey = writeKey.count > 4
            ? "***" + writeKey.suffix(4)
            : "***"
        bootstrapDebugInfo = [
            "writeKey": .string(maskedKey),
            "ingestionHost": .string(host),
        ]
        if let configError {
            bootstrapDebugInfo["configError"] = .string(configError)
        }
    }

    func getAnonymousId() async -> String {
        // Empty only on a config-disabled session — the degraded-but-resolved answer;
        // normal operation still awaits initialization and never returns empty.
        guard let client = await awaitClient() else { return "" }
        return await client.getAnonymousId()
    }

    func getDebugInfo() async -> [String: CodableValue] {
        if let client = real {
            return await client.getDebugInfo()
        }
        var info = bootstrapDebugInfo
        info["proxy"] = .bool(true)
        return info
    }

    private func forward(_ call: Call) {
        guard let r = real else { return }
        switch call {
        case .track(let e, let p): r.track(e, properties: p?.mapValues { $0.toAny() })
        case .identify(let userId, let traits): r.identify(userId, traits: traits?.mapValues { $0.toAny() })
        case .group(let groupId, let traits): r.group(groupId, traits: traits?.mapValues { $0.toAny() })
        case .screen(let name, let props): r.screen(name, properties: props?.mapValues { $0.toAny() })
        case .page(let name, let props): r.page(name, properties: props?.mapValues { $0.toAny() })
        case .alias(let newUserId): r.alias(newUserId)
        case .enableDebugLogging: r.enableDebugLogging()

        case .flush: r.flush()
        case .reset: r.reset()
        case .setAdvertisingId(let advertisingId): r.setAdvertisingId(advertisingId)
        case .clearAdvertisingId: r.clearAdvertisingId()
        case .setTracing(let enabled): r.setTracing(enabled)
        case .recordOpenedURL(let url, let source): r.recordOpenedURL(url, sourceApplication: source)
        }
    }
}
