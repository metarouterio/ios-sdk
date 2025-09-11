import Foundation

/// Utility for generating unique message IDs with timestamp prefixes
public enum MessageIdGenerator {

    /// Generate a messageId with a timestamp prefix (ms since epoch + UUID).
    /// This makes it easy to debug when events were created.
    /// Format: "{timestamp_ms}-{uuid}"
    /// Example: "1694123456789-550E8400-E29B-41D4-A716-446655440000"
    public static func generate() -> String {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)  // ms since epoch
        let uuid = UUID().uuidString
        return "\(timestamp)-\(uuid)"
    }

    /// Generate a message ID with custom timestamp
    /// Useful for testing or when you need to specify the exact time
    public static func generate(timestamp: Date) -> String {
        let timestampMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        let uuid = UUID().uuidString
        return "\(timestampMs)-\(uuid)"
    }

    /// Extract timestamp from a message ID if it follows the expected format
    /// Returns nil if the message ID doesn't have a timestamp prefix
    public static func extractTimestamp(from messageId: String) -> Date? {
        let components = messageId.components(separatedBy: "-")
        guard let firstComponent = components.first,
            let timestampMs = Int64(firstComponent)
        else {
            return nil
        }

        return Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    }

    /// Validate that a message ID follows the expected format
    public static func isValid(_ messageId: String) -> Bool {
        let components = messageId.components(separatedBy: "-")

        // Should have timestamp + UUID (UUID has 4 dashes, so 6 total components)
        guard components.count == 6 else { return false }

        // First component should be a valid timestamp
        guard Int64(components[0]) != nil else { return false }

        // Remaining components should form a valid UUID
        let uuidString = components.dropFirst().joined(separator: "-")
        return UUID(uuidString: uuidString) != nil
    }
}
