// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "bench",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "/Users/julius.taylor/projects/recorder/build/DerivedDataSwipe/SourcePackages/checkouts/FluidAudio")],
    targets: [.executableTarget(name: "bench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                                swiftSettings: [.swiftLanguageMode(.v5)])]
)
