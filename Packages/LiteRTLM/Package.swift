// swift-tools-version: 5.9
import PackageDescription

// Google's LiteRT-LM v0.18.0 (Apache 2.0, LICENSE) for Feder Lab and the Mac model bench (FED-142, FED-150): its Swift
// wrapper (Sources/LiteRTLM, copied unchanged from the tag's swift/ folder, tests and the Foundation Models adapter left
// out) and the release's prebuilt libraries, fetched by URL and checked against the checksums in the tag's
// Package.swift. Local instead of `.package(url:)`: the repository uses Git LFS, which Xcode's git lacks, so SwiftPM
// can't resolve it. The iPhone library is 61.6 MB (17.6 MB compressed), dynamic, linking Metal.
let package = Package(
    name: "LiteRTLM",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "LiteRTLM", targets: ["LiteRTLM"]),
    ],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.0/CLiteRTLM.xcframework.zip",
            checksum: "d765b99592d4ec3d0c9e2bd69469454af06c834861340672da1891c0c121c347"
        ),
        .binaryTarget(
            name: "CLiteRTLM_mac",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.0/CLiteRTLM_mac.xcframework.zip",
            checksum: "5f6ee68d95eeccb084c6e66d5ee47255e3020fa0fb29696dd0301ae26d6cfb4f"
        ),
        .target(
            name: "LiteRTLM",
            dependencies: [
                .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
                .target(name: "CLiteRTLM_mac", condition: .when(platforms: [.macOS])),
            ]
        ),
    ]
)
