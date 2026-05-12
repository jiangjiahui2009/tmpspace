// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FlashboxCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "FlashboxCore",
            targets: ["FlashboxCore"]
        ),
    ],
    targets: [
        .target(
            name: "FlashboxCore",
            path: "Sources"
        ),
    ]
)
