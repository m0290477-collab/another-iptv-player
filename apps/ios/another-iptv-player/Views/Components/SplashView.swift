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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AppTheme.background
                .ignoresSafeArea()

            VStack(spacing: 12) {
                // The Design-4 flame mark in the fixed brand
                // gradient (same treatment as the gate header).
                Image(systemName: "flame.fill")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(AppTheme.brandGradient)
                    .shadow(color: AppTheme.accentStart.opacity(0.45), radius: 16, x: 0, y: 8)

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
        .onAppear {
            // Subtle fade-in, one shot; instant under Reduce Motion
            // (Motion.animate collapses to nil there).
            withAnimation(Motion.animate(.easeOut(duration: 0.45))) {
                shown = true
            }
        }
    }
}

#Preview {
    SplashView()
        .preferredColorScheme(.dark)
}
