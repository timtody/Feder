import Foundation

/// The language the next recording is transcribed in: chosen with the record accessory's language button, otherwise
/// the first language in the iPhone's Settings > Language & Region list. Before the button, every recording used the
/// phone's language, so an English meeting on a German iPhone was transcribed as German.
nonisolated enum TranscriptionLanguage {
    /// UserDefaults key: a BCP-47 identifier ("en-US"); absent means the phone's language.
    static let key = "transcriptionLanguage"

    /// The phone's language. `Locale.current` would be wrong: it reflects the app's own localization (English only),
    /// so on a German phone it is "en_DE" and the transcriber would pick the English model.
    static var phone: Locale { Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier) }

    /// The chosen language, or the phone's.
    static func locale(stored: String) -> Locale { stored.isEmpty ? phone : Locale(identifier: stored) }

    static var current: Locale { locale(stored: UserDefaults.standard.string(forKey: key) ?? "") }

    /// The menu's languages: the phone's own languages first, then the European languages Parakeet transcribes most
    /// often in this app's use (German, English, French, Spanish, Italian, Dutch), one per language.
    static var choices: [Locale] {
        var seen = Set<String>()
        let identifiers = Locale.preferredLanguages + ["de-DE", "en-US", "fr-FR", "es-ES", "it-IT", "nl-NL"]
        return identifiers.map(Locale.init(identifier:)).filter { locale in
            guard let code = locale.language.languageCode?.identifier else { return false }
            return seen.insert(code).inserted
        }
    }

    /// "German" (in English, like the rest of the UI).
    static func name(_ locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? locale.identifier
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// "DE", for the accessory's button.
    static func code(_ locale: Locale) -> String {
        (locale.language.languageCode?.identifier ?? locale.identifier).uppercased()
    }

    /// The stored value for `locale`: empty when it is the phone's language, so a change of the phone's language
    /// carries through.
    static func stored(for locale: Locale) -> String {
        locale.language.languageCode == phone.language.languageCode ? "" : locale.identifier(.bcp47)
    }
}
