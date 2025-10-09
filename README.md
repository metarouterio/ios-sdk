# MetaRouter iOS SDK

[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey.svg)](https://github.com/metarouter/ios-sdk)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

A lightweight iOS analytics SDK that transmits events to your MetaRouter cluster.

## Installation

### Swift Package Manager

Add the following dependency to your `Package.swift`:

```swift
.package(url: "https://github.com/metarouter/ios-sdk.git", from: "1.0.0")
```

Or add it via Xcode: **File → Add Package Dependencies → Enter repository URL**

## Usage

### Basic Setup

```swift
import MetaRouter

// Initialize the analytics client (typically in AppDelegate or App.swift)
let options = InitOptions(
    writeKey: "your-write-key",
    ingestionHost: "https://your-ingestion-endpoint.com",
    debug: true, // Optional: enable debug mode
    flushIntervalSeconds: 30, // Optional: flush events every 30 seconds
    maxQueueEvents: 2000 // Optional: max events in memory queue
)

let analytics = MetaRouter.Analytics.initialize(with: options)
```

### Direct Usage

```swift
import MetaRouter

// Initialize (optionally await it but can use at anytime with events transmitted when client is available)
let analytics = MetaRouter.Analytics.initialize(with: options)

// Track events
analytics.track("User Action", properties: [
    "action": "button_click",
    "screen": "home"
])

// Identify users
analytics.identify("user123", traits: [
    "name": "John Doe",
    "email": "john@example.com"
])

// Track screen views
analytics.screen("Home Screen", properties: [
    "category": "navigation"
])

// Group users
analytics.group("company123", traits: [
    "name": "Acme Corp",
    "industry": "technology"
])

// Flush events immediately
analytics.flush()

// Reset analytics (useful for testing or logout)
analytics.reset()
```

### SwiftUI Usage

```swift
import SwiftUI
import MetaRouter

@main
struct MyApp: App {
    @StateObject private var analyticsManager = AnalyticsManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(analyticsManager)
                .onAppear {
                    analyticsManager.initialize()
                }
        }
    }
}

class AnalyticsManager: ObservableObject {
    private var analytics: AnalyticsInterface?

    func initialize() {
        let options = InitOptions(
            writeKey: "your-write-key",
            ingestionHost: "https://your-ingestion-endpoint.com"
        )
        analytics = MetaRouter.Analytics.initialize(with: options)
    }

    func track(_ event: String, properties: [String: Any]? = nil) {
        analytics?.track(event, properties: properties)
    }
}

// Use analytics in any view
struct ContentView: View {
    @EnvironmentObject var analyticsManager: AnalyticsManager

    var body: some View {
        Button("Submit") {
            analyticsManager.track("Button Pressed", properties: [
                "buttonName": "submit",
                "timestamp": Date().timeIntervalSince1970
            ])
        }
    }
}
```

### Example

Here's a simple example of how to integrate the MetaRouter SDK into your iOS app:

```swift
import UIKit
import MetaRouter

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var client: AnalyticsClient!

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Initialize the analytics client
        client = AnalyticsClient.initialize(options: InitOptions(writeKey: "your-write-key", ingestionHost: "https://your-ingestion-host.com", debug: true))

        // Note: The AnalyticsClient can be used as a singleton or assigned to a variable.
        // Both approaches will use the same instance under the hood.
        return true
    }
}
```

## API Reference

### MetaRouter.Analytics.initialize(options)

Initializes the analytics client and returns a **live proxy** to the client instance.

⚠️ `initialize()` returns immediately, but you **do not** need to wait before using analytics methods.

Calls to `track`, `identify`, etc. are **buffered in-memory** by the proxy and replayed **in order** once the client is fully initialized.

**Options:**

- `writeKey` (String, required): Your write key
- `ingestionHost` (String or URL, required): Your MetaRouter ingestor host
- `debug` (Bool, optional): Enable debug mode (default: `false`)
- `flushIntervalSeconds` (Int, optional): Interval in seconds to flush events (default: `10`)
- `maxQueueEvents` (Int, optional): Number of max events stored in memory (default: `2000`)

**Proxy behavior (quick notes):**

- Buffer is **in-memory only** (not persisted). Calls made before ready are lost if the process exits.
- Ordering is preserved relative to other buffered calls; normal FIFO + batching applies after ready.
- On fatal config errors (`401/403/404`), the client enters **disabled** state and drops subsequent calls.
- `sentAt` is stamped when the batch is prepared for transmission (just before network send). If you need the original occurrence time, pass your own `timestamp` on each event.

### Analytics Interface

The analytics client provides the following methods:

- `track(_ event: String, properties: [String: Any]?)`: Track custom events
- `identify(_ userId: String, traits: [String: Any]?)`: Identify users
- `group(_ groupId: String, traits: [String: Any]?)`: Group users
- `screen(_ name: String, properties: [String: Any]?)`: Track screen views
- `page(_ name: String, properties: [String: Any]?)`: Track page views
- `alias(_ newUserId: String)`: Alias user IDs
- `flush()`: Flush events immediately
- `reset()`: Reset analytics state and clear all stored data
- `enableDebugLogging()`: Enable debug logging
- `getDebugInfo() async`: Get current debug information

### Testing APIs

For tests that require synchronous initialization:

```swift
// Wait for initialization to complete
let analytics = await MetaRouter.Analytics.initializeAndWait(with: options)

// Wait for reset to complete
await MetaRouter.Analytics.resetAndWait()
```

⚠️ **Use these only in tests** — they block until initialization/reset completes.

## Features

- 🎯 **Custom Endpoints**: Send events to your own ingestion endpoints
- 📱 **iOS & macOS**: Native Swift SDK for Apple platforms
- 🔧 **Type-Safe**: Full Swift type safety with automatic `Any` conversion
- 🚀 **Lightweight**: Minimal overhead and zero external dependencies
- 🧵 **Thread-Safe**: Built on Swift actors and concurrency
- 🔄 **Reset Capability**: Easily reset analytics state for testing or logout scenarios
- 🐛 **Debug Support**: Built-in debugging tools for troubleshooting
- 💾 **Persistent Identity**: Anonymous ID and user identity stored in UserDefaults
- 🔌 **Circuit Breaker**: Intelligent retry logic with exponential backoff
- ⚡ **Batching**: Automatic event batching for network efficiency

## ✅ Compatibility

| Component | Supported Versions |
| --------- | ------------------ |
| iOS       | >= 15.0            |
| macOS     | >= 12.0            |
| Swift     | >= 5.5             |
| Xcode     | >= 13.0            |

## Debugging

If you're not seeing API calls being made, here are some steps to troubleshoot:

### 1. Enable Debug Logging

```swift
// Initialize with debug enabled
let options = InitOptions(
    writeKey: "your-write-key",
    ingestionHost: "https://your-ingestion-endpoint.com",
    debug: true // This enables detailed logging
)
let analytics = MetaRouter.Analytics.initialize(with: options)

// Or enable debug logging after initialization
analytics.enableDebugLogging()
```

### 2. Check Debug Information

```swift
// Get current state information
let debugInfo = await analytics.getDebugInfo()
print("Analytics debug info:", debugInfo)

// Debug info includes:
// - lifecycle: Current SDK state (idle/initializing/ready/resetting/disabled)
// - queueLength: Number of events waiting to be sent
// - writeKey: Masked write key (last 4 chars)
// - ingestionHost: Your ingestion endpoint
// - flushIntervalSeconds: Flush interval configuration
// - maxQueueEvents: Queue capacity
// - circuitState: Circuit breaker state (closed/halfOpen/open)
// - circuitRemainingMs: Cooldown time remaining
// - flushInFlight: Whether a flush is currently in progress
// - anonymousId: Device anonymous ID (if available)
// - userId: Current user ID (if identified)
// - groupId: Current group ID (if grouped)
```

### 3. Force Flush Events

```swift
// Manually flush events to see if they're being sent
analytics.flush()
```

### 4. Common Issues

- **Network Permissions**: Ensure your app has network permissions in Info.plist
- **UserDefaults**: The SDK uses UserDefaults for anonymous ID persistence
- **Endpoint URL**: Verify your ingestion endpoint is correct and accessible
- **Write Key**: Ensure your write key is valid and not masked

## Delivery & Backoff (How events flow under failures)

**Queue capacity:** The SDK keeps up to 2,000 events in memory. When the cap is reached, the oldest events are dropped first (drop-oldest). You can change this via `maxQueueEvents` in `InitOptions`.

This SDK uses a circuit breaker around network I/O. It keeps ordering stable, avoids tight retry loops, and backs off cleanly when your cluster is unhealthy or throttling.

**Queueing during backoff:** While the breaker is OPEN, new events are accepted and appended to the in-memory queue; nothing is sent until the cooldown elapses.

**Ordering (FIFO):** If a batch fails with a retryable error, that batch is requeued at the front (original order preserved). New events go to the tail. After cooldown, we try again; on success we continue draining in order.

**Half-open probe:** After cooldown, one probe is allowed.

- Success → breaker CLOSED (keep flushing).
- Failure → breaker OPEN again with longer cooldown.

**sentAt semantics:** `sentAt` is stamped when the batch is prepared for network transmission (at drain time), not when the event enters the queue.

| Status / Failure                    | Action                                                               | Breaker | Queue effect                   |
| ----------------------------------- | -------------------------------------------------------------------- | ------- | ------------------------------ |
| `2xx`                               | Success                                                              | close   | Batch removed                  |
| `5xx`                               | Retry: requeue **front**, schedule after cooldown                    | open↑   | Requeued (front)               |
| `408` (timeout)                     | Retry: requeue **front**, schedule after cooldown                    | open↑   | Requeued (front)               |
| `429` (throttle)                    | Retry: requeue **front**, wait = `max(Retry-After, breaker, 1000ms)` | open↑   | Requeued (front)               |
| `413` (payload too large)           | Halve `maxBatchSize`; requeue and retry; if already `1`, **drop**    | close   | Requeued or dropped (`size=1`) |
| `400`, `422`, other non-fatal `4xx` | **Drop** bad batch, continue                                         | close   | Dropped                        |
| `401`, `403`, `404`                 | **Disable** client (stop timers), clear queue                        | close   | Cleared                        |
| Network error / Timeout             | Retry: requeue **front**, schedule after cooldown                    | open↑   | Requeued (front)               |
| Reset during flush                  | Do **not** requeue in-flight chunk; **drop** it                      | —       | Dropped                        |

**Defaults:** `failureThreshold=3`, `cooldownMs=10s`, `maxCooldownMs=120s`, `jitter=±20%`, `halfOpenMaxConcurrent=1`.

**Identifiers:**

- `anonymousId` is a stable, persisted UUID for the device/user before identify; it does **not** include timestamps.
- `messageId` is generated as `<epochMillis>-<uuid>` (e.g., `1734691572843-6f0c7e85-...`) to aid debugging.

## App Lifecycle Handling

The SDK automatically handles app lifecycle events:

- **App Foreground**: Starts periodic flush loop and immediately flushes any queued events
- **App Background**: Flushes events, stops flush loop, and cancels any scheduled retries
- **Identity Persistence**: Anonymous ID, user ID, and group ID are persisted to UserDefaults across app launches

## License

MIT
