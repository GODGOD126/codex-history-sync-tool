// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexHistorySync",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CodexHistoryCore",
            targets: ["CodexHistoryCore"]
        ),
        .executable(
            name: "CodexHistorySyncApp",
            targets: ["CodexHistorySyncApp"]
        )
    ],
    targets: [
        .target(
            name: "CodexHistoryCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "CodexHistorySyncApp",
            dependencies: ["CodexHistoryCore"]
        ),
        .testTarget(
            name: "CodexHistoryCoreTests",
            dependencies: ["CodexHistoryCore"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
