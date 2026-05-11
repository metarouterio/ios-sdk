import Foundation

/// Process-level foreground state used to gate cold-launch and resume emits
/// in the lifecycle subsystem. Mirrors `UIApplication.State` (and the AppKit
/// equivalent) but is platform-neutral so non-UI code can pass it across
/// actor / Task boundaries.
public enum AppForegroundState: Sendable, Equatable {
    case active
    case inactive
    case background
}
