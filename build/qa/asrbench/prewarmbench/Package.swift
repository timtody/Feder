// swift-tools-version: 6.0
import PackageDescription

// FED-212: what prewarming Parakeet saves after Stop, by recording length. One measurement per process (run.sh):
//   prewarmbench words <file.wav>     Parakeet Ultra as the app runs it: load, then AsrManager.transcribe (German)
//   prewarmbench speakers <file.wav>  Nemotron 3 (c128-split-w8a8) as NemotronDiarizer runs it, loaded beforehand
// Prints one JSON line. Against the app's pinned FluidAudio checkout.
let package = Package(
    name: "prewarmbench",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../../DerivedDataSwipe/SourcePackages/checkouts/FluidAudio")],
    targets: [.executableTarget(name: "prewarmbench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                                swiftSettings: [.swiftLanguageMode(.v5)])]
)
