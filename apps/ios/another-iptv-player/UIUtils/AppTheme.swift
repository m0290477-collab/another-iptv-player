import Combine
import SwiftUI
import UIKit

/// Cinematic Dark design tokens (owner-picked "Style 1").
///
/// Central palette for the whole app: near-black backgrounds, dark card
/// surfaces, white primary text (via `.primary` under the forced dark
/// scheme), one blue accent (the asset-catalog `AccentColor`), and red
/// reserved for LIVE indicators only. Screens should use these tokens
/// instead of ad-hoc colors so the design stays consistent.
enum AppTheme {
    /// App-wide near-black background (#0B0B10).
    static let background = Color(red: 0.043, green: 0.043, blue: 0.063)
    /// Card / shelf surface (#16161D).
    static let surface = Color(red: 0.086, green: 0.086, blue: 0.114)
    /// Raised surface for sheets-on-sheets, chips and placeholders (#1E1E27).
    static let elevated = Color(red: 0.118, green: 0.118, blue: 0.153)
    /// The app accent — user-selectable since round 7 (Settings → App →
    /// Accent Color); defaults to the design blue #0A84FF. Views read the
    /// accent through this token; the root view observes
    /// `AccentThemeStore`, so a picker change re-renders the hierarchy
    /// and every read here picks up the new color (UIKit chrome is
    /// re-applied separately via `AppChrome.apply()`).
    static var accent: Color { AccentThemeStore.shared.color }
    /// LIVE badge / live-now indicator red (#E82A2E). Nothing else uses red
    /// except destructive actions, which keep the system red.
    static let live = Color(red: 0.910, green: 0.165, blue: 0.180)

    /// Rating gold (round 8): the ONE source for the rating star and the
    /// favorite star. Before round 8 the value was a hardcoded `.yellow`
    /// literal in seven places; the token wraps the exact same system
    /// yellow, so nothing renders differently — it just has one home now.
    /// Semantic like `live`: the accent picker never recolors it.
    static let ratingGold: Color = .yellow

    /// Generous corner radius used by cards and tiles in the design.
    static let cornerRadius: CGFloat = 14
    /// Hero / featured-art radius (round 8): the large 16:9 surfaces
    /// (Home featured slide, Live hero card). Named token for the value
    /// those surfaces already used, so the radius scale has one home.
    static let heroCornerRadius: CGFloat = 20
    /// Small-element radius (round 8): thumbnails, count chips, badges
    /// and compact buttons — the value those elements already used (8),
    /// tokenized; off-scale literals (4/6/10/12/16 on small elements)
    /// were mapped to the nearest token in the round-8 sweep.
    static let smallCornerRadius: CGFloat = 8

    // MARK: Round 14/15 tokens (B9 / C9 / C12)

    /// Font tokens (B9) — main surfaces use these instead of ad-hoc
    /// `.system(size: 10)` literals.
    static let fontSectionTitle: Font = .title2.weight(.bold)
    static let fontCardTitle: Font = .subheadline.weight(.semibold)
    static let fontMetadata: Font = .caption
    static let fontBadge: Font = .caption2.weight(.bold)

    /// Spacing tokens (B9).
    static let spacingScreenMargin: CGFloat = 16
    static let spacingShelfGap: CGFloat = 24
    static let spacingCardGap: CGFloat = 12

    /// The ONE card border token (B9): a hairline white at ~6% so
    /// posters separate from the near-black background.
    static let cardBorderColor = Color.white.opacity(0.06)
    /// Card surface shadow token (B9).
    static let cardShadowColor = Color.black.opacity(0.35)
    static let cardShadowRadius: CGFloat = 12
    static let cardShadowY: CGFloat = 4

    /// C12 seasonal glow (cosmetic, subtle): a soft accent-derived tint
    /// for selected-tab under-glow and similar accents. Derived from the
    /// user's current accent — never a fixed seasonal color.
    static var seasonalGlow: Color { accent.opacity(0.18) }
    /// Stronger cut of the same derived glow for the selected tab icon.
    static var tabGlow: Color { accent.opacity(0.55) }

    /// C9 iPad hover token (scale applied by `cardHover()` in Motion.swift).
    static let hoverScale: CGFloat = 1.02

    /// The app's chosen language as a Locale (C9 one-locale law):
    /// formatters bind to THIS, never to the device locale. Reads the
    /// same UserDefaults key LocalizationManager persists; "system"
    /// resolves through the preferred languages like the manager does.
    static var appLocale: Locale {
        let stored = UserDefaults.standard.string(forKey: "app.selected_language") ?? "system"
        if stored != "system" { return Locale(identifier: stored) }
        let supported: Set<String> = ["en", "tr", "ar", "de", "es", "fr", "hi", "pt", "ru", "zh"]
        for lang in Locale.preferredLanguages {
            let base = Locale(identifier: lang).language.languageCode?.identifier ?? lang
            if supported.contains(base) { return Locale(identifier: base) }
        }
        return Locale(identifier: "en")
    }
}

/// Per-section identity colors (B9 / owner point 7). LIVE keeps the
/// reserved red; Movies follows the user's accent; Series is a
/// hue-shifted derivative of the CURRENT accent preset — computed from
/// `AccentThemeStore`, never a hard-coded violet (the old hard-coded
/// violet Series tile is exactly what this replaces).
enum SectionTheme {
    static var live: Color { AppTheme.live }
    static var movies: Color { AppTheme.accent }
    static var series: Color {
        let ui = AccentThemeStore.shared.uiColor
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return AppTheme.accent
        }
        // +40° hue rotation: clearly a sibling of the accent, clearly
        // not the accent itself, for every preset.
        let shifted = UIColor(hue: (h + 40.0 / 360.0).truncatingRemainder(dividingBy: 1),
                              saturation: s, brightness: b, alpha: a)
        return Color(uiColor: shifted)
    }
}

/// Symbol table (C9): concept → SF Symbol + weight + rendering mode.
/// One "previous" language app-wide; the player concepts are covered
/// first so the player agents adopt these instead of picking per-view.
enum AppSymbols {
    struct Spec {
        let name: String
        let weight: Font.Weight
        let renderingMode: SymbolRenderingMode
    }

    static let defaultWeight: Font.Weight = .semibold
    static let defaultRenderingMode: SymbolRenderingMode = .monochrome

    static let play = Spec(name: "play.fill", weight: .semibold, renderingMode: .monochrome)
    static let pause = Spec(name: "pause.fill", weight: .semibold, renderingMode: .monochrome)
    static let previous = Spec(name: "backward.end.fill", weight: .semibold, renderingMode: .monochrome)
    static let next = Spec(name: "forward.end.fill", weight: .semibold, renderingMode: .monochrome)
    static let seekBack = Spec(name: "gobackward.10", weight: .semibold, renderingMode: .monochrome)
    static let seekForward = Spec(name: "goforward.10", weight: .semibold, renderingMode: .monochrome)
    static let favorite = Spec(name: "star.fill", weight: .semibold, renderingMode: .monochrome)
    static let favoriteOff = Spec(name: "star", weight: .semibold, renderingMode: .monochrome)
    static let pip = Spec(name: "pip.enter", weight: .semibold, renderingMode: .monochrome)
    static let pipExit = Spec(name: "pip.exit", weight: .semibold, renderingMode: .monochrome)
    static let airplay = Spec(name: "airplayvideo", weight: .semibold, renderingMode: .monochrome)
    static let cast = Spec(name: "tv.badge.wifi", weight: .semibold, renderingMode: .monochrome)
    static let close = Spec(name: "xmark", weight: .semibold, renderingMode: .monochrome)
    static let settings = Spec(name: "gearshape.fill", weight: .semibold, renderingMode: .monochrome)
    static let search = Spec(name: "magnifyingglass", weight: .semibold, renderingMode: .monochrome)
    static let download = Spec(name: "arrow.down.circle", weight: .semibold, renderingMode: .monochrome)
    static let liveBadge = Spec(name: "dot.radiowaves.left.and.right", weight: .bold, renderingMode: .monochrome)
}

// Round 16 (R5): the orphaned StyledEmptyState component is
// removed — zero call sites; screens keep their own inline
// empty states, as they already did.


// MARK: - Accent color (round 7)

/// Owner-facing accent presets (Settings → App → Accent Color). The
/// default is the design blue. Semantic colors never follow this
/// picker: the LIVE badge keeps `AppTheme.live` red and the rating
/// star keeps its gold.
enum AccentPreset: String, CaseIterable {
    case blue, violet, pink, red, orange, green, teal

    private var components: (r: Double, g: Double, b: Double) {
        switch self {
        case .blue: return (0.039, 0.518, 1.000)   // #0A84FF
        case .violet: return (0.486, 0.361, 1.000) // #7C5CFF
        case .pink: return (1.000, 0.216, 0.373)   // #FF375F
        // Round 15 (C9): shifted from #FF453A to a coral/scarlet
        // #FF5A2E — still clearly a red-family accent, but its hue
        // (~16°) is visibly distinct from the reserved LIVE red
        // #E82A2E (~357°), so a red-accent user can still tell a LIVE
        // badge apart from accent chrome at a glance.
        case .red: return (1.000, 0.353, 0.180)    // #FF5A2E
        case .orange: return (1.000, 0.624, 0.039) // #FF9F0A
        case .green: return (0.188, 0.820, 0.345)  // #30D158
        case .teal: return (0.251, 0.784, 0.878)   // #40C8E0
        }
    }

    var color: Color {
        Color(red: components.r, green: components.g, blue: components.b)
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(components.r), green: CGFloat(components.g), blue: CGFloat(components.b), alpha: 1)
    }

    /// Localizable.strings key for the preset's name.
    var nameKey: String { "settings.accent.\(rawValue)" }
}

/// The single source of truth for the app accent. Persisted in
/// UserDefaults; the root view observes the shared instance, so setting
/// `preset` repaints every SwiftUI surface that reads `AppTheme.accent`
/// or the environment accent, and re-applies the UIKit chrome (tab bar
/// / nav bar tints). It touches no catalog state — a color change never
/// triggers a recompute.
final class AccentThemeStore: ObservableObject {
    static let shared = AccentThemeStore()
    private static let storageKey = "app.accent_preset"

    @Published var preset: AccentPreset {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: Self.storageKey)
            AppChrome.apply()
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey)
        preset = AccentPreset(rawValue: raw ?? "") ?? .blue
    }

    var color: Color { preset.color }
    var uiColor: UIColor { preset.uiColor }
}

// MARK: - Motion (round 3)
//
// Professional polish with a hard performance budget: one-shot, view-local
// animations only. No repeating animations, no timers, no blur stacks —
// the catalog is huge and shelf scrolling must stay smooth.

/// Subtle scale-down press feedback for plain-style buttons (hero card,
/// "See all" links). Replaces `.plain` where tactile feedback is wanted;
/// the wrapped action/navigation is unchanged.
struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Round 14 (B12): card press = scale 0.94 on the shared press
        // spring, routed through the one Motion helper (instant under
        // Reduce Motion / motion .off).
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(Motion.animate(Motion.pressSpring), value: configuration.isPressed)
    }
}

/// One-shot shelf-card entrance: fade in with a rise the first time a
/// card's view appears, with a per-index stagger. Round 5 strengthens
/// round 3's version — the owner rated the subtle 10 pt / 0.35 s package
/// as "zero effects": the rise is now 20 pt, the duration 0.5 s, and the
/// stagger 0.05 s. Still one-shot and view-local: cards at index ≥ 12
/// render already-shown (no animation), so recycled cells deep in a long
/// shelf never replay a wave during scrolling. No repeating work, no
/// timers, no blur.
struct ShelfCardAppearModifier: ViewModifier {
    let index: Int
    @State private var shown = false
    /// Round 12 (point 7): honor Reduce Motion — with it on, cards
    /// render already-shown (no fade, no rise, no stagger).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { index < 12 && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .opacity(shown || !animates ? 1 : 0)
            .offset(y: shown || !animates ? 0 : 20)
            .onAppear {
                guard animates, !shown else { return }
                withAnimation(.easeOut(duration: 0.5).delay(Double(min(index, 8)) * 0.05)) {
                    shown = true
                }
            }
    }
}



extension View {
    /// One-shot fade-and-rise entrance for a shelf card at `index`.
    func shelfCardAppear(index: Int) -> some View {
        modifier(ShelfCardAppearModifier(index: index))
    }

    /// Paints the cinematic near-black background behind a screen.
    func cinematicBackground() -> some View {
        background(AppTheme.background.ignoresSafeArea())
    }

    /// For `List` / `Form` screens: hides the system scroll background and
    /// paints the cinematic near-black background instead, so rows/cards sit
    /// on the design surface.
    func cinematicScrollBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
    }
}

/// UIKit chrome (tab bar / navigation bar) matching the cinematic design.
/// Applied once at app launch from the app delegate; SwiftUI screens keep
/// using semantic colors under the forced dark color scheme.
enum AppChrome {
    static func apply() {
        let background = UIColor(red: 0.043, green: 0.043, blue: 0.063, alpha: 1)
        // Round 7: the chrome accent follows the user's picker choice.
        let accent = AccentThemeStore.shared.uiColor
        let muted = UIColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)

        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = background
        for itemAppearance in [tabBar.stackedLayoutAppearance,
                               tabBar.inlineLayoutAppearance,
                               tabBar.compactInlineLayoutAppearance] {
            itemAppearance.normal.iconColor = muted
            itemAppearance.normal.titleTextAttributes = [.foregroundColor: muted]
            itemAppearance.selected.iconColor = accent
            itemAppearance.selected.titleTextAttributes = [.foregroundColor: accent]
        }
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar

        let navBar = UINavigationBarAppearance()
        navBar.configureWithDefaultBackground()
        navBar.titleTextAttributes = [.foregroundColor: UIColor.white]
        navBar.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = navBar
        UINavigationBar.appearance().scrollEdgeAppearance = navBar
        UINavigationBar.appearance().compactAppearance = navBar
        UINavigationBar.appearance().tintColor = accent
    }
}
