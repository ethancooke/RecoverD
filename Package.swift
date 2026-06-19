// swift-tools-version: 6.0
// RecoverD — native macOS (Apple Silicon, macOS 14+) file-recovery tool.
// Swift 6 strict concurrency. SwiftUI-first. AppKit only where SwiftUI is insufficient.

import PackageDescription

let package = Package(
    name: "RecoverD",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RecoverDApp", targets: ["RecoverDApp"]),
        .library(name: "RecoverDEngine", targets: ["RecoverDEngine"]),
        .library(name: "RecoverDCore", targets: ["RecoverDCore"])
    ],
    dependencies: [
        // Future: libfsapfs bridge via a binaryTarget or system-module wrapper.
        // .package(url: "https://github.com/libyal/libfsapfs.git", from: "..."),
    ],
    targets: [
        .target(
            name: "RecoverDCore",
            dependencies: [],
            swiftSettings: librarySwiftSettings
        ),
        .target(
            name: "RecoverDEngine",
            dependencies: ["RecoverDCore"],
            swiftSettings: librarySwiftSettings
        ),
        .executableTarget(
            name: "RecoverDApp",
            dependencies: ["RecoverDEngine", "RecoverDCore"],
            swiftSettings: executableSwiftSettings
        ),
        .testTarget(
            name: "RecoverDCoreTests",
            dependencies: ["RecoverDCore"],
            swiftSettings: librarySwiftSettings
        ),
        .testTarget(
            name: "RecoverDEngineTests",
            dependencies: ["RecoverDEngine", "RecoverDCore"],
            swiftSettings: librarySwiftSettings
        )
    ]
)

let librarySwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

// The executable entry uses @main (not a main.swift file), so it must be parsed as a library.
let executableSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .unsafeFlags(["-parse-as-library"])
]
