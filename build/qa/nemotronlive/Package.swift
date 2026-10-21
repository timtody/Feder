// swift-tools-version: 6.0
import PackageDescription

// FED-196: Nemotron 3.5 ASR Streaming (FluidAudio, the app's pinned checkout) on the Mac, the way Feder's
// NemotronLiveTranscriber streams it: 100 ms buffers, token timings to words, all but the last word final.
//   swift run -c release nemotronlive wer <clips.json> [limit]      word errors on real clips (DiarBench's MLS)
//   swift run -c release nemotronlive stream <file.wav>…            the live words and their delay
let package = Package(
    name: "nemotronlive",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../DerivedDataSwipe/SourcePackages/checkouts/FluidAudio")],
    targets: [.executableTarget(name: "nemotronlive", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                                swiftSettings: [.swiftLanguageMode(.v5)])]
)
