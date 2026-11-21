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
///
/// Build 88 (owner-approved "max" Settings mockup): the header
/// becomes a GLASS card whose avatar is the flame brand mark in
/// a glowing brand-gradient ring; a NEW playlist glass card sits
/// under it with the playlist's REAL imported counts (the record-
/// layer `importedCounts` the gate summary reads), its real
/// recorded expiry line, and a glowing Refresh pill wired to the
/// SAME refresh the rest of the app runs (Xtream catalog refresh
/// / M3U remote re-import — the pill is hidden for a local-file
/// M3U, which has no remote source to refresh). The hub rows'
/// chips become glowing accent squares and their press is an
/// accent sheen sweep; every toggle the hub reaches renders the
/// shared glowing switch (one `.toggleStyle` at this root). The
/// header's brand elements (avatar ring, validity bar) stay on
/// the FIXED brand tokens; the interactive chrome (chips, pill,
/// switches) reads the existing accent token, so the accent
/// picker keeps governing this surface like every other.
///
/// Build 89 (item 6, consolidation): the header card and the
/// playlist card MERGE into one playlist box — the owner
/// counted the duplication (name twice, expiry twice, counts
/// truncated) and ordered everything into a single section.
/// The box carries name, connection status, the FULL counts,
/// expiry and Refresh, each exactly once; see playlistBox.

struct SettingsHubView: View {
    let playlist: Playlist
    let onDismiss: () -> Void
    let onSwitchPlaylist: (Playlist) -> Void

    @Query<PlaylistRequest> private var allPlaylists: [Playlist]?
    @State private var pinUnlocked = false
    /// Build 88 playlist card: the active playlist's real
    /// imported counts, read from the record layer on appear and
    /// after every card refresh (nil until the first read lands —
    /// the counts line simply isn't there yet, never a fake 0).
    @State private var playlistCounts: (live: Int, movies: Int, series: Int)?
    @State private var isRefreshingPlaylist = false

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
                playlistBox

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

                // Build 88 (F3): clearance so the last section
                // can always scroll fully clear of the floating
                // tab bar (the iOS 26 glass pill floats over
                // content; the destination Lists are system lists
                // whose bottom safe area the bar already reserves,
                // so only this ScrollView needs the extra room).
                Color.clear
                    .frame(height: 48)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .cinematicBackground()
        // Build 88: the ONE application of the glowing switch —
        // the environment carries it into every destination the
        // hub pushes, so all real toggles in Settings render it.
        .toggleStyle(GlowingToggleStyle())
    }

    // MARK: - Playlist box (build 89 consolidation)

    /// Build 89 (item 6): the hub's ONE playlist box. Builds
    /// 71–88 carried TWO cards at the top of the hub — the
    /// profile header (playlist name + "N playlists - Active
    /// until ...") and a playlist glass card under it (the name
    /// AGAIN, the counts truncated to "680...", the expiry
    /// AGAIN, Refresh) — and the owner ordered the duplication
    /// gone: everything about the playlist in one section, one
    /// box. Each fact now appears exactly once in this single
    /// glass box: the flame brand mark in its glowing ring, the
    /// playlist's name, its connection status (the last real
    /// verify/sync verdict in `PlaylistHealthStore` — the same
    /// read My Playlists renders — plus the real playlist
    /// count), the imported counts as stat cells whose numbers
    /// render IN FULL (see countsRow), the recorded provider
    /// expiry, the remaining-validity bar, and the glowing
    /// Refresh pill. Every value comes from the same stores the
    /// two cards read; Refresh runs the same per-playlist
    /// refresh it always ran (Xtream catalog refresh / M3U
    /// remote re-import; no pill for a local-file M3U, which has
    /// no remote source). The thin line at the bottom is the
    /// subscription's remaining-validity bar: it drains across
    /// the final year before the recorded expiry (full at a
    /// year or more left, empty once expired, full when no
    /// expiry is recorded).
    private var playlistBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AppTheme.surface)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(AppTheme.brandGradient)
                }
                .frame(width: 64, height: 64)
                .overlay {
                    Circle()
                        .stroke(AppTheme.brandGradient, lineWidth: 2.5)
                }
                .shadow(color: AppTheme.accentStart.opacity(0.45), radius: 12, y: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headerTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    statusLine
                }
                Spacer(minLength: 8)
                if !isM3U || !currentPlaylist.serverURL.isEmpty {
                    refreshPill
                }
            }

            countsRow

            expiryLine

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
        // The shared glass card (card gradient + the warm brand
        // glow low in the card — the FIXED Design-4 orange, never
        // the user accent — + the top sheen).
        .settingsGlassCard()
        .sectionAppear()
        .task { await loadPlaylistCounts() }
    }

    /// The header's display name: the active playlist's real
    /// name; the stored Xtream username when a playlist carries
    /// no name (M3U playlists always carry one).
    private var headerTitle: String {
        let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return playlist.username.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - Playlist box helpers

    /// The freshest record of the hub's playlist (the sections in
    /// SettingsComponents resolve theirs the same way).
    private var currentPlaylist: Playlist {
        allPlaylists?.first(where: { $0.id == playlist.id }) ?? playlist
    }

    /// The box's status line: the playlist's last known
    /// connection verdict — dot + label, the My Playlists
    /// convention, read fresh from `PlaylistHealthStore` on
    /// every render (a refresh that records a new verdict shows
    /// it as soon as the pill settles) — and the real playlist
    /// count. Neither piece repeats the name or the expiry,
    /// which live in the box's title and expiry line.
    private var statusLine: some View {
        let health = PlaylistHealthStore.health(for: playlist.id)
        return HStack(spacing: 6) {
            Circle()
                .fill(healthColor(health))
                .frame(width: 8, height: 8)
            Text(statusText(health))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusText(_ health: PlaylistHealth) -> String {
        var parts: [String] = [healthLabel(health)]
        if let count = allPlaylists?.count {
            parts.append(
                count == 1
                    ? L("settings.hub.playlist_count_one")
                    : L("settings.hub.playlists_count_format", count)
            )
        }
        return parts.joined(separator: " • ")
    }

    private func healthLabel(_ health: PlaylistHealth) -> String {
        switch health {
        case .responds: return L("playlists.health.responds")
        case .refused: return L("playlists.health.refused")
        case .expired: return L("playlists.health.expired")
        case .unknown: return L("playlists.health.unknown")
        }
    }

    private func healthColor(_ health: PlaylistHealth) -> Color {
        switch health {
        case .responds: return .green
        case .refused: return .red
        case .expired: return .orange
        case .unknown: return .gray.opacity(0.5)
        }
    }

    /// The counts row: one stat cell per catalog kind this
    /// playlist actually carries (Xtream: live / movies /
    /// series; M3U: live only, as before). The build-88 card
    /// squeezed its counts into one line beside the Refresh
    /// pill until "6,801" rendered as "680...". Here the row
    /// spans the whole box and nothing competes with the
    /// numbers: each cell is an icon + short label over the
    /// FULL count (locale-grouped: "6,801" / "22,342" /
    /// "8,473"), a single line at full size in its own equal
    /// share of the width, so a count cannot truncate at any
    /// screen size. Nothing renders until the first real read
    /// lands — never a placeholder 0.
    @ViewBuilder
    private var countsRow: some View {
        if let counts = playlistCounts {
            HStack(alignment: .top, spacing: 12) {
                countStat(
                    icon: "tv",
                    label: L("dashboard.live"),
                    value: counts.live,
                    summary: L("addplaylist.summary.live", counts.live)
                )
                if !isM3U {
                    countStat(
                        icon: "film",
                        label: L("dashboard.movies"),
                        value: counts.movies,
                        summary: L("addplaylist.summary.movies", counts.movies)
                    )
                    countStat(
                        icon: "rectangle.stack",
                        label: L("dashboard.series"),
                        value: counts.series,
                        summary: L("addplaylist.summary.series", counts.series)
                    )
                }
            }
        }
    }

    private func countStat(icon: String, label: String, value: Int, summary: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            // Build 90: the FULL count at every Dynamic Type
            // size — the number scales down rather than ever
            // truncating (lineLimit(1) alone clipped "22,342"
            // to "22,3…" at accessibility sizes).
            Text(value.formatted())
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    /// The box's expiry line: the recorded provider expiry,
    /// from the same store the account card reads — shown in
    /// the hub exactly once, here. Omitted entirely when
    /// nothing real is recorded (and for M3U, which carries no
    /// provider account).
    @ViewBuilder
    private var expiryLine: some View {
        if !isM3U, let expiry = ProviderExpiryStore.expiryDate(playlistId: playlist.id) {
            if ProviderExpiryStore.isExpired(expiryDate: expiry) {
                Text(L("subscription.expired_format", formattedExpiry(expiry)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text(L("settings.hub.active_until_format", formattedExpiry(expiry)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var refreshPill: some View {
        Button {
            Task { await refreshPlaylistCard() }
        } label: {
            HStack(spacing: 6) {
                if isRefreshingPlaylist {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                }
                Text(L("settings.hub.refresh"))
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(AppTheme.accent))
            .shadow(color: AppTheme.accent.opacity(0.45), radius: 9, y: 3)
        }
        .buttonStyle(PressOpacityButtonStyle())
        .disabled(isRefreshingPlaylist)
    }

    private func loadPlaylistCounts() async {
        playlistCounts = await PlaylistValidationService.importedCounts(
            playlistId: playlist.id,
            kind: playlist.kind
        )
    }

    /// The card's refresh: the app's own per-playlist refresh
    /// (see the card's comment), then the counts re-read so the
    /// line shows the post-refresh truth.
    private func refreshPlaylistCard() async {
        guard !isRefreshingPlaylist else { return }
        isRefreshingPlaylist = true
        defer { isRefreshingPlaylist = false }
        if isM3U {
            let target = currentPlaylist
            if !target.serverURL.isEmpty {
                do {
                    let content = try await M3UService().fetchRemote(
                        urlString: target.serverURL,
                        playlist: target
                    )
                    let parsed = try await M3UParser.parseAsync(content)
                    try await M3UImporter.replace(
                        playlist: target,
                        channels: parsed.channels,
                        epgURL: parsed.epgURL
                    )
                    PlaylistHealthStore.record(.responds, for: target.id)
                    await M3UContentStore.shared.reloadIfActive(playlist: target)
                } catch {
                    PlaylistHealthStore.record(.refused, for: target.id)
                }
            }
        } else {
            await PlaylistContentStore.shared.refreshFromNetwork(playlist: currentPlaylist)
        }
        await loadPlaylistCounts()
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
            // Build 88: the shared glass card (the build-71 card
            // gradient, plus the glass sheen).
            .settingsGlassCard(cornerRadius: AppTheme.cornerRadius)
            // Build 81 (item 8): hub sections fade/rise in once.
            .sectionAppear()
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        }
    }

    /// One Style-3 hub row: the title and a chevron beside the
    /// icon chip. Build 88: the chip is the mockup's glowing
    /// accent square — a translucent accent tile, the glyph in
    /// the accent itself, a soft halo under it — reading the
    /// existing accent token, so the row chrome follows the
    /// user's picked accent like the rest of the app (builds
    /// 71–87 kept these chips neutral; the approved build-88
    /// mockup supersedes that for this surface). NO value: the
    /// identity/state lives only in the header card.
    @ViewBuilder
    private func hubRow<Destination: View>(
        icon: String,
        title: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                SettingsIconTile(
                    systemImage: icon,
                    tint: AppTheme.accent.opacity(0.18),
                    size: 36,
                    glyphColor: AppTheme.accent,
                    glowColor: AppTheme.accent.opacity(0.45)
                )
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
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        // Build 88: the press is an accent sheen sweep (build 81
        // gave these rows the plain dim; the sweep supersedes it
        // on this surface).
        .buttonStyle(SettingsSweepPressStyle())
    }

    /// Hairline between grouped rows, inset to the title edge
    /// (14 row padding + 36 icon tile + 12 spacing).
    private var rowDivider: some View {
        Divider()
            .padding(.leading, 62)
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
            // Build 89 (item 6): the separate Provider
            // Subscriptions section is gone — the subscription
            // facts live inside the account card above, once.
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
