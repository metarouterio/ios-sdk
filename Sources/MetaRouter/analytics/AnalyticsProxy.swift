import Foundation

internal final class AnalyticsProxy: AnalyticsInterface, CustomStringConvertible,
    CustomDebugStringConvertible, @unchecked Sendable
{
    private let state = ProxyState()
    private let debugInfoLock = NSLock()
    private nonisolated(unsafe) var _boundClient: AnalyticsInterface?
    private var bootstrapDebugInfo: [String: CodableValue] = [:]

    public var description: String {
        return "MetaRouter.Analytics"
    }

    public var debugDescription: String {
        debugInfoLock.lock()
        let isBound = _boundClient != nil
        debugInfoLock.unlock()
        let method = isBound ? "ready" : "initializing"
        return "MetaRouter.Analytics(\(method))"
    }

    internal func bind(_ real: AnalyticsInterface) {
        // Store reference to bound client for synchronous debug info access
        debugInfoLock.lock()
        _boundClient = real
        debugInfoLock.unlock()

        Task { await state.bind(real) }
    }

    internal func unbind() {
        // Clear bound client reference
        debugInfoLock.lock()
        _boundClient = nil
        debugInfoLock.unlock()

        Task {
            await state.unbind()
        }
    }

    // Awaitable helpers for barrier APIs
    func _bindAndReplay(_ real: any AnalyticsInterface) async {
        // Avoid NSLock from async context; assign directly and then await state.bind
        _boundClient = real
        await state.bind(real)
    }

    func _unbindAndClear() async {
        _boundClient = nil
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

    public func getDebugInfo() async -> [String: CodableValue] {
        // Get client and bootstrap info atomically
        let (client, bootstrapInfo): (AnalyticsInterface?, [String: CodableValue]) = {
            debugInfoLock.lock()
            defer { debugInfoLock.unlock() }
            return (_boundClient, bootstrapDebugInfo)
        }()

        // If we have a bound client, get debug info from it
        if let client = client {
            return await client.getDebugInfo()
        }

        // No bound client, return bootstrap info with proxy flag
        var info = bootstrapInfo
        info["proxy"] = .bool(true)
        return info
    }

    public func flush() { Task { await state.enqueue(.flush) } }
    public func reset() { Task { await state.enqueue(.reset) } }
}

extension AnalyticsProxy {
    // Internal helper to seed debug info prior to binding
    internal func setBootstrapDebugInfo(writeKey: String, host: String) {
        debugInfoLock.lock()
        // Mask writeKey to show only last 4 characters
        let maskedKey = writeKey.count > 4 
            ? "***" + writeKey.suffix(4) 
            : "***"
        bootstrapDebugInfo = [
            "writeKey": .string(maskedKey),
            "ingestionHost": .string(host),
        ]
        debugInfoLock.unlock()
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
}

private actor ProxyState {
    private var real: AnalyticsInterface?
    private var queue: [Call] = []
    private let cap = 20

    func bind(_ client: AnalyticsInterface) {
        real = client
        // Replay queued calls
        for call in queue { forward(call) }
        queue.removeAll()
    }

    func unbind() {
        real = nil
        queue.removeAll()
    }

    func enqueue(_ call: Call) {
        if real != nil {
            forward(call)
        } else {
            if queue.count >= cap { _ = queue.removeFirst() }
            queue.append(call)
        }
    }

    private func forward(_ call: Call) {
        guard let r = real else { return }
        switch call {
        case .track(let e, let p): r.track(e, properties: p)
        case .identify(let userId, let traits): r.identify(userId, traits: traits)
        case .group(let groupId, let traits): r.group(groupId, traits: traits)
        case .screen(let name, let props): r.screen(name, properties: props)
        case .page(let name, let props): r.page(name, properties: props)
        case .alias(let newUserId): r.alias(newUserId)
        case .enableDebugLogging: r.enableDebugLogging()

        case .flush: r.flush()
        case .reset: r.reset()
        }
    }
}
