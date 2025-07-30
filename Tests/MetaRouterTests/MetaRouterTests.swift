import Testing
import Foundation
@testable import MetaRouter

@MainActor @Test func testDebugLoggingAndTrackCall() throws {
    let client = AnalyticsClient.shared

    // Enable debug logging
    client.enableDebugLogging()

    // Capture console output
    let output = captureStandardOutput {
        client.track(event: "Test Event", properties: ["key": "value"])
    }

    #expect(output.contains("[MetaRouter] track called with event: Test Event"))
    #expect(output.contains("key = value"))
}

@MainActor
@Test func testResetClearsState() throws {
    let client = AnalyticsClient.shared
    client.enableDebugLogging()
    client.reset()

    let debugInfo = client.getDebugInfo()
    #expect(debugInfo["debugEnabled"] as? Bool == true)
    #expect(debugInfo["queuedEvents"] as? Int == 0)
}

@MainActor
@Test func testInitializeLogsCorrectly() throws {
    let options = InitOptions(writeKey: "testKey", ingestionHost: "https://example.com")

    let output = captureStandardOutput {
        AnalyticsClient.shared.initialize(with: options)
    }

    #expect(output.contains("initialized with writeKey: testKey"))
    #expect(output.contains("ingestionHost: https://example.com"))
}

func captureStandardOutput(_ block: () -> Void) -> String {
    let pipe = Pipe()
    let original = dup(STDOUT_FILENO)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

    block()

    fflush(stdout)
    dup2(original, STDOUT_FILENO)

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
}
