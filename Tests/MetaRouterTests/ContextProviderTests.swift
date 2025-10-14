import XCTest

@testable import MetaRouter

final class ContextProviderTests: XCTestCase {

    var contextProvider: DeviceContextProvider!

    override func setUp() {
        super.setUp()
        contextProvider = DeviceContextProvider(libraryName: "test-sdk", libraryVersion: "1.0.0-test")
    }

    override func tearDown() {
        contextProvider = nil
        super.tearDown()
    }


    func testEventContextStructure() {
        let app = AppContext(
            name: "TestApp", version: "1.0", build: "123", namespace: "com.test.app")
        let device = DeviceContext(
            manufacturer: "Apple", model: "iPhone15,2", name: "Test Device", type: "phone")
        let library = LibraryContext(name: "test-sdk", version: "1.0.0")
        let os = OSContext(name: "iOS", version: "17.0")
        let screen = ScreenContext(density: 3.0, width: 1179, height: 2556)
        let network = NetworkContext(wifi: true)

        let context = EventContext(
            app: app,
            device: device,
            library: library,
            os: os,
            screen: screen,
            network: network,
            locale: "en_US",
            timezone: "America/New_York"
        )

        XCTAssertEqual(context.app.name, "TestApp")
        XCTAssertEqual(context.device.manufacturer, "Apple")
        XCTAssertEqual(context.library.name, "test-sdk")
        XCTAssertEqual(context.os.name, "iOS")
        XCTAssertEqual(context.screen.density, 3.0)
        XCTAssertEqual(context.network?.wifi, true)
        XCTAssertEqual(context.locale, "en_US")
        XCTAssertEqual(context.timezone, "America/New_York")
    }

    func testEventContextOptionalNetwork() {
        let app = AppContext(
            name: "TestApp", version: "1.0", build: "123", namespace: "com.test.app")
        let device = DeviceContext(
            manufacturer: "Apple", model: "iPhone15,2", name: "Test Device", type: "phone")
        let library = LibraryContext(name: "test-sdk", version: "1.0.0")
        let os = OSContext(name: "iOS", version: "17.0")
        let screen = ScreenContext(density: 3.0, width: 1179, height: 2556)

        let context = EventContext(
            app: app,
            device: device,
            library: library,
            os: os,
            screen: screen,
            network: nil,
            locale: "en_US",
            timezone: "America/New_York"
        )

        XCTAssertNil(context.network)
    }


    func testContextProviderInitialization() {
        let provider = DeviceContextProvider(libraryName: "custom-sdk", libraryVersion: "2.0.0")
        XCTAssertNotNil(provider)
    }

    func testContextProviderDefaultInitialization() {
        let provider = DeviceContextProvider()
        XCTAssertNotNil(provider)
    }

    func testContextProviderCaching() async {
        let context1 = await contextProvider.getContext()
        let context2 = await contextProvider.getContext()

        // Should be the same cached instance
        XCTAssertEqual(context1.app.name, context2.app.name)
        XCTAssertEqual(context1.device.model, context2.device.model)
        XCTAssertEqual(context1.library.name, context2.library.name)
        XCTAssertEqual(context1.os.name, context2.os.name)
        XCTAssertEqual(context1.locale, context2.locale)
        XCTAssertEqual(context1.timezone, context2.timezone)
    }

    func testContextProviderCacheClear() async {
        let context1 = await contextProvider.getContext()
        contextProvider.clearCache()
        let context2 = await contextProvider.getContext()

        // Should have same values but potentially different instances after cache clear
        XCTAssertEqual(context1.app.name, context2.app.name)
        XCTAssertEqual(context1.device.manufacturer, context2.device.manufacturer)
        XCTAssertEqual(context1.library.name, context2.library.name)
    }

    func testLibraryContext() async {
        let context = await contextProvider.getContext()

        XCTAssertEqual(context.library.name, "test-sdk")
        XCTAssertEqual(context.library.version, "1.0.0-test")
    }

    func testAppContext() async {
        let context = await contextProvider.getContext()

        XCTAssertFalse(context.app.name.isEmpty)
        XCTAssertFalse(context.app.version.isEmpty)
        XCTAssertFalse(context.app.build.isEmpty)
        XCTAssertFalse(context.app.namespace.isEmpty)

        // Basic validation that these look like app info
        XCTAssertNotEqual(context.app.name, "unknown")
        XCTAssertNotEqual(context.app.namespace, "unknown")
    }

    func testDeviceContext() async {
        let context = await contextProvider.getContext()

        XCTAssertEqual(context.device.manufacturer, "Apple")
        XCTAssertFalse(context.device.model.isEmpty)
        XCTAssertFalse(context.device.name.isEmpty)
        XCTAssertTrue(
            context.device.type == "phone" || context.device.type == "tablet"
                || context.device.type == "desktop")
    }

    func testOSContext() async {
        let context = await contextProvider.getContext()

        XCTAssertFalse(context.os.name.isEmpty)
        XCTAssertFalse(context.os.version.isEmpty)

        // Should be iOS in test environment or macOS when running tests on Mac
        XCTAssertTrue(
            context.os.name.contains("iOS") || context.os.name.contains("Simulator")
                || context.os.name.contains("macOS"))
    }

    func testScreenContext() async {
        let context = await contextProvider.getContext()

        XCTAssertGreaterThan(context.screen.density, 0)
        XCTAssertGreaterThan(context.screen.width, 0)
        XCTAssertGreaterThan(context.screen.height, 0)

        // Typical iOS screen densities
        XCTAssertTrue(context.screen.density >= 1.0 && context.screen.density <= 3.0)
    }

    func testLocaleContext() async {
        let context = await contextProvider.getContext()

        XCTAssertFalse(context.locale.isEmpty)
        XCTAssertTrue(context.locale.contains("_") || context.locale.contains("-"))
    }

    func testTimezoneContext() async {
        let context = await contextProvider.getContext()

        XCTAssertFalse(context.timezone.isEmpty)
        // Should look like a timezone identifier
        XCTAssertTrue(context.timezone.contains("/") || context.timezone.starts(with: "GMT"))
    }

    func testNetworkContextOptional() async {
        let context = await contextProvider.getContext()

        // Network context might be nil due to permissions or timeout
        if let network = context.network {
            // If present, should have wifi boolean
            XCTAssertNotNil(network.wifi)
        }
    }


    func testConcurrentContextAccess() async {
        await withTaskGroup(of: EventContext.self) { group in
            // Launch multiple concurrent context requests
            for _ in 0..<10 {
                group.addTask {
                    return await self.contextProvider.getContext()
                }
            }

            var contexts: [EventContext] = []
            for await context in group {
                contexts.append(context)
            }

            // All contexts should be identical (cached)
            let firstContext = contexts[0]
            for context in contexts {
                XCTAssertEqual(context.app.name, firstContext.app.name)
                XCTAssertEqual(context.device.model, firstContext.device.model)
                XCTAssertEqual(context.library.name, firstContext.library.name)
                XCTAssertEqual(context.locale, firstContext.locale)
            }
        }
    }

    func testConcurrentCacheClear() async {
        // Get initial context
        let _ = await contextProvider.getContext()

        // Test concurrent cache clearing doesn't cause issues
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    self.contextProvider.clearCache()
                }
            }

            for _ in 0..<5 {
                group.addTask {
                    let _ = await self.contextProvider.getContext()
                }
            }

            // Wait for all tasks
            for await _ in group {}
        }

        // Should still be able to get context after concurrent operations
        let finalContext = await contextProvider.getContext()
        XCTAssertNotNil(finalContext)
    }

    func testEventContextCodable() throws {
        let app = AppContext(
            name: "TestApp", version: "1.0", build: "123", namespace: "com.test.app")
        let device = DeviceContext(
            manufacturer: "Apple", model: "iPhone15,2", name: "Test Device", type: "phone")
        let library = LibraryContext(name: "test-sdk", version: "1.0.0")
        let os = OSContext(name: "iOS", version: "17.0")
        let screen = ScreenContext(density: 3.0, width: 1179, height: 2556)
        let network = NetworkContext(wifi: true)

        let originalContext = EventContext(
            app: app,
            device: device,
            library: library,
            os: os,
            screen: screen,
            network: network,
            locale: "en_US",
            timezone: "America/New_York"
        )

        // Test encoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalContext)
        XCTAssertFalse(data.isEmpty)

        // Test decoding
        let decoder = JSONDecoder()
        let decodedContext = try decoder.decode(EventContext.self, from: data)

        XCTAssertEqual(originalContext.app.name, decodedContext.app.name)
        XCTAssertEqual(originalContext.device.manufacturer, decodedContext.device.manufacturer)
        XCTAssertEqual(originalContext.library.name, decodedContext.library.name)
        XCTAssertEqual(originalContext.os.name, decodedContext.os.name)
        XCTAssertEqual(originalContext.screen.density, decodedContext.screen.density)
        XCTAssertEqual(originalContext.network?.wifi, decodedContext.network?.wifi)
        XCTAssertEqual(originalContext.locale, decodedContext.locale)
        XCTAssertEqual(originalContext.timezone, decodedContext.timezone)
    }

    func testEventContextCodableWithoutNetwork() throws {
        let app = AppContext(
            name: "TestApp", version: "1.0", build: "123", namespace: "com.test.app")
        let device = DeviceContext(
            manufacturer: "Apple", model: "iPhone15,2", name: "Test Device", type: "phone")
        let library = LibraryContext(name: "test-sdk", version: "1.0.0")
        let os = OSContext(name: "iOS", version: "17.0")
        let screen = ScreenContext(density: 3.0, width: 1179, height: 2556)

        let originalContext = EventContext(
            app: app,
            device: device,
            library: library,
            os: os,
            screen: screen,
            network: nil,
            locale: "en_US",
            timezone: "America/New_York"
        )

        // Test encoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalContext)
        XCTAssertFalse(data.isEmpty)

        // Test decoding
        let decoder = JSONDecoder()
        let decodedContext = try decoder.decode(EventContext.self, from: data)

        XCTAssertEqual(originalContext.app.name, decodedContext.app.name)
        XCTAssertEqual(originalContext.device.manufacturer, decodedContext.device.manufacturer)
        XCTAssertEqual(originalContext.library.name, decodedContext.library.name)
        XCTAssertEqual(originalContext.os.name, decodedContext.os.name)
        XCTAssertEqual(originalContext.screen.density, decodedContext.screen.density)
        XCTAssertEqual(originalContext.locale, decodedContext.locale)
        XCTAssertEqual(originalContext.timezone, decodedContext.timezone)
        XCTAssertNil(decodedContext.network)
    }


    func testDeviceContextWithAdvertisingId() {
        let device = DeviceContext(
            manufacturer: "Apple",
            model: "iPhone15,2",
            name: "Test Device",
            type: "phone",
            advertisingId: "12345678-1234-1234-1234-123456789012"
        )

        XCTAssertEqual(device.advertisingId, "12345678-1234-1234-1234-123456789012")
    }

    func testDeviceContextWithoutAdvertisingId() {
        let device = DeviceContext(
            manufacturer: "Apple",
            model: "iPhone15,2",
            name: "Test Device",
            type: "phone"
        )

        XCTAssertNil(device.advertisingId)
    }

    func testContextProviderWithAdvertisingId() async {
        let testAdvertisingId = "ABCD1234-5678-90EF-GHIJ-KLMNOPQRSTUV"
        let provider = DeviceContextProvider(
            libraryName: "test-sdk",
            libraryVersion: "1.0.0"
        )

        await provider.setAdvertisingId(testAdvertisingId)
        let context = await provider.getContext()

        XCTAssertEqual(context.device.advertisingId, testAdvertisingId)
    }

    func testContextProviderWithNilAdvertisingId() async {
        let provider = DeviceContextProvider(
            libraryName: "test-sdk",
            libraryVersion: "1.0.0"
        )

        let context = await provider.getContext()

        XCTAssertNil(context.device.advertisingId)
    }

    func testContextProviderWithoutAdvertisingId() async {
        let provider = DeviceContextProvider(
            libraryName: "test-sdk",
            libraryVersion: "1.0.0"
        )

        let context = await provider.getContext()

        XCTAssertNil(context.device.advertisingId)
    }

    func testDeviceContextCodableWithAdvertisingId() throws {
        let device = DeviceContext(
            manufacturer: "Apple",
            model: "iPhone15,2",
            name: "Test Device",
            type: "phone",
            advertisingId: "TEST-IDFA-UUID"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(device)
        XCTAssertFalse(data.isEmpty)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DeviceContext.self, from: data)

        XCTAssertEqual(device.manufacturer, decoded.manufacturer)
        XCTAssertEqual(device.model, decoded.model)
        XCTAssertEqual(device.name, decoded.name)
        XCTAssertEqual(device.type, decoded.type)
        XCTAssertEqual(device.advertisingId, decoded.advertisingId)
    }

    func testDeviceContextCodableWithoutAdvertisingId() throws {
        let device = DeviceContext(
            manufacturer: "Apple",
            model: "iPhone15,2",
            name: "Test Device",
            type: "phone"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(device)
        XCTAssertFalse(data.isEmpty)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DeviceContext.self, from: data)

        XCTAssertEqual(device.manufacturer, decoded.manufacturer)
        XCTAssertEqual(device.model, decoded.model)
        XCTAssertEqual(device.name, decoded.name)
        XCTAssertEqual(device.type, decoded.type)
        XCTAssertNil(decoded.advertisingId)
    }

    func testAdvertisingIdPersistsInCachedContext() async {
        let testId = "CACHED-TEST-ID"
        let provider = DeviceContextProvider(
            libraryName: "test-sdk",
            libraryVersion: "1.0.0"
        )

        await provider.setAdvertisingId(testId)

        // Get context twice - both should have the same IDFA
        let context1 = await provider.getContext()
        let context2 = await provider.getContext()

        XCTAssertEqual(context1.device.advertisingId, testId)
        XCTAssertEqual(context2.device.advertisingId, testId)
    }

    func testSetAdvertisingId() async {
        let provider = DeviceContextProvider(
            libraryName: "test-sdk",
            libraryVersion: "1.0.0"
        )

        // Initial context should have nil advertisingId
        let context1 = await provider.getContext()
        XCTAssertNil(context1.device.advertisingId)

        // Update advertisingId
        let newId = "NEW-ADVERTISING-ID"
        await provider.setAdvertisingId(newId)

        // New context should have updated advertisingId
        let context2 = await provider.getContext()
        XCTAssertEqual(context2.device.advertisingId, newId)
    }

    func testSetAdvertisingIdUpdatesExistingValue() async {
        let initialId = "INITIAL-ID"
        let provider = DeviceContextProvider(
            libraryName: "test-sdk",
            libraryVersion: "1.0.0"
        )

        await provider.setAdvertisingId(initialId)

        // Initial context should have initial ID
        let context1 = await provider.getContext()
        XCTAssertEqual(context1.device.advertisingId, initialId)

        // Update advertisingId to a new value
        let updatedId = "UPDATED-ID"
        await provider.setAdvertisingId(updatedId)

        // New context should have updated advertisingId
        let context2 = await provider.getContext()
        XCTAssertEqual(context2.device.advertisingId, updatedId)
    }

    func testSetAdvertisingIdToNil() async {
        let initialId = "INITIAL-ID"
        let provider = DeviceContextProvider(
            libraryName: "test-sdk",
            libraryVersion: "1.0.0"
        )

        await provider.setAdvertisingId(initialId)

        // Initial context should have initial ID
        let context1 = await provider.getContext()
        XCTAssertEqual(context1.device.advertisingId, initialId)

        // Update advertisingId to nil
        await provider.setAdvertisingId(nil)

        // New context should have nil advertisingId
        let context2 = await provider.getContext()
        XCTAssertNil(context2.device.advertisingId)
    }

    func testSetAdvertisingIdClearsCachedContext() async {
        let provider = DeviceContextProvider(
            libraryName: "test-sdk",
            libraryVersion: "1.0.0"
        )

        await provider.setAdvertisingId("INITIAL-ID")

        // Get initial context to populate cache
        let context1 = await provider.getContext()
        XCTAssertEqual(context1.device.advertisingId, "INITIAL-ID")

        // Set new advertising ID (which should clear cache)
        await provider.setAdvertisingId("NEW-ID")

        // Get context again - should have new value
        let context2 = await provider.getContext()
        XCTAssertEqual(context2.device.advertisingId, "NEW-ID")
        XCTAssertNotEqual(context1.device.advertisingId, context2.device.advertisingId)
    }

    func testConcurrentSetAdvertisingId() async {
        let provider = DeviceContextProvider(
            libraryName: "test-sdk",
            libraryVersion: "1.0.0"
        )

        // Concurrently set advertising ID multiple times
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    await provider.setAdvertisingId("ID-\(i)")
                }
            }

            for await _ in group {}
        }

        // Should still be able to get context and have a valid ID
        let context = await provider.getContext()
        XCTAssertNotNil(context.device.advertisingId)
        XCTAssertTrue(context.device.advertisingId?.starts(with: "ID-") ?? false)
    }
}
