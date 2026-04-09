import Foundation

/// Represents the current network connectivity status.
public enum NetworkStatus: Sendable, Equatable {
    case connected
    case disconnected
}

/// Protocol for network reachability monitoring.
/// Implementations report connectivity changes and expose current status.
public protocol NetworkReachability: AnyObject, Sendable {
    var currentStatus: NetworkStatus { get }
    func onStatusChange(_ handler: @escaping @Sendable (NetworkStatus) -> Void)
    func stop()
}
