import SwiftUI

/// Build 61 (B13, F4): first-run onboarding — exactly 3 short
/// Design-4 screens shown BEFORE the gate, on first launch only:
///
///  1. what Super X is — a player for your own playlist;
///  2. connect with Xtream or M3U;
///  3. your data stays on your device.
///
/// Skip and Next on every screen; finishing or skipping sets the
/// persisted flag `onboarding.completed.v1`, so the flow shows
/// exactly once. The T6 erase removes the whole UserDefaults
/// domain, which resets the flag — a post-erase launch is a
/// first launch again (verified in B13's report).
struct OnboardingView: View {
    /// Called when the user finishes or skips; ContentView
    /// persists the completion flag and drops the overlay.
    let onFinish: () -> Void

    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Page {
        let symbol: String
        let titleKey: String
        let bodyKey: String
    }

    private let pages: [Page] = [
        Page(symbol: "play.tv.fill",
             titleKey: "onboarding.page1.title",
             bodyKey: "onboarding.page1.body"),
        Page(symbol: "link.circle.fill",
             titleKey: "onboarding.page2.title",
             bodyKey: "onboarding.page2.body"),
        Page(symbol: "lock.shield.fill",
             titleKey: "onboarding.page3.title",
             bodyKey: "onboarding.page3.body")
    ]

    var body: some View {
        ZStack {
            AppTheme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Brand lockup (same treatment as the splash/gate).
                VStack(spacing: 10) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(AppTheme.brandGradient)
                        .shadow(color: AppTheme.accentStart.opacity(0.45), radius: 14, x: 0, y: 6)
                    HStack(spacing: 4) {
                        Text("Super")
                            .foregroundStyle(.white)
                        Text("X")
                            .foregroundStyle(AppTheme.brandGradient)
                    }
                    .font(.system(size: 34, weight: .black))
                    .tracking(-0.5)
                }
                .padding(.top, 56)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        pageView(pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: page)

                // Page dots — the one indicator instance.
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? AppTheme.accent : Color.white.opacity(0.25))
                            .frame(width: index == page ? 22 : 8, height: 8)
                    }
                }
                .padding(.bottom, 28)

                HStack(spacing: 12) {
                    Button(L("onboarding.skip")) { onFinish() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)

                    Button(page == pages.count - 1 ? L("onboarding.get_started") : L("onboarding.next")) {
                        if page == pages.count - 1 {
                            onFinish()
                        } else {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                page += 1
                            }
                        }
                    }
                    .font(.body.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.brandGradient, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            }
        }
    }

    private func pageView(_ page: Page) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: page.symbol)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 108, height: 108)
                .background(Circle().fill(AppTheme.surface))
            Text(L(page.titleKey))
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(L(page.bodyKey))
                .font(.body)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
            Spacer()
        }
    }
}
