import Foundation
import WebKit

internal final class AnalyticsProxy: AnalyticsInterface, CustomStringConvertible,
    CustomDebugStringConvertible, Sendable
{
    private let state = ProxyState()

    // Calls are queued or forwarded synchronously, under a lock, so they reach the
    // client in the host's call order. A Task hop per call into `state` let two
    // back-to-back calls arrive swapped.
    private let calls = CallPipe()

    // initialize, reset and an invalid-config disable run here, one at a time in call
    // order. As separate Tasks they ran in any order: a stale disable could unbind the
    // client a later initialize had bound, and a reset's clear could make the next
    // initialize look like a duplicate and be ignored.
    let lifecycle = SerialTaskQueue()

    // Bumped on the caller's thread by every reset or disable. A queued initialize
    // that sees it moved was reset before it ran, so it must not bind: calls made
    // after the reset would replay into a client that is about to be discarded.
    // The bump and the pipe detach, and the check and the bind, each hold the lock:
    // a reset landing while the client is being built must not slip in between.
    private let epochLock = NSLock()
    private nonisolated(unsafe) var epoch = 0

    func lifecycleEpoch() -> Int {
        epochLock.lock()
        defer { epochLock.unlock() }
        return epoch
    }

    // The bridge is owned here, not by a client: clients are disposable (reset()
    // creates a new one) while attached WebViews live on, and WebKit retains their
    // message handlers for the WebView's lifetime. The sink resolves "the current
    // client" at delivery time — a webview attached before init, or surviving a
    // reset/re-init cycle, delivers to whichever client is bound when its events
    // arrive, and events arriving with no ready client are NAKed not_ready instead
    // of silently lost.
    private let bridgeClient = BridgeClientBox()
    private let bridgeProcessor: BridgeMessageProcessor

    // Consent bypasses the pending-call queue entirely. The manager needs nothing
    // from an initialized client, so MetaRouter builds one per process and hands
    // the same instance to the proxy and to every client it binds. Queueing
    // consent would lose writes to the bind race and to queue eviction, and a
    // pre-bind read would have to lie — ignoring both a queued setConsent and the
    // consent persisted by the previous launch. Compliance state gets none of
    // those failure modes: every call acts on the manager immediately, bound or
    // not, and the client bound later stamps from that same manager.
    private let consentManager: ConsentManager

    // Bypasses the pending-call queue for the same reasons as consent, plus one of
    // its own: the queue drops its OLDEST entry at capacity (`CallPipe.cap`), so
    // a host that sets a vendor id and then tracks a burst of pre-initialize events
    // would have the id evicted — the one call that cannot be lost.
    private let providerContextManager: ProviderContextManager

    // Before bind, setAnonymousId writes storage directly, for the same reasons as
    // provider context. Every client's IdentityManager reads the anonymousId from
    // this same storage first, so a write landing between a client's creation and
    // its bind still reaches that client's next event.
    private let identityStorage: IdentityStorage

    /// The defaults read `UserDefaults.standard` — fine for a proxy never asked
    /// about consent, provider context or setAnonymousId; anything exercising one
    /// through a proxy must inject isolated storage.
    init(
        consentManager: ConsentManager = ConsentManager(storage: ConsentStorage()),
        providerContextManager: ProviderContextManager = ProviderContextManager(storage: ProviderContextStorage()),
        identityStorage: IdentityStorage = IdentityStorage()
    ) {
        self.consentManager = consentManager
        self.providerContextManager = providerContextManager
        self.identityStorage = identityStorage
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

    // Tests only, as are `_bindAndReplay` and `_unbindAndClear`: each goes through
    // the bind and unbind MetaRouter uses, so proxy tests cover them (with the
    // epoch read at bind time, so they are never refused).
    internal func bind(_ real: AnalyticsInterface) {
        guard bindCallsIfCurrent(real, epoch: lifecycleEpoch()) else { return }
        lifecycle.enqueue { [state] in await state.bind(real) }
    }

    internal func unbind() {
        detachCalls()
        lifecycle.enqueue { [self] in await _unbindState() }
    }

    /// The synchronous half of a reset: a call on the next line must not reach the
    /// client being discarded. The rest runs on `lifecycle` (`_unbindState`).
    internal func detachCalls() {
        epochLock.lock()
        defer { epochLock.unlock() }
        epoch += 1
        bridgeClient.clear()
        calls.unbind()
    }

    /// Before an initializeAndWait: an initialize still queued ahead of it is
    /// superseded, and calls from here on wait for the new client instead of reaching
    /// the one being replaced (an identify there would never reach the new client).
    /// Queued calls stay, uncapped until the bind.
    internal func supersedeForInitialize() {
        epochLock.lock()
        defer { epochLock.unlock() }
        epoch += 1
        bridgeClient.clear()
        calls.release()
    }

    /// The queued half of a reset or disable, on `lifecycle`. The pipe was detached
    /// on the caller's thread, and `_bindIfCurrent` keeps an earlier initialize from
    /// binding it since.
    func _unbindState() async {
        await state.unbind()
    }

    /// Binds `real` unless a reset or disable has run since `epoch`, returning
    /// whether it did. A refused client was never seen by a call.
    func _bindIfCurrent(_ real: any AnalyticsInterface, epoch: Int) async -> Bool {
        guard bindCallsIfCurrent(real, epoch: epoch) else { return false }
        await state.bind(real)
        return true
    }

    private func bindCallsIfCurrent(_ real: any AnalyticsInterface, epoch: Int) -> Bool {
        epochLock.lock()
        defer { epochLock.unlock() }
        guard self.epoch == epoch else { return false }
        // The bridge's synchronous mirror is set before the actor bind, so bridge
        // events racing it resolve the new client instead of NAKing not_ready.
        bridgeClient.set(real)
        calls.bind(real)
        return true
    }

    func _bindAndReplay(_ real: any AnalyticsInterface) async {
        await lifecycle.run { [self] in _ = await _bindIfCurrent(real, epoch: lifecycleEpoch()) }
    }

    func _unbindAndClear() async {
        detachCalls()
        await lifecycle.run { [self] in await _unbindState() }
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
        calls.send(.track(event, converted))
    }

    public func track(_ event: String) {
        calls.send(.track(event, nil))
    }

    public func identify(_ userId: String, traits: [String: Any]?) {
        let converted = traits.flatMap { CodableValue.convert($0) }
        calls.send(.identify(userId, converted))
    }

    public func identify(_ userId: String) {
        calls.send(.identify(userId, nil))
    }

    public func group(_ groupId: String, traits: [String: Any]?) {
        let converted = traits.flatMap { CodableValue.convert($0) }
        calls.send(.group(groupId, converted))
    }

    public func group(_ groupId: String) {
        calls.send(.group(groupId, nil))
    }

    public func screen(_ name: String, properties: [String: Any]?) {
        let converted = properties.flatMap { CodableValue.convert($0) }
        calls.send(.screen(name, converted))
    }

    public func screen(_ name: String) {
        calls.send(.screen(name, nil))
    }

    public func page(_ name: String, properties: [String: Any]?) {
        let converted = properties.flatMap { CodableValue.convert($0) }
        calls.send(.page(name, converted))
    }

    public func page(_ name: String) {
        calls.send(.page(name, nil))
    }

    public func alias(_ newUserId: String) {
        calls.send(.alias(newUserId))
    }

    public func enableDebugLogging() {
        calls.send(.enableDebugLogging)
    }

    /// Waits for any initialize/reset already called: a read right after one must not
    /// be answered from the previous session's state.
    private func settled() async {
        await lifecycle.run {}
    }

    public func getAnonymousId() async -> String {
        await settled()
        return await state.getAnonymousId()
    }

    @discardableResult
    public func setAnonymousId(_ anonymousId: String) -> Bool {
        if let client = bridgeClient.get() as? AnalyticsClient {
            return client.setAnonymousId(anonymousId)
        }
        return IdentityManager.apply(hostAnonymousId: anonymousId, to: identityStorage)
    }

    public func getSessionId() async -> String? {
        await settled()
        return await state.getSessionId()
    }

    public func getDebugInfo() async -> [String: CodableValue] {
        await settled()
        var info = await state.getDebugInfo()
        // Pre-bind, the bootstrap info has no client to report consent; the manager
        // exists regardless, and "what consent is the SDK holding before init" is
        // exactly what someone debugging a CMP-first launch wants to see.
        if info["consent"] == nil {
            info["consent"] = consentManager.getConsent().debugInfoValue
        }
        if info["providerContext"] == nil {
            info["providerContext"] = providerContextManager.debugInfoValue
        }
        return info
    }

    public func flush() { calls.send(.flush) }
    public func reset() {
        // Here, not in the client's reset: this is the host's call site, while the
        // client's runs later (after a queued replay at bind, or a Task hop), where
        // it would also discard a setAnonymousId made after this call. Routed like
        // setAnonymousId so both touch the same storage.
        if let client = bridgeClient.get() as? AnalyticsClient {
            client.noteResetRequested()
        } else {
            identityStorage.noteResetRequested()
        }
        calls.send(.reset)
    }

    public func setAdvertisingId(_ advertisingId: String?) {
        calls.send(.setAdvertisingId(advertisingId))
    }

    public func clearAdvertisingId() {
        calls.send(.clearAdvertisingId)
    }

    public func setTracing(_ enabled: Bool) {
        calls.send(.setTracing(enabled))
    }

    public func recordOpenedURL(_ url: URL, sourceApplication: String?) {
        calls.send(.recordOpenedURL(url, sourceApplication))
    }

    // MARK: - Consent (direct, never queued — see consentManager)

    public func registerConsentCategories(_ categories: [ConsentCategory]) {
        consentManager.registerConsentCategories(categories)
    }

    @discardableResult
    public func setConsent(_ consent: Consent) -> Bool {
        consentManager.setConsent(consent)
    }

    public func getConsent() -> Consent {
        consentManager.getConsent()
    }

    public func clearConsent() {
        consentManager.clearConsent()
    }

    public func subscribeToConsent(_ handler: @escaping ConsentHandler) -> ConsentSubscription {
        ConsentSubscription(onCancel: consentManager.subscribe(handler))
    }

    // MARK: - Provider context (direct, never queued — see providerContextManager)

    @discardableResult
    public func setProviderContext(_ provider: String, key: String, value: Any?) -> Bool {
        providerContextManager.setValue(provider: provider, key: key, value: value)
    }

    public func getProviderContext() -> [String: [String: CodableValue]] {
        providerContextManager.getAll()
    }

    public func clearProviderContext(_ provider: String) {
        providerContextManager.clear(provider: provider)
    }

    public func clearAllProviderContext() {
        providerContextManager.clearAll()
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

/// Holds the bound client for the call path. Synchronous on purpose: see `calls`.
private final class CallPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var real: AnalyticsInterface?
    private var queue: [Call] = []
    private let cap = 20
    private var released = false

    func bind(_ client: AnalyticsInterface) {
        lock.lock()
        defer { lock.unlock() }
        real = client
        released = false
        // Replayed under the lock, so a call made during the bind cannot overtake
        // the ones queued before it.
        for call in queue { forward(call, to: client) }
        queue.removeAll()
    }

    func unbind() {
        lock.lock()
        defer { lock.unlock() }
        real = nil
        released = false
        queue.removeAll()
    }

    /// Unbinds without dropping queued calls, and lifts the cap until the next bind:
    /// the client they wait for is already being built.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        real = nil
        released = true
    }

    func send(_ call: Call) {
        lock.lock()
        defer { lock.unlock() }
        if let client = real {
            forward(call, to: client)
        } else {
            if queue.count >= cap && !released { _ = queue.removeFirst() }
            queue.append(call)
        }
    }

    // Under the lock: every client method called here only submits work and
    // returns, and none calls back into the proxy.
    private func forward(_ call: Call, to r: AnalyticsInterface) {
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

private actor ProxyState {
    private var real: AnalyticsInterface?
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
        // Resume any callers waiting for binding
        for continuation in bindContinuations {
            continuation.resume(returning: client)
        }
        bindContinuations.removeAll()
    }

    func unbind() {
        real = nil
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

    func getSessionId() async -> String? {
        // No await-for-bind, unlike getAnonymousId: sessions are minted by
        // events, so before a client is bound "nil — no session yet" is the
        // correct, documented answer. Suspending here would turn a prompt
        // diagnostic read into a process-lifetime hang whenever initialize()
        // is never called (or a reset() is never followed by one). The same
        // nil also serves the config-disabled session without a sentinel.
        guard let client = real else { return nil }
        return await client.getSessionId()
    }

    func getDebugInfo() async -> [String: CodableValue] {
        if let client = real {
            return await client.getDebugInfo()
        }
        var info = bootstrapDebugInfo
        info["proxy"] = .bool(true)
        return info
    }
}
