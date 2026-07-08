// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MemoryPenguin",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MemoryPenguinCore", targets: ["MemoryPenguinCore"]),
        .executable(name: "MemoryPenguin", targets: ["MemoryPenguin"]),
        .executable(name: "MemoryPenguinCoreSelfTests", targets: ["MemoryPenguinCoreSelfTests"])
    ],
    targets: [
        .target(name: "MemoryPenguinCore"),
        .executableTarget(
            name: "MemoryPenguin",
            dependencies: ["MemoryPenguinCore"]
        ),
        .executableTarget(
            name: "MemoryPenguinCoreSelfTests",
            dependencies: ["MemoryPenguinCore"],
            path: "Tests/MemoryPenguinCoreSelfTests"
        )
    ]
)
