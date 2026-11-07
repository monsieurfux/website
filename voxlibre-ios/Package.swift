// swift-tools-version:5.9
import PackageDescription

// The platform-independent protocol/library core. The very same files under
// Sources/VoxLibreCore are also compiled straight into the iOS app target (see project.yml),
// so nothing here needs `public`. This package exists so the core can be unit-tested with a
// plain `swift test` on a Mac, without a simulator.
let package = Package(
    name: "VoxLibreCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "VoxLibreCore", targets: ["VoxLibreCore"]),
    ],
    targets: [
        .target(name: "VoxLibreCore", path: "Sources/VoxLibreCore"),
        .testTarget(
            name: "VoxLibreCoreTests",
            dependencies: ["VoxLibreCore"],
            path: "Tests/VoxLibreCoreTests"
        ),
    ]
)
