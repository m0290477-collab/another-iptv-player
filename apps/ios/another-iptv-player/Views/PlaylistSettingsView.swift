import SwiftUI
import GRDB
import GRDBQuery

struct PlaylistSettingsView: View {
    let playlist: Playlist
    let onDismiss: () -> Void
    /// Round 10: switching the active playlist from My Playlists —
    /// threaded from ContentView (which owns the selection) through
    /// the dashboard into this screen.
    let onSwitchPlaylist: (Playlist) -> Void

    @Query<PlaylistRequest> private var allPlaylists: [Playlist]?

    @State private var authResponse: XtreamAuthResponse?
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// A catalog refresh (syncContents) error — kept separate from the playlist info error (errorMessage);
    /// they used to get mixed up and "Try Again" triggered the wrong action.
    @State private var syncError: String?

    @State private var isPasswordRevealed = false
    @State private var showEditSheet = false

    @State private var isSyncing = false
    @State private var progressMessage: String?

    @State private var liveCount: Int = 0
    @State private var vodCount: Int = 0
    @State private var seriesCount: Int = 0
    @State private var historyCount: Int = 0

    @State private var filterAdultContent: Bool
    @State private var showClearHistoryAlert = false

    @AppStorage("player.pipEnabled") private var pipEnabled = true
    @AppStorage("player.continuePlayingInBackground") private var continuePlayingInBackground = true
    @AppStorage("player.speedUpOnLongPress") private var speedUpOnLongPress = true
    @AppStorage("player.autoPlayNextEpisode") private var autoPlayNextEpisode = true
    @AppStorage("download.wifi_only") private var downloadWifiOnly = false
    // Round 14 (B3): auto-download next episode — the DownloadManager
    // behavior reads this exact key.
    @AppStorage("downloads.autoDownloadNextEpisode") private var autoDownloadNextEpisode = false
    // Round 11: the STRONG-arrangement settings that were missing —
    // every one wired to real behavior in PlayerView / KSPlayerEngine
    // / NotificationsView (same UserDefaults keys on both sides).
    // Round 14 (A4): the old "Next-episode timer" row is GONE — its
    // meaning is replaced by the T-50s next-episode card; the
    // Auto-Play Next Episode toggle above stays as the master switch.
    @AppStorage("player.showSkipIntro") private var showSkipIntro = true
    @AppStorage("player.skipIntroLengthSeconds") private var skipIntroLengthSeconds = 85
    @AppStorage("player.defaultSleepTimerMinutes") private var defaultSleepTimerMinutes = 0
    // Round 20 (R20-2 cleanup): the "Playback engine" picker is
    // REMOVED — the R20-4 playback restoration dropped the only
    // reader of `player.enginePreference` (build-33 playback has
    // no engine-preference override), so the picker wrote a key
    // nothing read: inert UI. The stored key itself is left in
    // UserDefaults untouched; it is simply never read or written
    // again.
    @AppStorage("notifications.expiryAlertsEnabled") private var expiryAlertsEnabled = true

    @State private var downloadUsedBytes: Int64 = 0
    @State private var showingDeleteAllDownloadsAlert = false

    // Round 14 (B3): "Test connection" state (account card button).
    @State private var isTestingConnection = false
    @State private var connectionTestResult: String?

    // Round 15 (C5/C3): settings search, the settings PIN lock and
    // the adult-filter PIN guard.
    @State private var settingsSearch = ""
    @State private var pinUnlocked = false
    @State private var showPINForFilterOff = false
    @State private var suppressNextFilterSave = false

    init(playlist: Playlist, onDismiss: @escaping () -> Void, onSwitchPlaylist: @escaping (Playlist) -> Void) {
        self.playlist = playlist
        self.onDismiss = onDismiss
        self.onSwitchPlaylist = onSwitchPlaylist
        _filterAdultContent = State(initialValue: playlist.filterAdultContent)
        _allPlaylists = Query(PlaylistRequest(), in: \.appDatabase)
    }

    /// The freshest copy of this playlist (an edit from the account
    /// card or My Playlists updates the row in place; the struct the
    /// dashboard passed in would otherwise go stale for the rest of
    /// the session).
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
            // — Account card (round 10): identity, ALL subscription
            // info and the Edit / Sign Out actions in ONE card. This
            // replaces the old flat "Content & Data" info list —
            // nothing of that list remains as a long flat section. —
            if settingsSearchMatches(settingsSearch, "account subscription playlist username password expiry connection test") {
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
            // before Player — the shared card component. —
            if settingsSearchMatches(settingsSearch, "activation device pin lifetime") {
                ActivationSettingsSection()
            }

            // — Player (round 14, B4: the "Next-episode timer" row
            // is removed — A4's T-50 card replaces it; Auto-Play Next
            // Episode stays as the master switch. NEW real rows:
            // Default video fit (the player's own
            // player.videoAspectMode), Subtitle Appearance (the
            // existing sheet, presented at last) and Audio Delay
            // (the tracks panel's AudioDelayPersistence). Skip Intro
            // length is disabled/dimmed while its toggle is off.) —
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

                // Round 14 (B4): the three NEW real Player rows.
                VideoFitSettingsRow()

                SubtitleAppearanceSettingsRow()

                AudioDelaySettingsRow()
            }
            }

            // — Build 61 (B3, owner rule O5 — fixed group order
            // Playback / Appearance / Downloads / Parental /
            // Storage / Support & About): the Playback group
            // (buffer, play-last-channel) and the Appearance
            // group (appearance choice) directly follow the
            // legacy Player group, ahead of Downloads. —
            if settingsSearchMatches(settingsSearch, "buffer play last channel launch playback") {
                PlaybackSettingsSection()
            }
            if settingsSearchMatches(settingsSearch, "appearance theme light dark") {
                AppearanceSettingsSection()
            }

            // — Content & Data (round 14, B4): a standalone group
            // again — the block leaves the account card so the EPG
            // rows are ALWAYS visible, not gated on the account
            // fetch succeeding. Re-download, the counts strip and
            // Clear Watch History live here too. —
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

                // Round 14 (B3): the DownloadManager's auto-download
                // behavior reads this exact AppStorage key.
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

            // — App & Appearance (round 14, B4): language, accent,
            // the expiry-alerts toggle and parental controls raised
            // into one group. —
            if settingsSearchMatches(settingsSearch, "app appearance language accent expiry alerts notifications parental filter adult") {
            Section(header: ScopedSectionHeader(title: L("settings.group.app_appearance"), thisPlaylist: false)) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "globe", tint: AppTheme.accent)
                    LanguagePickerRow()
                }

                // Round 7: accent color picker (owner's order).
                AccentColorPickerRow()

                // Round 11: real gate for the provider-expiry alerts
                // — NotificationsView derives no items while this is
                // off. (These are in-app alerts; the app has no push
                // pipeline and the row does not pretend otherwise.)
                // Round 14 (B4): relabeled to say exactly that —
                // "Subscription expiry alerts" (Xtream screen only).
                Toggle(isOn: $expiryAlertsEnabled) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "bell.fill", tint: .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings.app.expiry_alerts.title"))
                            Text(L("settings.app.notifications.desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Parental Controls — the app's real adult-content
                // filter. Round 15 (C5): turning the filter OFF
                // requires the parental PIN when one is set — the
                // toggle reverts until the PIN is entered.
                Toggle(isOn: $filterAdultContent) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "shield.fill", tint: .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings.parental_controls.title"))
                            Text(L("settings.filter_adult.xtream_desc"))
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
            // — Build 61 (B3, O5): the Parental group continues
            // with the locked categories (item 5), then the
            // Storage group (T1 cache). —
            if settingsSearchMatches(settingsSearch, "locked categories parental lock pin") {
                LockedCategoriesSection(playlist: playlist)
            }
            if settingsSearchMatches(settingsSearch, "storage cache space") {
                StorageSettingsSection()
            }
            if settingsSearchMatches(settingsSearch, "backup export import reset defaults transfer") {
                BackupSettingsSection(playlists: allPlaylists ?? [])
            }

            // — Build 61 (B3, Support & About group, O5):
            // subscriptions (T5) and support (item 13) sit with
            // the backup section above and About/Privacy below —
            // the whole tail of this form is the Support & About
            // group, in the fixed order. —
            if settingsSearchMatches(settingsSearch, "subscription expiry provider playlists") {
                SubscriptionSettingsSection(playlists: allPlaylists ?? [])
            }
            if settingsSearchMatches(settingsSearch, "support faq help diagnostics") {
                SupportSettingsSection(playlists: allPlaylists ?? [])
            }

            // — About & Legal (round 14, B4): the version appears
            // ONCE, here. Round 17 (R17-6): the "Open-source
            // project → GitHub" row is REMOVED — Super X does not
            // present itself as a GitHub project. What stays is
            // the one thing the MIT license requires: a licenses /
            // credits notice for the original project. —
            if settingsSearchMatches(settingsSearch, "about version licenses credits legal") {
            Section(header: ScopedSectionHeader(title: L("settings.group.about_legal"), thisPlaylist: false)) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "info.circle", tint: .gray)
                    Text(L("settings.about.version"))
                    Spacer()
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
            // group — Contact Support, Privacy Policy, Terms of
            // Use, Report objectionable content, Delete Account.
            // Round 14 (B4): stays LAST before the brand footer. —
            if settingsSearchMatches(settingsSearch, "privacy legal support terms report delete account") {
                PrivacyLegalSection(onExitToGate: onDismiss)
            }

            // — Build 61 (B3, T6): danger zone, double-confirmed. —
            if settingsSearchMatches(settingsSearch, "danger sign out erase delete all data zone") {
                DangerZoneSection(onExitToGate: onDismiss)
            }

            // Round 14 (B4): the standalone Sign Out section is
            // DELETED — Sign Out lives ONCE, in the account card.

            // — Brand footer (round 14, B4): wordmark only — the
            // version number moved out (it appears once, in About). —
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
                // suppress flag keeps the guard from re-firing on
                // this programmatic change).
                suppressNextFilterSave = true
                filterAdultContent = false
                Task { await saveFilterSetting(newValue: false) }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            AddPlaylistView(editingPlaylist: currentPlaylist)
        }
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
            await fetchAuthInfo()
            await fetchLocalStats()
            await refreshDownloadUsage()
        }
        .refreshable {
            await fetchAuthInfo()
            await fetchLocalStats()
            await refreshDownloadUsage()
        }
        .cinematicScrollBackground()
    }

    // MARK: - Account card (round 10)

    /// The complete account box at the top of Settings: identity
    /// (icon tile, name, live connection status, kind badge), the
    /// remaining-time bar, ALL subscription info as compact rows
    /// (username, password with reveal, the PROVIDER subscription's
    /// expiry and remaining time, active/max connections — every
    /// value from the live auth fetch or the saved playlist, nothing
    /// invented; no server address, per round 11), the Edit / Sign
    /// Out actions, and — round 14 — the Test Connection button.
    /// (Round 11's in-card Content & Data block moved back out to
    /// its own group in round 14 — see `contentDataRows`.) While
    /// the fetch is in flight the card shows its progress; on
    /// failure it shows the error and the retry — the states the
    /// old flat list carried.
    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: currentPlaylist.kind == .m3u ? "list.bullet" : "tv",
                                 tint: AppTheme.accent, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentPlaylist.name)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if authResponse?.userInfo != nil {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 7, height: 7)
                            Text(L("settings.playlist.connected"))
                                .font(.caption)
                                .foregroundColor(.green)
                        } else if isLoading {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 7, height: 7)
                            Text(L("settings.playlist.checking"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 7, height: 7)
                            Text(L("settings.playlist.connection_failed"))
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        Text(currentPlaylist.kind == .m3u ? "M3U" : "Xtream")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.16), in: Capsule())
                    }
                }
                Spacer()
            }

            if let userInfo = authResponse?.userInfo,
               let fraction = subscriptionRemainingFraction(userInfo: userInfo) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(AppTheme.accent)
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 3)
            }

            // Compact account facts. Round 11: NO Server URL row —
            // the owner ordered the raw server address out of
            // Settings entirely.
            VStack(alignment: .leading, spacing: 7) {
                accountInfoRow(label: L("settings.playlist.username"), value: currentPlaylist.username)

                // Password row with the reveal toggle the old list had.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L("settings.playlist.password"))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 108, alignment: .leading)
                    Text(isPasswordRevealed
                         ? currentPlaylist.password
                         : String(repeating: "•", count: currentPlaylist.password.count))
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        isPasswordRevealed.toggle()
                    } label: {
                        Image(systemName: isPasswordRevealed ? "eye.slash" : "eye")
                            .font(.caption)
                            .foregroundColor(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPasswordRevealed ? L("settings.hide_password") : L("settings.show_password"))
                }

                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L("settings.playlist.fetching_info"))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                } else if let error = errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("settings.playlist.info_error", error))
                            .font(.caption)
                            .foregroundColor(.red)
                        Button(L("common.try_again")) {
                            Task { await fetchAuthInfo() }
                        }
                        .font(.caption.weight(.semibold))
                    }
                } else if let userInfo = authResponse?.userInfo {
                    // Round 11 (points 7–8): the expiry is the
                    // PROVIDER (panel) subscription's — labeled
                    // exactly that way, with honest remaining-time
                    // math (an expiry today reads "Expires today",
                    // never a bare "0 Days" next to Connected). An
                    // account with no exp_date has no expiry, full
                    // stop — the row says so instead of guessing.
                    if let expiry = providerExpiryDate(userInfo.expDate) {
                        accountInfoRow(
                            label: L("settings.account.provider_subscription"),
                            value: L("settings.account.until_format", formattedExpiry(expiry))
                        )
                        // Round 14 (A1): the ONE expiry verdict —
                        // the shared store's timestamp semantics
                        // (now > exp_date), same as the gate and
                        // the playback block.
                        accountInfoRow(
                            label: L("settings.playlist.subscription"),
                            value: ProviderExpiryStore.isExpired(expDateString: userInfo.expDate)
                                ? L("settings.playlist.expired")
                                : providerRemainingText(expiry: expiry)
                        )
                    } else {
                        accountInfoRow(
                            label: L("settings.account.provider_subscription"),
                            value: L("settings.account.no_expiry")
                        )
                    }
                    accountInfoRow(
                        label: L("settings.playlist.active_connection"),
                        value: userInfo.activeCons ?? L("settings.playlist.unknown")
                    )
                    accountInfoRow(
                        label: L("settings.playlist.max_connection"),
                        value: userInfo.maxConnections ?? L("settings.playlist.unlimited")
                    )
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.10))

            // Card actions: Edit (the existing edit flow) and Sign Out
            // (back to the gate — the app's sign-out).
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

            Divider()
                .overlay(Color.white.opacity(0.10))

            // Round 14 (B3): Test connection — verify + a short
            // stream probe, reported in plain language under the
            // button. Runs on demand only.
            Button {
                Task { await testConnection() }
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "antenna.radiowaves.left.and.right", tint: AppTheme.accent)
                    Text(L("settings.test_connection.title"))
                        .foregroundColor(.white)
                    Spacer()
                    if isTestingConnection {
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isTestingConnection)

            if isTestingConnection {
                Text(L("settings.test_connection.testing"))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            } else if let connectionTestResult {
                Text(connectionTestResult)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Round 14 (B4): the Content & Data block no longer
            // lives in this card — it is its own group below
            // (`contentDataRows`), so its EPG rows are always
            // visible. The card is identity + subscription +
            // Edit / Sign Out + this test, nothing more.
        }
        .padding(14)
        // Round 16 (P4a): pre-composited OPAQUE card background —
        // the same gradient over the page's own backdrop color in
        // one background stack, instead of an alpha gradient blended
        // live over the scrolling Form on every frame (a contributor
        // to the Settings scroll ghosting). Pixel-identical result.
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
    /// group: Re-download All Content (+ progress / error / retry),
    /// the four-count strip (local DB counts — always available),
    /// time zone + server message (shown when the auth fetch has
    /// them), the TV Guide (EPG) rows — ALWAYS visible now, no
    /// longer gated on the account fetch succeeding — and Clear
    /// Watch History. Every action wired exactly as before.
    private var contentDataRows: some View {
        Group {
            Button(action: {
                Task { await syncContents() }
            }) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "arrow.clockwise", tint: AppTheme.accent)
                    Text(L("settings.refresh_all"))
                        .foregroundColor(.primary)
                    Spacer()
                    if isSyncing {
                        ProgressView()
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isSyncing)

            if isSyncing, let msg = progressMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let syncError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(syncError)
                        .font(.caption)
                        .foregroundColor(.red)
                    Button(L("common.try_again")) {
                        Task { await syncContents() }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                }
            }

            // Content statistics as ONE compact strip (local counts).
            HStack(spacing: 0) {
                statCell(value: liveCount, label: L("dashboard.live"))
                statCell(value: vodCount, label: L("dashboard.movies"))
                statCell(value: seriesCount, label: L("dashboard.series"))
                statCell(value: historyCount, label: L("settings.stats.history_count"))
            }
            .padding(.vertical, 2)

            if let timeZone = authResponse?.serverInfo?.timezone {
                HStack(spacing: 12) {
                    Text(L("settings.server.timezone"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(timeZone)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let message = authResponse?.userInfo?.message, !message.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("settings.server.message"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // TV Guide (EPG) — ALWAYS visible (round 14, B4).
            XtreamEPGSettingsRows(playlist: playlist)

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

    // MARK: - Test connection (round 14, B3)

    /// Verify + a short stream probe, reported in plain language:
    /// server reachable / account active or expired / stream OK or
    /// refused. The probe is a bounded data task (8 s timeout, first
    /// bytes only, then cancelled) against the first live channel's
    /// real stream URL — the same URL the player would open.
    private func testConnection() async {
        isTestingConnection = true
        connectionTestResult = nil
        defer { isTestingConnection = false }

        let client = XtreamAPIClient(playlist: currentPlaylist)
        let response: XtreamAuthResponse
        do {
            response = try await client.verify()
        } catch {
            PlaylistHealthStore.record(.refused, for: currentPlaylist.id)
            connectionTestResult = L("settings.test_connection.unreachable")
            return
        }
        PlaylistHealthStore.recordVerified(playlistId: currentPlaylist.id, expDate: response.userInfo?.expDate)

        var parts: [String] = [L("settings.test_connection.server_ok")]
        let expired = ProviderExpiryStore.isExpired(expDateString: response.userInfo?.expDate)
            || (response.userInfo?.status?.caseInsensitiveCompare("Expired") == .orderedSame)
        parts.append(expired
            ? L("settings.test_connection.account_expired")
            : L("settings.test_connection.account_active"))

        // First live channel id from the local catalog for the probe.
        let pid = currentPlaylist.id
        let firstLiveId: Int? = try? await AppDatabase.shared.read { db in
            try Int.fetchOne(db, sql: "SELECT streamId FROM liveStream WHERE playlistId = ? ORDER BY streamId LIMIT 1", arguments: [pid])
        }
        guard let firstLiveId,
              let probeURL = PlaybackURLBuilder(playlist: currentPlaylist).liveURL(streamId: firstLiveId) else {
            parts.append(L("settings.test_connection.no_channel"))
            connectionTestResult = parts.joined(separator: " · ")
            return
        }

        // Stream probe: open the URL and read only the FIRST bytes
        // (AsyncBytes returns at the headers; one byte proves data
        // actually flows), then cancel — a live stream would
        // otherwise download forever. 8 s caps the whole probe.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, httpResponse) = try await session.bytes(for: URLRequest(url: probeURL))
            if let http = httpResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                parts.append(L("settings.test_connection.stream_refused"))
            } else {
                var iterator = bytes.makeAsyncIterator()
                let firstByte = try await iterator.next()
                parts.append(firstByte != nil
                    ? L("settings.test_connection.stream_ok")
                    : L("settings.test_connection.stream_refused"))
            }
        } catch {
            parts.append(L("settings.test_connection.stream_refused"))
        }
        connectionTestResult = parts.joined(separator: " · ")
    }

    /// One compact label/value line inside the account card.
    private func accountInfoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 108, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    /// One cell of the Content section's stat strip.
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

    /// The panel's provider-subscription expiry as a real date; nil
    /// for the no-expiry cases (timestamp 0, absent or unparseable),
    /// which the provider row then describes as "No expiry".
    private func providerExpiryDate(_ expDate: String?) -> Date? {
        guard let expDate, let timestamp = TimeInterval(expDate), timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func formattedExpiry(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// Honest remaining-time text for the provider subscription
    /// (round 11, point 8): calendar-day math, so the expiry day
    /// itself reads "Expires today" — the old code's raw
    /// dateComponents difference printed a bare "0 Days" next to a
    /// Connected status, which read as broken. Past the date the row
    /// says "Expired"; there is no path to an invented value.
    private func providerRemainingText(expiry: Date) -> String {
        let now = Date()
        if expiry <= now {
            return L("settings.playlist.expired")
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(expiry) {
            return L("settings.account.expires_today")
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: expiry)
        ).day ?? 0
        if days <= 1 {
            return L("settings.account.day_left")
        }
        return L("settings.account.days_left", days)
    }

    /// Fraction of the subscription period still remaining, computed
    /// from the live-fetched created_at / exp_date timestamps. Nil when
    /// either value is missing or unparseable, the period is degenerate,
    /// or the subscription has already expired (the card line already
    /// reads "Expired" then) — the bar is never shown on invented data.
    private func subscriptionRemainingFraction(userInfo: XtreamUserInfo) -> Double? {
        guard let createdStr = userInfo.createdAt, let created = TimeInterval(createdStr),
              let expStr = userInfo.expDate, let exp = TimeInterval(expStr),
              exp > created else { return nil }
        let remaining = exp - Date().timeIntervalSince1970
        guard remaining > 0 else { return nil }
        return min(1, max(0, remaining / (exp - created)))
    }

    private func refreshDownloadUsage() async {
        let pid = playlist.id
        let bytes = await Task.detached(priority: .utility) {
            DownloadStorage.usedBytes(playlistId: pid)
        }.value
        await MainActor.run { downloadUsedBytes = bytes }
    }

    private func fetchLocalStats() async {
        do {
            let pid = playlist.id
            let counts = try await AppDatabase.shared.read { db in
                let live = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liveStream WHERE playlistId = ?", arguments: [pid]) ?? 0
                let vod = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vodStream WHERE playlistId = ?", arguments: [pid]) ?? 0
                let series = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM series WHERE playlistId = ?", arguments: [pid]) ?? 0
                let history = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watchHistory WHERE playlistId = ?", arguments: [pid]) ?? 0
                return (live, vod, series, history)
            }

            await MainActor.run {
                self.liveCount = counts.0
                self.vodCount = counts.1
                self.seriesCount = counts.2
                self.historyCount = counts.3
            }
        } catch {
            Log.error("PlaylistSettings", "Stats fetch error: \(error.localizedDescription)")
        }
    }

    private func clearHistory() async {
        do {
            let pid = playlist.id
            try await AppDatabase.shared.write { db in
                try db.execute(sql: "DELETE FROM watchHistory WHERE playlistId = ?", arguments: [pid])
            }
            await fetchLocalStats()
            // Continue watching row in Dashboard will update via GRDB watcher if implemented,
            // or on next disappear/appear.
        } catch {
            Log.error("PlaylistSettings", "History clear error: \(error.localizedDescription)")
        }
    }

    private func fetchAuthInfo() async {
        isLoading = true
        errorMessage = nil
        let client = XtreamAPIClient(playlist: currentPlaylist)
        do {
            let response = try await client.verify()
            // Round 12 (point 9): feed the playback gate's expiry
            // record from the same verify the account card shows.
            // Round 15 (C13): the same outcome feeds the per-playlist
            // health dot (recordVerified also records the expiry).
            PlaylistHealthStore.recordVerified(playlistId: currentPlaylist.id, expDate: response.userInfo?.expDate)
            await MainActor.run {
                self.authResponse = response
                self.isLoading = false
            }
            // Refresh the cached panel timezone (used for timeshift start-time
            // conversion) whenever it changed.
            if let tz = response.serverInfo?.timezone?.trimmingCharacters(in: .whitespacesAndNewlines),
               !tz.isEmpty, tz != currentPlaylist.serverTimezone {
                var updated = currentPlaylist
                updated.serverTimezone = tz
                try? await AppDatabase.shared.write { db in try updated.save(db) }
            }
        } catch {
            PlaylistHealthStore.record(.refused, for: currentPlaylist.id)
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func saveFilterSetting(newValue: Bool) async {
        var updated = currentPlaylist
        updated.filterAdultContent = newValue
        do {
            try await AppDatabase.shared.write { db in
                try updated.save(db)
            }
            // When the filter changes, re-download the contents automatically
            await syncContents()
        } catch {
            await MainActor.run {
                self.syncError = L("misc.save_setting_error", error.localizedDescription)
            }
        }
    }

    private func syncContents() async {
        isSyncing = true
        syncError = nil

        do {
            try await PlaylistContentStore.shared.syncFromNetworkReplacingLocal(playlist: currentPlaylist) { msg in
                progressMessage = msg
            }
            await fetchLocalStats()
            await PlaylistContentStore.shared.reloadFromDatabaseIfActive(playlistId: playlist.id)
            await MainActor.run {
                self.isSyncing = false
                self.progressMessage = nil
            }
        } catch {
            await MainActor.run {
                self.syncError = L("misc.refresh_error", error.localizedDescription)
                self.isSyncing = false
                self.progressMessage = nil
            }
        }
    }
}
