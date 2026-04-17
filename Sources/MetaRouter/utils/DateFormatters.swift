import Foundation

/// Shared ISO8601 formatter. `ISO8601DateFormatter` is thread-safe for
/// `string(from:)` / `date(from:)` in practice, so a single static instance
/// is reused across the SDK instead of allocating one per component.
enum DateFormatters {
    nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()
}
