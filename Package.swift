// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CTX",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CTX", targets: ["CTX"]),
        .executable(name: "CTXCheck", targets: ["CTXCheck"]),
        .library(name: "CTXCore", targets: ["CTXCore"])
    ],
    targets: [
        .executableTarget(
            name: "CTX",
            dependencies: ["CTXCore"],
            resources: [.process("Resources")]
        ),
        .target(name: "CTXCore"),
        .executableTarget(
            name: "CTXCheck",
            dependencies: ["CTXCore"]
        ),
        .executableTarget(
            name: "CTXCoreTests",
            dependencies: ["CTXCore"]
        )
    ]
)
