import Foundation
import Network

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
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



public final class DeviceContextProvider: ContextProvider, @unchecked Sendable {

    private let contextActor = ContextActor()
    private let library: LibraryContext
    private let advertisingIdActor = AdvertisingIdActor()

    public init(
        libraryName: String = "metarouter-ios-sdk",
        libraryVersion: String = "1.0.0"
    ) {
        self.library = LibraryContext(name: libraryName, version: libraryVersion)
    }

    public func getContext() async -> EventContext {
        await contextActor.getOrCreateContext { [self] in
            await collectContext()
        }
    }

    public func clearCache() {
        Task { await contextActor.clearCache() }
    }

    public func setAdvertisingId(_ advertisingId: String?) async {
        await advertisingIdActor.set(advertisingId)
        await contextActor.clearCache()
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
        let info = bundle.infoDictionary ?? [:]

        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? "Unknown"
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let namespace = bundle.bundleIdentifier ?? "unknown"

        return AppContext(name: name, version: version, build: build, namespace: namespace)
    }

    private func collectDeviceContext() async -> DeviceContext {
        let currentAdvertisingId = await advertisingIdActor.get()

        #if canImport(UIKit)
        let snapshot = await readDeviceSnapshot()

        // Low-level model code (e.g., "iPhone16,2")
        var sys = utsname(); uname(&sys)
        let modelCode = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(validatingCString: ptr) ?? "unknown"
            }
        }

        let mappedModel = mapDeviceModel(modelCode)
        let type = await deviceTypeFromIdiom(UIDevice.current.userInterfaceIdiom)

        return DeviceContext(
            manufacturer: "Apple",
            model: mappedModel,
            name: snapshot.name,
            type: type,
            advertisingId: currentAdvertisingId
        )
        #elseif canImport(AppKit)
        return DeviceContext(
            manufacturer: "Apple",
            model: macHardwareModel(), // e.g., "Mac14,5"
            name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            type: "desktop",
            advertisingId: currentAdvertisingId
        )
        #else
        return DeviceContext(
            manufacturer: "Apple",
            model: "unknown",
            name: "unknown",
            type: "unknown",
            advertisingId: currentAdvertisingId
        )
        #endif
    }

    private func collectOSContext() async -> OSContext {
        #if canImport(UIKit)
        let snap = await readDeviceSnapshot()
        let osName: String
        if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac {
            osName = "macOS" // Catalyst / iOS app on Mac
        } else {
            osName = snap.systemName // "iOS"/"iPadOS"/"tvOS"
        }
        return OSContext(name: osName, version: snap.systemVersion)
        #elseif canImport(AppKit)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return OSContext(name: "macOS", version: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        #else
        return OSContext(name: "unknown", version: "unknown")
        #endif
    }

    private func collectScreenContext() async -> ScreenContext {
        #if canImport(UIKit)
        let snap = await readScreenSnapshot()
        return ScreenContext(density: snap.scale, width: snap.width, height: snap.height)
        #elseif canImport(AppKit)
        let snap = await readMacScreenSnapshot()
        return ScreenContext(density: snap.scale, width: snap.width, height: snap.height)
        #else
        return ScreenContext(density: 1.0, width: 0, height: 0)
        #endif
    }

    private func collectNetworkContext() async -> NetworkContext? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "network-monitor")

        return await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.resume(returning: NetworkContext(wifi: path.usesInterfaceType(.wifi)))
                monitor.cancel()
            }
            monitor.start(queue: queue)
        }
    }

    private func collectLocale() -> String { Locale.current.identifier }
    private func collectTimezone() -> String { TimeZone.current.identifier }


    #if canImport(UIKit)
    @MainActor
    private func readDeviceSnapshot() -> DeviceSnapshot {
        let d = UIDevice.current
        return DeviceSnapshot(
            model: d.model,
            name: d.name,
            systemName: d.systemName,
            systemVersion: d.systemVersion,
            userInterfaceIdiom: d.userInterfaceIdiom.rawValue
        )
    }

    @MainActor
    private func readScreenSnapshot() -> ScreenSnapshot {
        let s = UIScreen.main
        let bounds = s.bounds
        let scale = s.scale
        return ScreenSnapshot(
            width: Int(bounds.width * scale),
            height: Int(bounds.height * scale),
            scale: Double(scale)
        )
    }

    private func deviceTypeFromIdiom(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone: return "phone"
        case .pad: return "tablet"
        case .tv: return "tv"
        case .carPlay: return "car"
        default:
            if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac { return "desktop" }
            return "unknown"
        }
    }
    #endif


    #if canImport(AppKit)
    private func macHardwareModel() -> String {
        var size: size_t = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: Int(size))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    @MainActor
    private func readMacScreenSnapshot() -> ScreenSnapshot {
        if let s = NSScreen.main {
            let frame = s.frame
            let scale = s.backingScaleFactor
            return ScreenSnapshot(
                width: Int(frame.width * scale),
                height: Int(frame.height * scale),
                scale: Double(scale)
            )
        }
        return ScreenSnapshot(width: 1920, height: 1080, scale: 2.0) // sensible default
    }
    #endif
}



extension DeviceContextProvider {
    /// Maps iOS device model codes to human-readable names (fallbacks to raw code)
    private func mapDeviceModel(_ modelCode: String) -> String {
        let modelMap: [String: String] = [
            // iPhone (examples)
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

            // iPad (examples)
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
        if let cached = cachedContext { return cached }
        let context = await factory()
        cachedContext = context
        return context
    }

    func clearCache() { cachedContext = nil }
}

private actor AdvertisingIdActor {
    private var advertisingId: String?

    func set(_ newValue: String?) {
        advertisingId = newValue
    }

    func get() -> String? {
        return advertisingId
    }
}
