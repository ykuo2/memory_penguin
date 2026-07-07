// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MemoryPenguin",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MemoryPenguin", targets: ["MemoryPenguin"])
    ],
    targets: [
        .executableTarget(name: "MemoryPenguin")
    ]
)
