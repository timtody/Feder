// swift-tools-version: 6.2
// Scratch bench (gitignored): streams the DiarBench meetings through the app's own LSEENDLiveDiarizer and
// SortformerLiveDiarizer (symlinked from the worktree) and scores the live labels with the app's TranscriptAligner.
import PackageDescription
let package = Package(
    name: "sfbench",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "/Users/julius.taylor/projects/recorder/build/DerivedDataSwipe/SourcePackages/checkouts/FluidAudio")],
    targets: [.executableTarget(
        name: "sfbench",
        dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
        swiftSettings: [
            .swiftLanguageMode(.v6),
            .defaultIsolation(MainActor.self),                       // as the app (SWIFT_DEFAULT_ACTOR_ISOLATION)
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .enableUpcomingFeature("MemberImportVisibility"),
        ])]
)
