// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SketchMake",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SketchMake", targets: ["SketchMake"])],
    targets: [
        .target(name: "SketchCore"),
        .target(name: "SketchIO", dependencies: ["SketchCore"]),
        .target(name: "SketchUI", dependencies: ["SketchCore", "SketchIO"], path: "Sources/SketchMake"),
        .executableTarget(name: "SketchMake", dependencies: ["SketchUI"], path: "Sources/SketchLauncher"),
        .testTarget(name: "SketchCoreTests", dependencies: ["SketchCore"]),
        .testTarget(name: "SketchIOTests", dependencies: ["SketchIO", "SketchCore"]),
        .testTarget(name: "SketchUITests", dependencies: ["SketchUI", "SketchCore", "SketchIO"])
    ]
)
