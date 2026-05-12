// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FlashboxSettings",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "FlashboxSettings",
            targets: ["FlashboxSettings"]
        ),
    ],
    dependencies: [
        .package(path: "../FlashboxCore"),
        .package(path: "../FlashboxMenuBar"),
        .package(path: "../FlashboxEditor"),
        .package(path: "../FlashboxStorage"),
    ],
    targets: [
        .target(
            name: "FlashboxSettings",
            dependencies: [
                "FlashboxCore",
                "FlashboxMenuBar",
                "FlashboxEditor",
                "FlashboxStorage",
            ],
            path: "Sources",
            exclude: ["Info.plist"]
        ),
    ]
)
