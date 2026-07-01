// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FoundationModelsFrameworkCLI",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "afm",
            targets: ["AFMCLI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/rryam/FoundationModelsKit.git", exact: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.1")
    ],
    targets: [
        .executableTarget(
            name: "AFMCLI",
            dependencies: [
                "AFMServer",
                .product(name: "FoundationModelsKit", package: "FoundationModelsKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .target(
            name: "AFMServer",
            dependencies: [
                .product(name: "FoundationModelsKit", package: "FoundationModelsKit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ]
        ),
        .testTarget(
            name: "AFMCLITests",
            dependencies: ["AFMCLI"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "AFMServerTests",
            dependencies: [
                "AFMServer",
                .product(name: "FoundationModelsKit", package: "FoundationModelsKit"),
                .product(name: "NIOEmbedded", package: "swift-nio")
            ]
        )
    ]
)
