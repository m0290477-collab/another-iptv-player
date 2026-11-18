import Foundation

/// Widget chrome labels.
///
/// The widget extension cannot read the app's Localizable.strings,
/// so its few fixed labels live in this table, keyed by language
/// code. All ten app languages are filled, matching the app's own
/// translations for the same concepts (the `widget.*` keys in
/// Localizable.strings). Lookup falls back to English.
enum WidgetLabels {
    private static let table: [String: [String: String]] = [
        "continueWatching": [
            "en": "Continue Watching",
            "tr": "İzlemeye Devam Et",
            "ar": "متابعة المشاهدة",
            "de": "Weiter ansehen",
            "es": "Seguir viendo",
            "fr": "Reprendre la lecture",
            "hi": "देखना जारी रखें",
            "pt": "Continuar Assistindo",
            "ru": "Продолжить просмотр",
            "zh": "继续观看",
        ],
        "favoriteChannels": [
            "en": "Favorite Channels",
            "tr": "Favori Kanallar",
            "ar": "القنوات المفضلة",
            "de": "Lieblingskanäle",
            "es": "Canales favoritos",
            "fr": "Chaînes favorites",
            "hi": "पसंदीदा चैनल",
            "pt": "Canais Favoritos",
            "ru": "Избранные каналы",
            "zh": "收藏频道",
        ],
        "onNow": [
            "en": "On Now",
            "tr": "Şu An Yayında",
            "ar": "يُعرض الآن",
            "de": "Jetzt läuft",
            "es": "Ahora",
            "fr": "En ce moment",
            "hi": "अभी चल रहा है",
            "pt": "Passando Agora",
            "ru": "Сейчас в эфире",
            "zh": "正在播出",
        ],
        "openSuperX": [
            "en": "Open Super X",
            "tr": "Super X'i Aç",
            "ar": "فتح Super X",
            "de": "Super X öffnen",
            "es": "Abrir Super X",
            "fr": "Ouvrir Super X",
            "hi": "Super X खोलें",
            "pt": "Abrir Super X",
            "ru": "Открыть Super X",
            "zh": "打开 Super X",
        ],
    ]

    static func text(_ key: String) -> String {
        let language = Locale.preferredLanguages.first?
            .prefix(2)
            .lowercased() ?? "en"
        if let value = table[key]?[String(language)] { return value }
        return table[key]?["en"] ?? key
    }
}
