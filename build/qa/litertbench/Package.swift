// swift-tools-version: 6.2
import PackageDescription

// Mac bench for FED-142: Gemma 4 E4B on Google's LiteRT-LM against the app's Gemma 4 E2B on MLX, through the app's
// own TranscriptTitler, LocalLanguageModel and LiteRTLanguageModel (symlinked from Recorder/; LITERT defined as in
// Feder Lab). The MLX pins are project.yml's; LiteRT-LM is the app's local package (Packages/LiteRTLM).
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
        .package(path: "../../../Packages/LiteRTLM"),
    ],
    targets: [
        .executableTarget(
            name: "LiteRTBench",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "LiteRTLM", package: "LiteRTLM"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self), .define("DEBUG"), .define("LITERT")]
        ),
    ]
)
