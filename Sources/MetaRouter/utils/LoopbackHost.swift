import Foundation

/// Single definition of "local development host" for cleartext-http warnings —
/// the config validator and the webview bridge share the same policy, and a
/// second copy of this list is how the two would quietly diverge.
internal enum LoopbackHost {
    static func isLoopback(_ host: String) -> Bool {
        // URL.host reports IPv6 literals without brackets; origin strings carry them.
        let name = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        return name == "localhost" || name == "127.0.0.1" || name == "::1"
    }
}
