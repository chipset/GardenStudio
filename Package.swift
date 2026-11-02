// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GardenStudio",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GardenStudio", targets: ["GardenStudio"])],
    targets: [
        .target(name: "GardenStudioCore"),
        .target(name: "GardenStudioIO", dependencies: ["GardenStudioCore"]),
        .target(name: "GardenStudioUI", dependencies: ["GardenStudioCore", "GardenStudioIO"], path: "Sources/GardenStudioApp"),
        .executableTarget(name: "GardenStudio", dependencies: ["GardenStudioUI"], path: "Sources/GardenStudioLauncher"),
        .testTarget(name: "GardenStudioCoreTests", dependencies: ["GardenStudioCore"]),
        .testTarget(name: "GardenStudioIOTests", dependencies: ["GardenStudioIO", "GardenStudioCore"]),
        .testTarget(name: "GardenStudioUITests", dependencies: ["GardenStudioUI", "GardenStudioCore", "GardenStudioIO"])
    ]
)
