import Foundation
import Combine
import SwiftUI

/// Localization manager with runtime language switching.
/// Default = device language (when no setting exists). The user's choice is stored in UserDefaults.
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    /// Supported languages — the same as the l10n ARB files in the Flutter project.
    nonisolated static let supportedLanguages: [AppLanguage] = [
        .init(code: "system", nativeName: "Sistem Dili", englishName: "System"),
        .init(code: "en", nativeName: "English", englishName: "English"),
        .init(code: "tr", nativeName: "Türkçe", englishName: "Turkish"),
        .init(code: "ar", nativeName: "العربية", englishName: "Arabic"),
        .init(code: "de", nativeName: "Deutsch", englishName: "German"),
        .init(code: "es", nativeName: "Español", englishName: "Spanish"),
        .init(code: "fr", nativeName: "Français", englishName: "French"),
        .init(code: "hi", nativeName: "हिन्दी", englishName: "Hindi"),
        .init(code: "pt", nativeName: "Português", englishName: "Portuguese"),
        .init(code: "ru", nativeName: "Русский", englishName: "Russian"),
        .init(code: "zh", nativeName: "中文", englishName: "Chinese"),
    ]

    /// UserDefaults key — "system" veya iki harfli ISO 639-1 kod.
    private let storageKey = "app.selected_language"

    /// The user's choice. @Published so all views re-render when it changes.
    @Published var selectedLanguage: String {
        didSet {
            UserDefaults.standard.set(selectedLanguage, forKey: storageKey)
        }
    }

    private init() {
        self.selectedLanguage = UserDefaults.standard.string(forKey: storageKey) ?? "system"
    }

    /// The actively used language code — "system" resolves to the device language.
    var effectiveLanguageCode: String {
        if selectedLanguage == "system" {
            return Self.systemLanguageCode()
        }
        return selectedLanguage
    }

    /// The .lproj bundle for the selected language; falls back to English, then main.
    var bundle: Bundle {
        if let b = loadBundle(for: effectiveLanguageCode) {
            return b
        }
        if let fallback = loadBundle(for: "en") {
            return fallback
        }
        return .main
    }

    private func loadBundle(for code: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return nil
        }
        return bundle
    }

    /// Returns the string for the given key in the current language. If it is missing in the selected language, falls back to English, and if that is missing too,
    /// to the main bundle, and as a last resort to the key itself (for debugging).
    func string(for key: String) -> String {
        Self.resolveLocalizedString(for: key)
    }

    /// Actor-independent lookup — safe to call from nonisolated contexts such as LocalizedError.
    /// The selected language is read from UserDefaults (the `selectedLanguage` @Published value is already written to UserDefaults).
    nonisolated static func resolveLocalizedString(for key: String) -> String {
        let sentinel = "\u{1e}__missing__\u{1e}"
        let stored = UserDefaults.standard.string(forKey: "app.selected_language") ?? "system"
        let effective = stored == "system" ? systemLanguageCode() : stored

        if let bundle = nonisolatedBundle(for: effective) {
            let primary = bundle.localizedString(forKey: key, value: sentinel, table: nil)
            if primary != sentinel { return primary }
        }

        // If the key is missing in the selected language, fall back to English.
        if effective != "en", let en = nonisolatedBundle(for: "en") {
            let enValue = en.localizedString(forKey: key, value: sentinel, table: nil)
            if enValue != sentinel { return enValue }
        }

        return key
    }

    nonisolated private static func nonisolatedBundle(for code: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return nil
        }
        return bundle
    }

    // MARK: - System detection

    nonisolated private static func systemLanguageCode() -> String {
        // Preferred languages in order; find the first supported match.
        let supportedCodes = Set(supportedLanguages.map { $0.code }).subtracting(["system"])
        for lang in Locale.preferredLanguages {
            let base = Locale(identifier: lang).language.languageCode?.identifier ?? lang
            if supportedCodes.contains(base) {
                return base
            }
        }
        return "en"
    }
}

struct AppLanguage: Identifiable, Equatable {
    var id: String { code }
    let code: String
    let nativeName: String
    let englishName: String
}

/// Global helper — used in all views: e.g. `L("settings.title")`.
/// When the language changes, LocalizationManager publishes, the view re-renders, and L() picks up the new value.
/// `nonisolated` — can also be called from actor-independent contexts such as LocalizedError.
nonisolated func L(_ key: String) -> String {
    LocalizationManager.resolveLocalizedString(for: key)
}

/// Parametreli format helper: `L("episode_count", 10)` → `"10 episodes"`.
/// Uses `String.localizedStringWithFormat` so the plural rules in Localizable.stringsdict
/// (one/few/many/other) are applied — plain `String(format:)` ignores them
/// and produces wrong text such as "1 Days".
nonisolated func L(_ key: String, _ args: CVarArg...) -> String {
    let format = LocalizationManager.resolveLocalizedString(for: key)
    return withVaList(args) { NSString(format: format, locale: nil, arguments: $0) as String }
}
