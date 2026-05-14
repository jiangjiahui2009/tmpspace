// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TmpspaceEditor",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "TmpspaceEditor",
            targets: ["TmpspaceEditor"]
        ),
    ],
    dependencies: [
        .package(path: "../TmpspaceCore"),
    ],
    targets: [
        .target(
            name: "TmpspaceEditor",
            dependencies: ["TmpspaceCore"],
            path: "Sources",
            resources: [.process("Resources")]
        ),
    ]
)
