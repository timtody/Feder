import Foundation

/// What is left of the vocabulary merge (DictationTranscriber's terms over the accurate pass's words, removed with the
/// Dictation pass in FED-210; VocabularySpelling does the vocabulary now): the word comparison PipelineProgress uses
/// to tell a changed word from the same one.
nonisolated enum VocabularyMerge {
    /// Lowercased letters and digits only, diacritics folded: "MaRisk," -> "marisk", "Aufwands-" -> "aufwands".
    static func normalized(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
