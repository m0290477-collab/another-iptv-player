import GRDB
import GRDBQuery
import SwiftUI

/// The Settings hub IS the whole of Settings (build 66 end
/// state): exactly 12 destinations (Playlists, Account, Playback,
/// Display, Guide, Downloads, Notifications, Parental & Locks,
/// Storage, Backup & Data, Support, About), every setting that
/// existed in the retired legacy forms reachable exactly once
/// through them, and ONE PIN gate at this root. The legacy
/// per-kind settings forms and the "All Settings" card are
/// deleted; the fake activation section is deleted with them
/// (no card, no destination).
///
/// Build 71: the hub home surface is restyled to the owner's
/// picked "Profile Header" (Style 3) — ONE profile header card
/// on top (circular monogram avatar from the ACTIVE playlist's
/// real name, its real playlist count and provider expiry as
/// the subtitle — never any premium/subscription-for-Super-X
/// copy, the app is free; the identity/state lives ONLY in
/// this header, no row repeats it), then the SAME 12
/// destinations grouped into three titled sections (GENERAL /
/// MEDIA / SECURITY & DATA) as plain navigation rows — icon
/// chip, title, chevron, NO row values. The settings search
/// field stays REMOVED (owner's order since build 68). The
/// "Subtitles & Audio" row has no standalone destination in
/// build 70 — its controls (subtitle appearance, audio delay)
/// live inside the Player section of the Playback page — so it
/// navigates to that same Playback page; nothing is duplicated
/// and nothing is dropped. Colors on this surface are the
/// FIXED Design-4 tokens (brand gradient, accentStart,
/// charcoal surfaces) so the hub renders near-black charcoal +
/// red-orange regardless of the user's saved accent preset.
/// Destinations and sub-screens are byte-for-byte the build-70
/// ones; only this home surface changed.
struct SettingsHubView: View {
    let playlist: Playlist
    let onDismiss: () -> Void
    let onSwitchPlaylist: (Playlist) -> Void

    @Query<PlaylistRequest> private var allPlaylists: [Playlist]?
    @State private var pinUnlocked = false

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
            VStack(alignment: .leading, spacing: 22) {
                headerCard

                hubSection(title: L("settings.hub.section_general")) {
                    hubRow(
                        icon: "list.bullet.rectangle.portrait.fill",
                        title: L("settings.my_playlists")
                    ) {
                        playlistsDestination
                    }

                    rowDivider

                    hubRow(
                        icon: "paintpalette.fill",
                        title: L("settings.appearance.title")
                    ) {
                        DisplaySettingsView()
                    }

                    rowDivider

                    hubRow(
                        icon: "play.circle.fill",
                        title: L("settings.playback.title")
                    ) {
                        playbackDestination
                    }
                }

                hubSection(title: L("settings.hub.section_media")) {
                    hubRow(
                        icon: "captions.bubble.fill",
                        title: L("settings.hub.subtitles_audio")
                    ) {
                        playbackDestination
                    }

                    rowDivider

                    hubRow(
                        icon: "arrow.down.to.line",
                        title: L("download.title")
                    ) {
                        downloadsDestination
                    }

                    rowDivider

                    hubRow(
                        icon: "bell.fill",
                        title: L("notifications.title")
                    ) {
                        notificationsDestination
                    }
                }

                hubSection(title: L("settings.hub.section_security_data")) {
                    hubRow(
                        icon: "person.crop.circle.fill",
                        title: L("settings.hub.account")
                    ) {
                        accountDestination
                    }

                    rowDivider

                    hubRow(
                        icon: "lock.fill",
                        title: L("applock.title")
                    ) {
                        parentalLocksDestination
                    }

                    rowDivider

                    hubRow(
                        icon: "internaldrive.fill",
                        title: L("storage.title")
                    ) {
                        storageDestination
                    }

                    rowDivider

                    hubRow(
                        icon: "arrow.clockwise.icloud.fill",
                        title: L("settings.hub.backup_restore")
                    ) {
                        backupDataDestination
                    }

                    rowDivider

                    hubRow(
                        icon: "questionmark.circle.fill",
                        title: L("support.title")
                    ) {
                        supportDestination
                    }

                    rowDivider

                    hubRow(
                        icon: "info.circle.fill",
                        title: L("settings.about.title")
                    ) {
                        aboutDestination
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

    /// Build 71 profile header (Style 3): a circular monogram
    /// avatar derived from the ACTIVE playlist's real name (the
    /// flame brand mark when the name yields no letter — never a
    /// fake person), the playlist's name as the title, and a
    /// subtitle composed ONLY of real state: the real playlist
    /// count and the provider expiry recorded in
    /// `ProviderExpiryStore` (the same source as the account
    /// card). Any piece with no real value is omitted; if nothing
    /// applies, the subtitle falls back to the playlist's real
    /// server URL, exactly what the build-66 header showed. The
    /// thin line under the header is the subscription's
    /// remaining-validity bar: it drains across the final year
    /// before the recorded expiry (full at a year or more left,
    /// empty once expired, full when no expiry is recorded).
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AppTheme.brandGradient)
                        .frame(width: 64, height: 64)
                    if headerInitial.isEmpty {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text(headerInitial)
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(headerTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.overlayFill(0.10))
                    Capsule()
                        .fill(AppTheme.accentStart)
                        .frame(width: geo.size.width * headerProgress)
                }
            }
            .frame(height: 4)
        }
        .padding(18)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                    .fill(AppTheme.cardGradient)
                // The mockup's subtle warm glow, low in the card —
                // the FIXED Design-4 orange, never the user accent.
                RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.clear, AppTheme.accentStart.opacity(0.16)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                .stroke(AppTheme.cardBorderColor, lineWidth: 1)
        }
    }

    /// The header's display name: the active playlist's real
    /// name; the stored Xtream username when a playlist carries
    /// no name (M3U playlists always carry one).
    private var headerTitle: String {
        let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return playlist.username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Monogram initial from the header title: its first letter,
    /// uppercased (the mockup's single-letter avatar). Empty when
    /// the title has no letters (the header then shows the flame
    /// mark instead).
    private var headerInitial: String {
        guard let first = headerTitle.first(where: { $0.isLetter }) else { return "" }
        return String(first).uppercased()
    }

    private var headerSubtitle: String {
        var parts: [String] = []
        if let count = allPlaylists?.count {
            parts.append(
                count == 1
                    ? L("settings.hub.playlist_count_one")
                    : L("settings.hub.playlists_count_format", count)
            )
        }
        if !isM3U, let expiry = ProviderExpiryStore.expiryDate(playlistId: playlist.id) {
            if ProviderExpiryStore.isExpired(expiryDate: expiry) {
                parts.append(L("subscription.expired_format", formattedExpiry(expiry)))
            } else {
                parts.append(L("settings.hub.active_until_format", formattedExpiry(expiry)))
            }
        }
        guard !parts.isEmpty else { return playlist.serverURL }
        return parts.joined(separator: " • ")
    }

    /// Remaining-validity fraction for the header line: full
    /// when no expiry is recorded (nothing running out) or when
    /// a year or more remains; drains linearly across the final
    /// year; zero once expired.
    private var headerProgress: Double {
        guard !isM3U, let expiry = ProviderExpiryStore.expiryDate(playlistId: playlist.id) else {
            return 1
        }
        if ProviderExpiryStore.isExpired(expiryDate: expiry) { return 0 }
        let daysRemaining = expiry.timeIntervalSinceNow / 86_400
        return min(max(daysRemaining / 365, 0), 1)
    }

    /// Same date formatting as the account card in
    /// SettingsComponents (medium date, no time).
    private func formattedExpiry(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Section & row

    /// One Style-3 hub section: the small caps gray title above
    /// a dark rounded card of rows.
    @ViewBuilder
    private func hubSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .background {
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(AppTheme.cardGradient)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(AppTheme.cardBorderColor, lineWidth: 1)
            }
            // Build 81 (item 8): hub sections fade/rise in once.
            .sectionAppear()
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        }
    }

    /// One Style-3 hub row: a small muted icon chip (neutral
    /// scheme-paired chip — the mockup's chips, NOT the user
    /// accent, so this surface keeps the Design-4 look for every
    /// preset; build 76 pairs the tint and glyph with the scheme),
    /// the title, and a chevron. NO value: the identity/state
    /// lives only in the header card.
    @ViewBuilder
    private func hubRow<Destination: View>(
        icon: String,
        title: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: icon, tint: AppTheme.overlayFill(0.09), size: 30, glyphColor: .primary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        // Build 81 (item 8): hub rows dim on press (was .plain —
        // no feedback at all).
        .buttonStyle(PressOpacityButtonStyle())
    }

    /// Hairline between grouped rows, inset to the title edge
    /// (14 row padding + 30 icon tile + 12 spacing).
    private var rowDivider: some View {
        Divider()
            .padding(.leading, 56)
    }

    // MARK: - Destinations (build 70, unchanged)

    private var playlistsDestination: some View {
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

    private var accountDestination: some View {
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

    private var playbackDestination: some View {
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

    private var downloadsDestination: some View {
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

    private var notificationsDestination: some View {
        List {
            ExpiryAlertsSettingsSection()
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

    private var parentalLocksDestination: some View {
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

    private var storageDestination: some View {
        List {
            StorageSettingsSection()
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .cinematicScrollBackground()
        .navigationTitle(L("storage.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var backupDataDestination: some View {
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

    private var supportDestination: some View {
        List {
            SupportSettingsSection(playlists: allPlaylists ?? [])
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .cinematicScrollBackground()
        .navigationTitle(L("support.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var aboutDestination: some View {
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

    // MARK: - Honest current values

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
