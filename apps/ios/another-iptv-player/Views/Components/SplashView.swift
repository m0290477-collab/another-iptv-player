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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// X1 guards: ignition is a heavy effect — skipped entirely
    /// (flame renders at rest) under Reduce Motion / Q21 / motion-off.
    private var ignitionAllowed: Bool {
        EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion)
    }

    var body: some View {
        ZStack {
            AppTheme.background
                .ignoresSafeArea()

            VStack(spacing: 12) {
                // The Design-4 flame mark in the fixed brand
                // gradient (same treatment as the gate header).
                // X1: ignition — spark → full flame with a glow
                // flash; tap anywhere skips to the rest state.
                Image(systemName: "flame.fill")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(AppTheme.brandGradient)
                    .shadow(color: AppTheme.accentStart.opacity(ignited ? 0.45 : 0.95),
                            radius: ignited ? 16 : 30, x: 0, y: 8)
                    .scaleEffect(ignitionAllowed && !ignited ? 0.55 : 1)
                    .opacity(ignitionAllowed && !ignited ? 0.6 : 1)

                // Wordmark: "Super" white, the X in the brand
                // gradient — the mockup's flame-treated X.
                HStack(spacing: 4) {
                    Text("Super")
                        .foregroundStyle(.white)
                    Text("X")
                        .foregroundStyle(AppTheme.brandGradient)
                }
                .font(.system(size: 48, weight: .black))
                .tracking(-0.5)

                Text(L("gate.subtitle"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.accent)
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
        }
    }
}

#Preview {
    SplashView()
        .preferredColorScheme(.dark)
}
