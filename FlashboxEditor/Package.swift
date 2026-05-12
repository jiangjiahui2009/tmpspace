// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FlashboxEditor",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "FlashboxEditor",
            targets: ["FlashboxEditor"]
        ),
    ],
    dependencies: [
        .package(path: "../FlashboxCore"),
    ],
    targets: [
        .target(
            name: "FlashboxEditor",
            dependencies: ["FlashboxCore"],
            path: "Sources"
        ),
    ]
)
