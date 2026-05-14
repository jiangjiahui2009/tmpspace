// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TmpspaceMenuBar",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "TmpspaceMenuBar",
            targets: ["TmpspaceMenuBar"]
        ),
    ],
    dependencies: [
        .package(path: "../TmpspaceCore"),
    ],
    targets: [
        .target(
            name: "TmpspaceMenuBar",
            dependencies: ["TmpspaceCore"],
            path: "Sources",
            resources: [
                .copy("icon"),
            ]
        ),
    ]
)
