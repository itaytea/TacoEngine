// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TacoMaker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TacoMaker", targets: ["TacoMaker"]),
        .executable(name: "gbaexport", targets: ["gbaexport"]),
    ],
    targets: [
        .target(name: "EngineKit"),
        .executableTarget(name: "TacoMaker", dependencies: ["EngineKit"]),
        .executableTarget(name: "gbaexport", dependencies: ["EngineKit"]),
    ]
)
