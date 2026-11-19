import GRDB
import GRDBQuery
import SwiftUI

/// Build 66 (W1): the Settings end state — the hub IS the whole
/// of Settings. Exactly 12 cards (Playlists, Account, Playback,
/// Display, Guide, Downloads, Notifications, Parental & Locks,
/// Storage, Backup & Data, Support, About), every setting that
/// existed in the retired legacy forms reachable exactly once
/// through them, and ONE PIN gate at this root. The legacy
/// legacy per-kind settings forms and the "All Settings" card
/// are deleted in this build; the fake activation section is
/// deleted with them (no card, no destination). Tile tints come only from AppTheme tokens
/// (charcoal surfaces, red-orange accent) — no rainbow literals.
///
/// Build 68 (W-A): the hub is restyled to the owner's picked
/// "Profile Header List" (Style 2) — a profile header card on
/// top (circular monogram avatar from the ACTIVE playlist's
/// real name, its real account/playlist/expiry state as the
/// subtitle — never any premium/subscription-for-Super-X copy,
/// the app is free), then the SAME 12 destinations in the SAME
/// order as ONE grouped list of rows (icon chip, title,
/// right-aligned live value, chevron), each row navigating to
/// exactly the build-66 destination. The settings search field
/// is REMOVED at the owner's order (no search bar in the hub).
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

                // Build 68 (W-A): the 12 build-66 destinations as
                // ONE grouped list (Style 2) — same set, same
                // order, same destinations, same live values.
                VStack(spacing: 0) {
                    hubRow(
                        icon: "list.bullet.rectangle.portrait.fill",
                        tint: AppTheme.accent,
                        title: L("playlists.title"),
                        value: playlist.name
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
                            .settingsCardRows()
                            if isM3U {
                                M3UContentSettingsSection(playlist: playlist)
                            } else {
                                XtreamContentSettingsSection(playlist: playlist)
                            }
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(16)
                        .cinematicScrollBackground()
                        .navigationTitle(L("playlists.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    rowDivider

                    hubRow(
                        icon: "person.crop.circle.fill",
                        tint: AppTheme.accent,
                        title: L("settings.hub.account"),
                        value: playlist.name
                    ) {
                        List {
                            if isM3U {
                                M3UAccountSettingsSection(playlist: playlist, onDismiss: onDismiss)
                            } else {
                                XtreamAccountSettingsSection(playlist: playlist, onDismiss: onDismiss)
                            }
                            SubscriptionSettingsSection(playlists: allPlaylists ?? [])
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(16)
                        .cinematicScrollBackground()
                        .navigationTitle(L("settings.hub.account"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    rowDivider

                    hubRow(
                        icon: "play.rectangle.fill",
                        tint: AppTheme.live,
                        title: L("settings.playback.title"),
                        value: nil
                    ) {
                        List {
                            PlayerSettingsSection()
                            PlaybackSettingsSection()
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(16)
                        .cinematicScrollBackground()
                        .navigationTitle(L("settings.playback.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    rowDivider

                    hubRow(
                        icon: "paintbrush.pointed.fill",
                        tint: AppTheme.accent,
                        title: L("display.title"),
                        value: appearanceName
                    ) {
                        DisplaySettingsView()
                    }

                    rowDivider

                    hubRow(
                        icon: "calendar.badge.clock",
                        tint: AppTheme.accent,
                        title: L("epg.settings.section_title"),
                        value: nil
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
                            .settingsCardRows()
                            EPGOffsetSettingsSection()
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(16)
                        .cinematicScrollBackground()
                        .navigationTitle(L("epg.settings.section_title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    rowDivider

                    hubRow(
                        icon: "arrow.down.circle.fill",
                        tint: AppTheme.accent,
                        title: L("download.title"),
                        value: downloadsValue
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
                            .settingsCardRows()
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(16)
                        .cinematicScrollBackground()
                        .navigationTitle(L("download.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    rowDivider

                    hubRow(
                        icon: "bell.badge.fill",
                        tint: AppTheme.accent,
                        title: L("notifications.title"),
                        value: nil
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
                            .settingsCardRows()
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(16)
                        .cinematicScrollBackground()
                        .navigationTitle(L("notifications.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    rowDivider

                    hubRow(
                        icon: "lock.shield.fill",
                        tint: AppTheme.accent,
                        title: L("settings.hub.parental_locks"),
                        value: nil
                    ) {
                        List {
                            AdultFilterSettingsSection(playlist: playlist)
                            ParentalPINSection()
                            AppLockSection()
                            LockedCategoriesSection(playlist: playlist)
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(16)
                        .cinematicScrollBackground()
                        .navigationTitle(L("settings.hub.parental_locks"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    rowDivider

                    hubRow(
                        icon: "internaldrive.fill",
                        tint: AppTheme.accent,
                        title: L("storage.title"),
                        value: storageValue
                    ) {
                        List {
                            StorageSettingsSection()
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(16)
                        .cinematicScrollBackground()
                        .navigationTitle(L("storage.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    rowDivider

                    hubRow(
                        icon: "externaldrive.fill",
                        tint: AppTheme.accent,
                        title: L("settings.hub.backup_data"),
                        value: nil
                    ) {
                        List {
                            BackupSettingsSection(playlists: allPlaylists ?? [])
                            // Danger Zone LAST on this page.
                            DangerZoneSection(onExitToGate: onDismiss)
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(16)
                        .cinematicScrollBackground()
                        .navigationTitle(L("settings.hub.backup_data"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    rowDivider

                    hubRow(
                        icon: "questionmark.circle.fill",
                        tint: AppTheme.accent,
                        title: L("support.title"),
                        value: nil
                    ) {
                        List {
                            SupportSettingsSection(playlists: allPlaylists ?? [])
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(16)
                        .cinematicScrollBackground()
                        .navigationTitle(L("support.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }

                    rowDivider

                    hubRow(
                        icon: "info.circle.fill",
                        tint: AppTheme.accent,
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
                                NavigationLink {
                                    LegalDocumentView(kind: .license)
                                } label: {
                                    HStack(spacing: 12) {
                                        SettingsIconTile(systemImage: "doc.text", tint: AppTheme.elevated)
                                        Text(L("settings.about.licenses.title"))
                                    }
                                }
                            }
                            .settingsCardRows()
                            // W10: PrivacyLegalSection's own file is
                            // outside this pass's ownership, so its
                            // Section gets the same row treatment
                            // here at the instance (listRow* modifiers
                            // reach its rows through the environment);
                            // its plain-Text header is flagged in the
                            // build-66 legacy-look list.
                            PrivacyLegalSection(onExitToGate: onDismiss)
                                .settingsCardRows()
                        }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(16)
                        .cinematicScrollBackground()
                        .navigationTitle(L("settings.about.title"))
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        .fill(AppTheme.cardGradient)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        .stroke(AppTheme.cardBorderColor, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .cinematicBackground()
    }

    // MARK: - Header card

    /// Build 68 (W-A) profile header (Style 2): a circular
    /// monogram avatar derived from the ACTIVE playlist's real
    /// name (the flame brand mark when the name yields no
    /// letters — never a fake person), the playlist's name as
    /// the title, and a subtitle composed ONLY of real state:
    /// the stored Xtream username, the real playlist count, and
    /// the provider expiry recorded in `ProviderExpiryStore`
    /// (the same source and wording as the account card). Any
    /// piece with no real value is omitted; if nothing applies,
    /// the subtitle falls back to the playlist's real server
    /// URL, exactly what the build-66 header showed.
    private var headerCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.brandGradient)
                    .frame(width: 56, height: 56)
                if headerInitials.isEmpty {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text(headerInitials)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
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

    /// Monogram initials from the active playlist's name: the
    /// first letters of its first two words, uppercased. Empty
    /// when the name has no letters (the header then shows the
    /// flame mark instead).
    private var headerInitials: String {
        let words = playlist.name.split(whereSeparator: { $0.isWhitespace })
        return String(words.prefix(2).compactMap { $0.first }).uppercased()
    }

    private var headerSubtitle: String {
        var parts: [String] = []
        if !isM3U {
            let username = playlist.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if !username.isEmpty {
                parts.append(username)
            }
        }
        if let count = allPlaylists?.count {
            parts.append(L("b68wa.hub.playlists_count_format", count))
        }
        if !isM3U, let expiry = ProviderExpiryStore.expiryDate(playlistId: playlist.id) {
            if ProviderExpiryStore.isExpired(expiryDate: expiry) {
                parts.append(L("subscription.expired_format", formattedExpiry(expiry)))
            } else {
                parts.append(L("subscription.active_format", formattedExpiry(expiry), expiryRemainingText(expiry)))
            }
        }
        guard !parts.isEmpty else { return playlist.serverURL }
        return parts.joined(separator: " • ")
    }

    /// Same date formatting as the account card in
    /// SettingsComponents (medium date, no time).
    private func formattedExpiry(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// Same honest calendar-day math as the account card.
    private func expiryRemainingText(_ expiry: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(expiry) { return L("settings.account.expires_today") }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: expiry)
        ).day ?? 0
        if days <= 1 { return L("settings.account.day_left") }
        return L("settings.account.days_left", days)
    }

    // MARK: - Row

    /// One Style-2 hub row: a small rounded-square icon chip
    /// (the shared `SettingsIconTile` — tinted fill, white
    /// glyph), the title, the destination's LIVE value
    /// right-aligned when it has one, and a chevron. Navigation
    /// and destination are exactly the build-66 card's.
    @ViewBuilder
    private func hubRow<Destination: View>(
        icon: String,
        tint: Color,
        title: String,
        value: String?,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: icon, tint: tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let value, !value.isEmpty {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Hairline between grouped rows, inset to the title edge
    /// (14 row padding + 28 icon tile + 12 spacing).
    private var rowDivider: some View {
        Divider()
            .padding(.leading, 54)
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
