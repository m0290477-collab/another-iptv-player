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

            // Build 88 (gate max): very subtle floating embers
            // over the collage — a dozen tiny dots drifting
            // slowly upward, as in the approved mockup. Pure
            // decoration: rendered ONLY while the effects gate
            // allows heavy effects (stilled entirely by Reduce
            // Motion / Q21), and never hit-tested, so the
            // tap-to-skip gesture below is untouched.
            if EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion) {
                GateEmberParticles()
                    .ignoresSafeArea()
            }

            VStack(spacing: 12) {
                // The Design-4 flame mark in the fixed brand
                // gradient (same treatment as the gate header).
                // X1: ignition — spark → full flame with a glow
                // flash; tap anywhere skips to the rest state.
                // Build 88 (gate max): the mockup's glowing ring
                // now encircles the flame — a thin brand-gradient
                // circle whose glow breathes on the SAME pulse
                // driver as the flame's shadow, so the lockup
                // breathes as one. The ring itself is a static
                // design element; only the pulse is gated (via
                // glowPulse, which never starts when the gate
                // is closed). Ignition scale/opacity moved to
                // the ZStack so ring and flame ignite together.
                ZStack {
                    Circle()
                        .stroke(AppTheme.brandGradient, lineWidth: 2.5)
                        .frame(width: 128, height: 128)
                        .shadow(color: AppTheme.accentStart.opacity(ignited ? (glowPulse ? 0.55 : 0.35) : 0.8),
                                radius: ignited ? 14 : 24)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(AppTheme.brandGradient)
                        .shadow(color: AppTheme.accentStart.opacity(ignited ? (glowPulse ? 0.62 : 0.45) : 0.95),
                                radius: ignited ? 16 : 30, x: 0, y: 8)
                }
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

// MARK: - Build 88 gate embers

/// One ember: a tiny dot that drifts slowly upward and
/// fades, on its own duration/delay, looping forever.
/// Transform + opacity only, animated by the compositor —
/// no timers, no per-frame state.
private struct GateEmberDot: View {
    let xFraction: CGFloat
    let yFraction: CGFloat
    let size: CGFloat
    let drift: CGFloat
    let duration: Double
    let delay: Double

    @State private var floated = false

    var body: some View {
        GeometryReader { proxy in
            Circle()
                .fill(AppTheme.accentStart.opacity(floated ? 0.08 : 0.5))
                .frame(width: size, height: size)
                .position(
                    x: xFraction * proxy.size.width,
                    y: yFraction * proxy.size.height - (floated ? drift : 0)
                )
        }
        .onAppear {
            withAnimation(.easeInOut(duration: duration).delay(delay).repeatForever(autoreverses: true)) {
                floated = true
            }
        }
    }
}

/// The ember field: a fixed, seeded scatter of dots over
/// the gate collage (deterministic layout — the same sky
/// on every launch, no random churn). Rendered only while
/// the effects gate allows heavy effects (see SplashView).
private struct GateEmberParticles: View {
    private struct EmberSpec {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let drift: CGFloat
        let duration: Double
        let delay: Double
    }

    private static let embers: [EmberSpec] = [
        EmberSpec(x: 0.08, y: 0.78, size: 3.0, drift: 80, duration: 7.5, delay: 0.0),
        EmberSpec(x: 0.16, y: 0.62, size: 2.2, drift: 60, duration: 6.0, delay: 1.2),
        EmberSpec(x: 0.24, y: 0.85, size: 4.0, drift: 90, duration: 8.5, delay: 0.6),
        EmberSpec(x: 0.33, y: 0.70, size: 2.6, drift: 65, duration: 6.8, delay: 2.0),
        EmberSpec(x: 0.42, y: 0.90, size: 3.4, drift: 75, duration: 7.8, delay: 0.3),
        EmberSpec(x: 0.50, y: 0.66, size: 2.0, drift: 55, duration: 5.6, delay: 1.6),
        EmberSpec(x: 0.58, y: 0.82, size: 3.8, drift: 85, duration: 8.2, delay: 0.9),
        EmberSpec(x: 0.66, y: 0.74, size: 2.4, drift: 60, duration: 6.4, delay: 2.4),
        EmberSpec(x: 0.74, y: 0.88, size: 3.2, drift: 70, duration: 7.2, delay: 0.5),
        EmberSpec(x: 0.82, y: 0.64, size: 2.2, drift: 58, duration: 6.1, delay: 1.9),
        EmberSpec(x: 0.90, y: 0.80, size: 3.6, drift: 88, duration: 8.8, delay: 1.1),
        EmberSpec(x: 0.95, y: 0.70, size: 2.6, drift: 66, duration: 6.9, delay: 2.8),
    ]

    var body: some View {
        ZStack {
            ForEach(Array(Self.embers.enumerated()), id: \.offset) { _, ember in
                GateEmberDot(
                    xFraction: ember.x, yFraction: ember.y, size: ember.size,
                    drift: ember.drift, duration: ember.duration, delay: ember.delay
                )
            }
        }
        .allowsHitTesting(false)
    }
}
