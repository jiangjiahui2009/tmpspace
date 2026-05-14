// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TmpspaceSettings",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "TmpspaceSettings",
            targets: ["TmpspaceSettings"]
        ),
    ],
    dependencies: [
        .package(path: "../TmpspaceCore"),
        .package(path: "../TmpspaceMenuBar"),
        .package(path: "../TmpspaceEditor"),
        .package(path: "../TmpspaceStorage"),
    ],
    targets: [
        .target(
            name: "TmpspaceSettings",
            dependencies: [
                "TmpspaceCore",
                "TmpspaceMenuBar",
                "TmpspaceEditor",
                "TmpspaceStorage",
            ],
            path: "Sources",
            exclude: ["Info.plist"]
        ),
    ]
)
