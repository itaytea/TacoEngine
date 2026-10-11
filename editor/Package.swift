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
        // Tests as a plain executable, so they run with the command line tools alone: swift run enginekit-tests
        .executableTarget(name: "enginekit-tests", dependencies: ["EngineKit"], path: "Tests/EngineKitTests",
                          exclude: ["Fixtures"]),
    ]
)
