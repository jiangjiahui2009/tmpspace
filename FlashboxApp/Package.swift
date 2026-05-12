// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FlashboxApp",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "Flashbox",
            targets: ["Flashbox"]
        ),
    ],
    dependencies: [
        .package(path: "../FlashboxCore"),
        .package(path: "../FlashboxMenuBar"),
        .package(path: "../FlashboxEditor"),
        .package(path: "../FlashboxStorage"),
        .package(path: "../FlashboxSettings"),
    ],
    targets: [
        .executableTarget(
            name: "Flashbox",
            dependencies: [
                "FlashboxCore",
                "FlashboxMenuBar",
                "FlashboxEditor",
                "FlashboxStorage",
                "FlashboxSettings",
            ],
            path: "Sources"
        ),
    ]
)
