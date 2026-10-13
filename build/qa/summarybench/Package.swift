// swift-tools-version: 6.2
import PackageDescription

// Mac bench for Feder's summaries (README › Summary styles): the app's TranscriptTitler, SummaryStyle and
// LocalLanguageModel (symlinked from Recorder/, with what they use) running Gemma 4 E2B with MLX on the Mac's GPU.
// The pins are project.yml's. Build with xcodebuild (SwiftPM alone doesn't compile MLX's Metal shaders):
//   xcodebuild -scheme SummaryBench -destination 'platform=macOS' -derivedDataPath .build/dd build
// The weights (mlx-community/gemma-4-e2b-it-4bit) and the texts stay local, never committed.
let package = Package(
    name: "SummaryBench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
    ],
    targets: [
        .executableTarget(
            name: "SummaryBench",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self), .define("DEBUG")]
        ),
    ]
)
