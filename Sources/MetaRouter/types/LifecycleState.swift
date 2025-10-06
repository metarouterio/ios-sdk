import Foundation

public enum LifecycleState: String, Sendable {
    case idle = "idle"
    case initializing = "initializing"
    case ready = "ready"
    case resetting = "resetting"
    case disabled = "disabled"
}

