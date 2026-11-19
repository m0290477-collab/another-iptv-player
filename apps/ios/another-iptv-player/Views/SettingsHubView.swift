import GRDB
import GRDBQuery
import SwiftUI

/// Build 65 (Settings style 2 'Visual Cards', owner-picked): the
/// Settings tab opens on a hub — the active playlist as a header
/// card, then a grid of LARGE category cards (big icon tile,
/// title, the current value where the app can state one
/// honestly). Each card pushes a focused page built from the
/// EXISTING settings sections, and the wide "All settings" card
/// at the bottom opens the complete settings form exactly as
/// shipped before — every setting that existed stays reachable;
/// nothing was removed, and no card is decorative: each one
/// navigates to the real controls it names.
struct SettingsHubView: View {
    let playlist: Playlist
    let onDismiss: () -> Void
    let onSwitchPlaylist: (Playlist) -> Void

    @Query<PlaylistRequest> private var allPlaylists: [Playlist]?
    @State private var pinUnlocked = false
    @AppStorage("app.appearance") private var appearance = "dark"

    init(playlist: Playlist, onDismiss: @escaping () -> Void, onSwitchPlaylist: @escaping (Playlist) -> Void) {
        self.playlist = playlist
        self.onDismiss = onDismiss
        self.onSwitchPlaylist = onSwitchPlaylist
        _allPlaylists = Query(PlaylistRequest(), in: \.appDatabase)
    }

    /// The same settings PIN gate the form applies (C3): the hub
    /// is the settings root now, so the lock lives here too.
    private var needsPINLock: Bool {
        UserDefaults.standard.bool(forKey: "pin.lockSettings") && PINStore.hasPIN && !pinUnlocked
    }

    private var isM3U: Bool { playlist.kind == .m3u }

    var body: some View {
        Group {
            if needsPINLock {
                PINLockScreen { pinUnlocked = true }
            } else {
                hub
            }
        }
    }

    private var hub: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                headerCard

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    spacing: 14
                ) {
                    hubCard(
                        icon: "list.bullet.rectangle.portrait.fill",
                        tint: AppTheme.accent,
                        title: L("playlists.title"),
                        value: playlist.name
                    ) {
                        MyPlaylistsView(
                            activePlaylistId: playlist.id,
                            onActivate: onSwitchPlaylist,
                            onExitToGate: onDismiss
                        )
                    }

                    hubCard(
                        icon: "play.rectangle.fill",
                        tint: AppTheme.live,
                        title: L("settings.group.player"),
                        value: nil
                    ) {
                        List {
                            PlaybackSettingsSection()
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("settings.group.player"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "paintbrush.pointed.fill",
                        tint: SectionTheme.series,
                        title: L("display.title"),
                        value: appearanceName
                    ) {
                        DisplaySettingsView()
                    }

                    hubCard(
                        icon: "calendar.badge.clock",
                        tint: .teal,
                        title: L("epg.settings.section_title"),
                        value: nil
                    ) {
                        List {
                            Section {
                                if isM3U {
                                    M3UEPGSettingsRows(playlist: playlist)
                                } else {
                                    XtreamEPGSettingsRows(playlist: playlist)
                                }
                            }
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("epg.settings.section_title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "arrow.down.circle.fill",
                        tint: .green,
                        title: L("download.title"),
                        value: downloadsValue
                    ) {
                        DownloadsView(playlist: playlist)
                    }

                    hubCard(
                        icon: "bell.badge.fill",
                        tint: .orange,
                        title: L("notifications.title"),
                        value: nil
                    ) {
                        NotificationsView(playlist: playlist)
                    }

                    hubCard(
                        icon: "internaldrive.fill",
                        tint: .gray,
                        title: L("storage.title"),
                        value: storageValue
                    ) {
                        List {
                            StorageSettingsSection()
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("storage.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "questionmark.circle.fill",
                        tint: .blue,
                        title: L("support.title"),
                        value: nil
                    ) {
                        List {
                            SupportSettingsSection(playlists: allPlaylists ?? [])
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("support.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "info.circle.fill",
                        tint: .purple,
                        title: L("settings.about.title"),
                        value: appVersion
                    ) {
                        List {
                            Section {
                                HStack {
                                    Text(L("settings.about.version"))
                                    Spacer()
                                    Text(appVersion)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            PrivacyLegalSection(onExitToGate: onDismiss)
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("settings.about.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    // The complete form — every remaining setting
                    // (account, parental, backup, danger zone…)
                    // exactly as shipped.
                    hubCard(
                        icon: "slider.horizontal.3",
                        tint: AppTheme.accent,
                        title: L("settings.hub.all_settings"),
                        value: nil
                    ) {
                        Group {
                            if isM3U {
                                M3UPlaylistSettingsView(playlist: playlist, onDismiss: onDismiss, onSwitchPlaylist: onSwitchPlaylist)
                            } else {
                                PlaylistSettingsView(playlist: playlist, onDismiss: onDismiss, onSwitchPlaylist: onSwitchPlaylist)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .cinematicBackground()
    }

    // MARK: - Header card

    /// The mockup's top card: flame mark + the ACTIVE playlist's
    /// real name and server, nothing invented.
    private var headerCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.brandGradient)
                    .frame(width: 48, height: 48)
                Image(systemName: "flame.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(playlist.serverURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .fill(AppTheme.cardGradient)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.cardBorderColor, lineWidth: 1)
        }
    }

    // MARK: - Card

    private func hubCard<Destination: View>(
        icon: String,
        tint: Color,
        title: String,
        value: String?,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint)
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let value, !value.isEmpty {
                        Text(value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(AppTheme.cardGradient)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(AppTheme.cardBorderColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
    }

    // MARK: - Honest current values

    private var appearanceName: String {
        switch appearance {
        case "light": return L("settings.appearance.light")
        case "system": return L("settings.appearance.system")
        default: return L("settings.appearance.dark")
        }
    }

    private var downloadsValue: String? {
        let count = StorageService.downloadsCount()
        guard count > 0 else { return nil }
        return "\(count) · \(ByteCountFormatter.string(fromByteCount: StorageService.downloadsSizeBytes(), countStyle: .file))"
    }

    private var storageValue: String {
        ByteCountFormatter.string(
            fromByteCount: StorageService.cacheSizeBytes() + StorageService.downloadsSizeBytes(),
            countStyle: .file
        )
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
