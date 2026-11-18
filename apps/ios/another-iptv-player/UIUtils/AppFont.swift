import SwiftUI

/// ST5 — Bundled Arabic UI font helper.
///
/// Applies IBM Plex Sans Arabic (OFL, bundled in Resources/Fonts and registered
/// via UIAppFonts in App-Info.plist) ONLY when the app language is Arabic.
/// All other languages keep the system font untouched.
///
/// PostScript names read from the font files themselves (name ID 6):
///   Regular  -> "IBMPlexSansArabic-Regular"  (family "IBM Plex Sans Arabic")
///   SemiBold -> "IBMPlexSansArabic-SemiBold" (family "IBM Plex Sans Arabic")
enum AppFont {
    static let arabicRegularPostScriptName = "IBMPlexSansArabic-Regular"
    static let arabicSemiBoldPostScriptName = "IBMPlexSansArabic-SemiBold"

    /// True when the currently selected app language is Arabic.
    static var isArabic: Bool {
        LocalizationManager.shared.effectiveLanguageCode == "ar"
    }

    /// Returns the Arabic font at the given size when Arabic is active,
    /// otherwise the system font at the same size/weight so Latin layouts
    /// are completely unaffected.
    static func uiFont(size: CGFloat, semibold: Bool = false) -> Font {
        guard isArabic else {
            return .system(size: size, weight: semibold ? .semibold : .regular)
        }
        return .custom(semibold ? arabicSemiBoldPostScriptName : arabicRegularPostScriptName,
                       size: size)
    }
}
