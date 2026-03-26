import Foundation

/// Versioned envelope for disk-persisted event queue snapshots.
/// Version 1 stores events as a flat JSON array of EnrichedEventPayload.
public struct QueueSnapshot: Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let events: [EnrichedEventPayload]

    public init(events: [EnrichedEventPayload]) {
        self.version = Self.currentVersion
        self.events = events
    }

    /// Estimated serialized size in bytes.
    /// Called during threshold checks, not on every enqueue.
    public var estimatedSizeBytes: Int {
        guard let data = try? JSONEncoder().encode(self) else { return 0 }
        return data.count
    }
}

// MARK: - Codable with resilient decoding

extension QueueSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)

        guard version == Self.currentVersion else {
            Logger.warn("Queue snapshot version \(version) is not supported (expected \(Self.currentVersion)). Skipping all events.")
            self.events = []
            return
        }

        // Resilient decoding: skip individual corrupt events rather than failing entirely
        var eventsContainer = try container.nestedUnkeyedContainer(forKey: .events)
        var decoded: [EnrichedEventPayload] = []
        var skipped = 0

        while !eventsContainer.isAtEnd {
            do {
                let event = try eventsContainer.decode(EnrichedEventPayload.self)
                decoded.append(event)
            } catch {
                // Skip unreadable event — advance past it
                _ = try? eventsContainer.decode(SnapshotAnyCodable.self)
                skipped += 1
            }
        }

        if skipped > 0 {
            Logger.warn("Skipped \(skipped) unreadable event(s) during queue snapshot decode")
        }

        self.events = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(events, forKey: .events)
    }
}

/// Throwaway type used only to advance the decoder past unreadable array elements.
private struct SnapshotAnyCodable: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if let _ = try? container.decode(Bool.self) { return }
        if let _ = try? container.decode(Int.self) { return }
        if let _ = try? container.decode(Double.self) { return }
        if let _ = try? container.decode(String.self) { return }
        if let _ = try? container.decode([SnapshotAnyCodable].self) { return }
        if let _ = try? container.decode([String: SnapshotAnyCodable].self) { return }
    }
}
