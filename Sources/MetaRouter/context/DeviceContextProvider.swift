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
    private let advertisingIdActor = AdvertisingIdActor()

    public init(
        libraryName: String = "metarouter-ios-sdk",
        libraryVersion: String = MetaRouterSDK.version,
        appContext: AppContext = .fromBundle()
    ) {
        self.library = LibraryContext(name: libraryName, version: libraryVersion)
        self.appContext = appContext
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
        appContext
    }

    private func collectDeviceContext() async -> DeviceContext {
        let currentAdvertisingId = await advertisingIdActor.get()

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
            type: type,
            advertisingId: currentAdvertisingId
        )
        #elseif canImport(AppKit)
        let hwModel = macHardwareModel()
        return DeviceContext(
            manufacturer: "Apple",
            model: hwModel,
            type: "macos",
            advertisingId: currentAdvertisingId
        )
        #else
        return DeviceContext(
            manufacturer: "Apple",
            model: "unknown",
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
        let once = NetworkContinuationGuard()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                monitor.pathUpdateHandler = { path in
                    if once.claim() {
                        continuation.resume(returning: NetworkContext(wifi: path.usesInterfaceType(.wifi)))
                    }
                    monitor.cancel()
                }
                monitor.start(queue: queue)

                // Timeout after 2 seconds to prevent leak if handler never fires
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if once.claim() {
                        monitor.cancel()
                        continuation.resume(returning: nil)
                    }
                }
            }
        } onCancel: {
            if once.claim() {
                // onCancel can't resume the continuation safely here,
                // but cancelling the monitor will cause the timeout to fire
            }
            monitor.cancel()
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

/// Thread-safe one-shot guard ensuring a continuation is resumed exactly once.
private final class NetworkContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns `true` the first time it is called; `false` thereafter.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
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
