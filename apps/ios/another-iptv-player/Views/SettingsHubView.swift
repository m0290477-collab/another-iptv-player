import GRDB
import GRDBQuery
import SwiftUI

/// Build 66 (W1): the Settings end state — the hub IS the whole
/// of Settings. Exactly 12 cards (Playlists, Account, Playback,
/// Display, Guide, Downloads, Notifications, Parental & Locks,
/// Storage, Backup & Data, Support, About), every setting that
/// existed in the retired legacy forms reachable exactly once
/// through them, ONE PIN gate at this root, and settings search
/// on this root (reusing the legacy forms' `settingsSearchMatches`
/// keyword data, moved here with the cards). The legacy
/// legacy per-kind settings forms and the "All Settings" card
/// are deleted in this build; the fake activation section is
/// deleted with them (no card, no destination). Tile tints come only from AppTheme tokens
/// (charcoal surfaces, red-orange accent) — no rainbow literals.
struct SettingsHubView: View {
    let playlist: Playlist
    let onDismiss: () -> Void
    let onSwitchPlaylist: (Playlist) -> Void

    @Query<PlaylistRequest> private var allPlaylists: [Playlist]?
    @State private var pinUnlocked = false
    @State private var settingsSearch = ""
    @AppStorage("app.appearance") private var appearance = "dark"

    init(playlist: Playlist, onDismiss: @escaping () -> Void, onSwitchPlaylist: @escaping (Playlist) -> Void) {
        self.playlist = playlist
        self.onDismiss = onDismiss
        self.onSwitchPlaylist = onSwitchPlaylist
        _allPlaylists = Query(PlaylistRequest(), in: \.appDatabase)
    }

    /// The ONE settings PIN gate (build 66): at the hub root
    /// only — the legacy forms carried a second gate each, so the
    /// user was prompted twice; they are deleted now.
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

                searchField

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    spacing: 14
                ) {
                    hubCard(
                        icon: "list.bullet.rectangle.portrait.fill",
                        tint: AppTheme.accent,
                        title: L("playlists.title"),
                        value: playlist.name,
                        keywords: "playlists my playlists switch content data refresh epg guide history clear counts m3u file"
                    ) {
                        List {
                            Section {
                                NavigationLink {
                                    MyPlaylistsView(
                                        activePlaylistId: playlist.id,
                                        onActivate: onSwitchPlaylist,
                                        onExitToGate: onDismiss
                                    )
                                } label: {
                                    HStack(spacing: 12) {
                                        SettingsIconTile(systemImage: "list.bullet.rectangle", tint: AppTheme.accent)
                                        Text(L("settings.my_playlists"))
                                        Spacer()
                                        if let count = allPlaylists?.count {
                                            Text("\(count)")
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                            if isM3U {
                                M3UContentSettingsSection(playlist: playlist)
                            } else {
                                XtreamContentSettingsSection(playlist: playlist)
                            }
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("playlists.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "person.crop.circle.fill",
                        tint: AppTheme.accent,
                        title: L("settings.hub.account"),
                        value: playlist.name,
                        keywords: "account subscription playlist username password expiry connection test edit sign out provider"
                    ) {
                        List {
                            if isM3U {
                                M3UAccountSettingsSection(playlist: playlist, onDismiss: onDismiss)
                            } else {
                                XtreamAccountSettingsSection(playlist: playlist, onDismiss: onDismiss)
                            }
                            SubscriptionSettingsSection(playlists: allPlaylists ?? [])
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("settings.hub.account"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "play.rectangle.fill",
                        tint: AppTheme.live,
                        title: L("settings.playback.title"),
                        value: nil,
                        keywords: "player auto-play pip sleep background long press video fit subtitle audio delay buffer play last channel launch playback loudness data saver dead channels audio only"
                    ) {
                        List {
                            PlayerSettingsSection()
                            PlaybackSettingsSection()
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("settings.playback.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "paintbrush.pointed.fill",
                        tint: AppTheme.accent,
                        title: L("display.title"),
                        value: appearanceName,
                        keywords: "appearance theme light dark language accent reduce effects empty categories section visibility motion ui sounds poster size density display"
                    ) {
                        DisplaySettingsView()
                    }

                    hubCard(
                        icon: "calendar.badge.clock",
                        tint: AppTheme.accent,
                        title: L("epg.settings.section_title"),
                        value: nil,
                        keywords: "epg guide tv time offset refresh url"
                    ) {
                        List {
                            Section {
                                if isM3U {
                                    M3UEPGSettingsRows(playlist: playlist)
                                    Text(L("epg.settings.url_footer"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    XtreamEPGSettingsRows(playlist: playlist)
                                }
                            }
                            EPGOffsetSettingsSection()
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("epg.settings.section_title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "arrow.down.circle.fill",
                        tint: AppTheme.accent,
                        title: L("download.title"),
                        value: downloadsValue,
                        keywords: "downloads wifi auto-download storage delete library cap"
                    ) {
                        List {
                            DownloadsSettingsSection(playlist: playlist)
                            Section {
                                NavigationLink {
                                    DownloadsView(playlist: playlist)
                                } label: {
                                    HStack(spacing: 12) {
                                        SettingsIconTile(systemImage: "arrow.down.circle.fill", tint: AppTheme.accent)
                                        Text(L("download.title"))
                                    }
                                }
                            }
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("download.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "bell.badge.fill",
                        tint: AppTheme.accent,
                        title: L("notifications.title"),
                        value: nil,
                        keywords: "notifications expiry alerts reminders lead time programme"
                    ) {
                        List {
                            ExpiryAlertsSettingsSection()
                            RemindersSettingsSection()
                            Section {
                                NavigationLink {
                                    NotificationsView(playlist: playlist)
                                } label: {
                                    HStack(spacing: 12) {
                                        SettingsIconTile(systemImage: "bell.fill", tint: AppTheme.accent)
                                        Text(L("notifications.title"))
                                    }
                                }
                            }
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("notifications.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "lock.shield.fill",
                        tint: AppTheme.accent,
                        title: L("settings.hub.parental_locks"),
                        value: nil,
                        keywords: "parental filter adult pin lock settings app lock face id touch id passcode locked categories"
                    ) {
                        List {
                            AdultFilterSettingsSection(playlist: playlist)
                            ParentalPINSection()
                            AppLockSection()
                            LockedCategoriesSection(playlist: playlist)
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("settings.hub.parental_locks"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "internaldrive.fill",
                        tint: AppTheme.accent,
                        title: L("storage.title"),
                        value: storageValue,
                        keywords: "storage cache space clear watch search history"
                    ) {
                        List {
                            StorageSettingsSection()
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("storage.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "externaldrive.fill",
                        tint: AppTheme.accent,
                        title: L("settings.hub.backup_data"),
                        value: nil,
                        keywords: "backup export import reset defaults transfer danger sign out erase delete all data zone"
                    ) {
                        List {
                            BackupSettingsSection(playlists: allPlaylists ?? [])
                            // Danger Zone LAST on this page.
                            DangerZoneSection(onExitToGate: onDismiss)
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("settings.hub.backup_data"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    hubCard(
                        icon: "questionmark.circle.fill",
                        tint: AppTheme.accent,
                        title: L("support.title"),
                        value: nil,
                        keywords: "support faq help diagnostics speed test"
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
                        tint: AppTheme.accent,
                        title: L("settings.about.title"),
                        value: appVersion,
                        keywords: "about version licenses credits legal privacy terms"
                    ) {
                        List {
                            Section {
                                HStack {
                                    Text(L("settings.about.version"))
                                    Spacer()
                                    Text(appVersion)
                                        .foregroundStyle(.secondary)
                                }
                                NavigationLink {
                                    LegalDocumentView(kind: .license)
                                } label: {
                                    HStack(spacing: 12) {
                                        SettingsIconTile(systemImage: "doc.text", tint: AppTheme.elevated)
                                        Text(L("settings.about.licenses.title"))
                                    }
                                }
                            }
                            PrivacyLegalSection(onExitToGate: onDismiss)
                        }
                        .cinematicScrollBackground()
                        .navigationTitle(L("settings.about.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .cinematicBackground()
    }

    // MARK: - Search

    /// Settings search on the hub root (build 66): filters the
    /// 12 cards with the legacy forms' keyword matching
    /// (`settingsSearchMatches`, moved here with the cards).
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L("common.search"), text: $settingsSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !settingsSearch.isEmpty {
                Button {
                    settingsSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                .fill(AppTheme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                .stroke(AppTheme.cardBorderColor, lineWidth: 1)
        }
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

    @ViewBuilder
    private func hubCard<Destination: View>(
        icon: String,
        tint: Color,
        title: String,
        value: String?,
        keywords: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        if settingsSearchMatches(settingsSearch, "\(title) \(keywords)") {
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
