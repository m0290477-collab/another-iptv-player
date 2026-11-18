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

    // MARK: - Build 61 fixer (ST5 application)
    //
    // B11 bundled the font + this helper but no call site used them.
    // The application points are: the environment default at the app
    // root (ContentView), the tab labels, `SettingsGroupHeader` and
    // `CinematicSectionHeader`. Everything below preserves the Latin
    // rendering EXACTLY (system font, same style/weight/size) and
    // swaps in IBM Plex Sans Arabic only when the language is Arabic.

    /// Environment default for the app root: nil unless Arabic (a nil
    /// font modifier changes nothing), else the Arabic regular face
    /// at body size, Dynamic-Type-scaled relative to `.body`. Text
    /// with no hard-specified font picks this up; text that specifies
    /// its own system font keeps it (documented ST5 limit).
    static var environmentDefault: Font? {
        guard isArabic else { return nil }
        return .custom(arabicRegularPostScriptName, size: 17, relativeTo: .body)
    }

    /// Style-based variant for chrome that already names a text
    /// style: Latin returns the identical system style + weight;
    /// Arabic returns the matching Plex face (SemiBold for
    /// semibold-and-heavier weights), sized at the style's default
    /// point size and Dynamic-Type-scaled relative to that style.
    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        guard isArabic else {
            return .system(style, weight: weight)
        }
        let semibold = weight == .semibold || weight == .bold
            || weight == .heavy || weight == .black
        return .custom(semibold ? arabicSemiBoldPostScriptName : arabicRegularPostScriptName,
                       size: defaultPointSize(for: style),
                       relativeTo: style)
    }

    /// UIKit's default point sizes for the text styles (the size a
    /// `.custom(..., relativeTo:)` font starts from at the default
    /// Dynamic Type setting).
    private static func defaultPointSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        default: return 17
        }
    }
}
