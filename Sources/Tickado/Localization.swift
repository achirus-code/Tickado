import Foundation

/// Übersetzung der Oberfläche. Schlüssel ist der englische Text; fehlt eine Übersetzung, bleibt er Englisch.
/// Zahlen und Preise folgen weiter der Region des Systems, nur die Texte folgen der gewählten Sprache.
enum L10n {
    /// Unterstützte Sprachen (nur links-nach-rechts, damit das Layout nicht gespiegelt werden muss).
    static let languages = [
        "en", "de", "fr", "es", "it", "pt", "nl", "pl", "cs", "sv", "da", "nb", "fi",
        "tr", "ru", "uk", "el", "hu", "ro", "ja", "ko", "zh-Hans", "zh-Hant", "id", "vi",
    ]

    private static let translations: [String: [String: String]] = [
        "de": de, "fr": fr, "es": es, "it": it, "pt": pt, "nl": nl, "pl": pl, "cs": cs, "sv": sv,
        "da": da, "nb": nb, "fi": fi, "tr": tr, "ru": ru, "uk": uk, "el": el, "hu": hu, "ro": ro,
        "ja": ja, "ko": ko, "zh-Hans": zhHans, "zh-Hant": zhHant, "id": id, "vi": vi,
    ]

    // Wird nur auf dem Main Thread gesetzt, gelesen auch aus Netzwerk-Fehlermeldungen.
    nonisolated(unsafe) private(set) static var code = "en"
    nonisolated(unsafe) fileprivate static var table: [String: String] = [:]

    /// `preference`: gespeicherte Sprache, nil = Systemsprache.
    static func apply(_ preference: String?) {
        code = preference.flatMap { languages.contains($0) ? $0 : nil } ?? systemLanguage
        table = translations[code] ?? [:]
    }

    static var locale: Locale { Locale(identifier: code) }

    /// Erste bevorzugte Sprache des Systems, die Tickado kann; sonst Englisch.
    static var systemLanguage: String {
        for identifier in Locale.preferredLanguages {
            let language = Locale.Language(identifier: identifier)
            guard let code = language.languageCode?.identifier else { continue }
            switch code {
            case "zh":
                let traditional = language.script?.identifier == "Hant"
                    || ["TW", "HK", "MO"].contains(language.region?.identifier ?? "")
                return traditional ? "zh-Hant" : "zh-Hans"
            case "nb", "nn", "no":
                return "nb"
            default:
                if languages.contains(code) { return code }
            }
        }
        return "en"
    }

    /// Name der Sprache in ihr selbst ("Deutsch", "日本語").
    static func name(of code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}

/// Übersetzter Text zum englischen Schlüssel.
func L(_ key: String) -> String {
    L10n.table[key] ?? key
}

/// Übersetzter Text mit Platzhaltern (%@, %d).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: L10n.locale, arguments: args)
}
