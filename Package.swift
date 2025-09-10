// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MetaRouter",
    platforms: [
        .iOS(.v15), // or your minimum supported iOS version
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "MetaRouter",
            targets: ["MetaRouter"]
        ),
    ],
    targets: [
        .target(
            name: "MetaRouter",
            path: "Sources/MetaRouter",
            resources: [], // Add resources here if needed later
            publicHeadersPath: nil
        ),
        .testTarget(
            name: "MetaRouterTests",
            dependencies: ["MetaRouter"],
            path: "Tests/MetaRouterTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
