import Foundation

internal final class AnalyticsProxy: AnalyticsInterface, CustomStringConvertible,
    CustomDebugStringConvertible, Sendable
{
    private let state = ProxyState()

    public var description: String {
        return "MetaRouter.Analytics"
    }

    public var debugDescription: String {
        return "MetaRouter.Analytics(proxy)"
    }

    internal func bind(_ real: AnalyticsInterface) {
        Task { await state.bind(real) }
    }

    internal func unbind() {
        Task { await state.unbind() }
    }

    // Awaitable helpers for barrier APIs
    func _bindAndReplay(_ real: any AnalyticsInterface) async {
        await state.bind(real)
    }

    func _unbindAndClear() async {
        await state.unbind()
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

    public func handleDeepLink(url: URL, sourceApplication: String?) {
        Task { await state.enqueue(.handleDeepLink(url, sourceApplication)) }
    }
}

extension AnalyticsProxy {
    // Internal helper to seed debug info prior to binding
    internal func setBootstrapDebugInfo(writeKey: String, host: String) {
        Task { await state.setBootstrapDebugInfo(writeKey: writeKey, host: host) }
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
    case handleDeepLink(URL, String?)
}

private actor ProxyState {
    private var real: AnalyticsInterface?
    private var queue: [Call] = []
    private let cap = 20
    private var bootstrapDebugInfo: [String: CodableValue] = [:]
    private var bindContinuations: [CheckedContinuation<AnalyticsInterface, Never>] = []

    func bind(_ client: AnalyticsInterface) {
        real = client
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
    }

    private func awaitClient() async -> AnalyticsInterface {
        if let client = real { return client }
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

    func setBootstrapDebugInfo(writeKey: String, host: String) {
        let maskedKey = writeKey.count > 4
            ? "***" + writeKey.suffix(4)
            : "***"
        bootstrapDebugInfo = [
            "writeKey": .string(maskedKey),
            "ingestionHost": .string(host),
        ]
    }

    func getAnonymousId() async -> String {
        let client = await awaitClient()
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
        case .handleDeepLink(let url, let source): r.handleDeepLink(url: url, sourceApplication: source)
        }
    }
}
