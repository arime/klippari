// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Klippari",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ClipboardCore", targets: ["ClipboardCore"]),
        .executable(name: "Klippari", targets: ["Klippari"]),
    ],
    targets: [
        .target(name: "ClipboardCore"),
        .executableTarget(name: "Klippari", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
    ]
)
