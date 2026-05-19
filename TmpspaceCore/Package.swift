// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TmpspaceCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "TmpspaceCore",
            targets: ["TmpspaceCore"]
        ),
    ],
    targets: [
        .target(
            name: "TmpspaceCore",
            path: "Sources",
            resources: [.process("Resources")]
        ),
    ]
)
