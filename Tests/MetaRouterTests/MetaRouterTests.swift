import Testing
import Foundation
@testable import MetaRouter

@MainActor
@Test func testDebugLoggingAndTrackCall() async throws {
    let options = InitOptions(writeKey: "testKey", ingestionHost: "https://example.com")
    let client = try await MetaRouter.Analytics.initialize(with: options)

    let output = await captureStandardOutput {
        await client.enableDebugLogging()
        await client.track(event: "Test Event", properties: ["key": .string("value")])
    }

    #expect(output.contains("[track] event: Test Event"))
    #expect(output.contains("key = value"))
}

@MainActor
@Test func testResetClearsState() async throws {
    let options = InitOptions(writeKey: "testKey", ingestionHost: "https://example.com")
    _ = try await MetaRouter.Analytics.initialize(with: options)

    await MetaRouter.Analytics.reset()

    let newClient = try await MetaRouter.Analytics.initialize(with: options)
    let debugInfo = await newClient.getDebugInfo()

    switch debugInfo["debugEnabled"] {
    case .bool(let value):
        #expect(value == true)
    default:
        throw TestFailure("debugEnabled not found or invalid type")
    }

    switch debugInfo["queueLength"] {
    case .int(let value):
        #expect(value == 0)
    default:
        throw TestFailure("queueLength not found or invalid type")
    }
}

@MainActor
@Test func testInitializeLogsCorrectly() async throws {
    let options = InitOptions(writeKey: "testKey", ingestionHost: "https://example.com")

    let output = await captureStandardOutput {
        _ = try? await MetaRouter.Analytics.initialize(with: options)
    }

    #expect(output.contains("writeKey: testKey"))
    #expect(output.contains("ingestionHost: https://example.com"))
}

func captureStandardOutput(_ block: @Sendable @escaping () async -> Void) async -> String {
    let pipe = Pipe()
    let original = dup(STDOUT_FILENO)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

    // Execute safely from a detached context
    await Task.detached(priority: .background) {
        await block()
    }.value

    fflush(stdout)
    dup2(original, STDOUT_FILENO)

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
}
struct TestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
