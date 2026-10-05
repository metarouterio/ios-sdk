import Foundation

/// Epoch wall-clock reads, in one place so every persisted timestamp in the SDK
/// (session activity, consent snapshots) is minted with the same unit and source.
internal enum WallClock {
    static func epochMillis() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}
