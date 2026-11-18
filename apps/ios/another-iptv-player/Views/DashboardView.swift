import GRDB
import SwiftUI

struct DashboardView: View {
    let playlist: Playlist
    let onDismiss: () -> Void
    /// Round 10: playlist switching from Settings ▸ My Playlists.
    let onSwitchPlaylist: (Playlist) -> Void
    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var epgStore = EPGStore.shared
    /// F6 (B13): section visibility — hidden Movies/Series leave
    /// the tab bar (Home and Live are never hidable).
    @ObservedObject private var sectionVisibility = SectionVisibilityStore.shared
    /// Round 15 (C3): foreground returns consume pending Siri /
    /// App Intent requests and refresh the widget snapshot.
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playerOverlay = PlayerOverlayController()

    /// Last content tab is restored on launch; Settings stays ephemeral.
    @AppStorage(DashboardTab.storageKey) private var savedTab: Int = DashboardTab.live.rawValue
    @State private var selectedTab: DashboardTab

    init(playlist: Playlist, onDismiss: @escaping () -> Void, onSwitchPlaylist: @escaping (Playlist) -> Void) {
        self.playlist = playlist
        self.onDismiss = onDismiss
        self.onSwitchPlaylist = onSwitchPlaylist
        // Restore synchronously so the first frame already renders the correct tab.
        // An async restore in .task set selectedTab after the first render, causing a
        // Live→saved-tab flash and a title/tab desync ("title tam oturmuyor").
        _selectedTab = State(initialValue: DashboardTab.restoreInitialTab())
    }

    /// Settings selections are not persisted, so we never restore into it.
    /// Round 16 (P3): the round-14 tab-change slide state is GONE.
    /// The fade + 6 pt offset were applied to the whole TabView —
    /// system tab bar included — which made the bar double/shift
    /// during transitions on the owner's phone and fought the
    /// system's own bar morph. Tab changes are plain selection
    /// changes now (the system animates its bar itself); the B12
    /// light haptic stays.
    private var tabBinding: Binding<DashboardTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                guard newTab != selectedTab else { return }
                // B12 haptics map: light selection on tab change.
                Haptics.selection()
                selectedTab = newTab
                if newTab.isPersisted { savedTab = newTab.rawValue }
            }
        )
    }

    /// Round 14/15 (B9 + C12): one tab label for every tab — a single
    /// icon weight family (semibold, filled symbols) and the selected
    /// tab's icon carries the accent under-glow.
    @ViewBuilder
    private func tabLabel(_ title: String, glyph: String, tab: DashboardTab) -> some View {
        let isSelected = selectedTab == tab
        Label {
            // ST5 (fixer): tab labels render in IBM Plex Sans Arabic
            // when the app language is Arabic; in every other
            // language the label keeps the tab bar's own system font
            // untouched (no explicit font applied at all).
            if AppFont.isArabic {
                Text(title)
                    .font(AppFont.uiFont(size: 10, semibold: isSelected))
            } else {
                Text(title)
            }
        } icon: {
            // ST4 (B7): custom flame-X-family line glyphs from the
            // asset catalog (template-rendered vector PDFs), NOT
            // stock system symbols. The ST2 signature glow under
            // the selected tab is the existing accent under-glow.
            Image(glyph)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .shadow(color: isSelected ? AppTheme.tabGlow : .clear,
                        radius: isSelected ? 7 : 0, y: isSelected ? 3 : 0)
        }
    }

    // Keep poster sizing tied to the display, not to this view's transient layout.
    // Keyboard/status-bar/player transitions can temporarily shrink GeometryReader.
    private let posterMetrics = PosterMetrics(windowSize: UIScreen.main.bounds.size)
    @State private var showDownloadsSheet = false

    var body: some View {
        ZStack {
            TabView(selection: tabBinding) {
                Tab(value: DashboardTab.home) {
                    NavigationStack {
                        HomeView(
                            playlist: playlist,
                            onOpenLive: { tabBinding.wrappedValue = .live },
                            onOpenMovies: { tabBinding.wrappedValue = .movies },
                            onOpenSeries: { tabBinding.wrappedValue = .series },
                            // Finisher (C4 follow-up): Dashboard's existing
                            // playlist-switch mechanism, passed through so
                            // Home's quick-switcher actually switches.
                            onSwitchPlaylist: onSwitchPlaylist
                        )
                        // Round 8 (R-1): Home gets the Favorites star
                        // like every other content tab — it was the one
                        // tab Favorites could not be reached from.
                        // Round 10: the star moved INTO Home's own top
                        // bar (the STRONG-style bar carries it as its
                        // own button), so the nav-bar star is NOT added
                        // here — the Favorites entry exists exactly
                        // once on this tab, in the top bar.
                        // Round 11: the large "Home" title goes too —
                        // Home's own top bar is the top of the screen.
                        .dashboardNavigation(playlist: playlist, tabTitle: L("dashboard.home"), hidesNavigationBar: true)
                    }
                } label: { tabLabel(L("dashboard.home"), glyph: "TabGlyphHome", tab: DashboardTab.home) }

                Tab(value: DashboardTab.live) {
                    NavigationStack {
                        LiveStreamsView(playlist: playlist)
                            .dashboardNavigation(playlist: playlist, tabTitle: L("dashboard.live"), type: "live")
                    }
                } label: { tabLabel(L("dashboard.live"), glyph: "TabGlyphLive", tab: DashboardTab.live) }

                // F6 (B13): Movies/Series tabs exist only while
                // their section is visible in the ONE store.
                if sectionVisibility.isVisible(.movies) {
                    Tab(value: DashboardTab.movies) {
                        NavigationStack {
                            VODView(playlist: playlist)
                                .dashboardNavigation(playlist: playlist, tabTitle: L("dashboard.movies"), type: "vod")
                        }
                    } label: { tabLabel(L("dashboard.movies"), glyph: "TabGlyphMovies", tab: DashboardTab.movies) }
                }

                if sectionVisibility.isVisible(.series) {
                    Tab(value: DashboardTab.series) {
                        NavigationStack {
                            SeriesView(playlist: playlist)
                                .dashboardNavigation(playlist: playlist, tabTitle: L("dashboard.series"), type: "series")
                        }
                    } label: { tabLabel(L("dashboard.series"), glyph: "TabGlyphSeries", tab: DashboardTab.series) }
                }

                Tab(value: DashboardTab.settings) {
                    NavigationStack {
                        PlaylistSettingsView(playlist: playlist, onDismiss: onDismiss, onSwitchPlaylist: onSwitchPlaylist)
                            .dashboardNavigation(playlist: playlist, tabTitle: L("dashboard.settings"))
                    }
                } label: { tabLabel(L("dashboard.settings"), glyph: "TabGlyphSettings", tab: DashboardTab.settings) }

                // Round 7: NO Search tab. Round 5's six tabs made iOS
                // collapse everything past the fifth into an automatic
                // "More" tab that buried Settings + Search together —
                // the owner ordered "More" gone: the bar is exactly
                // Home / Live TV / Movies / Series / Settings. Search
                // itself is untouched: it lives at the top of every
                // content tab (HomeSearchBar → SearchView sheet), which
                // is also the app's ONE search entry (no duplication).
            }
            // Round 16 (P3): NO container animation/offset and no
            // .sidebarAdaptable. The adaptable style presents the
            // bar as a floating overlay on iPhone — content scrolls
            // underneath it and bottom rows rest hidden behind it,
            // and the round-14 fade+offset on the container made
            // the bar double/shift mid-transition. The standard
            // tab bar reserves the bottom safe area again (on
            // iOS 26 it is still the floating glass pill; on
            // iOS 18 the AppChrome opaque dark bar), there is
            // exactly one bar instance at all times, and its
            // targets are the platform-standard size.
            .environment(\.posterMetrics, posterMetrics)
            // W2b (B7): regular-width iPad gets the sidebar form of
            // the SAME tab bar; compact width is unchanged.
            .iPadSidebarAdaptable()

            ZStack {
                if let item = playerOverlay.presentation {
                    item.root
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.playerOverlayDismiss) {
                            playerOverlay.dismiss(animated: true)
                        }
                        .environment(\.playerOverlayMode, playerOverlay.mode)
                        .environment(\.playerOverlayPresentationID, item.id)
                        .environment(\.playerOverlayMinimize) { playerOverlay.minimize() }
                        .environment(\.playerOverlayExpand) { playerOverlay.expand() }
                        // Keep UIKit-backed video surfaces at a fixed geometry while they attach.
                        // Moving the whole AVPlayer/KSPlayer subtree produced a launch flash.
                        .transition(.opacity)
                }
            }
            // Animate only insertion/removal. A source switch changes presentation.id while
            // preserving PlayerView identity and must not animate the entire player subtree.
            .animation(.easeOut(duration: 0.14), value: playerOverlay.presentation != nil)
            .zIndex(10_000)
        }
        .environmentObject(playerOverlay)
        .environment(\.epgSnapshot, epgStore.snapshot)
        // G5 (B13): the shared offline indicator — local content
        // (cached catalog, downloads) stays usable beneath it.
        .overlay(alignment: .top) {
            OfflineBannerView()
        }
        // F6 (B13): if the section the user is standing in gets
        // hidden from Settings, land on Home instead of a vanished
        // tab.
        .onChange(of: sectionVisibility.hiddenSections) { _, hidden in
            if (selectedTab == .movies && hidden.contains(.movies))
                || (selectedTab == .series && hidden.contains(.series)) {
                selectedTab = .home
            }
        }
        .task(id: playlist.id) {
            await contentStore.loadPlaylist(playlist)
            // Round 12 (point 9): keep the provider-expiry record
            // fresh for the playback gate (no-op when verified within
            // the last 6 hours; Xtream playlists only).
            await ProviderExpiryStore.refreshIfStale(playlist: playlist)
            // Bind the EPG store to this playlist and refresh the guide if stale.
            // Runs after the catalog load so the wanted-channel set is populated.
            epgStore.setActivePlaylist(playlist)
            await epgStore.refreshIfStale(playlist: playlist)
            // Round 15 (C11 + C3, Features): after the catalog load —
            // schedule expiry alerts from the recorded exp_dates,
            // diff favorite/watched series for new-episode alerts,
            // refresh the widget snapshot from real local data, and
            // consume any pending Siri / App Intent request. Each
            // step is gated by its own settings toggle inside the
            // scheduler; authorization is only requested when there
            // is something real to schedule.
            await NotificationScheduler.scheduleExpiryAlerts(for: [playlist])
            await NotificationScheduler.checkNewEpisodes(playlist: playlist)
            await WidgetSnapshotStore.refresh(playlist: playlist)
            consumePendingPlayback()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            consumePendingPlayback()
            Task { await WidgetSnapshotStore.refresh(playlist: playlist) }
        }
        .alert(L("loading.error.title"), isPresented: Binding(
            get: {
                contentStore.loadError != nil
                    && contentStore.activePlaylistId == playlist.id
                    && !contentStore.isLoading
            },
            set: { if !$0 { contentStore.loadError = nil } }
        )) {
            Button(L("common.ok")) {
                contentStore.loadError = nil
            }
            Button(L("common.try_again")) {
                contentStore.loadError = nil
                Task { await contentStore.loadPlaylist(playlist) }
            }
        } message: {
            Text(contentStore.loadError ?? "")
        }
        .alert(L("download.player_warning.title"), isPresented: Binding(
            get: { playerOverlay.pendingPresentation != nil },
            set: { if !$0 { playerOverlay.cancelPending() } }
        )) {
            Button(L("common.cancel"), role: .cancel) {
                playerOverlay.cancelPending()
            }
            Button(L("download.player_warning.go_to_downloads")) {
                playerOverlay.cancelPending()
                showDownloadsSheet = true
            }
            Button(L("download.player_warning.continue")) {
                playerOverlay.confirmPending()
            }
        } message: {
            Text(L("download.player_warning.message"))
        }
        .sheet(isPresented: $showDownloadsSheet) {
            NavigationStack {
                DownloadsView(playlist: playlist)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L("common.close")) { showDownloadsSheet = false }
                        }
                    }
            }
            .environmentObject(playerOverlay)
        }
    }

    // MARK: - Round 15 (C3): pending Siri / App Intent playback

    /// Consumes a pending request stored by `PlayChannelIntent` /
    /// `ResumeWatchingIntent` (`Models/SuperXIntents.swift`) and
    /// presents playback through the SAME overlay path the Home
    /// history rows use. Requests for another playlist, or while a
    /// player is already up, are dropped (consume-once).
    private func consumePendingPlayback() {
        guard playerOverlay.presentation == nil,
              let pending = PendingPlayback.consume(),
              pending["playlistId"] == nil || pending["playlistId"] == playlist.id.uuidString
        else { return }

        switch pending["kind"] {
        case "live":
            guard let streamId = pending["streamId"].flatMap(Int.init),
                  let stream = contentStore.liveStreams.first(where: { $0.stream.streamId == streamId })?.stream
            else { return }
            let live = LiveChannelCategorySection.xtreamLiveQueue()
            playerOverlay.present(playlistId: playlist.id) {
                LivePlayerShell(playlist: playlist, queue: live.queue, sections: live.sections,
                                initialStream: stream, initialHistory: nil, subtitle: nil)
            }
        case "resume":
            Task {
                let history = (try? await AppDatabase.shared.read { db in
                    try DBWatchHistory
                        .filter(Column("playlistId") == playlist.id)
                        .order(Column("lastWatchedAt").desc)
                        .fetchOne(db)
                }) ?? nil
                guard let history, playerOverlay.presentation == nil else { return }
                presentPendingHistory(history)
            }
        default:
            return
        }
    }

    /// Mirrors HomeView's history routing: series episodes go
    /// through `HistorySeriesPlayerShell`, live through
    /// `LivePlayerShell`, everything else through `PlayerView`
    /// with its saved resume position.
    private func presentPendingHistory(_ item: DBWatchHistory) {
        let builder = PlaybackURLBuilder(playlist: playlist)
        switch item.type {
        case "series":
            guard let url = builder.seriesURL(streamId: item.streamId, containerExtension: item.containerExtension) else { return }
            playerOverlay.present(playlistId: playlist.id) {
                HistorySeriesPlayerShell(playlist: playlist, history: item, url: url)
            }
        case "live":
            guard let streamId = Int(item.streamId) else { return }
            let stream = contentStore.liveStreams.first(where: { $0.stream.streamId == streamId })?.stream
                ?? DBLiveStream(streamId: streamId, name: item.title, streamIcon: item.imageURL,
                                categoryId: nil, sortIndex: 0, playlistId: playlist.id)
            let live = LiveChannelCategorySection.xtreamLiveQueue()
            playerOverlay.present(playlistId: playlist.id) {
                LivePlayerShell(playlist: playlist, queue: live.queue, sections: live.sections,
                                initialStream: stream, initialHistory: item, subtitle: nil)
            }
        default:
            guard let url = builder.movieURL(streamId: Int(item.streamId) ?? 0,
                                             containerExtension: item.containerExtension) else { return }
            playerOverlay.present(playlistId: playlist.id) {
                PlayerView(
                    url: url,
                    title: item.title,
                    subtitle: item.secondaryTitle,
                    artworkURL: item.imageURL.flatMap { URL(string: $0) },
                    isLiveStream: false,
                    playlistId: playlist.id,
                    streamId: item.streamId,
                    type: item.type,
                    seriesId: item.seriesId,
                    resumeTimeMs: item.lastTimeMs
                )
            }
        }
    }

}

// MARK: - Dashboard Tab
private enum DashboardTab: Int, CaseIterable {
    case home = 0
    case live = 1
    case movies = 2
    case series = 3
    case settings = 4

    static let storageKey = "dashboard_selected_tab"

    /// Only content tabs are persisted; Settings is ephemeral by design.
    var isPersisted: Bool { rawValue <= DashboardTab.series.rawValue }

    /// Round 15 (C11): the two locked tab-migration flags and their
    /// index shifting are REMOVED — the fossils dated from the era when
    /// Home was removed (v1) and re-added (v2), and both migrations have
    /// long since latched on every installed device. The stored index
    /// is now simply clamped to the valid range; a missing value is a
    /// first launch and lands on Home, and an ephemeral Settings value
    /// keeps its historical fallback to Live.
    static func restoreInitialTab() -> DashboardTab {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: storageKey) != nil else { return .home }
        let clamped = min(max(defaults.integer(forKey: storageKey), 0), DashboardTab.settings.rawValue)
        let tab = DashboardTab(rawValue: clamped) ?? .home
        return tab.isPersisted ? tab : .live
    }

}

// MARK: - Dashboard Navigation Modifier
private struct DashboardNavigationModifier: ViewModifier {
    let playlist: Playlist
    let tabTitle: String
    let type: String?
    /// Round 11 (owner, build 47): Home carries its own STRONG-style
    /// top bar (Super X wordmark + action buttons) as the top of the
    /// screen — the large "Home" navigation title above it was
    /// duplicated chrome. Home therefore hides the navigation bar
    /// entirely; pushed screens (Notifications, Downloads, detail
    /// pages) declare their own titles and get the bar back.
    var hidesNavigationBar: Bool = false
    @Environment(\.posterMetrics) private var posterMetrics

    func body(content: Content) -> some View {
        content
            .navigationTitle(hidesNavigationBar ? "" : tabTitle)
            .navigationBarTitleDisplayMode(hidesNavigationBar ? .inline : .large)
            .toolbar {
                if let type = type {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NavigationLink(destination: FavoritesView(playlist: playlist, initialType: type)) {
                            Image(systemName: "star.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                }
            }
            .toolbar(hidesNavigationBar ? .hidden : .visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

extension View {
    // Round 8 (F-8): the modifier's old `onDismiss` parameter was dead —
    // accepted at every call site but never used (the modifier renders
    // no dismiss control; the real back-to-gate path is the Settings
    // "Back to Playlists" row, which calls DashboardView's own
    // `onDismiss`). Parameter removed from the modifier, this helper,
    // and all five call sites.
    func dashboardNavigation(playlist: Playlist, tabTitle: String, type: String? = nil, hidesNavigationBar: Bool = false) -> some View {
        modifier(DashboardNavigationModifier(playlist: playlist, tabTitle: tabTitle, type: type, hidesNavigationBar: hidesNavigationBar))
    }
}
