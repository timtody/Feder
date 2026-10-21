import UIKit

/// The system's spell checker (UITextChecker: the keyboard's dictionaries, on the device) for VocabularySpelling's near
/// misses: a heard word may only become a vocabulary term when it isn't a word in the recording's language, so
/// "Marisa", "Bahn" or "digitalisieren" stay. Main actor (UIKit); it gets only the few words a near miss would change.
@MainActor
enum SpellCheck {
    /// Those of `words` the spell checker doesn't know in `locale`'s language; none when it has no dictionary for the
    /// language (then no near miss is fixed, the safe side).
    static func nonWords(in words: Set<String>, locale: Locale) -> Set<String> {
        guard !words.isEmpty, let language = language(for: locale) else { return [] }
        let checker = UITextChecker()
        return words.filter { word in
            checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: (word as NSString).length),
                                          startingAt: 0, wrap: false, language: language).location != NSNotFound
        }
    }

    /// The checker's identifier for the locale ("de_DE"): the same region if it has one, else any of the language.
    static func language(for locale: Locale) -> String? {
        let available = UITextChecker.availableLanguages
        let code = locale.language.languageCode?.identifier
        let region = locale.region?.identifier
        let candidates = available.filter { Locale(identifier: $0).language.languageCode?.identifier == code }
        return candidates.first { Locale(identifier: $0).region?.identifier == region } ?? candidates.first
    }
}
