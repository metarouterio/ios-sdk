import XCTest
@testable import MetaRouter

final class InitOptionsTests: XCTestCase {
    func testInitOptionsFromStringRemovesTrailingSlash() {
        let options = InitOptions(writeKey: "wk", ingestionHost: "https://example.com/")
        XCTAssertEqual(options.writeKey, "wk")
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://example.com")
    }

    func testInitOptionsFromStringTrimsWhitespace() {
        let options = InitOptions(writeKey: "wk", ingestionHost: "  https://example.com  ")
        XCTAssertEqual(options.ingestionHost.scheme, "https")
        XCTAssertEqual(options.ingestionHost.host, "example.com")
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://example.com")
    }

    func testInitOptionsFromURLStoresExactly() {
        let url = URL(string: "https://api.metarouter.io")!
        let options = InitOptions(writeKey: "wk", ingestionHost: url)
        XCTAssertEqual(options.ingestionHost, url)
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://api.metarouter.io")
    }

    func testInitOptionsFromStringWithPathPreserved() {
        let options = InitOptions(writeKey: "wk", ingestionHost: "https://host.tld/base")
        XCTAssertEqual(options.ingestionHost.path, "/base")
        XCTAssertEqual(options.ingestionHost.absoluteString, "https://host.tld/base")
    }

    func testInversionWarningEmittedWhenDiskSmallerThanMemory() {
        let output = captureStderrAndStdout {
            _ = InitOptions(
                writeKey: "wk",
                ingestionHost: URL(string: "https://example.com")!,
                maxQueueEvents: 2000,
                maxDiskEvents: 500
            )
        }
        XCTAssertTrue(output.contains("maxDiskEvents"), "warning should mention maxDiskEvents, got: \(output)")
        XCTAssertTrue(output.contains("maxQueueEvents"), "warning should mention maxQueueEvents")
        XCTAssertTrue(output.contains("500") && output.contains("2000"), "warning should include both values")
    }

    func testNoInversionWarningWhenDiskLargerThanMemory() {
        let output = captureStderrAndStdout {
            _ = InitOptions(
                writeKey: "wk",
                ingestionHost: URL(string: "https://example.com")!,
                maxQueueEvents: 2000,
                maxDiskEvents: 10_000
            )
        }
        XCTAssertFalse(output.contains("maxDiskEvents") && output.contains("less than"),
                       "no inversion warning should fire when disk >= memory")
    }

    func testNoInversionWarningWhenDiskDisabled() {
        let output = captureStderrAndStdout {
            _ = InitOptions(
                writeKey: "wk",
                ingestionHost: URL(string: "https://example.com")!,
                maxQueueEvents: 2000,
                maxDiskEvents: 0
            )
        }
        XCTAssertFalse(output.contains("less than"),
                       "disk=0 is the 'disable persistence' case, not an inversion")
    }

    func testNoInversionWarningWhenEqual() {
        let output = captureStderrAndStdout {
            _ = InitOptions(
                writeKey: "wk",
                ingestionHost: URL(string: "https://example.com")!,
                maxQueueEvents: 2000,
                maxDiskEvents: 2000
            )
        }
        XCTAssertFalse(output.contains("less than"),
                       "equal values are not an inversion")
    }

    func testTrackLifecycleEventsDefaultsToTrue() {
        let urlOptions = InitOptions(
            writeKey: "wk",
            ingestionHost: URL(string: "https://example.com")!
        )
        XCTAssertTrue(urlOptions.trackLifecycleEvents,
                      "trackLifecycleEvents should default to true (URL initializer)")

        let stringOptions = InitOptions(
            writeKey: "wk",
            ingestionHost: "https://example.com"
        )
        XCTAssertTrue(stringOptions.trackLifecycleEvents,
                      "trackLifecycleEvents should default to true (String initializer)")
    }

    func testTrackLifecycleEventsCanBeDisabled() {
        let urlOptions = InitOptions(
            writeKey: "wk",
            ingestionHost: URL(string: "https://example.com")!,
            trackLifecycleEvents: false
        )
        XCTAssertFalse(urlOptions.trackLifecycleEvents)

        let stringOptions = InitOptions(
            writeKey: "wk",
            ingestionHost: "https://example.com",
            trackLifecycleEvents: false
        )
        XCTAssertFalse(stringOptions.trackLifecycleEvents)
    }
}

/// Captures both stdout and stderr during `block`. Used to assert on Logger.warn output.
/// Order matters: restore the original fds before reading so the pipe writer reaches EOF.
private func captureStderrAndStdout(_ block: () -> Void) -> String {
    let pipe = Pipe()
    let origOut = dup(fileno(stdout))
    let origErr = dup(fileno(stderr))
    setvbuf(stdout, nil, _IONBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)
    dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stdout))
    dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stderr))

    block()

    // Restore stdout/stderr FIRST so no more writers reference the pipe
    dup2(origOut, fileno(stdout))
    dup2(origErr, fileno(stderr))
    close(origOut)
    close(origErr)
    // Now safe to close the writer and read until EOF
    pipe.fileHandleForWriting.closeFile()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}


