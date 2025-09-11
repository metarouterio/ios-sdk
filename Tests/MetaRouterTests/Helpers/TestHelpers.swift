import Foundation
@testable import MetaRouter


enum TestDataFactory {
    static func makeInitOptions(
        writeKey: String = "test-write-key",
        ingestionHost: String = "https://test.metarouter.com"
    ) -> InitOptions {
        InitOptions(writeKey: writeKey, ingestionHost: ingestionHost)
    }

    static func makeProperties() -> [String: CodableValue] {
        [
            "userId": "user123",
            "plan": "premium",
            "revenue": 99.99,
            "active": true,
            "tags": ["analytics", "test"],
            "metadata": [
                "source": "ios",
                "version": "1.0"
            ]
        ]
    }

    static func makeTraits() -> [String: CodableValue] {
        [
            "name": "John Doe",
            "email": "john@example.com",
            "age": 30,
            "premium": true
        ]
    }
}

// Mock Analytics Interface

final class MockAnalyticsInterface: AnalyticsInterface, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [AnalyticsCall] = []

    var calls: [AnalyticsCall] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _calls.count
    }

    func resetMock() {
        lock.lock()
        defer { lock.unlock() }
        _calls.removeAll()
    }

    private func recordCall(_ call: AnalyticsCall) {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(call)
    }

    // AnalyticsInterface Implementation

    func track(_ event: String, properties: [String: CodableValue]?) {
        recordCall(.track(event: event, properties: properties))
    }

    func track(_ event: String) {
        track(event, properties: nil)
    }

    func identify(_ userId: String, traits: [String: CodableValue]?) {
        recordCall(.identify(userId: userId, traits: traits))
    }

    func identify(_ userId: String) {
        identify(userId, traits: nil)
    }

    func group(_ groupId: String, traits: [String: CodableValue]?) {
        recordCall(.group(groupId: groupId, traits: traits))
    }

    func group(_ groupId: String) {
        group(groupId, traits: nil)
    }

    func screen(_ name: String, properties: [String: CodableValue]?) {
        recordCall(.screen(name: name, properties: properties))
    }

    func screen(_ name: String) {
        screen(name, properties: nil)
    }

    func page(_ name: String, properties: [String: CodableValue]?) {
        recordCall(.page(name: name, properties: properties))
    }

    func page(_ name: String) {
        page(name, properties: nil)
    }

    func alias(_ newUserId: String) {
        recordCall(.alias(newUserId: newUserId))
    }

    func enableDebugLogging() {
        recordCall(.enableDebugLogging)
    }

    func getDebugInfo() -> [String: CodableValue] {
        recordCall(.getDebugInfo)
        return ["mock": "debug-info"]
    }

    func flush() {
        recordCall(.flush)
    }

    func reset() {
        recordCall(.reset)
    }
}

// Analytics Call Recording

enum AnalyticsCall: Equatable {
    case track(event: String, properties: [String: CodableValue]?)
    case identify(userId: String, traits: [String: CodableValue]?)
    case group(groupId: String, traits: [String: CodableValue]?)
    case screen(name: String, properties: [String: CodableValue]?)
    case page(name: String, properties: [String: CodableValue]?)
    case alias(newUserId: String)
    case enableDebugLogging
    case getDebugInfo
    case flush
    case reset
}

// CodableValue Test Extensions

extension CodableValue: Equatable {
    public static func == (lhs: CodableValue, rhs: CodableValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let l), .string(let r)): return l == r
        case (.int(let l), .int(let r)): return l == r
        case (.double(let l), .double(let r)): return l == r
        case (.bool(let l), .bool(let r)): return l == r
        case (.array(let l), .array(let r)): return l == r
        case (.object(let l), .object(let r)): return l == r
        case (.null, .null): return true
        default: return false
        }
    }
}

// Test Utilities

enum TestUtilities {
    static func waitFor(
        timeout: TimeInterval = 1.0,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        return condition()
    }
}
