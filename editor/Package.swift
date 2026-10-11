// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TacoEngine",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TacoEngine", targets: ["TacoEngine"]),
        .executable(name: "gbaexport", targets: ["gbaexport"]),
    ],
    targets: [
        .target(name: "EngineKit"),
        .executableTarget(name: "TacoEngine", dependencies: ["EngineKit"]),
        .executableTarget(name: "gbaexport", dependencies: ["EngineKit"]),
    ]
)
