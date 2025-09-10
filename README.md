# MetaRouter iOS SDK

A lightweight analytics SDK for iOS that forwards tracking events to your MetaRouter pipeline.  
This SDK is designed to support extensibility, low overhead, and thread-safe event handling.

## Features

- 📦 Lightweight Swift package with minimal dependencies
- 🧵 Thread-safe via actor isolation and proxy pattern
- 🔌 Complete analytics API: `track`, `identify`, `group`, `screen`, `page`, `alias`
- 🚧 Built-in debug logging with configurable output
- 🎯 Type-safe event properties with `CodableValue` enum
- ⚡ Event queuing and replay for early-initialization scenarios
- 🔄 Singleton pattern with global state management
- 🛠 Designed for future support of:
  - HTTP request handling and retry logic
  - Offline event persistence
  - Identity resolution and attribution
  - Advanced batching and flush strategies

## Installation

### Swift Package Manager

Add the following dependency to your `Package.swift`:

```swift
.package(url: "https://github.com/metarouter/ios-sdk.git", from: "0.0.1")
```

Or add it via Xcode: File → Add Package Dependencies → Enter repository URL

## Quick Start

### Basic Setup

```swift
import MetaRouter

// Initialize the SDK (typically in AppDelegate or App.swift)
let options = InitOptions(
    writeKey: "your-write-key",
    ingestionHost: "https://your-metarouter-host.com"
)

let client = MetaRouter.Analytics.initialize(with: options)
```

### Basic Usage

```swift
// Track events
client.track("Purchase Completed", properties: [
    "product_id": "abc123",
    "price": 29.99,
    "currency": "USD"
])

// Identify users
client.identify("user-123", traits: [
    "email": "user@example.com",
    "name": "John Doe",
    "plan": "premium"
])

// Group users
client.group("company-456", traits: [
    "name": "Acme Corp",
    "industry": "Technology"
])

// Screen tracking
client.screen("Product Details", properties: [
    "category": "Electronics",
    "product_id": "abc123"
])

// Page tracking (for web-like experiences)
client.page("Landing Page", properties: [
    "referrer": "google.com",
    "campaign": "summer-sale"
])

// Alias users (link identities)
client.alias("new-user-id")
```

### Advanced Usage

#### Debug Logging

```swift
// Enable global debug logging
MetaRouter.Analytics.setDebugLogging(true)

// Or enable on specific client
client.enableDebugLogging()

// Get debug information
let info = client.getDebugInfo()
print("Write Key: \(info["writeKey"])")
print("Host: \(info["ingestionHost"])")
```

#### Early Initialization Pattern

The SDK supports making analytics calls before initialization (useful for app launch scenarios):

```swift
// Calls made before initialization are queued
let client = MetaRouter.Analytics.client()
client.track("App Launched")  // This gets queued

// Later, when you have configuration
let options = InitOptions(writeKey: "key", ingestionHost: "host")
MetaRouter.Analytics.initialize(with: options)  // Queued calls replay automatically
```

#### Reset and Cleanup

```swift
// Reset individual client
client.reset()

// Reset global SDK state
MetaRouter.Analytics.reset()
```

#### Synchronous barrier APIs (testing only)

These helpers block until global state changes are fully applied and the proxy is bound/unbound. They are intended for tests and sequencing-only scenarios; production code should prefer the non-blocking `initialize` and `reset`.

```swift
// Testing-only: initialize and wait until proxy is bound to the real client
let client = await MetaRouter.Analytics.initializeAndWait(with: options)

// ... perform assertions that require immediate binding

// Testing-only: clear state and wait until unbound
await MetaRouter.Analytics.resetAndWait()

// Safe to re-initialize immediately after a barrier reset
let rebound = await MetaRouter.Analytics.initializeAndWait(with: options)
```

Guarantees:

- initializeAndWait: returns only after the proxy is bound and any queued calls have been replayed.
- resetAndWait: returns only after the proxy is unbound and global state is cleared.

Recommendation: Use these barrier APIs in tests; use `initialize` and `reset` in app code for better startup latency.

## API Reference

### Analytics Methods

| Method       | Description                 | Parameters                                           |
| ------------ | --------------------------- | ---------------------------------------------------- |
| `track()`    | Record user actions         | `event: String, properties: [String: CodableValue]?` |
| `identify()` | Associate user with traits  | `userId: String, traits: [String: CodableValue]?`    |
| `group()`    | Associate user with a group | `groupId: String, traits: [String: CodableValue]?`   |
| `screen()`   | Track screen views (mobile) | `name: String, properties: [String: CodableValue]?`  |
| `page()`     | Track page views (web-like) | `name: String, properties: [String: CodableValue]?`  |
| `alias()`    | Link user identities        | `newUserId: String`                                  |

### Utility Methods

| Method                 | Description              | Returns                  |
| ---------------------- | ------------------------ | ------------------------ |
| `flush()`              | Force send queued events | `Void`                   |
| `reset()`              | Clear user data          | `Void`                   |
| `enableDebugLogging()` | Enable debug output      | `Void`                   |
| `getDebugInfo()`       | Get configuration info   | `[String: CodableValue]` |

### CodableValue

Properties and traits use the `CodableValue` enum for type safety:

```swift
let properties: [String: CodableValue] = [
    "string_value": "hello",
    "number_value": 42,
    "decimal_value": 3.14,
    "boolean_value": true,
    "null_value": .null,
    "array_value": ["item1", "item2"],
    "object_value": [
        "nested_key": "nested_value"
    ]
]
```

## Platform Support

- **iOS**: 15.0+
- **macOS**: 12.0+
- **Swift**: 5.5+
- **Xcode**: 13.0+

## Thread Safety

The SDK is fully thread-safe:

- All public methods can be called from any thread
- Internal state is protected by Swift actors
- Event queuing handles concurrent access safely

## Development

### Building

```bash
swift build
```

### Testing

```bash
swift test
```

### Documentation

See `CLAUDE.md` for detailed development guidelines and architecture decisions.

## License

[Your License Here]

## Support

- **Issues**: [GitHub Issues](https://github.com/metarouter/ios-sdk/issues)
- **Documentation**: [MetaRouter Docs](https://docs.metarouter.io)
- **Community**: [Discord/Slack Link]
