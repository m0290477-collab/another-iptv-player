import SwiftUI

// MARK: - Branded splash (build 61, D2)
//
// The in-app splash shown at cold start: the Design-4 brand lockup
// (flame mark + Super X wordmark) on the charcoal background, with a
// subtle one-shot fade-in. It is NOT a timed splash — ContentView
// keeps it up only until the first content decision is ready (the
// playlists query has answered), then it cross-fades out and the
// gate or the auto-loaded dashboard takes over. No artificial delay
// anywhere: a fast cold start may show it for a single frame.
//
// The system UILaunchScreen configuration is untouched — this view
// covers the gap between the system launch screen and the first
// real content, in the app's own design language.

struct SplashView: View {
    @State private var shown = false
    /// X1 (B7): the one-shot ignition — the flame scales up from a
    /// spark with a bright flash, ~0.8 s total, once per cold start.
    @State private var ignited = false
    /// Build 87 (per-surface motion): the collage's very slow
    /// Ken Burns push-in (one settle, never a loop) and the
    /// flame's soft breathing glow — both effects-gated.
    @State private var kenBurns = false
    @State private var glowPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// X1 guards: ignition is a heavy effect — skipped entirely
    /// (flame renders at rest) under Reduce Motion / Q21 / motion-off.
    private var ignitionAllowed: Bool {
        EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion)
    }

    var body: some View {
        ZStack {
            // Build 87 (owner-picked gate design 2, 'cinematic'):
            // the bundled poster/stadium collage under a smooth
            // black gradient — ONE local asset, no network, so
            // the splash renders instantly on cold launch. The
            // lockup, ignition and hand-off behavior are
            // unchanged; only the presentation was replaced.
            Image("GateCollage")
                .resizable()
                .scaledToFill()
                .scaleEffect(kenBurns ? 1.07 : 1.0)
                .offset(y: kenBurns ? -8 : 0)
                .ignoresSafeArea()
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.62), location: 0),
                    .init(color: .black.opacity(0.30), location: 0.45),
                    .init(color: .black.opacity(0.78), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                // The Design-4 flame mark in the fixed brand
                // gradient (same treatment as the gate header).
                // X1: ignition — spark → full flame with a glow
                // flash; tap anywhere skips to the rest state.
                Image(systemName: "flame.fill")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(AppTheme.brandGradient)
                    .shadow(color: AppTheme.accentStart.opacity(ignited ? (glowPulse ? 0.62 : 0.45) : 0.95),
                            radius: ignited ? 16 : 30, x: 0, y: 8)
                    .scaleEffect(ignitionAllowed && !ignited ? 0.55 : 1)
                    .opacity(ignitionAllowed && !ignited ? 0.6 : 1)

                // Wordmark: "Super" white, the X in the brand
                // gradient — the mockup's flame-treated X.
                // Build 61 fixer (Z11): this release presents as
                // "Super X Pro Max" — DISPLAY string only (bundle
                // ID / CFBundleDisplayName / product name untouched);
                // the size steps down so the longer lockup fits.
                HStack(spacing: 4) {
                    Text("Super")
                        .foregroundStyle(.white)
                    Text("X")
                        .foregroundStyle(AppTheme.brandGradient)
                    Text("Pro Max")
                        .foregroundStyle(.white)
                }
                .font(.system(size: 34, weight: .black))
                .tracking(-0.5)

                // Build 87 (design 2): the cinematic tagline
                // replaces the functional subtitle on the splash.
                Text(L("gate.tagline"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.85))
            }
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.96)
        }
        .accessibilityLabel(L("splash.accessibility_label"))
        // X1: tap to skip the ignition (the splash itself still
        // hands off the moment content is ready — ContentView owns
        // dismissal; this only settles the flame to its rest state).
        .onTapGesture {
            withAnimation(Motion.animate(.easeOut(duration: 0.2))) {
                ignited = true
                shown = true
            }
        }
        .onAppear {
            // Subtle fade-in, one shot; instant under Reduce Motion
            // (Motion.animate collapses to nil there).
            withAnimation(Motion.animate(.easeOut(duration: 0.45))) {
                shown = true
            }
            // X1 ignition: one spring to full flame over ~0.8 s.
            if ignitionAllowed {
                withAnimation(.spring(response: 0.8, dampingFraction: 0.62)) {
                    ignited = true
                }
            } else {
                ignited = true
            }
            // Build 87: the Ken Burns settle (one slow push-in
            // over the splash's whole stay — the view itself is
            // animated, the bundled asset is untouched) and the
            // flame's breathing glow. Both still entirely
            // under the effects gate / Reduce Motion.
            if EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion) {
                withAnimation(.easeOut(duration: 18)) {
                    kenBurns = true
                }
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                    glowPulse = true
                }
            }
        }
    }
}

#Preview {
    SplashView()
        .preferredColorScheme(.dark)
}
