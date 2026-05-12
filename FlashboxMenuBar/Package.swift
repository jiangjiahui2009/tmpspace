// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FlashboxMenuBar",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "FlashboxMenuBar",
            targets: ["FlashboxMenuBar"]
        ),
    ],
    dependencies: [
        .package(path: "../FlashboxCore"),
    ],
    targets: [
        .target(
            name: "FlashboxMenuBar",
            dependencies: ["FlashboxCore"],
            path: "Sources"
        ),
    ]
)
