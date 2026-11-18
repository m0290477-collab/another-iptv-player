import SwiftUI
import UIKit

// MARK: - Build 61 (B7) shared design system
//
// The wave-3 visual pass's shared pieces: the effects gate every
// D/X-pack effect reads, the ONE empty-state component (O10), the
// branded loader (X6), the animated success check (X7), the poster
// shine (X4), the shimmer overlay (D4) and the persisted Home row
// order (J3). Everything here is presentation only — no store, no
// playback, no navigation logic lives in this file.

// MARK: - Effects gate (X-pack mandatory guards + Q21)

/// The single gate for non-essential animation. An effect may run
/// its full form ONLY when `allowsHeavyEffects` is true:
/// - system Reduce Motion collapses every effect (fade/none), and
/// - B10's Q21 "Reduce effects" flag (`appearance.reduceEffects`,
///   the SAME AppStorage key Settings writes and CachedImage reads)
///   disables the heavy effects (X2/X3/X8 class).
enum EffectsGate {
    /// B10 Q21 single source: the AppStorage/UserDefaults key.
    static let reduceEffectsKey = "appearance.reduceEffects"

    static var reduceEffects: Bool {
        UserDefaults.standard.bool(forKey: reduceEffectsKey)
    }

    /// Heavy effects (shared-element transitions, staggered
    /// entrances, ambient glow, shine, shimmer sweeps) are OFF when
    /// Reduce Motion is on, when Q21 light mode is on, or when the
    /// user's motion intensity collapses animations to nil.
    static func allowsHeavyEffects(reduceMotion: Bool) -> Bool {
        guard !reduceMotion, !reduceEffects else { return false }
        return Motion.animate(.linear(duration: 0.1)) != nil
    }
}

// MARK: - O10 shared empty state

/// O10: the ONE designed empty state — icon + one-line message +
/// one optional action. No blank screens, no bare spinners as final
/// states. Callers pass their EXISTING localized text; the component
/// owns only the layout.
struct EmptyStateView: View {
    let iconName: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(AppTheme.fontCardTitle)
                    .foregroundStyle(AppTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}

// MARK: - X6 branded loader

/// X6: the branded loader — a pulsing flame inside a red-orange
/// ring — replacing the stock spinner VIEWS app-wide. This is a
/// pure view swap: it owns no state beyond its pulse and never
/// touches buffering/loading logic at any call site. Static (no
/// pulse) under Reduce Motion / Q21 / motion-off.
struct BrandedLoader: View {
    var size: CGFloat = 44
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppTheme.accent.opacity(0.22), lineWidth: 3)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(
                    AppTheme.brandGradient,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Image(systemName: "flame.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(AppTheme.brandGradient)
                .scaleEffect(pulsing ? 1.12 : 0.94)
                .opacity(pulsing ? 1 : 0.75)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(L("b7.loader.loading"))
        .onAppear {
            guard animates, !pulsing else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

// MARK: - X7 animated success check

/// X7: a drawn checkmark (stroke trim, one shot) for success
/// moments — playlist-add success (L2 summary) and download
/// completion. One-shot and view-local; renders the completed
/// check instantly under Reduce Motion / Q21 / motion-off.
struct AnimatedCheckView: View {
    var size: CGFloat = 28
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion) }

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.accent.opacity(0.16))
            CheckmarkShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                .padding(size * 0.26)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear {
            if animates {
                withAnimation(.easeOut(duration: 0.45)) { drawn = true }
            } else {
                drawn = true
            }
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

// MARK: - X4 poster shine

/// X4: a subtle light sweep across a poster card WHILE PRESSED.
/// Presentation overlay only — a simultaneous zero-distance gesture
/// observes the press; it never consumes touches, never delays the
/// tap, and renders nothing when the effects gate is closed.
struct PosterShineModifier: ViewModifier {
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion) }

    func body(content: Content) -> some View {
        content
            .overlay {
                if animates {
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(pressed ? 0.16 : 0), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.25), value: pressed)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false }
            )
    }
}

extension View {
    /// X4 poster shine while pressed (see `PosterShineModifier`).
    func posterShine() -> some View {
        modifier(PosterShineModifier())
    }

    /// D4: one shared shimmer sweep for skeleton placeholders —
    /// a single animated overlay on the placeholder container,
    /// never per-cell work. Renders nothing (static placeholder)
    /// when the effects gate is closed.
    func shimmerSweep(active: Bool) -> some View {
        modifier(ShimmerSweepModifier(active: active))
    }
}

// MARK: - D4 shimmer sweep

struct ShimmerSweepModifier: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool {
        active && EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if animates {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.07), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard animates else { return }
                phase = -1
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - X8 ambient hero glow

/// X8: a very slow breathing red-orange glow behind the Home hero.
/// Presentation only, behind the hero card; it renders NOTHING when
/// the effects gate is closed (Reduce Motion / Q21 light mode /
/// motion-off) — the hero then sits on the plain charcoal
/// background. The breathing is opacity-only on a single blurred
/// shape (no per-cell work), and the owning screen only mounts it
/// while Home is visible, so it pauses off-screen by construction.
struct AmbientHeroGlow: View {
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion) {
            Ellipse()
                .fill(AppTheme.accent.opacity(breathing ? 0.20 : 0.10))
                .frame(width: 340, height: 200)
                .blur(radius: 60)
                .allowsHitTesting(false)
                .onAppear {
                    guard !breathing else { return }
                    withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                        breathing = true
                    }
                }
        }
    }
}

// MARK: - J3 Home row order

/// J3: the user-reorderable Home CONTENT rows. The hero and every
/// banner (S4 expiry, R4 what's-new, F7 update, offline) are NOT
/// rows and never enter this list. O1 is the default order until
/// the user changes it in Home Edit mode; the order persists in
/// UserDefaults (`home.sectionOrder.v1`, row raw values).
enum HomeRowKind: String, CaseIterable {
    case continueWatching
    case continueSeries
    case recentChannels
    case live
    case discovery
    case recentlyAdded
    case matches

    /// O1 default: Continue Watching → Continue Series → Recent
    /// Channels → Live → Movies/Series (discovery) → Recently
    /// Added → Today's Matches.
    static let defaultOrder: [HomeRowKind] = [
        .continueWatching, .continueSeries, .recentChannels, .live,
        .discovery, .recentlyAdded, .matches
    ]
}

final class HomeSectionOrderStore: ObservableObject {
    static let shared = HomeSectionOrderStore()
    private static let storageKey = "home.sectionOrder.v1"

    @Published private(set) var order: [HomeRowKind]

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        var restored = stored.compactMap(HomeRowKind.init(rawValue:))
        // Sanitize: drop duplicates, append any row the stored order
        // predates (new rows land at their O1 position's end-state —
        // appended in default order), so the list is always complete.
        var seen = Set<HomeRowKind>()
        restored = restored.filter { seen.insert($0).inserted }
        for kind in HomeRowKind.defaultOrder where !seen.contains(kind) {
            restored.append(kind)
        }
        order = restored
    }

    /// Moves one row one step (-1 = up, +1 = down) and persists.
    func move(_ kind: HomeRowKind, by delta: Int) {
        guard let index = order.firstIndex(of: kind) else { return }
        let target = index + delta
        guard target >= 0, target < order.count else { return }
        var next = order
        next.swapAt(index, target)
        order = next
        UserDefaults.standard.set(next.map(\.rawValue), forKey: Self.storageKey)
        Haptics.selection()
    }
}
