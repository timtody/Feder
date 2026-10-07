import Foundation

/// The language the next recording is transcribed in: chosen with the record accessory's language button, otherwise
/// German on a German iPhone and English on every other (`standard`). Before the button, every recording used the
/// phone's language, so an English meeting on a German iPhone was transcribed as German.
nonisolated enum TranscriptionLanguage {
    /// UserDefaults key: a BCP-47 identifier ("en-US"); absent means `standard`.
    static let key = "transcriptionLanguage"

    /// The phone's first language. `Locale.current` would be wrong: it reflects the app's own localization (English
    /// or German), so on a phone set to French it is "en_FR".
    static var phone: Locale { Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier) }

    /// The language a recording gets when none was picked: the phone's when it is German or English (with its region,
    /// "de-AT", "en-GB"), English otherwise, as the app's own texts are.
    static var standard: Locale {
        let phone = phone
        switch phone.language.languageCode?.identifier {
        case "de", "en": return phone
        default: return Locale(identifier: "en-US")
        }
    }

    /// The chosen language, or `standard`.
    static func locale(stored: String) -> Locale { stored.isEmpty ? standard : Locale(identifier: stored) }

    static var current: Locale { locale(stored: UserDefaults.standard.string(forKey: key) ?? "") }

    /// The menu's languages: the phone's own languages first, then the European languages transcribed most
    /// often in this app's use (German, English, French, Spanish, Italian, Dutch), one per language.
    static var choices: [Locale] {
        var seen = Set<String>()
        let identifiers = Locale.preferredLanguages + ["de-DE", "en-US", "fr-FR", "es-ES", "it-IT", "nl-NL"]
        return identifiers.map(Locale.init(identifier:)).filter { locale in
            guard let code = locale.language.languageCode?.identifier else { return false }
            return seen.insert(code).inserted
        }
    }

    /// "German" or "Deutsch": in the app's language (`AppLanguage`), like the rest of the UI.
    static func name(_ locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? locale.identifier
        return AppLanguage.locale.localizedString(forLanguageCode: code) ?? code   // "German" / "Deutsch"
    }

    /// "DE", for the accessory's button.
    static func code(_ locale: Locale) -> String {
        (locale.language.languageCode?.identifier ?? locale.identifier).uppercased()
    }

    /// The stored value for `locale`: empty when it is the standard language, so a change of the phone's language
    /// carries through.
    static func stored(for locale: Locale) -> String {
        locale.language.languageCode == standard.language.languageCode ? "" : locale.identifier(.bcp47)
    }
}
