import Foundation

/**
 * Simple logger utility for MetaRouter SDK.
 *
 * Allows toggling debug logging for development and troubleshooting.
 * Always logs warnings and errors, regardless of debug setting.
 * Prepends all logs with a [MetaRouter] tag for easy identification.
 */
public enum Logger {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var enabled = false
    
    /**
     * Enables or disables debug logging.
     */
    public static func setDebugLogging(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        enabled = value
    }
    
    /**
     * Logs a message to the console if debug logging is enabled.
     */
    public static func log(_ items: Any...) {
        lock.lock()
        let isEnabled = enabled
        lock.unlock()
        
        guard isEnabled else { return }
        
        let message = items.map { "\($0)" }.joined(separator: " ")
        print("[MetaRouter]", message)
    }
    
    /**
     * Logs a contextual message with writeKey and host info if debug logging is enabled.
     */
    public static func log(_ message: String, writeKey: String? = nil, host: String? = nil) {
        lock.lock()
        let isEnabled = enabled
        lock.unlock()
        
        guard isEnabled else { return }
        
        var contextualMessage = message
        if let writeKey = writeKey {
            contextualMessage += ", writeKey=\(writeKey)"
        }
        if let host = host {
            contextualMessage += ", host=\(host)"
        }
        
        print("[MetaRouter]", contextualMessage)
    }
    
    /**
     * Logs a warning to the console (always, regardless of debug setting).
     */
    public static func warn(_ items: Any...) {
        let message = items.map { "\($0)" }.joined(separator: " ")
        print("[MetaRouter] WARNING:", message)
    }
    
    /**
     * Logs an error to the console (always, regardless of debug setting).
     */
    public static func error(_ items: Any...) {
        let message = items.map { "\($0)" }.joined(separator: " ")
        print("[MetaRouter] ERROR:", message)
    }
}