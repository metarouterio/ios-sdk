# MetaRouter iOS SDK

[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey.svg)](https://github.com/metarouter/ios-sdk)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

A lightweight iOS analytics SDK that transmits events to your MetaRouter cluster.

## Table of Contents

- [Installation](#installation)
- [Usage](#usage)
  - [Basic Setup](#basic-setup)
  - [SwiftUI Usage](#swiftui-usage)
  - [UIKit Usage](#uikit-usage)
  - [Direct Usage](#direct-usage)
- [API Reference](#api-reference)
- [Features](#features)
- [Compatibility](#-compatibility)
- [Debugging](#debugging)
- [Identity Persistence](#identity-persistence)
- [Advertising ID (IDFA)](#advertising-id-idfa)
- [Using the alias() Method](#using-the-alias-method)
- [License](#license)

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

// Initialize the analytics client
let options = InitOptions(
    writeKey: "your-write-key",
    ingestionHost: "https://your-ingestion-endpoint.com",
    debug: true, // Optional: enable debug mode
    flushIntervalSeconds: 30, // Optional: flush events every 30 seconds
    maxQueueEvents: 2000 // Optional: max events in memory queue
)

let analytics = MetaRouter.Analytics.initialize(with: options)
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

    func identify(_ userId: String, traits: [String: Any]? = nil) {
        analytics?.identify(userId, traits: traits)
    }

    func screen(_ name: String, properties: [String: Any]? = nil) {
        analytics?.screen(name, properties: properties)
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

### UIKit Usage

```swift
import UIKit
import MetaRouter

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var analytics: AnalyticsInterface!

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Initialize the analytics client
        let options = InitOptions(
            writeKey: "your-write-key",
            ingestionHost: "https://your-ingestion-endpoint.com",
            debug: true
        )
        analytics = MetaRouter.Analytics.initialize(with: options)

        return true
    }
}
```

### Direct Usage

```swift
import MetaRouter

// Initialize the client (optionally await it), but you can use it at any time
// with events transmitted when the client is ready.
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

// Track page views
analytics.page("Home Page", properties: [
    "url": "/home",
    "referrer": "/landing"
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

## API Reference

### MetaRouter.Analytics.initialize(with:)

Initializes the analytics client and returns a **live proxy** to the client instance.

⚠️ `initialize()` returns immediately, but you **do not** need to wait before using analytics methods.

Calls to `track`, `identify`, etc. are **buffered in-memory** by the proxy and replayed **in order** once the client is fully initialized.

**Options:**

- `writeKey` (String, required): Your write key
- `ingestionHost` (String or URL, required): Your MetaRouter ingestor host
- `debug` (Bool, optional): Enable debug mode
- `flushIntervalSeconds` (Int, optional): Interval in seconds to flush events
- `maxQueueEvents` (Int, optional): Number of max events stored in memory

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
- `alias(_ newUserId: String)`: Connect anonymous users to known user IDs. See [Using the alias() Method](#using-the-alias-method) for details
- `setAdvertisingId(_ advertisingId: String?)`: Set the advertising identifier (IDFA) for ad tracking. See [Advertising ID](#advertising-id-idfa) section for usage and compliance requirements
- `clearAdvertisingId()`: Clear the advertising identifier from storage and context. Useful for GDPR/CCPA compliance when users opt out of ad tracking
- `flush()`: Flush events immediately
- `reset()`: Reset analytics state and clear all stored data (includes clearing advertising ID)
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
// - advertisingId: Current advertising ID (if set)
```

### 3. Force Flush Events

```swift
// Manually flush events to see if they're being sent
analytics.flush()
```

### 4. Common Issues

- **Network Permissions**: Ensure your app has network permissions in Info.plist
- **UserDefaults**: The SDK uses UserDefaults for identity persistence (anonymousId, userId, groupId, advertisingId)
- **Endpoint URL**: Verify your ingestion endpoint is correct and accessible
- **Write Key**: Ensure your write key is valid

### Delivery & Backoff (How events flow under failures)

**Queue capacity:** The SDK keeps up to 2,000 events in memory. When the cap is reached, the oldest events are dropped first (drop-oldest). You can change this via `maxQueueEvents` in `InitOptions`.

This SDK uses a circuit breaker around network I/O. It keeps ordering stable, avoids tight retry loops, and backs off cleanly when your cluster is unhealthy or throttling.

**Queueing during backoff:** While the breaker is OPEN, new events are accepted and appended to the in-memory queue; nothing is sent until the cooldown elapses.

**Ordering (FIFO):** If a batch fails with a retryable error, that batch is requeued at the front (original order preserved). New events go to the tail. After cooldown, we try again; on success we continue draining in order.

**Half-open probe:** After cooldown, one probe is allowed.
Success → breaker CLOSED (keep flushing).
Failure → breaker OPEN again with longer cooldown.

**sentAt semantics:** `sentAt` is stamped when the event is enqueued. If the client is backing off, the actual transmit may be later; `sentAt` reflects when the event entered the queue.

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

## Identity Persistence

The MetaRouter iOS SDK automatically manages and persists user identifiers across app sessions using UserDefaults. This ensures consistent user tracking even after app restarts.

### The Four Identity Fields

#### 1. userId (Common User ID)

The `userId` is set when you identify a user and represents their unique identifier in your system (e.g., database ID, email, employee ID).

**How to set:**

```swift
analytics.identify("user123", traits: [
    "name": "John Doe",
    "email": "john@example.com",
    "role": "Sales Associate"
])
```

**Behavior:**

- Persisted to UserDefaults (key: `metarouter:user_id`)
- Automatically loaded on app restart
- Automatically included in **all** subsequent events (`track`, `page`, `screen`, `group`)
- Remains set until `reset()` is called or app is uninstalled

**Example flow:**

```swift
// Day 1: User logs in
analytics.identify("employeeID", traits: ["name": "Jane"])
analytics.track("Product Viewed", properties: ["sku": "ABC123"])
// Event includes: userId: "employeeID"

// App restarts...

// Day 2: User opens app
analytics.track("App Opened")
// Event STILL includes: userId: "employeeID" (auto-loaded from storage)
```

#### 2. anonymousId

The `anonymousId` is a unique identifier automatically generated for each device/installation before a user is identified.

**How it's set:**

- **Automatically** generated as a UUID on first SDK initialization
- No manual action required

**Behavior:**

- Persisted to UserDefaults (key: `metarouter:anonymous_id`)
- Automatically loaded on app restart
- Automatically included in **all** events
- Remains stable across app sessions until `reset()` is called
- Cleared on `reset()` and a **new** UUID is generated on next initialization

**Use case:**
Track user behavior before they log in or create an account, then connect pre-login and post-login activity using the `alias()` method.

#### 3. groupId

The `groupId` associates a user with an organization, team, account, or other group entity.

**How to set:**

```swift
analytics.group("company123", traits: [
    "name": "Acme Corp",
    "plan": "Enterprise",
    "industry": "Technology"
])
```

**Behavior:**

- Persisted to UserDefaults (key: `metarouter:group_id`)
- Automatically loaded on app restart
- Automatically included in **all** subsequent events after being set
- Remains set until `reset()` is called

**Example use case:**

```swift
// User logs into their company account
analytics.identify("user123", traits: ["name": "Jane"])
analytics.group("acme-corp", traits: ["name": "Acme Corp"])

// All future events include both userId and groupId
analytics.track("Report Generated")
// Event includes: userId: "user123", groupId: "acme-corp"
```

#### 4. advertisingId (Optional)

The `advertisingId` is used for ad tracking and attribution (IDFA on iOS). See the [Advertising ID](#advertising-id-idfa) section below for detailed usage and compliance requirements.

### Persistence Summary

| Field             | Set By                 | Storage Key                 | Auto-Attached        | Cleared By                          |
| ----------------- | ---------------------- | --------------------------- | -------------------- | ----------------------------------- |
| **userId**        | `identify(userId)`     | `metarouter:user_id`        | All events           | `reset()`                           |
| **anonymousId**   | Auto-generated (UUID)  | `metarouter:anonymous_id`   | All events           | `reset()` (new ID generated on init)|
| **groupId**       | `group(groupId)`       | `metarouter:group_id`       | All events after set | `reset()`                           |
| **advertisingId** | `setAdvertisingId(id)` | `metarouter:advertising_id` | Event context        | `clearAdvertisingId()`, `reset()`   |

### Event Enrichment Flow

Every event you send (track, page, screen, group) is automatically enriched with persisted identity information:

```swift
// You call:
analytics.track("Button Clicked", properties: ["buttonName": "Submit"])

// SDK automatically adds:
{
  "type": "track",
  "event": "Button Clicked",
  "properties": { "buttonName": "Submit" },
  "userId": "employeeID",        // ← Auto-added from storage
  "anonymousId": "a1b2c3d4-...", // ← Auto-added from storage
  "groupId": "company123",       // ← Auto-added from storage (if set)
  "timestamp": "2025-10-23T...",
  "context": {
    "device": {
      "advertisingId": "..."     // ← Auto-added from storage (if set)
    }
  }
}
```

### Resetting Identity

Call `reset()` to clear **all** identity data, typically when a user logs out:

```swift
analytics.reset()
```

**What `reset()` does:**

- Clears `userId`, `anonymousId`, `groupId`, and `advertisingId` from memory
- Removes all identity fields from UserDefaults
- Stops background flush loops
- Clears event queue
- Next initialization will generate a **new** `anonymousId`

**Common logout flow:**

```swift
// User logs out
analytics.reset()

// User is now tracked with a new anonymousId (auto-generated on next event)
// No userId or groupId until they log in again
```

### Best Practices

1. **On Login:** Call `identify()` immediately after successful authentication
2. **On Logout:** Call `reset()` to clear user identity
3. **Cross-Session Tracking:** The SDK handles this automatically - no action needed
4. **Group Associations:** Set `groupId` after determining the user's organization/team
5. **Pre-Login Tracking:** Events are tracked with `anonymousId` before login
6. **Connecting Sessions:** Use `alias()` to connect pre-login and post-login activity

### Example: Complete User Journey

```swift
// App starts - SDK initializes
let analytics = MetaRouter.Analytics.initialize(with: options)
// anonymousId: "abc-123" (auto-generated and persisted)

// User browses before login
analytics.track("Product Viewed", properties: ["sku": "XYZ"])
// Includes: anonymousId: "abc-123"

// User logs in
analytics.identify("user456", traits: ["name": "John", "email": "john@example.com"])
// userId: "user456" is now persisted

// User performs actions
analytics.track("Added to Cart", properties: ["sku": "XYZ"])
// Includes: userId: "user456", anonymousId: "abc-123"

// App closes and reopens...

// SDK auto-loads userId from storage
analytics.track("App Reopened")
// STILL includes: userId: "user456", anonymousId: "abc-123"

// User logs out
analytics.reset()
// All IDs cleared, new anonymousId will be generated on next init
```

### Storage Location

All identity data is stored in **UserDefaults**, which provides:

- Persistent storage across app sessions
- Automatic data encryption on iOS (Keychain-backed when using appropriate data protection classes)
- Secure local storage
- Cleared only on app uninstall or explicit `reset()` call

### App Lifecycle Handling

The SDK automatically handles app lifecycle events:

- **App Foreground**: Starts periodic flush loop and immediately flushes any queued events
- **App Background**: Flushes events, stops flush loop, and cancels any scheduled retries
- **Identity Persistence**: Anonymous ID, user ID, group ID, and advertising ID are persisted across app launches

## Using the alias() Method

The `alias()` method connects an **anonymous user** (tracked by `anonymousId`) to a **known user ID**. It's used to link pre-login activity to post-login identity.

### When to Use alias()

Use `alias()` when a user **signs up** or **logs in for the first time**, and you want to connect their pre-login browsing activity to their new account.

**Primary use case:** Connecting anonymous browsing sessions to newly created user accounts.

### How It Works

```swift
analytics.alias(newUserId)
```

This does two things:

1. Sets the new `userId` (same as `identify()`)
2. Sends an `alias` event to your analytics backend, telling it: "This anonymousId and this userId are the same person"

### Example: User Sign-Up Flow

```swift
// App starts - user is anonymous
let analytics = MetaRouter.Analytics.initialize(with: options)
// anonymousId: "abc-123" (auto-generated)

// User browses anonymously
analytics.track("Product Viewed", properties: ["productId": "XYZ"])
analytics.track("Add to Cart", properties: ["productId": "XYZ"])
// Both events tracked with anonymousId: "abc-123"

// User creates an account / signs up
analytics.alias("user-456")
// Sends alias event connecting: anonymousId "abc-123" → userId "user-456"

// Optionally add user traits
analytics.identify("user-456", traits: [
    "name": "John Doe",
    "email": "john@example.com"
])

// Future events now tracked as authenticated user
analytics.track("Purchase Complete", properties: ["orderId": "789"])
// Event includes: userId: "user-456", anonymousId: "abc-123"
```

### alias() vs identify()

| Method           | When to Use                                                     | What It Does                                                   |
| ---------------- | --------------------------------------------------------------- | -------------------------------------------------------------- |
| **`alias()`**    | **First-time sign-up/login** when connecting anonymous activity | Sets userId + sends `alias` event to link anonymousId → userId |
| **`identify()`** | Subsequent logins or updating user traits                       | Sets userId + sends `identify` event with user traits          |

### Best Practices

1. **First-time sign-up:** Call `alias()` to connect anonymous activity to the new account
2. **Subsequent logins:** Use `identify()` - no need to alias again
3. **Backend support:** Ensure your analytics backend supports alias events for merging user profiles
4. **One-time operation:** You typically only need `alias()` once per user - when they first create an account

### Real-World Example: E-Commerce App

```swift
// Day 1: Anonymous browsing
analytics.track("App Opened")
analytics.track("Product Viewed", properties: ["sku": "SHOE-123"])
analytics.track("Product Viewed", properties: ["sku": "SHIRT-456"])
// All tracked with anonymousId: "anon-xyz"

// User signs up
analytics.alias("user-789")
analytics.identify("user-789", traits: [
    "name": "Jane Doe",
    "email": "jane@example.com"
])

// User continues shopping (now authenticated)
analytics.track("Added to Cart", properties: ["sku": "SHIRT-456"])
analytics.track("Purchase", properties: ["total": 49.99])

// Your analytics platform can now show the complete customer journey:
// - Pre-signup activity (anonymous product views)
// - Post-signup activity (cart additions, purchase)
// - Full conversion funnel from anonymous → identified → converted
```

## Advertising ID (IDFA)

The SDK supports including advertising identifiers (IDFA - Identifier for Advertisers) in event context for ad tracking and attribution purposes.

### Usage

The MetaRouter SDK supports including the IDFA in your analytics events for ad tracking and attribution purposes. This is useful for marketing analytics, ad campaign measurement, and user acquisition tracking.

#### Prerequisites

1. **iOS 14.5+**: App Tracking Transparency (ATT) is required
2. **Info.plist**: Add `NSUserTrackingUsageDescription` to explain why you need tracking permission
3. **Frameworks**: Import `AppTrackingTransparency` and `AdSupport`

#### 1. Update Info.plist

Add the tracking usage description to your `Info.plist`:

```xml
<key>NSUserTrackingUsageDescription</key>
<string>We use your advertising identifier to measure ad campaign effectiveness and provide personalized experiences.</string>
```

#### 2. Request Tracking Authorization

Request permission before accessing the IDFA:

**Note**: The `setAdvertisingId()` method can be called at any time, even immediately after initialization. If called during initialization, the SDK will queue the operation and apply it once ready. The advertising ID is persisted to UserDefaults and will be automatically restored on subsequent app launches.

```swift
import AppTrackingTransparency
import AdSupport
import MetaRouter

// Request tracking authorization (typically in AppDelegate or SceneDelegate)
func requestTrackingPermission() {
    // Initialize MetaRouter first
    let options = InitOptions(
        writeKey: "your-write-key",
        ingestionHost: "https://your-ingestion-endpoint.com"
    )
    let analytics = MetaRouter.Analytics.initialize(with: options)

    // Only request on iOS 14.5+
    if #available(iOS 14.5, *) {
        ATTrackingManager.requestTrackingAuthorization { status in
            switch status {
            case .authorized:
                // Permission granted - get IDFA and set it
                let advertisingId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                analytics.setAdvertisingId(advertisingId)
            case .denied, .restricted, .notDetermined:
                // Permission not granted - don't include IDFA
                analytics.setAdvertisingId(nil)
            @unknown default:
                analytics.setAdvertisingId(nil)
            }
        }
    } else {
        // iOS 14.4 and below - IDFA available without ATT
        let advertisingId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        analytics.setAdvertisingId(advertisingId)
    }
}
```

#### 3. SwiftUI Example

```swift
import SwiftUI
import AppTrackingTransparency
import AdSupport
import MetaRouter

@main
struct MyApp: App {
    @StateObject private var analyticsManager = AnalyticsManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(analyticsManager)
                .onAppear {
                    // Request tracking permission after a brief delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        requestTrackingAndInitialize()
                    }
                }
        }
    }

    func requestTrackingAndInitialize() {
        // Initialize analytics first
        analyticsManager.initialize()

        // Then request tracking permission and set IDFA
        if #available(iOS 14.5, *) {
            ATTrackingManager.requestTrackingAuthorization { status in
                let advertisingId = status == .authorized
                    ? ASIdentifierManager.shared().advertisingIdentifier.uuidString
                    : nil
                analyticsManager.setAdvertisingId(advertisingId)
            }
        } else {
            let advertisingId = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            analyticsManager.setAdvertisingId(advertisingId)
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

    func setAdvertisingId(_ advertisingId: String?) {
        analytics?.setAdvertisingId(advertisingId)
    }

    func track(_ event: String, properties: [String: Any]? = nil) {
        analytics?.track(event, properties: properties)
    }
}
```

Once set, the `advertisingId` will be automatically included in the device context of all subsequent events:

```json
{
  "context": {
    "device": {
      "advertisingId": "your-advertising-id",
      "manufacturer": "Apple",
      "model": "iPhone 14",
      ...
    }
  }
}
```

### Privacy & Compliance

⚠️ **Important**: Advertising identifiers are Personally Identifiable Information (PII). Before collecting advertising IDs, you must:

1. **Obtain User Consent**: Request explicit permission from users before tracking
2. **Comply with Regulations**: Follow GDPR, CCPA, and other applicable privacy laws
3. **App Store Requirements**:
   - iOS: Follow Apple's [App Tracking Transparency (ATT)](https://developer.apple.com/documentation/apptrackingtransparency) framework
   - Accurately declare data usage in your App Privacy details in App Store Connect

#### GDPR Compliance: Clearing Advertising ID

When users withdraw consent for advertising tracking (e.g., in response to a GDPR data subject request), you must stop collecting their IDFA. Use the `clearAdvertisingId()` method:

```swift
// User withdraws consent for advertising tracking
analytics.clearAdvertisingId()

// Analytics continues to work without IDFA
// Only anonymous ID and user ID will be included in events
analytics.track("checkout_completed", properties: ["order_id": "12345"])
```

**When to clear advertising ID:**

- User opts out of advertising tracking in your app settings
- User revokes ATT permission in iOS Settings
- Responding to GDPR "right to erasure" requests
- User unsubscribes from personalized advertising

**Note:** The `reset()` method also clears the advertising ID along with all other analytics data.

#### Best Practices

1. **Request permission contextually**: Explain the benefits before showing the ATT prompt
2. **Respect user choice**: Don't repeatedly ask if denied
3. **Update privacy policy**: Clearly state IDFA collection and usage
4. **App Store privacy label**: Declare IDFA under "Identifiers" in App Store Connect
5. **Handle nil gracefully**: Your analytics should work with or without IDFA
6. **Provide opt-out**: Give users an in-app way to withdraw consent and clear their advertising ID

#### Checking ATT Status

```swift
import AppTrackingTransparency

func checkTrackingStatus() -> ATTrackingManager.AuthorizationStatus {
    if #available(iOS 14, *) {
        return ATTrackingManager.trackingAuthorizationStatus
    } else {
        return .notDetermined
    }
}
```

### Validation

The SDK validates advertising IDs before setting them:

- Must be a non-empty string
- Cannot be only whitespace
- Invalid values are rejected and logged as warnings

## License

MIT
