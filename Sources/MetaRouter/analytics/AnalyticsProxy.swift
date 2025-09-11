import Foundation

public final class AnalyticsProxy: AnalyticsInterface {
    private let state = ProxyState()
    private let debugInfoLock = NSLock()
    private nonisolated(unsafe) var _boundClient: AnalyticsInterface?

    public func bind(_ real: AnalyticsInterface) {
        // Store reference to bound client for synchronous debug info access
        debugInfoLock.lock()
        _boundClient = real
        debugInfoLock.unlock()

        Task { await state.bind(real) }
    }

    public func unbind() {
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

    public func track(_ event: String, properties: [String: CodableValue]?) {
        Task { await state.enqueue(.track(event, properties)) }
    }

    public func track(_ event: String) {
        Task { await state.enqueue(.track(event, nil)) }
    }

    public func identify(_ userId: String, traits: [String: CodableValue]?) {
        Task { await state.enqueue(.identify(userId, traits)) }
    }

    public func identify(_ userId: String) {
        Task { await state.enqueue(.identify(userId, nil)) }
    }

    public func group(_ groupId: String, traits: [String: CodableValue]?) {
        Task { await state.enqueue(.group(groupId, traits)) }
    }

    public func group(_ groupId: String) {
        Task { await state.enqueue(.group(groupId, nil)) }
    }

    public func screen(_ name: String, properties: [String: CodableValue]?) {
        Task { await state.enqueue(.screen(name, properties)) }
    }

    public func screen(_ name: String) {
        Task { await state.enqueue(.screen(name, nil)) }
    }

    public func page(_ name: String, properties: [String: CodableValue]?) {
        Task { await state.enqueue(.page(name, properties)) }
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

    public func getDebugInfo() -> [String: CodableValue] {
        debugInfoLock.lock()
        defer { debugInfoLock.unlock() }

        // If we have a bound client, get debug info from it
        // This will be recorded by the mock, but that's expected for explicit getDebugInfo calls
        if let client = _boundClient {
            return client.getDebugInfo()
        }

        // No bound client, return empty
        return [:]
    }

    public func flush() { Task { await state.enqueue(.flush) } }
    public func reset() { Task { await state.enqueue(.reset) } }
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
        if let _ = real {
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
