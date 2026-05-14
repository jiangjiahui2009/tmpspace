// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TmpspaceApp",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "Tmpspace",
            targets: ["Tmpspace"]
        ),
    ],
    dependencies: [
        .package(path: "../TmpspaceCore"),
        .package(path: "../TmpspaceMenuBar"),
        .package(path: "../TmpspaceEditor"),
        .package(path: "../TmpspaceStorage"),
        .package(path: "../TmpspaceSettings"),
    ],
    targets: [
        .executableTarget(
            name: "Tmpspace",
            dependencies: [
                "TmpspaceCore",
                "TmpspaceMenuBar",
                "TmpspaceEditor",
                "TmpspaceStorage",
                "TmpspaceSettings",
            ],
            path: "Sources",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ]),
            ]
        ),
    ]
)
