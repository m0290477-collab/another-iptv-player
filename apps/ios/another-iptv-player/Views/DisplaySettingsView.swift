import SwiftUI

/// Build 65 (Display / Appearance style 1 'Live Preview Cards',
/// owner-picked): every display option is a card whose choices
/// carry a LIVE mini-preview, and the panel at the top re-renders
/// a miniature Home with the CURRENT choices the moment any of
/// them changes — what you see is exactly what the app does:
///
/// - Theme → the existing `app.appearance` choice (System = the
///   automatic mode: the app follows the device; Dark / Light pin
///   it). Orientation needs no control at all: every layout in
///   the app adapts to rotation automatically, in both
///   directions, which the Automatic card states plainly.
/// - Accent → the existing `AccentThemeStore` presets.
/// - Poster size → `PosterSizePreference`, consumed by
///   `PosterMetrics` app-wide.
/// - Home density → `HomeDensityPreference`, consumed by
///   HomeView's row stack.
///
/// Build 66 (W1): this page is now the ONLY appearance/accent
/// UI in Settings (the legacy forms and their duplicate pickers
/// are deleted). It also carries the migrated appearance
/// leftovers — language, reduce effects, empty categories,
/// section visibility, motion intensity and UI sounds — via the
/// shared sections below, each reachable exactly once.
struct DisplaySettingsView: View {
    @AppStorage("app.appearance") private var appearance = "dark"
    @AppStorage(PosterSizePreference.defaultsKey) private var posterSizeRaw = PosterSizePreference.medium.rawValue
    @AppStorage(HomeDensityPreference.defaultsKey) private var densityRaw = HomeDensityPreference.comfortable.rawValue
    @ObservedObject private var accentStore = AccentThemeStore.shared

    private var posterSize: PosterSizePreference {
        PosterSizePreference(rawValue: posterSizeRaw) ?? .medium
    }

    private var density: HomeDensityPreference {
        HomeDensityPreference(rawValue: densityRaw) ?? .comfortable
    }

    var body: some View {
        Form {
            // The live preview panel (the mockup's "Preview
            // updates in real time" promise, kept literally).
            Section {
                previewPanel
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text(L("display.preview"))
            }

            // Automatic: orientation adaptation is not a setting
            // — it is how the app is built; theme follows the
            // device when set to System below.
            Section {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "rotate.3d", tint: AppTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("display.automatic"))
                        Text(L("display.automatic.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L("display.automatic"))
            }

            Section {
                HStack(spacing: 10) {
                    themeTile(value: "system", titleKey: "settings.appearance.system")
                    themeTile(value: "dark", titleKey: "settings.appearance.dark")
                    themeTile(value: "light", titleKey: "settings.appearance.light")
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text(L("display.theme"))
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        ForEach(AccentPreset.allCases, id: \.self) { preset in
                            Button {
                                accentStore.preset = preset
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(preset.color)
                                        .frame(width: 34, height: 34)
                                    if accentStore.preset == preset {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.black))
                                            .foregroundStyle(.white)
                                            .shadow(color: .black.opacity(0.6), radius: 2)
                                    }
                                }
                                .overlay {
                                    Circle()
                                        .stroke(accentStore.preset == preset ? Color.white : Color.clear, lineWidth: 2)
                                        .padding(-4)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L(preset.nameKey))
                        }
                    }
                    Text(L(accentStore.preset.nameKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text(L("display.accent"))
            }

            Section {
                HStack(spacing: 10) {
                    ForEach(PosterSizePreference.allCases, id: \.self) { size in
                        choiceTile(
                            isSelected: posterSize == size,
                            titleKey: size.nameKey
                        ) {
                            HStack(alignment: .bottom, spacing: 4) {
                                ForEach(0..<3, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Color.secondary.opacity(0.55))
                                        .frame(width: 16 * size.factor, height: 24 * size.factor)
                                }
                            }
                            .frame(height: 32, alignment: .bottom)
                        } action: {
                            posterSizeRaw = size.rawValue
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text(L("display.poster_size"))
            }

            Section {
                HStack(spacing: 10) {
                    ForEach(HomeDensityPreference.allCases, id: \.self) { option in
                        choiceTile(
                            isSelected: density == option,
                            titleKey: option.nameKey
                        ) {
                            VStack(spacing: option == .compact ? 4 : 9) {
                                ForEach(0..<3, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Color.secondary.opacity(0.55))
                                        .frame(height: 7)
                                }
                            }
                            .frame(height: 32)
                        } action: {
                            densityRaw = option.rawValue
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text(L("display.density"))
            }

            // Build 66 (W1): language picker, migrated from the
            // legacy forms' App & Appearance group.
            Section {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "globe", tint: AppTheme.accent)
                    LanguagePickerRow()
                }
            } header: {
                Text(L("settings.language.title"))
            }

            // Build 66 (W1): appearance leftovers (reduce
            // effects, show empty categories, section visibility).
            AppearanceSettingsSection()

            // Build 66 (W1): motion intensity + UI sounds.
            MotionSoundSettingsSection()
        }
        .cinematicScrollBackground()
        .navigationTitle(L("display.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Live preview panel

    /// A miniature Home rendered from the CURRENT choices: hero
    /// block in the accent, a poster row at the chosen poster
    /// size, row spacing at the chosen density, surfaces in the
    /// chosen theme (System renders split — half dark, half
    /// light — because it follows the device).
    private var previewPanel: some View {
        let dark = appearance != "light"
        return VStack(alignment: .leading, spacing: density == .compact ? 7 : 12) {
            // Hero block.
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentStore.color.opacity(0.85), accentStore.color.opacity(0.35)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 74)
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppTheme.onAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(accentStore.color))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 64, height: 6)
                }
                .padding(10)
            }
            // Poster row at the chosen size.
            HStack(spacing: density == .compact ? 6 : 10) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(index == 0 ? 0.65 : 0.4))
                        .frame(width: 34 * posterSize.factor, height: 50 * posterSize.factor)
                }
                Spacer(minLength: 0)
            }
            Text(L("display.preview.note"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(dark ? AppTheme.surface : Color(white: 0.92))
                if appearance == "system" {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(white: 0.92))
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: 90)
                        }
                        .opacity(0.55)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.cardBorderColor, lineWidth: 1)
        }
    }

    // MARK: - Tiles

    private func themeTile(value: String, titleKey: String) -> some View {
        choiceTile(isSelected: appearance == value, titleKey: titleKey) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(value == "light" ? Color(white: 0.9) : AppTheme.background)
                    .frame(height: 32)
                if value == "system" {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(white: 0.9))
                        .frame(height: 32)
                        .mask(alignment: .trailing) { Rectangle().frame(width: 22) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(value == "dark" ? Color.white.opacity(0.8) : Color.black.opacity(0.55))
                        .frame(width: 20, height: 4)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accentStore.color)
                        .frame(width: 13, height: 4)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } action: {
            appearance = value
        }
    }

    /// One selectable preview tile: preview content over a label,
    /// with the accent ring + check on the current choice.
    private func choiceTile<Preview: View>(
        isSelected: Bool,
        titleKey: String,
        @ViewBuilder preview: () -> Preview,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview()
                    .frame(maxWidth: .infinity)
                HStack(spacing: 4) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    Text(L(titleKey))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.elevated)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? AppTheme.accent : AppTheme.cardBorderColor, lineWidth: isSelected ? 1.6 : 1)
            }
        }
        .buttonStyle(.plain)
    }
}
