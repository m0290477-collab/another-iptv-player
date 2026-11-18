import SwiftUI
import UIKit

// MARK: - Motion (Rounds 14/15, B12 + C5 + C12)
//
// The ONE motion helper for the whole app. Transform/opacity only — no
// blur stacks, no repeating timers except where a spec item explicitly
// asks for a pulse. The user's intensity choice (Settings, C5) is read
// from UserDefaults key "motion.intensity" ("full" / "reduced" / "off",
// default "full"); the system Reduce Motion setting always wins and
// forces the effective intensity to at most .reduced, and per B12
// Reduce Motion collapses animations to instant (nil).

enum MotionIntensity {
    case full, reduced, off
}

enum Motion {
    /// UserDefaults key written by the Settings motion picker (C5).
    static let intensityKey = "motion.intensity"

    static var intensity: MotionIntensity {
        let stored: MotionIntensity
        switch UserDefaults.standard.string(forKey: intensityKey) {
        case "reduced": stored = .reduced
        case "off": stored = .off
        default: stored = .full
        }
        // System Reduce Motion forces at most .reduced.
        if UIAccessibility.isReduceMotionEnabled, stored == .full {
            return .reduced
        }
        return stored
    }

    /// Returns the animation to run, or nil when the change must be
    /// instant: intensity .off, or system Reduce Motion (B12: Reduce
    /// Motion collapses to instant — short fades included).
    static func animate(_ base: Animation) -> Animation? {
        if intensity == .off { return nil }
        if UIAccessibility.isReduceMotionEnabled { return nil }
        return base
    }

    /// Tab switch (B12): fade 0.28 s. The directional 6 pt slide is
    /// applied by the dashboards alongside this animation. Instant
    /// (zero-duration) when motion is off or Reduce Motion is on.
    static var tabFade: Animation {
        animate(.easeInOut(duration: 0.28)) ?? .linear(duration: 0)
    }

    /// Shelf entrance spring (B12): response 0.55, damping 0.85.
    static var shelfSpring: Animation {
        .spring(response: 0.55, dampingFraction: 0.85)
    }

    /// Card/hero press spring (B12: hero buttons scale 0.92, cards 0.94).
    static var pressSpring: Animation {
        .spring(response: 0.32, dampingFraction: 0.72)
    }
}

// MARK: - Haptics (B12 map)

/// Light selection on tab change, success on favorite / refresh
/// completion, error on the failure surface. Suppressed entirely when
/// the user's motion intensity is .off.
enum Haptics {
    static func selection() {
        guard Motion.intensity != .off else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        guard Motion.intensity != .off else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        guard Motion.intensity != .off else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - Shelf entrance (B12 amplitude, replayable)

/// Shelf entrance with the B12 amplitude: rise 28 pt, `Motion.shelfSpring`,
/// stagger 0.06 s per index. A LIGHT version (rise 10 pt, no stagger)
/// replays whenever `replayToken` changes — the section views bump the
/// token on each tab return, so the entrance is not once-ever. Transform
/// and opacity only. Indices ≥ 12 render already-shown so recycled cells
/// deep in a long shelf never replay a wave while scrolling.
struct ShelfEntranceModifier: ViewModifier {
    let index: Int
    let replayToken: Int
    @State private var shown = false
    @State private var rise: CGFloat = 28
    @State private var lastToken: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Build 61 fixer (X3→Q21): the staggered entrance now reads the
    // SAME EffectsGate as every other B7 effect — Reduce Motion +
    // `appearance.reduceEffects` (Q21) + motion intensity. Before,
    // this modifier read Motion/Reduce-Motion only, so entrances
    // still animated under Q21 (critic F-5).
    private var animates: Bool {
        index < 12 && EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : rise)
            .onAppear {
                if lastToken == nil { lastToken = replayToken }
                guard animates, !shown else { shown = true; return }
                withAnimation(Motion.shelfSpring.delay(Double(min(index, 8)) * 0.06)) {
                    shown = true
                }
            }
            .onChange(of: replayToken) { _, newToken in
                guard animates, lastToken != nil, newToken != lastToken else {
                    lastToken = newToken
                    return
                }
                lastToken = newToken
                // Light replay on tab return: small rise, no stagger.
                rise = 10
                shown = false
                withAnimation(Motion.shelfSpring) { shown = true }
            }
    }
}

// MARK: - iPad hover (C9)

/// One hover token for cards/buttons on iPad, reusing the press style's
/// language: a slight scale up plus the card border in the accent.
/// No-op on iPhone (no hover) and instant under Reduce Motion / .off.
struct CardHoverModifier: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? AppTheme.hoverScale : 1)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(hovering ? AppTheme.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .animation(Motion.animate(Motion.pressSpring), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// B12 shelf entrance (rise 28 pt, shelfSpring, stagger 0.06);
    /// bump `replayToken` to replay the light version (tab return).
    func shelfEntrance(index: Int, replayToken: Int = 0) -> some View {
        modifier(ShelfEntranceModifier(index: index, replayToken: replayToken))
    }

    /// C9 iPad hover token (reuses the press spring + card border).
    func cardHover() -> some View {
        modifier(CardHoverModifier())
    }

    /// C9 tracking law: letter tracking applies to Latin brand text
    /// ONLY (e.g. the "Super X" wordmark). NEVER apply tracking — this
    /// helper or `.tracking` directly — to a localized `L(...)` string:
    /// tracking Arabic (or any connected-script) text breaks its letter
    /// joins (the Arabic LIVE-badge defect). This helper exists so the
    /// one legitimate use has a named, auditable home.
    func latinBrandTracking(_ value: CGFloat = 0.6) -> some View {
        tracking(value)
    }
}
