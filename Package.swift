// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Riftway",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RiftwayCore", targets: ["RiftwayCore"]),
        .executable(name: "riftway", targets: ["riftway"]),
        .executable(name: "riftway-shim", targets: ["RiftwayShim"]),
        // The Mac app's executable; scripts/build-app.sh wraps it in Riftway.app.
        .executable(name: "RiftwayApp", targets: ["RiftwayApp"]),
        // Release tooling: signing keys and the update feed. Not shipped in the app.
        .executable(name: "riftway-release", targets: ["RiftwayRelease"]),
        // Controller to keys and mouse (PRD-08); build-app.sh wraps it in Riftway Input.app.
        .executable(name: "riftway-input", targets: ["RiftwayInput"]),
    ],
    targets: [
        .target(name: "RiftwayCore"),
        .executableTarget(name: "riftway", dependencies: ["RiftwayCore"]),
        .executableTarget(name: "RiftwayShim", dependencies: ["RiftwayCore"]),
        .executableTarget(name: "RiftwayApp", dependencies: ["RiftwayCore"]),
        .executableTarget(name: "RiftwayRelease", dependencies: ["RiftwayCore"]),
        .executableTarget(name: "RiftwayInput", dependencies: ["RiftwayCore"]),
        .testTarget(name: "RiftwayCoreTests", dependencies: ["RiftwayCore"]),
    ]
)
