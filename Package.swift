// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TerrapinPilot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "terrapinpilot",
            targets: ["CLI"]
        )
    ],
    targets: [
        .target(name: "Logger"),
        .target(name: "Stores"),
        .target(name: "Enums"),
        .target(
            name: "Helpers",
            dependencies: ["Stores"]
        ),
        .target(
            name: "Tools",
            dependencies: ["Logger", "Stores"]
        ),
        .executableTarget(
            name: "CLI",
            dependencies: ["Logger", "Stores", "Tools", "Enums", "Helpers"]
        ),
    ]
)
