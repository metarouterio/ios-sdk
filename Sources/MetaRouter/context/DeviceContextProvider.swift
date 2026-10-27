import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif


struct DeviceSnapshot: Sendable {
    let model: String
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
    private let appContext: AppContext
    private let advertisingIdBox = AdvertisingIdBox()

    public init(
        libraryName: String = "metarouter-ios-sdk",
        libraryVersion: String = MetaRouterSDK.version,
        appContext: AppContext = .fromBundle()
    ) {
        self.library = LibraryContext(name: libraryName, version: libraryVersion)
        self.appContext = appContext
    }

    /// Static fields only (app, device, library, os, screen, locale, timezone),
    /// collected once and cached. Network is volatile and the SDK client's
    /// enrichment stamps it per event from the live monitor, so it is absent here.
    public func getContext() async -> EventContext {
        var context = await contextActor.getOrCreateContext { [self] in
            await collectContext()
        }
        if let advertisingId = advertisingIdBox.get() {
            context.device = context.device.with(advertisingId: advertisingId)
        }
        return context
    }

    public func clearCache() {
        Task { await contextActor.clearCache() }
    }

    /// Overlaid on each `getContext()` result rather than baked into the cache:
    /// invalidating the cache here forced a full rebuild (main-actor UIKit reads)
    /// on the next event for a value that is one field. The SDK client does not
    /// call this — enrichment overlays the ad ID from `IdentityManager` — so it
    /// only matters for a provider used standalone.
    public func setAdvertisingId(_ advertisingId: String?) async {
        advertisingIdBox.set(advertisingId)
    }


    private func collectContext() async -> EventContext {
        let app = await collectAppContext()
        let device = await collectDeviceContext()
        let os = await collectOSContext()
        let screen = await collectScreenContext()
        let locale = collectLocale()
        let timezone = collectTimezone()

        return EventContext(
            app: app,
            device: device,
            library: library,
            os: os,
            screen: screen,
            locale: locale,
            timezone: timezone
        )
    }

    private func collectAppContext() async -> AppContext {
        appContext
    }

    private func collectDeviceContext() async -> DeviceContext {
        #if canImport(UIKit)
        var sys = utsname(); uname(&sys)
        let modelCode = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(validatingCString: ptr) ?? "unknown"
            }
        }

        let type = await deviceTypeFromIdiom(UIDevice.current.userInterfaceIdiom)

        return DeviceContext(
            manufacturer: "Apple",
            model: modelCode,
            type: type
        )
        #elseif canImport(AppKit)
        let hwModel = macHardwareModel()
        return DeviceContext(
            manufacturer: "Apple",
            model: hwModel,
            type: "macos"
        )
        #else
        return DeviceContext(
            manufacturer: "Apple",
            model: "unknown",
            type: "unknown"
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

    private func collectLocale() -> String { Locale.current.identifier }
    private func collectTimezone() -> String { TimeZone.current.identifier }


    #if canImport(UIKit)
    @MainActor
    private func readDeviceSnapshot() -> DeviceSnapshot {
        let d = UIDevice.current
        return DeviceSnapshot(
            model: d.model,
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
        case .phone: return "ios"
        case .pad: return "ios"
        case .tv: return "tv"
        case .carPlay: return "car"
        default:
            if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac { return "macos" }
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

/// A lock, not an actor: `getContext` reads this on every event, and an actor hop
/// there is a suspension per event for a value the SDK client never sets.
private final class AdvertisingIdBox: @unchecked Sendable {
    private let lock = NSLock()
    private var advertisingId: String?

    func set(_ newValue: String?) {
        lock.withLock { advertisingId = newValue }
    }

    func get() -> String? {
        lock.withLock { advertisingId }
    }
}
