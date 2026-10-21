// swift-tools-version: 6.0
import PackageDescription

// FED-204: the app's VocabularySpelling (copied in by run.sh) on saved recognizer output, with macOS's spell checker in
// place of UITextChecker. ./run.sh <in.json> <out.json> <terms.json>
let package = Package(
    name: "spellfix",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "spellfix", swiftSettings: [.swiftLanguageMode(.v5)])]
)
