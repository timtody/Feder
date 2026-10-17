// swift-tools-version: 6.2
import PackageDescription

// Mac bench for FED-142: Gemma 4 E4B on Google's LiteRT-LM against the app's Gemma 4 E2B on MLX, through the app's
// own TranscriptTitler and LocalLanguageModel (symlinked from Recorder/). The MLX pins are project.yml's. Run
// fetch-litertlm.sh once first.
// Build with xcodebuild (SwiftPM alone doesn't compile MLX's Metal shaders):
//   xcodebuild -scheme LiteRTBench -destination 'platform=macOS' -derivedDataPath .build/dd build
// The weights (models/) and the texts stay local, never committed.
let package = Package(
    name: "LiteRTBench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
    ],
    targets: [
        .executableTarget(
            name: "LiteRTBench",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                "LiteRTLM",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self), .define("DEBUG")]
        ),
        // LiteRT-LM v0.18.0's Swift wrapper and Mac library, fetched by fetch-litertlm.sh (its repository uses Git
        // LFS, which Xcode's git lacks, so SwiftPM can't resolve it as a package here).
        .binaryTarget(name: "CLiteRTLM", path: "vendor/CLiteRTLM_mac.xcframework"),
        .target(name: "LiteRTLM", dependencies: ["CLiteRTLM"], path: "vendor/LiteRTLM",
                swiftSettings: [.swiftLanguageMode(.v5)]),     // its own Package.swift is tools 5.9
    ]
)
