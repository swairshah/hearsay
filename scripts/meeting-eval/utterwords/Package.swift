// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "utterwords",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The same FluidAudio checkout the app builds against (run an Xcode build first).
        .package(path: "../../../build/SourcePackages/checkouts/FluidAudio"),
    ],
    targets: [
        .executableTarget(
            name: "utterwords",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
