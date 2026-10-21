// swift-tools-version: 6.0
import PackageDescription

// FED-201: Parakeet Ultra with FluidAudio's vocabulary boosting (a CTC keyword spotter over the audio, then rescoring
// of Parakeet's words), against the app's pinned FluidAudio checkout. Writes ../out/<run>.json for ../score.py.
//   swift run -c release parakeetvocab <run> mls|synth [--ctc 110m|06b] [--hotwords short|builtin]
let package = Package(
    name: "parakeetvocab",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../../DerivedDataSwipe/SourcePackages/checkouts/FluidAudio")],
    targets: [.executableTarget(name: "parakeetvocab", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                                swiftSettings: [.swiftLanguageMode(.v5)])]
)
