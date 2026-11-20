import Foundation

/// Zweisprachige Oberfläche (Deutsch/Englisch). Die Texte stehen direkt am Verwendungsort:
/// `tr("Einstellungen", "Settings")`. Bei nur zwei Sprachen ist das übersichtlicher als
/// Schlüssel in .strings-Dateien und erlaubt einen Sprachwechsel ohne Neustart.
enum Lang: String {
    case de, en
}

/// Einstellung in der App und im Hook (`SPEAK_LANGUAGE` in der config): system | de | en
enum LanguagePreference: String, CaseIterable, Identifiable {
    case system, de, en
    var id: String { rawValue }

    var resolved: Lang {
        switch self {
        case .de: return .de
        case .en: return .en
        case .system:
            // Wie im Hook: Deutsch, wenn es die bevorzugte Sprache ist, sonst Englisch
            return (Locale.preferredLanguages.first ?? "en").hasPrefix("de") ? .de : .en
        }
    }

    var label: String {
        switch self {
        case .system: return tr("Systemsprache", "System language") + " (\(LanguagePreference.system.resolved == .de ? "Deutsch" : "English"))"
        case .de: return "Deutsch"
        case .en: return "English"
        }
    }
}

enum L10n {
    nonisolated(unsafe) static var lang: Lang = LanguagePreference(rawValue: HookConfig.load().language)?.resolved ?? .de
}

func tr(_ de: String, _ en: String) -> String {
    L10n.lang == .de ? de : en
}
