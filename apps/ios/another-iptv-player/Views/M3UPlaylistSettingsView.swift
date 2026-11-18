import SwiftUI
import GRDB
import GRDBQuery
import UniformTypeIdentifiers

/// The settings screen specific to an M3U playlist. It has none of Xtream's auth/subscription/stats sections.
///
/// Round 10: rebuilt to the SAME structure as the Xtream settings —
/// account card on top (identity + source + Edit / Sign Out), a
/// Playlists section into My Playlists, grouped Player / App /
/// Content sections, a red Sign Out near the bottom and the brand
/// footer. The old flat "Content & Data" info list is gone here too.
///
/// Round 11: same restructure as the Xtream screen — the content
/// block (refresh actions, stats strip, EPG rows, clear history)
/// moves INTO the identity card, the Player/App groups follow
/// STRONG's order with the same wired round-11 settings, and the
/// card no longer prints the playlist's raw server URL.
struct M3UPlaylistSettingsView: View {
    let playlist: Playlist
    let onDismiss: () -> Void
    /// Round 10: playlist switching from My Playlists (ContentView
    /// owns the selection; threaded through the dashboard).
    let onSwitchPlaylist: (Playlist) -> Void

    @Query<PlaylistRequest> private var allPlaylists: [Playlist]?

    @State private var channelCount: Int = 0
    @State private var groupCount: Int = 0
    @State private var historyCount: Int = 0

    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showFileImporter = false
    @State private var showEditSheet = false

    @State private var filterAdultContent: Bool
    @State private var showClearHistoryAlert = false

    @AppStorage("player.pipEnabled") private var pipEnabled = true
    @AppStorage("player.continuePlayingInBackground") private var continuePlayingInBackground = true
    @AppStorage("player.speedUpOnLongPress") private var speedUpOnLongPress = true
    @AppStorage("player.autoPlayNextEpisode") private var autoPlayNextEpisode = true
    @AppStorage("download.wifi_only") private var downloadWifiOnly = false
    // Round 14 (B3): auto-download next episode — shared key with
    // the Xtream screen; the DownloadManager behavior reads it.
    @AppStorage("downloads.autoDownloadNextEpisode") private var autoDownloadNextEpisode = false
    // Round 11: same wired settings as the Xtream screen (shared keys).
    // Round 14 (A4): the "Next-episode timer" row is removed (T-50
    // card replaces it); Auto-Play Next Episode stays.
    // Round 14 (B4): NO notifications toggle on this screen — the
    // expiry-alerts toggle is Xtream-only (M3U has no account whose
    // expiry could be alerted on).
    @AppStorage("player.showSkipIntro") private var showSkipIntro = true
    @AppStorage("player.skipIntroLengthSeconds") private var skipIntroLengthSeconds = 85
    @AppStorage("player.defaultSleepTimerMinutes") private var defaultSleepTimerMinutes = 0
    // Round 20 (R20-2 cleanup): the "Playback engine" picker is
    // REMOVED, same as the Xtream screen — `player.enginePreference`
    // has no reader since the R20-4 playback restoration, so the
    // picker was inert UI writing an unread key.
    @State private var downloadUsedBytes: Int64 = 0
    @State private var showingDeleteAllDownloadsAlert = false

    // Round 15 (C5/C3): settings search, the settings PIN lock and
    // the adult-filter PIN guard (same as the Xtream screen).
    @State private var settingsSearch = ""
    @State private var pinUnlocked = false
    @State private var showPINForFilterOff = false
    @State private var suppressNextFilterSave = false

    @ObservedObject private var locale = LocalizationManager.shared

    init(playlist: Playlist, onDismiss: @escaping () -> Void, onSwitchPlaylist: @escaping (Playlist) -> Void) {
        self.playlist = playlist
        self.onDismiss = onDismiss
        self.onSwitchPlaylist = onSwitchPlaylist
        _filterAdultContent = State(initialValue: playlist.filterAdultContent)
        _allPlaylists = Query(PlaylistRequest(), in: \.appDatabase)
    }

    /// The freshest copy of this playlist (edits update the row in
    /// place; the struct passed in would otherwise go stale).
    private var currentPlaylist: Playlist {
        allPlaylists?.first(where: { $0.id == playlist.id }) ?? playlist
    }

    var body: some View {
        Group {
            if needsPINLock {
                PINLockScreen { pinUnlocked = true }
            } else {
                settingsForm
            }
        }
    }

    /// Round 15 (C3): opening Settings requires the PIN when the
    /// lock toggle is on and a PIN exists.
    private var needsPINLock: Bool {
        UserDefaults.standard.bool(forKey: "pin.lockSettings") && PINStore.hasPIN && !pinUnlocked
    }

    private var settingsForm: some View {
        Form {
            // — Account card (round 10): identity + source + actions —
            if settingsSearchMatches(settingsSearch, "account playlist source m3u") {
            Section(header: ScopedSectionHeader(title: L("settings.playlist.info.title"), thisPlaylist: true)) {
                accountCard
            }
            }

            // — Playlists (round 10) —
            if settingsSearchMatches(settingsSearch, "playlists my playlists switch") {
            Section(header: ScopedSectionHeader(title: L("playlists.title"), thisPlaylist: false)) {
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
            }

            // — Activation (round 12, point 6): after Playlists,
            // before Player — the shared card component, identical
            // to the Xtream screen. —
            if settingsSearchMatches(settingsSearch, "activation device pin lifetime") {
                ActivationSettingsSection()
            }

            // — Player (round 11: STRONG's order, same rows as the
            // Xtream screen) —
            if settingsSearchMatches(settingsSearch, "player auto-play skip intro pip sleep background long press video fit subtitle audio delay") {
            Section(header: ScopedSectionHeader(title: L("settings.group.player"), thisPlaylist: false)) {
                Toggle(isOn: $autoPlayNextEpisode) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "play.fill", tint: AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings.player.autonext.title"))
                            Text(L("settings.player.autonext.desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle(isOn: $showSkipIntro) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "forward.end.fill", tint: AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings.player.show_skip_intro.title"))
                            Text(L("settings.player.show_skip_intro.desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsPickerRow(
                    systemImage: "stopwatch",
                    tint: .teal,
                    title: L("settings.player.skip_intro_length.title"),
                    selection: $skipIntroLengthSeconds
                ) {
                    ForEach([30, 60, 85, 90, 120], id: \.self) { seconds in
                        Text(L("common.seconds_format", seconds)).tag(seconds)
                    }
                }
                // Round 14 (B4): dimmed/disabled while Skip Intro is off.
                .disabled(!showSkipIntro)
                .opacity(showSkipIntro ? 1 : 0.45)

                Toggle(isOn: $pipEnabled) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "pip.enter", tint: .gray)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings.player.pip.title"))
                            Text(L("settings.player.pip.desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsPickerRow(
                    systemImage: "moon.fill",
                    tint: .indigo,
                    title: L("settings.player.sleep_default.title"),
                    selection: $defaultSleepTimerMinutes
                ) {
                    Text(L("common.off")).tag(0)
                    ForEach([15, 30, 45, 60], id: \.self) { minutes in
                        Text(L("player.sleep_timer.minutes", minutes)).tag(minutes)
                    }
                }

                Toggle(isOn: $continuePlayingInBackground) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "speaker.wave.2.fill", tint: .purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings.player.background.title"))
                            Text(L("settings.player.background.desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle(isOn: $speedUpOnLongPress) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "timer", tint: .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings.player.longpress.title"))
                            Text(L("settings.player.longpress.desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Round 14 (B4): the three NEW real Player rows —
                // same shared components as the Xtream screen.
                VideoFitSettingsRow()

                SubtitleAppearanceSettingsRow()

                AudioDelaySettingsRow()
            }
            }

            // — Content & Data (round 14, B4): standalone group,
            // same structure as the Xtream screen — refresh
            // actions, stats strip, EPG rows (always visible) and
            // Clear Watch History. —
            if settingsSearchMatches(settingsSearch, "content data refresh epg guide history clear counts") {
            Section(header: ScopedSectionHeader(title: L("settings.group.content_data"), thisPlaylist: true)) {
                contentDataRows
            }
            }

            // — Downloads (round 14, B4): its own group. —
            if settingsSearchMatches(settingsSearch, "downloads wifi auto-download storage delete") {
            Section(header: ScopedSectionHeader(title: L("download.title"), thisPlaylist: true)) {
                NavigationLink {
                    DownloadsView(playlist: playlist)
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "arrow.down.circle.fill", tint: .green)
                        Text(L("download.title"))
                    }
                }

                Toggle(isOn: $downloadWifiOnly) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "wifi", tint: .teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("download.wifi_only.title"))
                            Text(L("download.wifi_only.desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Round 14 (B3): shared auto-download key.
                Toggle(isOn: $autoDownloadNextEpisode) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "arrow.down.to.line.compact", tint: AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("download.auto_next.title"))
                            Text(L("download.auto_next.desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "internaldrive", tint: .gray)
                    Text(L("download.storage_used"))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: downloadUsedBytes, countStyle: .file))
                        .foregroundColor(.secondary)
                }

                if downloadUsedBytes > 0 {
                    Button(role: .destructive) {
                        showingDeleteAllDownloadsAlert = true
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIconTile(systemImage: "trash", tint: .red)
                            Text(L("download.delete_all"))
                        }
                    }
                }
            }
            }

            // — App & Appearance (round 14, B4): language, accent
            // and parental controls. NO notifications toggle here —
            // it is Xtream-only and removed from this screen. —
            if settingsSearchMatches(settingsSearch, "app appearance language accent parental filter adult") {
            Section(header: ScopedSectionHeader(title: L("settings.group.app_appearance"), thisPlaylist: false)) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "globe", tint: AppTheme.accent)
                    LanguagePickerRow()
                }

                // Round 7: accent color picker (owner's order).
                AccentColorPickerRow()

                // Parental Controls — the real adult-content
                // filter. Round 15 (C5): turning it OFF requires
                // the parental PIN when one is set.
                Toggle(isOn: $filterAdultContent) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "shield.fill", tint: .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings.parental_controls.title"))
                            Text(L("settings.filter_adult.m3u_desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onChange(of: filterAdultContent) { _, newValue in
                    if suppressNextFilterSave {
                        suppressNextFilterSave = false
                        return
                    }
                    if newValue == false, PINStore.hasPIN {
                        suppressNextFilterSave = true
                        filterAdultContent = true
                        showPINForFilterOff = true
                        return
                    }
                    Task { await saveFilterSetting(newValue: newValue) }
                }
            }
            }

            // — Round 15 (Part C): new feature settings, the
            // parental PIN group and Backup & Reset. —
            if settingsSearchMatches(settingsSearch, "advanced reminders zapping motion next episode ui sounds image cache") {
                NewFeatureSettingsSection()
            }
            if settingsSearchMatches(settingsSearch, "pin parental lock settings") {
                ParentalPINSection()
            }
            if settingsSearchMatches(settingsSearch, "backup export import reset defaults transfer") {
                BackupSettingsSection(playlists: allPlaylists ?? [])
            }

            // — About & Legal (round 14, B4): version ONCE here.
            // Round 17 (R17-6): the "Open-source project → GitHub"
            // row is REMOVED (identical to the Xtream screen);
            // the MIT licenses / credits notice stays, as the
            // license requires. —
            if settingsSearchMatches(settingsSearch, "about version licenses credits legal") {
            Section(header: ScopedSectionHeader(title: L("settings.group.about_legal"), thisPlaylist: false)) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "info.circle", tint: .gray)
                    Text(L("settings.about.version")); Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                        .foregroundColor(.secondary)
                }
                NavigationLink {
                    LegalDocumentView(kind: .license)
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "doc.text", tint: .gray)
                        Text(L("settings.about.licenses.title"))
                    }
                }
            }
            }

            // — Privacy & Legal (round 12, point 4): the shared
            // group, identical to the Xtream screen. Round 14
            // (B4): stays LAST before the brand footer. —
            if settingsSearchMatches(settingsSearch, "privacy legal support terms report delete account") {
                PrivacyLegalSection(onExitToGate: onDismiss)
            }

            // Round 14 (B4): the standalone Sign Out section is
            // DELETED — Sign Out lives ONCE, in the identity card.

            // — Brand footer (round 14, B4): wordmark only, no
            // version number. —
            if settingsSearch.isEmpty {
            Section {
                VStack(spacing: 4) {
                    HStack(spacing: 3) {
                        Text("Super")
                        Text("X")
                            .foregroundColor(AppTheme.accent)
                    }
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            }
        }
        .searchable(text: $settingsSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: L("common.search"))
        .sheet(isPresented: $showPINForFilterOff) {
            PINEntrySheet(message: L("pin.guard.filter_off")) {
                // PIN accepted: apply the OFF change for real (the
                // suppress flag keeps the guard from re-firing).
                suppressNextFilterSave = true
                filterAdultContent = false
                Task { await saveFilterSetting(newValue: false) }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            AddM3UPlaylistView(editingPlaylist: currentPlaylist)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.allowedFileTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert(L("common.error"), isPresented: $showError, actions: {
            Button(L("common.ok"), role: .cancel) { }
        }, message: {
            Text(errorMessage ?? L("common.unknown_error"))
        })
        .alert(L("history.clear.title"), isPresented: $showClearHistoryAlert) {
            Button(L("common.cancel"), role: .cancel) { }
            Button(L("common.confirm_delete_yes"), role: .destructive) {
                Task { await clearHistory() }
            }
        } message: {
            Text(L("history.clear.message.all"))
        }
        .alert(L("download.delete_all"), isPresented: $showingDeleteAllDownloadsAlert) {
            Button(L("common.cancel"), role: .cancel) { }
            Button(L("common.confirm_delete_yes"), role: .destructive) {
                Task {
                    await DownloadManager.shared.deleteAll(playlistId: playlist.id)
                    await refreshDownloadUsage()
                }
            }
        } message: {
            Text(L("download.delete_all.message"))
        }
        .task {
            await fetchStats()
            await refreshDownloadUsage()
        }
        .refreshable {
            await fetchStats()
            await refreshDownloadUsage()
        }
        .cinematicScrollBackground()
    }

    // MARK: - Account card (round 10)

    /// Identity card at the top of Settings, mirroring the Xtream
    /// card's treatment and structure. M3U playlists have no account,
    /// no connection state and no subscription, so the card shows the
    /// kind badge and the playlist's source KIND (local file / remote
    /// playlist — round 11: never the raw server URL) — plus the
    /// same Edit / Sign Out actions and, in its lower half, the
    /// content block.
    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: "list.bullet",
                                 tint: AppTheme.accent, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentPlaylist.name)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("M3U")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.16), in: Capsule())
                        Text(currentPlaylist.serverURL.isEmpty ? L("playlists.local_file") : L("playlists.remote_playlist"))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                Spacer()
            }

            Divider()
                .overlay(Color.white.opacity(0.10))

            HStack(spacing: 10) {
                Button {
                    showEditSheet = true
                } label: {
                    Label(L("common.edit"), systemImage: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    onDismiss()
                } label: {
                    Label(L("settings.sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.red.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // Round 14 (B4): the content block no longer lives in
            // this card — it is the standalone Content & Data group
            // below (`contentDataRows`). The card is identity +
            // Edit / Sign Out only.
        }
        .padding(14)
        // Round 16 (P4a): pre-composited OPAQUE card background —
        // same change as PlaylistSettingsView (identical look, one
        // opaque layer instead of a live alpha blend while scrolling).
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(AppTheme.background)
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(LinearGradient(colors: [AppTheme.accent.opacity(0.38), AppTheme.surface],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Content & Data group (round 14)

    /// Round 14 (B4): the Content & Data block as a standalone Form
    /// group (round 11 had moved it into the identity card):
    /// refresh-from-URL / refresh-from-file actions (+ progress),
    /// the three-count strip, the TV Guide (EPG) rows — always
    /// visible — with their explanatory caption, and Clear Watch
    /// History. Every action wired exactly as before.
    private var contentDataRows: some View {
        Group {
            if !currentPlaylist.serverURL.isEmpty {
                Button {
                    Task { await refreshFromURL() }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "arrow.clockwise", tint: AppTheme.accent)
                        Text(L("settings.m3u.refresh_url"))
                            .foregroundColor(.primary)
                        Spacer()
                        if isSyncing { ProgressView() }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSyncing)
            }

            Button {
                showFileImporter = true
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "doc.badge.arrow.up", tint: AppTheme.accent)
                    Text(L("settings.m3u.refresh_file"))
                        .foregroundColor(.primary)
                }
            }
            .buttonStyle(.plain)
            .disabled(isSyncing)

            if isSyncing, let msg = syncMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Content statistics as ONE compact strip.
            HStack(spacing: 0) {
                statCell(value: channelCount, label: L("dashboard.channels"))
                statCell(value: groupCount, label: L("settings.stats.group_count"))
                statCell(value: historyCount, label: L("settings.stats.history_count"))
            }
            .padding(.vertical, 2)

            // TV Guide (EPG) — always visible (round 14, B4).
            M3UEPGSettingsRows(playlist: playlist)

            Text(L("epg.settings.url_footer"))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Clear watch history (verbatim action + alert).
            Button(role: .destructive) {
                showClearHistoryAlert = true
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "trash", tint: .red)
                    Text(L("history.clear.button_entry"))
                        .foregroundColor(.red)
                }
            }
            .buttonStyle(.plain)
            .disabled(historyCount == 0)
        }
    }

    /// One cell of the card's stat strip.
    private func statCell(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text(CatalogCountFormatter.string(value))
                .font(.subheadline.weight(.bold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func refreshDownloadUsage() async {
        let pid = playlist.id
        let bytes = await Task.detached(priority: .utility) {
            DownloadStorage.usedBytes(playlistId: pid)
        }.value
        await MainActor.run { downloadUsedBytes = bytes }
    }

    // MARK: - File Picker

    private static var allowedFileTypes: [UTType] {
        var types: [UTType] = [.plainText, .data]
        if let m3u = UTType(filenameExtension: "m3u") { types.insert(m3u, at: 0) }
        if let m3u8 = UTType(filenameExtension: "m3u8") { types.insert(m3u8, at: 0) }
        return types
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            errorMessage = err.localizedDescription
            showError = true
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await refreshFromLocalFile(url: url) }
        }
    }

    // MARK: - Sync

    private func refreshFromURL() async {
        isSyncing = true
        syncMessage = L("settings.m3u.downloading")
        defer {
            isSyncing = false
            syncMessage = nil
        }
        do {
            let content = try await M3UService().fetchRemote(urlString: currentPlaylist.serverURL)
            syncMessage = L("settings.m3u.parsing")
            let parsed = try await M3UParser.parseAsync(content)
            syncMessage = L("settings.m3u.saving")
            try await M3UImporter.replace(
                playlist: currentPlaylist,
                channels: parsed.channels,
                epgURL: parsed.epgURL
            )
            PlaylistHealthStore.record(.responds, for: currentPlaylist.id)
            await fetchStats()
            await M3UContentStore.shared.reloadIfActive(playlist: currentPlaylist)
        } catch {
            PlaylistHealthStore.record(.refused, for: currentPlaylist.id)
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func refreshFromLocalFile(url: URL) async {
        isSyncing = true
        syncMessage = L("settings.m3u.reading_file")
        defer {
            isSyncing = false
            syncMessage = nil
        }
        do {
            let content = try await M3UService().readLocalAsync(url: url)
            syncMessage = L("settings.m3u.parsing")
            let parsed = try await M3UParser.parseAsync(content)
            syncMessage = L("settings.m3u.saving")
            try await M3UImporter.replace(
                playlist: currentPlaylist,
                channels: parsed.channels,
                epgURL: parsed.epgURL,
                clearServerURL: true
            )
            PlaylistHealthStore.record(.responds, for: currentPlaylist.id)
            await fetchStats()
            await M3UContentStore.shared.reloadIfActive(playlist: currentPlaylist)
        } catch {
            PlaylistHealthStore.record(.refused, for: currentPlaylist.id)
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func fetchStats() async {
        do {
            let pid = playlist.id
            let stats = try await AppDatabase.shared.read { db -> (Int, Int, Int) in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM m3uChannel WHERE playlistId = ?", arguments: [pid]) ?? 0
                let groups = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT groupTitle) FROM m3uChannel WHERE playlistId = ?", arguments: [pid]) ?? 0
                let history = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watchHistory WHERE playlistId = ?", arguments: [pid]) ?? 0
                return (count, groups, history)
            }
            await MainActor.run {
                self.channelCount = stats.0
                self.groupCount = stats.1
                self.historyCount = stats.2
            }
        } catch {
            Log.error("M3USettings", "stats fetch error: \(error.localizedDescription)")
        }
    }

    // MARK: - Adult Filter / History

    private func saveFilterSetting(newValue: Bool) async {
        var updated = currentPlaylist
        updated.filterAdultContent = newValue
        do {
            try await AppDatabase.shared.write { db in
                try updated.save(db)
            }
            await M3UContentStore.shared.reloadIfActive(playlist: updated)
        } catch {
            errorMessage = L("misc.save_setting_error", error.localizedDescription)
            showError = true
        }
    }

    private func clearHistory() async {
        do {
            let pid = playlist.id
            try await AppDatabase.shared.write { db in
                try db.execute(sql: "DELETE FROM watchHistory WHERE playlistId = ?", arguments: [pid])
            }
            await fetchStats()
        } catch {
            errorMessage = L("misc.history_delete_error", error.localizedDescription)
            showError = true
        }
    }
}
