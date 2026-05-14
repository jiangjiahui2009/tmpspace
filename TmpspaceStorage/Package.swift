// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TmpspaceStorage",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "TmpspaceStorage",
            targets: ["TmpspaceStorage"]
        ),
    ],
    dependencies: [
        .package(path: "../TmpspaceCore"),
    ],
    targets: [
        .target(
            name: "TmpspaceStorage",
            dependencies: ["TmpspaceCore"],
            path: "Sources"
        ),
    ]
)
