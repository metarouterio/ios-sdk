import Darwin
import Foundation
import Network

#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif
#if canImport(CoreTelephony)
    import CoreTelephony
#endif

struct DeviceSnapshot: Sendable {
    let model: String
    let name: String
    let systemName: String
    let systemVersion: String
    let userInterfaceIdiom: Int
}

struct ScreenSnapshot: Sendable {
    let width: Int
    let height: Int
    let scale: Double
}

/// iOS-specific implementation of context collection
public final class IOSContextProvider: ContextProvider, @unchecked Sendable {

    private let contextActor = ContextActor()
    private let library: LibraryContext

    public init(libraryName: String = "metarouter-ios-sdk", libraryVersion: String = "1.0.0") {
        self.library = LibraryContext(name: libraryName, version: libraryVersion)
    }

    public func getContext() async -> EventContext {
        return await contextActor.getOrCreateContext { [self] in
            await collectContext()
        }
    }

    public func clearCache() {
        Task {
            await contextActor.clearCache()
        }
    }

    private func collectContext() async -> EventContext {
        let app = await collectAppContext()
        let device = await collectDeviceContext()
        let os = await collectOSContext()
        let screen = await collectScreenContext()
        let network = await collectNetworkContext()
        let locale = collectLocale()
        let timezone = collectTimezone()

        return EventContext(
            app: app,
            device: device,
            library: library,
            os: os,
            screen: screen,
            network: network,
            locale: locale,
            timezone: timezone
        )
    }

    private func collectAppContext() async -> AppContext {
        let bundle = Bundle.main
        let infoDictionary = bundle.infoDictionary ?? [:]

        let name =
            infoDictionary["CFBundleDisplayName"] as? String ?? infoDictionary["CFBundleName"]
            as? String ?? "Unknown"

        let version = infoDictionary["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = infoDictionary["CFBundleVersion"] as? String ?? "unknown"
        let namespace = bundle.bundleIdentifier ?? "unknown"

        return AppContext(
            name: name,
            version: version,
            build: build,
            namespace: namespace
        )
    }

    private func collectDeviceContext() async -> DeviceContext {
        #if canImport(UIKit)
            let snapshot = await readDeviceSnapshot()

            // Get device model identifier
            var systemInfo = utsname()
            uname(&systemInfo)
            let modelCode = withUnsafePointer(to: &systemInfo.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                    String(validatingCString: ptr) ?? "unknown"
                }
            }

            // Map to human-readable name
            let mappedModel = mapDeviceModel(modelCode)

            return DeviceContext(
                manufacturer: "Apple",
                model: mappedModel,
                name: snapshot.name,
                type: snapshot.userInterfaceIdiom == 1 ? "tablet" : "phone"
            )
        #else
            // macOS fallback
            var systemInfo = utsname()
            uname(&systemInfo)
            let modelCode = withUnsafePointer(to: &systemInfo.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                    String(validatingCString: ptr) ?? "unknown"
                }
            }

            return DeviceContext(
                manufacturer: "Apple",
                model: modelCode,
                name: ProcessInfo.processInfo.hostName,
                type: "desktop"
            )
        #endif
    }

    private func collectOSContext() async -> OSContext {
        #if canImport(UIKit)
            let snapshot = await readDeviceSnapshot()
            return OSContext(
                name: snapshot.systemName,
                version: snapshot.systemVersion
            )
        #else
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return OSContext(
                name: "macOS",
                version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            )
        #endif
    }

    private func collectScreenContext() async -> ScreenContext {
        #if canImport(UIKit)
            let snapshot = await readScreenSnapshot()

            return ScreenContext(
                density: snapshot.scale,
                width: snapshot.width,
                height: snapshot.height
            )
        #else
            // macOS fallback - use main screen if available
            if let screen = NSScreen.main {
                let bounds = screen.frame
                let scale = screen.backingScaleFactor

                return ScreenContext(
                    density: Double(scale),
                    width: Int(bounds.width * scale),
                    height: Int(bounds.height * scale)
                )
            } else {
                return ScreenContext(
                    density: 2.0,  // Typical Retina density
                    width: 1920,  // Default fallback
                    height: 1080
                )
            }
        #endif
    }

    private func collectNetworkContext() async -> NetworkContext? {
        // Simple network detection using Network framework
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "network-monitor")

        return await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                let isWifi = path.usesInterfaceType(.wifi)
                let networkContext = NetworkContext(wifi: isWifi)
                continuation.resume(returning: networkContext)
                monitor.cancel()
            }
            monitor.start(queue: queue)
        }
    }

    private func collectLocale() -> String {
        return Locale.current.identifier
    }

    private func collectTimezone() -> String {
        return TimeZone.current.identifier
    }

    #if canImport(UIKit)
        @MainActor
        private func readDeviceSnapshot() -> DeviceSnapshot {
            let device = UIDevice.current
            return DeviceSnapshot(
                model: device.model,
                name: device.name,
                systemName: device.systemName,
                systemVersion: device.systemVersion,
                userInterfaceIdiom: device.userInterfaceIdiom.rawValue
            )
        }

        @MainActor
        private func readScreenSnapshot() -> ScreenSnapshot {
            let screen = UIScreen.main
            let bounds = screen.bounds
            let scale = screen.scale
            return ScreenSnapshot(
                width: Int(bounds.width * scale),
                height: Int(bounds.height * scale),
                scale: Double(scale)
            )
        }
    #endif
}

extension IOSContextProvider {
    /// Maps iOS device model codes to human-readable names
    private func mapDeviceModel(_ modelCode: String) -> String {
        let modelMap: [String: String] = [
            // iPhone models
            "iPhone14,7": "iPhone 13 mini",
            "iPhone14,8": "iPhone 13",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone15,4": "iPhone 14",
            "iPhone15,5": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone16,3": "iPhone 15",
            "iPhone16,4": "iPhone 15 Plus",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone Air",

            // iPad models
            "iPad13,18": "iPad (10th generation)",
            "iPad13,19": "iPad (10th generation)",
            "iPad14,3": "iPad Pro 11-inch (4th generation)",
            "iPad14,4": "iPad Pro 11-inch (4th generation)",
            "iPad14,5": "iPad Pro 12.9-inch (6th generation)",
            "iPad14,6": "iPad Pro 12.9-inch (6th generation)",

            // Simulator
            "x86_64": "Simulator",
            "arm64": "Simulator",
        ]

        return modelMap[modelCode] ?? modelCode
    }
}

private actor ContextActor {
    private var cachedContext: EventContext?

    func getOrCreateContext(factory: () async -> EventContext) async -> EventContext {
        if let cached = cachedContext {
            return cached
        }

        let context = await factory()
        cachedContext = context
        return context
    }

    func clearCache() {
        cachedContext = nil
    }
}
