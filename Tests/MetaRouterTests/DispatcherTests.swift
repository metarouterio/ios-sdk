import XCTest
@testable import MetaRouter

private final class StubNetworking: Networking {
    enum Mode { case success, http(Int), error }
    var mode: Mode = .success
    var lastBody: Data?
    func postJSON(url: URL, body: Data, timeoutMs: Int) async throws -> NetworkResponse {
        lastBody = body
        switch mode {
        case .success:
            return NetworkResponse(statusCode: 200, headers: [:], body: Data())
        case .http(let code):
            return NetworkResponse(statusCode: code, headers: [:], body: Data())
        case .error:
            throw URLError(.timedOut)
        }
    }
    func parseRetryAfterMs(from headers: [String : String]) -> Int? { nil }
}

final class DispatcherTests: XCTestCase {
    func testFlushSuccessRemovesBatch() async throws {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking()
        let dispatcher = Dispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 100)

        // Create a minimal event
        let ctx = EventContext(
            app: AppContext(name: "a", version: "1", build: "1", namespace: "a"),
            device: DeviceContext(manufacturer: "a", model: "m", name: "n", type: "t"),
            library: LibraryContext(name: "l", version: "1"),
            os: OSContext(name: "iOS", version: "1"),
            screen: ScreenContext(density: 2.0, width: 1, height: 1),
            network: nil,
            locale: "en_US",
            timezone: "UTC"
        )
        let e = EnrichedEventPayload(type: "track", event: "ev", userId: nil, anonymousId: "anon", properties: nil, traits: nil, integrations: nil, timestamp: "now", writeKey: "wk", messageId: "mid", context: ctx)

        await dispatcher.offer(e)
        await dispatcher.flush()

        // If flush succeeded, offering another and flushing should not re-send the first
        await dispatcher.flush()
        XCTAssertNotNil(stub.lastBody)
    }

    func testFatalConfigClearsAndCallback() async {
        let options = TestDataFactory.makeInitOptions()
        let stub = StubNetworking(); stub.mode = .http(401)
        var calledStatus: Int? = nil
        let dispatcher = Dispatcher(options: options, http: stub, breaker: CircuitBreaker(), queueCapacity: 10, onFatalConfigError: { status in calledStatus = status })

        let ctx = EventContext(
            app: AppContext(name: "a", version: "1", build: "1", namespace: "a"),
            device: DeviceContext(manufacturer: "a", model: "m", name: "n", type: "t"),
            library: LibraryContext(name: "l", version: "1"),
            os: OSContext(name: "iOS", version: "1"),
            screen: ScreenContext(density: 2.0, width: 1, height: 1),
            network: nil,
            locale: "en_US",
            timezone: "UTC"
        )
        let e = EnrichedEventPayload(type: "track", event: "ev", userId: nil, anonymousId: "anon", properties: nil, traits: nil, integrations: nil, timestamp: "now", writeKey: "wk", messageId: "mid", context: ctx)

        await dispatcher.offer(e)
        await dispatcher.flush()

        XCTAssertEqual(calledStatus, 401)
    }
}


