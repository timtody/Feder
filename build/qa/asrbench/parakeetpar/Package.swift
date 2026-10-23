// swift-tools-version: 6.0
import PackageDescription

// Can Parakeet go faster with more parallelism? Times the app's call (AsrManager.transcribe, German, Ultra) on one long
// file at several chunk concurrencies, the model load on its own, and two separately loaded model copies (Neural
// Engine + GPU) each on half of the file. Against the app's pinned FluidAudio checkout.
//   swift run -c release parakeetpar audio/meeting18.wav   (audio/: six DiarBench meetings joined, see README.txt)
let package = Package(
    name: "parakeetpar",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../../DerivedDataSwipe/SourcePackages/checkouts/FluidAudio")],
    targets: [.executableTarget(name: "parakeetpar", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                                swiftSettings: [.swiftLanguageMode(.v5)])]
)
