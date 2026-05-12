// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FlashboxStorage",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "FlashboxStorage",
            targets: ["FlashboxStorage"]
        ),
    ],
    dependencies: [
        .package(path: "../FlashboxCore"),
    ],
    targets: [
        .target(
            name: "FlashboxStorage",
            dependencies: ["FlashboxCore"],
            path: "Sources"
        ),
    ]
)
