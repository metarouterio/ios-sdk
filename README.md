# MetaRouter iOS SDK

A lightweight analytics SDK for iOS that forwards tracking events to your MetaRouter pipeline.  
This SDK is designed to support extensibility, low overhead, and offline-safe event buffering.

## Features

- 📦 Lightweight Swift package
- 🧵 Thread-safe (via actor isolation)
- 🔌 `track`, `identify`, `group`, `screen`, `alias` methods
- 🚧 Built-in debug logging
- 🛠 Designed for future support of:
  - Event queueing
  - Retry/backoff and flush logic
  - Identity resolution and attribution

## Installation

Using Swift Package Manager, add the following dependency to your `Package.swift`:

```swift
.package(url: "https://github.com/metarouter/ios-sdk.git", from: "0.0.1")
```
