// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "switch",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "SwitchApp",
            path: "Sources/SwitchApp",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "SwitchAppTests",
            dependencies: ["SwitchApp"]
        )
    ]
)
