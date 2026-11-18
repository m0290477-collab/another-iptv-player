import SwiftUI
import GRDB
import GRDBQuery

// MARK: - Home tab (round 5)

/// The Home tab — the app's front door, built entirely from the loaded
/// catalog (PlaylistContentStore) and the existing watch-history source.
/// Nothing here is hard-coded: the featured carousel ranks movies/series
/// that carry artwork by the round-3 normalized rating rule, the tiles
/// show the real catalog totals, Top Rated rows reuse that same ranking,
/// New rows reuse the catalog's own added/last-modified ordering, and
/// Continue Watching is the same ContinueWatchingRow the Live tab uses,
/// with no type filter. Every tap routes into an existing detail view,
/// player shell, or tab — no new navigation machinery.
struct HomeView: View {
    let playlist: Playlist
    let onOpenLive: () -> Void
    let onOpenMovies: () -> Void
    let onOpenSeries: () -> Void

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @ObservedObject private var epgStore = EPGStore.shared
    /// B3 (Round 14): quick playlist switcher — wired by the dashboard
    /// to ContentView's existing switch mechanism. Optional so this
    /// view's existing call site compiles unchanged; when nil the
    /// playlist name is shown but is not a switcher (no fake UI).
    var onSwitchPlaylist: ((Playlist) -> Void)? = nil
    @Query<PlaylistRequest> private var allPlaylists: [Playlist]?
    @Query<RecentWatchHistoryRequest> private var recentHistory: [DBWatchHistory]
    @Query<FavoriteLiveRequest> private var favoriteLive: [LiveStreamWithCategory]
    @Query<FavoriteVODRequest> private var favoriteVODs: [VODWithCategory]
    @Query<FavoriteSeriesRequest> private var favoriteSeries: [SeriesWithCategory]
    @State private var showPlaylistSwitcher = false
    @State private var showUpdatedToast = false
    /// C12: in-app banner when a download finishes while the user is
    /// in another section (posted by DownloadManager.markCompleted).
    @State private var showDownloadToast = false
    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @Environment(\.posterMetrics) private var posterMetrics
    @Environment(\.scenePhase) private var scenePhase

    // Computed home data — rebuilt off-main whenever the catalog lands or
    // a hidden-category set changes (same recompute pattern as the tabs).
    init(playlist: Playlist,
         onOpenLive: @escaping () -> Void,
         onOpenMovies: @escaping () -> Void,
         onOpenSeries: @escaping () -> Void,
         onSwitchPlaylist: ((Playlist) -> Void)? = nil) {
        self.playlist = playlist
        self.onOpenLive = onOpenLive
        self.onOpenMovies = onOpenMovies
        self.onOpenSeries = onOpenSeries
        self.onSwitchPlaylist = onSwitchPlaylist
        _allPlaylists = Query(PlaylistRequest(), in: \.appDatabase)
        _recentHistory = Query(RecentWatchHistoryRequest(playlistId: playlist.id, limit: 50), in: \.appDatabase)
        _favoriteLive = Query(FavoriteLiveRequest(playlistId: playlist.id), in: \.appDatabase)
        _favoriteVODs = Query(FavoriteVODRequest(playlistId: playlist.id), in: \.appDatabase)
        _favoriteSeries = Query(FavoriteSeriesRequest(playlistId: playlist.id), in: \.appDatabase)
    }

    @State private var featured: [FeaturedEntry] = []
    @State private var topRatedMovies: [DBVODStream] = []
    @State private var topRatedSeries: [DBSeries] = []
    @State private var newMovies: [DBVODStream] = []
    @State private var newSeries: [DBSeries] = []
    // Round 14/15 (B6/C6) extra shelves, all from real store/EPG/history data.
    @State private var becauseYouWatched: [FeaturedEntry] = []
    @State private var newEpisodeSeries: [DBSeries] = []
    @State private var newSinceVisit: [FeaturedEntry] = []
    @State private var tonightEntries: [TonightEntry] = []
    // Round 10: the category tiles are icon cards now — the tile-art
    // state rounds 5–9 maintained for them is gone with the photos.

    // Carousel state.
    @State private var featuredIndex = 0
    @State private var carouselPauseUntil = Date.distantPast
    @State private var suppressCarouselPause = false
    @State private var isVisible = false

    // Detail navigation (matches the tabs' navigationDestination pattern).
    @State private var pendingMovieDetail: DBVODStream?
    @State private var pendingSeriesDetail: DBSeries?

    // Search entry (round 7): the owner's order puts the search bar at
    // the TOP of every content tab — Home included. It opens the same
    // global SearchView sheet as the other tabs; it is the tab's ONE
    // search entry (the Search tab was removed from the tab bar).
    // Round 10: on Home the bar itself is replaced by the STRONG-style
    // top bar (wordmark + square icon buttons); its Search button
    // opens this same sheet — still the ONE search system.
    @State private var showSearchSheet = false
    @State private var homeSearchText = ""

    // Round 10 top-bar sheets / actions.
    @State private var showDownloadsSheet = false
    @State private var showNotificationsSheet = false
    @State private var showRefreshConfirm = false
    @State private var isRefreshingHome = false

    // Build 61 (S4): expiry-banner dismissal for THIS appearance of
    // Home; the durable per-expiry-date record is in UserDefaults
    // (see expiryBannerModel).
    @State private var expiryBannerDismissed = false

    // Build 61 (B13): F6 section visibility (shelves + tiles read
    // the ONE store), F7 new-version notice, G5 offline alert for
    // this screen's refresh actions.
    @ObservedObject private var sectionVisibility = SectionVisibilityStore.shared
    @ObservedObject private var updateService = AppUpdateService.shared
    @State private var showOfflineAlert = false

    private var liveHiddenIds: Set<String> { hiddenStore.hiddenIds(playlistId: playlist.id, type: "live") }
    private var vodHiddenIds: Set<String> { hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod") }
    private var seriesHiddenIds: Set<String> { hiddenStore.hiddenIds(playlistId: playlist.id, type: "series") }

    /// Round 7 (landscape fix): the card width used to derive from the
    /// screen's WIDTH alone — `min(width - 32, 760)`. In landscape the
    /// width is the long edge (~852 pt), so the card grew to 760 pt and
    /// its 16:9 art to ~427 pt tall — taller than the entire landscape
    /// viewport (~393 pt) — and a 2:3 poster was fill-cropped into that
    /// frame at full-screen size: the giant faces in the owner's video
    /// ("the top images blow up… not tidy"). The art height is now
    /// capped at 62% of the screen HEIGHT and the width derives from
    /// that cap when it binds. Portrait phones are unchanged
    /// (361 pt wide → 203 pt of art; the height cap is ~528 pt there).
    private var cardWidth: CGFloat {
        let bounds = UIScreen.main.bounds
        let heightCappedWidth = (bounds.height * 0.62) * 16 / 9
        return min(bounds.width - 32, 760, heightCappedWidth)
    }

    var body: some View {
        Group {
            if catalogIsEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 26) {
                        // Round 10 (owner, build 46): the STRONG-style
                        // top bar — wordmark on one side, tidy square
                        // icon buttons on the other (Favorites star,
                        // Refresh with confirm, Search, Downloads,
                        // Notifications). It replaces the round-7
                        // search bar on this tab only; the other tabs
                        // keep theirs.
                        homeTopBar
                            .padding(.horizontal, 16)

                        // Build 61 (S4): subscription-expiry banner —
                        // real ProviderExpiryStore data for the ACTIVE
                        // playlist only.
                        if let expiryBanner = expiryBannerModel {
                            expiryBannerView(expiryBanner)
                                .padding(.horizontal, 16)
                        }

                        // Build 61 (F7, B13): new-version banner —
                        // only when the iTunes lookup found a newer
                        // store version that was not dismissed.
                        if let update = updateService.availableUpdate {
                            updateBannerView(update)
                                .padding(.horizontal, 16)
                        }

                        // Round 18 (R18-4): the "Back to the last
                        // thing" pill is REMOVED. It duplicated the
                        // same most-recent title two more times on
                        // this one screen (Featured hero + first
                        // Continue Watching card) — the no-duplication
                        // defect the owner circled. Resume itself is
                        // unchanged: Continue Watching below resumes
                        // the same item through the same handler.

                        if !featured.isEmpty {
                            featuredCarousel
                        } else if !contentStore.streamsLoaded {
                            // B6: skeleton placeholders instead of the
                            // bare spinner while the catalog lands.
                            SkeletonShelf()
                        }

                        // B6: "On now on your channels" — directly
                        // under the hero, real EPG now-titles.
                        if !onNowEntries.isEmpty {
                            onNowShelf
                        }

                        // B6: Continue Watching ABOVE the category tiles.
                        ContinueWatchingRow(
                            playlist: playlist,
                            typeFilter: nil,
                            destination: {
                                WatchHistoryListView(playlist: playlist, typeFilter: nil) { item in
                                    presentHistoryItem(item)
                                }
                            },
                            onPlay: { item in
                                presentHistoryItem(item)
                            }
                        )

                        categoryTiles

                        // C6: remaining shelves ordered by the
                        // watch-history time bucket (see shelfOrder).
                        ForEach(shelfOrder, id: \.self) { kind in
                            shelfView(kind)
                        }

                        // B6 per-type loading: a type that has not
                        // landed yet shows a skeleton while the others
                        // already render.
                        if !contentStore.streamsLoaded {
                            if contentStore.vodStreams.isEmpty { SkeletonShelf() }
                            if contentStore.seriesItems.isEmpty { SkeletonShelf() }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .refreshable {
                    // G5 (B13): playlist refresh is network-only —
                    // offline it answers with the plain offline
                    // message instead of a spinner.
                    if OfflineState.shared.isOffline {
                        showOfflineAlert = true
                        return
                    }
                    // Same cancellation-proof pattern as the Live tab: an
                    // independent Task so a ScrollView redraw can't cancel
                    // the network work mid-flight.
                    let work = Task { await contentStore.refreshFromNetwork(playlist: playlist) }
                    await work.value
                    // C12: refresh-completion feedback (haptic + sound +
                    // brief toast) only after the REAL refresh finished.
                    if contentStore.loadError == nil {
                        Haptics.success()
                        AppSound.play(.refreshSuccess)
                        withAnimation(Motion.animate(.easeOut(duration: 0.25))) { showUpdatedToast = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_800_000_000)
                            withAnimation(Motion.animate(.easeOut(duration: 0.25))) { showUpdatedToast = false }
                        }
                    }
                }
            }
        }
        .cinematicBackground()
        .sheet(isPresented: $showSearchSheet) {
            NavigationStack {
                SearchView(playlist: playlist, searchText: $homeSearchText)
            }
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
        .sheet(isPresented: $showPlaylistSwitcher) {
            NavigationStack {
                List {
                    ForEach(allPlaylists ?? []) { candidate in
                        Button {
                            showPlaylistSwitcher = false
                            if candidate.id != playlist.id {
                                onSwitchPlaylist?(candidate)
                            }
                        } label: {
                            HStack {
                                Text(candidate.name).foregroundStyle(.primary)
                                Spacer()
                                if candidate.id == playlist.id {
                                    Image(systemName: "checkmark").foregroundStyle(AppTheme.accent)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .cinematicScrollBackground()
                .navigationTitle(L("home.switch_playlist"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("common.close")) { showPlaylistSwitcher = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showNotificationsSheet) {
            NavigationStack {
                NotificationsView(playlist: playlist)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L("common.close")) { showNotificationsSheet = false }
                        }
                    }
            }
        }
        // A3 (Round 14): centered .alert — the old
        // .confirmationDialog anchored at the bottom of the screen,
        // which the owner filmed and rejected.
        .alert(L("home.refresh.title"), isPresented: $showRefreshConfirm) {
            Button(L("home.refresh.action")) { runHomeRefresh() }
            Button(L("common.cancel"), role: .cancel) { }
        } message: {
            Text(L("home.refresh.message"))
        }
        // G5 (B13): the offline answer for this screen's refresh
        // actions, with Retry.
        .alert(L("offline.title"), isPresented: $showOfflineAlert) {
            Button(L("common.try_again")) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { runHomeRefresh() }
            }
            Button(L("common.cancel"), role: .cancel) { }
        } message: {
            Text(L("offline.message"))
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("superx.downloadCompleted"))) { _ in
            AppSound.play(.downloadComplete)
            withAnimation(Motion.animate(.easeOut(duration: 0.25))) { showDownloadToast = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation(Motion.animate(.easeOut(duration: 0.25))) { showDownloadToast = false }
            }
        }
        .overlay(alignment: .bottom) {
            if showDownloadToast {
                Label(L("download.completed"), systemImage: "checkmark.circle.fill")
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(AppTheme.accent))
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        // C12: brief "Updated ✓" after a real refresh completes.
        .overlay(alignment: .top) {
            if showUpdatedToast {
                Label(L("home.refresh.updated"), systemImage: "checkmark.circle.fill")
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(AppTheme.accent))
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .navigationDestination(item: $pendingMovieDetail) { movie in
            MovieDetailView(playlist: playlist, movie: movie, queue: topRatedMovies)
        }
        .navigationDestination(item: $pendingSeriesDetail) { series in
            SeriesDetailView(playlist: playlist, series: series)
        }
        // Round 7 (performance): ONE recompute trigger. Round 5 had four
        // separate `.task(id:)` modifiers (streamsLoaded + one per
        // hidden set); at catalog load they fired back-to-back — up to
        // four full recomputes in a row, each re-scanning the whole
        // catalog. The combined token runs the pass exactly once per
        // actual change set.
        // B6 per-type loading: the token carries each type's count
        // separately, so the pass re-runs as EACH content type lands
        // instead of waiting on the one streamsLoaded flag.
        .task(id: HomeRecomputeToken(
            loaded: contentStore.streamsLoaded,
            liveCount: contentStore.liveStreams.count,
            vodCount: contentStore.vodStreams.count,
            seriesCount: contentStore.seriesItems.count,
            historyCount: recentHistory.count,
            live: liveHiddenIds,
            vod: vodHiddenIds,
            series: seriesHiddenIds
        )) { await recompute() }
        // C6 Tonight row: rebuild when the EPG snapshot changes.
        .task(id: epgStore.snapshot?.version ?? 0) { await recomputeTonight() }
        .onDisappear {
            // C6: stamp the visit AFTER the shelves computed against
            // the previous stamp (New-since-last-visit baseline).
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastVisitKey)
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: featured) { _, newValue in
            if featuredIndex >= newValue.count { featuredIndex = 0 }
        }
    }

    private var catalogIsEmpty: Bool {
        contentStore.liveStreams.isEmpty && contentStore.vodStreams.isEmpty && contentStore.seriesItems.isEmpty
    }

    @ViewBuilder
    private var emptyState: some View {
        // Round 12 (point 3): phase 2 (streams) sets isLoading back
        // to false while the catalog is still empty — the old
        // condition fell through to the "no category" placeholder
        // for the whole phase-2 duration. Until streamsLoaded (and
        // no error to show instead), an empty catalog means
        // LOADING, not empty.
        if contentStore.isLoading
            || playlist.id != contentStore.activePlaylistId
            || (!contentStore.streamsLoaded && contentStore.loadError == nil) {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                Text(contentStore.loadingMessage ?? L("live.empty.preparing"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError = contentStore.loadError {
            CatalogLoadErrorView(message: loadError) {
                Task { await contentStore.loadPlaylist(playlist) }
            }
        } else {
            // C9: styled surface card empty state with accent icon.
            VStack(spacing: 14) {
                Image(systemName: "house.slash")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(AppTheme.elevated))
                Text(L("live.empty.no_category"))
                    .font(AppTheme.fontCardTitle)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous).fill(AppTheme.surface))
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Top bar (round 10)

    /// STRONG-style top bar: the Super X wordmark on one side, five
    /// tidy square icon buttons on the other — Favorites (the tab's
    /// ONE favorites entry; the nav-bar star was removed for this
    /// tab), Refresh (confirm first, spins while refreshing), Search
    /// (the ONE unified search sheet), Downloads (the existing
    /// Downloads screen) and Notifications (real account-derived
    /// items only — see NotificationsView).
    private var homeTopBar: some View {
        HStack(spacing: 8) {
            // B6: playlist name under the wordmark. B3: when the
            // dashboard wired a switcher, tapping the name opens the
            // quick playlist switcher (real switching via ContentView's
            // existing mechanism, passed down as onSwitchPlaylist).
            VStack(alignment: .leading, spacing: 1) {
                // Build 61 (Design-4, home panel 4): flame mark +
                // SUPER X wordmark — the flame in the fixed brand
                // gradient, the X in the accent.
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(AppTheme.brandGradient)
                    Text("Super")
                    Text("X")
                        .foregroundColor(AppTheme.accent)
                }
                .font(.system(size: 24, weight: .black))
                // C9: tracking on the Latin brand wordmark ONLY.
                .latinBrandTracking(-0.5)
                .foregroundStyle(.white)

                if onSwitchPlaylist != nil {
                    Button { showPlaylistSwitcher = true } label: {
                        HStack(spacing: 3) {
                            Text(playlist.name)
                                .font(AppTheme.fontMetadata)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("home.switch_playlist"))
                } else {
                    Text(playlist.name)
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // F6 (B13): the Library (Favorites) entry follows the
            // ONE visibility store, like its Home shelf.
            if sectionVisibility.isVisible(.library) {
                NavigationLink {
                    FavoritesView(playlist: playlist, initialType: "live")
                } label: {
                    topBarSquare(systemName: "star.fill", tint: AppTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("favorites.title"))
            }

            Button {
                showRefreshConfirm = true
            } label: {
                topBarSquare(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isRefreshingHome ? 360 : 0))
                    .animation(
                        isRefreshingHome
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default,
                        value: isRefreshingHome
                    )
            }
            .buttonStyle(.plain)
            .disabled(isRefreshingHome)
            .accessibilityLabel(L("home.refresh.action"))

            Button {
                showSearchSheet = true
            } label: {
                // Build 61 (Design-4, home panel 4): Search is the
                // circular ACCENT button at the top bar's end; the
                // other actions keep their square tiles.
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.onAccent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.brandGradient))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("dashboard.search"))

            Button {
                showDownloadsSheet = true
            } label: {
                topBarSquare(systemName: "arrow.down.to.line")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("download.title"))

            Button {
                showNotificationsSheet = true
            } label: {
                topBarSquare(systemName: "bell.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("notifications.title"))
        }
    }

    private func topBarSquare(systemName: String, tint: Color = .white) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.elevated)
            )
    }

    // MARK: - S4 expiry banner (build 61)

    // MARK: - F7 new-version banner (build 61, B13)

    /// Shown only while `AppUpdateService` holds a newer,
    /// undismissed store version. Tapping opens the App Store
    /// page; the X dismisses for THIS store version only (the
    /// service remembers it per version).
    private func updateBannerView(_ update: (version: String, storeURL: URL)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            Link(destination: update.storeURL) {
                Text(L("update.banner_format", update.version))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                updateService.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("update.dismiss"))
        }
        .padding(12)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(AppTheme.accent.opacity(0.45), lineWidth: 1)
        )
    }

    /// The banner's data: the ACTIVE playlist's recorded provider
    /// expiry (ProviderExpiryStore — Xtream playlists only; M3U
    /// records none, so no banner). Shown when the subscription is
    /// already expired, or expires within 7 days. Dismissal is
    /// remembered PER EXPIRY DATE: the stored stamp is the expiry
    /// timestamp itself, so a renewal (a new recorded date) makes
    /// the banner eligible again.
    private struct ExpiryBannerModel {
        let expiry: Date
        let text: String
    }

    private var expiryBannerModel: ExpiryBannerModel? {
        guard !expiryBannerDismissed,
              let expiry = ProviderExpiryStore.expiryDate(playlistId: playlist.id)
        else { return nil }
        let dismissalKey = "home.expiryBanner.dismissed.\(playlist.id.uuidString)"
        guard UserDefaults.standard.double(forKey: dismissalKey) != expiry.timeIntervalSince1970
        else { return nil }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = AppTheme.appLocale
        let dateText = formatter.string(from: expiry)

        if ProviderExpiryStore.isExpired(expiryDate: expiry) {
            return ExpiryBannerModel(expiry: expiry, text: L("home.expiry.expired", dateText))
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: expiry)
        ).day ?? 0
        guard days <= 7 else { return nil }
        return ExpiryBannerModel(expiry: expiry, text: L("home.expiry.expiring", max(days, 0), dateText))
    }

    private func expiryBannerView(_ model: ExpiryBannerModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
            Text(model.text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                UserDefaults.standard.set(
                    model.expiry.timeIntervalSince1970,
                    forKey: "home.expiryBanner.dismissed.\(playlist.id.uuidString)"
                )
                expiryBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("home.expiry.dismiss"))
        }
        .padding(12)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
        )
    }

    /// The confirmed top-bar refresh: the same network refresh the
    /// pull-to-refresh gesture runs, with the button spinning for
    /// exactly its duration.
    private func runHomeRefresh() {
        guard !isRefreshingHome else { return }
        // G5 (B13): offline → the plain message, no spinner.
        if OfflineState.shared.isOffline {
            showOfflineAlert = true
            return
        }
        isRefreshingHome = true
        Task {
            await contentStore.refreshFromNetwork(playlist: playlist)
            isRefreshingHome = false
            if contentStore.loadError == nil {
                Haptics.success()
                AppSound.play(.refreshSuccess)
                withAnimation(Motion.animate(.easeOut(duration: 0.25))) { showUpdatedToast = true }
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation(Motion.animate(.easeOut(duration: 0.25))) { showUpdatedToast = false }
            }
        }
    }

    /// "2026 • Drama" for poster cards — built only from fields the
    /// record actually carries (its own release year, its first
    /// genre); nil when neither exists. Shared by the ranked shelves.
    private func cardMetaLine(year: String?, genre: String?) -> String? {
        var parts: [String] = []
        if let year { parts.append(year) }
        if let first = DetailFormatting.genreList(genre).first { parts.append(first) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    // MARK: - Featured carousel

    private var featuredCarousel: some View {
        VStack(spacing: 10) {
            TabView(selection: $featuredIndex) {
                ForEach(featured.indices, id: \.self) { index in
                    FeaturedSlide(
                        entry: featured[index],
                        isCurrent: index == featuredIndex,
                        width: cardWidth,
                        onPlay: { playFeatured(featured[index]) },
                        onDetails: { showFeaturedDetails(featured[index]) }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: cardWidth, height: cardWidth * 9 / 16)
            .frame(maxWidth: .infinity)
            .onChange(of: featuredIndex) { _, _ in
                // Timer-driven advances set the suppression flag first; a
                // change without it is a user swipe — pause auto-advance
                // so the carousel never fights the reader.
                if suppressCarouselPause {
                    suppressCarouselPause = false
                } else {
                    carouselPauseUntil = Date().addingTimeInterval(12)
                }
            }

            // Page dots — tappable since round 10 (manual jump; the
            // onChange above pauses auto-rotation after any manual
            // move, dots included).
            HStack(spacing: 6) {
                ForEach(featured.indices, id: \.self) { index in
                    Button {
                        withAnimation(Motion.animate(Motion.shelfSpring) ?? .easeInOut(duration: 0.45)) {
                            featuredIndex = index
                        }
                    } label: {
                        // B12: the active dot is an elongated pill
                        // whose width springs; inactive dots stay 7 pt.
                        Capsule()
                            .fill(index == featuredIndex ? AppTheme.accent : Color.secondary.opacity(0.4))
                            .frame(width: index == featuredIndex ? 22 : 7, height: 7)
                            .frame(width: 22, height: 22)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .animation(Motion.animate(Motion.shelfSpring), value: featuredIndex)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: featured.count) { await runCarouselTimer() }
    }

    /// The round's ONLY repeating timer. Advances the carousel every ~6 s,
    /// and only while Home is actually on screen, the app is active, no
    /// player is presented, and the user hasn't recently swiped.
    private func runCarouselTimer() async {
        guard featured.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            guard isVisible,
                  scenePhase == .active,
                  playerOverlay.presentation == nil,
                  Date() >= carouselPauseUntil,
                  featured.count > 1 else { continue }
            suppressCarouselPause = true
            withAnimation(.easeInOut(duration: 0.45)) {
                featuredIndex = (featuredIndex + 1) % featured.count
            }
        }
    }

    private func playFeatured(_ entry: FeaturedEntry) {
        switch entry {
        case .movie(let movie):
            let queue = topRatedMovies.isEmpty ? [movie] : topRatedMovies
            playerOverlay.present(playlistId: playlist.id) {
                VODPlayerShell(playlist: playlist, queue: queue, initialMovie: movie, initialResumeMs: nil)
            }
        case .series(let series):
            // Round 8 (F-2): Play now PLAYS. It used to route to Series
            // Detail — the exact same destination as the Details button
            // beside it. SeriesPlayShell runs the real episode pipeline
            // (load episodes if the catalog hasn't yet, resume the
            // in-progress episode, else the next unwatched, else S1E1)
            // and presents the player with working prev/next.
            playerOverlay.present(playlistId: playlist.id) {
                SeriesPlayShell(
                    playlist: playlist,
                    series: series,
                    onNavigateToDetail: { target in
                        playerOverlay.dismiss()
                        pendingSeriesDetail = target
                    }
                )
            }
        }
    }

    private func showFeaturedDetails(_ entry: FeaturedEntry) {
        switch entry {
        case .movie(let movie): pendingMovieDetail = movie
        case .series(let series): pendingSeriesDetail = series
        }
    }

    // MARK: - Category tiles

    private var categoryTiles: some View {
        HStack(alignment: .top, spacing: 12) {
            // Round 10 (owner, build 46): STRONG-style icon cards —
            // a colored circular glyph + the section name + the REAL
            // count beneath. The photo tiles (round 9's single
            // representative image) are gone entirely. Hues stay
            // inside the blue-led palette: the LIVE red is the
            // design's reserved live color, Movies takes the accent,
            // Series the violet preset.
            HomeCategoryTile(
                title: L("dashboard.live"),
                countText: L("home.count_channels", CatalogCountFormatter.string(contentStore.liveStreams.count)),
                tint: AppTheme.live,
                iconName: "tv",
                action: onOpenLive
            )
            // F6 (B13): the Movies/Series tiles follow the ONE
            // section-visibility store, same as their tabs.
            if sectionVisibility.isVisible(.movies) {
                HomeCategoryTile(
                    title: L("dashboard.movies"),
                    countText: L("home.count_movies", CatalogCountFormatter.string(contentStore.vodStreams.count)),
                    tint: AppTheme.accent,
                    iconName: "film",
                    action: onOpenMovies
                )
            }
            if sectionVisibility.isVisible(.series) {
                HomeCategoryTile(
                    title: L("dashboard.series"),
                    countText: L("home.count_series", CatalogCountFormatter.string(contentStore.seriesItems.count)),
                    // Build 61: the Series tile follows the shared
                    // SectionTheme (a hue-shifted sibling of the CURRENT
                    // accent) instead of a hard-coded violet preset, so
                    // the tile family stays inside the Design-4 system
                    // for every accent choice.
                    tint: SectionTheme.series,
                    iconName: "play.tv",
                    action: onOpenSeries
                )
            }
        }
        .padding(.horizontal, 16)
        // Round 8 (audit E3): cap the row at 560 pt like the Live hero —
        // in landscape the three tiles otherwise split the full ~820 pt
        // width and stretch into wide strips. The second frame
        // re-expands to full width so the capped row stays centered.
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shelves

    private var topRatedMoviesShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("home.top_rated_movies")) {
                AllVODView(playlist: playlist)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(topRatedMovies.indices, id: \.self) { index in
                        NavigationLink {
                            MovieDetailView(playlist: playlist, movie: topRatedMovies[index], queue: topRatedMovies)
                        } label: {
                            RankedPosterCard(
                                rank: index + 1,
                                imageURL: moviePosterURL(topRatedMovies[index]),
                                title: topRatedMovies[index].name,
                                ratingText: ContentRating.normalizedDisplayText(rating: topRatedMovies[index].rating, rating5Based: topRatedMovies[index].rating5Based),
                                metaText: cardMetaLine(year: DetailFormatting.year(from: topRatedMovies[index].releaseDate), genre: topRatedMovies[index].genre),
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                iconName: "film"
                            )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .shelfEntrance(index: index)
                        .contextMenu {
                            Button {
                                toggleFavorite(streamId: topRatedMovies[index].streamId, type: "vod",
                                               currentlyFavorite: isFavoriteMovie(topRatedMovies[index]))
                            } label: {
                                Label(isFavoriteMovie(topRatedMovies[index]) ? L("favorites.remove") : L("favorites.add"), systemImage: "star")
                            }
                            if let categoryId = topRatedMovies[index].categoryId {
                                Button {
                                    hiddenStore.setHidden(true, playlistId: playlist.id, type: "vod", categoryId: categoryId)
                                } label: {
                                    Label(L("category_picker.hide"), systemImage: "eye.slash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
        }
    }

    private var topRatedSeriesShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("home.top_rated_series")) {
                AllSeriesView(playlist: playlist)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(topRatedSeries.indices, id: \.self) { index in
                        NavigationLink {
                            SeriesDetailView(playlist: playlist, series: topRatedSeries[index])
                        } label: {
                            RankedPosterCard(
                                rank: index + 1,
                                imageURL: seriesPosterURL(topRatedSeries[index]),
                                title: topRatedSeries[index].name,
                                ratingText: ContentRating.normalizedDisplayText(rating: topRatedSeries[index].rating, rating5Based: topRatedSeries[index].rating5Based),
                                metaText: cardMetaLine(year: DetailFormatting.year(from: topRatedSeries[index].releaseDate), genre: topRatedSeries[index].genre),
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                iconName: "play.tv"
                            )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .shelfEntrance(index: index)
                        .contextMenu {
                            Button {
                                toggleFavorite(streamId: topRatedSeries[index].seriesId, type: "series",
                                               currentlyFavorite: isFavoriteSeries(topRatedSeries[index]))
                            } label: {
                                Label(isFavoriteSeries(topRatedSeries[index]) ? L("favorites.remove") : L("favorites.add"), systemImage: "star")
                            }
                            if let categoryId = topRatedSeries[index].categoryId {
                                Button {
                                    hiddenStore.setHidden(true, playlistId: playlist.id, type: "series", categoryId: categoryId)
                                } label: {
                                    Label(L("category_picker.hide"), systemImage: "eye.slash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
        }
    }

    private var newMoviesShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("home.new_movies")) {
                RecentlyAddedVODDetailView(playlist: playlist, items: newMovies)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(newMovies.indices, id: \.self) { index in
                        NavigationLink {
                            MovieDetailView(playlist: playlist, movie: newMovies[index], queue: newMovies)
                        } label: {
                            VODStreamCard(
                                playlistId: playlist.id,
                                stream: newMovies[index],
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                imageLoadProfile: .shelf
                            )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .shelfEntrance(index: index)
                        .contextMenu {
                            Button {
                                toggleFavorite(streamId: newMovies[index].streamId, type: "vod",
                                               currentlyFavorite: isFavoriteMovie(newMovies[index]))
                            } label: {
                                Label(isFavoriteMovie(newMovies[index]) ? L("favorites.remove") : L("favorites.add"), systemImage: "star")
                            }
                            if let categoryId = newMovies[index].categoryId {
                                Button {
                                    hiddenStore.setHidden(true, playlistId: playlist.id, type: "vod", categoryId: categoryId)
                                } label: {
                                    Label(L("category_picker.hide"), systemImage: "eye.slash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
        }
    }

    private var newSeriesShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("home.new_series")) {
                RecentlyAddedSeriesDetailView(playlist: playlist, items: newSeries)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(newSeries.indices, id: \.self) { index in
                        NavigationLink {
                            SeriesDetailView(playlist: playlist, series: newSeries[index])
                        } label: {
                            // Round 9: portrait poster card (the series
                            // cover), the exact Movies-shelf pattern —
                            // the wide 16:9 card showed low-res art
                            // upscaled (owner recording, build 45).
                            // Destination unchanged.
                            SeriesCard(
                                playlistId: playlist.id,
                                stream: newSeries[index],
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                imageLoadProfile: .shelf
                            )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .shelfEntrance(index: index)
                        .contextMenu {
                            Button {
                                toggleFavorite(streamId: newSeries[index].seriesId, type: "series",
                                               currentlyFavorite: isFavoriteSeries(newSeries[index]))
                            } label: {
                                Label(isFavoriteSeries(newSeries[index]) ? L("favorites.remove") : L("favorites.add"), systemImage: "star")
                            }
                            if let categoryId = newSeries[index].categoryId {
                                Button {
                                    hiddenStore.setHidden(true, playlistId: playlist.id, type: "series", categoryId: categoryId)
                                } label: {
                                    Label(L("category_picker.hide"), systemImage: "eye.slash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - Round 14/15 shelves (B6 / C6)

    private static let lastVisitKey = "home.lastVisitAt"

    /// C6 first-week rule: while watch history is thin the layout is
    /// discovery-first; once real history exists the veteran order
    /// takes over. The threshold is a count of REAL history rows.
    private var isVeteranHome: Bool { recentHistory.count >= 5 }

    private enum HomeShelfKind: Hashable {
        case topMovies, topSeries, newMovies, newSeries
        case because, favorites, newEpisodes, tonight, newSinceVisit
    }

    /// C6: shelf order varies by time-of-day bucket DERIVED FROM
    /// WATCH-HISTORY TIMESTAMPS: the modal bucket of the user's own
    /// `lastWatchedAt` hours (morning 5-11, afternoon 11-17, evening
    /// 17-23, night 23-5). No history -> the current hour's bucket.
    private var shelfOrder: [HomeShelfKind] {
        var bucketCounts: [Int: Int] = [:]
        let cal = Calendar.current
        for item in recentHistory {
            let hour = cal.component(.hour, from: item.lastWatchedAt)
            let bucket = hour < 5 ? 3 : (hour < 11 ? 0 : (hour < 17 ? 1 : (hour < 23 ? 2 : 3)))
            bucketCounts[bucket, default: 0] += 1
        }
        let bucket = bucketCounts.max(by: { $0.value < $1.value })?.key
            ?? { let h = cal.component(.hour, from: Date()); return h < 5 ? 3 : (h < 11 ? 0 : (h < 17 ? 1 : (h < 23 ? 2 : 3))) }()
        let discovery: [HomeShelfKind] = [.topMovies, .topSeries, .newMovies, .newSeries, .tonight, .because, .favorites, .newEpisodes, .newSinceVisit]
        let veteran: [HomeShelfKind] = [.because, .favorites, .tonight, .newEpisodes, .topMovies, .topSeries, .newMovies, .newSeries, .newSinceVisit]
        let evening: [HomeShelfKind] = [.tonight, .because, .favorites, .newEpisodes, .topMovies, .newSeries, .topSeries, .newMovies, .newSinceVisit]
        let morning: [HomeShelfKind] = [.newMovies, .newSeries, .newSinceVisit, .topMovies, .topSeries, .tonight, .because, .favorites, .newEpisodes]
        if !isVeteranHome { return discovery }
        switch bucket {
        case 0: return morning
        case 2: return evening
        default: return veteran
        }
    }

    @ViewBuilder
    private func shelfView(_ kind: HomeShelfKind) -> some View {
        switch kind {
        // F6 (B13): the Movies/Series shelves and the Library
        // (favorites) shelf follow the ONE visibility store.
        case .topMovies:
            if sectionVisibility.isVisible(.movies), topRatedMovies.count >= 3 { topRatedMoviesShelf }
        case .topSeries:
            if sectionVisibility.isVisible(.series), topRatedSeries.count >= 3 { topRatedSeriesShelf }
        case .newMovies:
            if sectionVisibility.isVisible(.movies), !newMovies.isEmpty { newMoviesShelf }
        case .newSeries:
            if sectionVisibility.isVisible(.series), !newSeries.isEmpty { newSeriesShelf }
        case .because:
            if !becauseYouWatched.isEmpty { becauseShelf }
        case .favorites:
            if sectionVisibility.isVisible(.library), !favoriteLive.isEmpty || !favoriteVODs.isEmpty || !favoriteSeries.isEmpty { favoritesShelf }
        case .newEpisodes:
            if !newEpisodeSeries.isEmpty { newEpisodesShelf }
        case .tonight:
            if !tonightEntries.isEmpty { tonightShelf }
        case .newSinceVisit:
            if !newSinceVisit.isEmpty { newSinceVisitShelf }
        }
    }

    // MARK: On now (B6)

    private struct OnNowEntry: Identifiable {
        let stream: DBLiveStream
        let nowTitle: String
        let progress: Double?
        var id: Int { stream.streamId }
    }

    private var onNowEntries: [OnNowEntry] {
        guard let snapshot = epgStore.snapshot else { return [] }
        var out: [OnNowEntry] = []
        for item in contentStore.liveStreams where !liveHiddenIds.contains(item.stream.categoryId ?? "") {
            let stream = item.stream
            guard let nn = snapshot[EPGChannelKey.forXtream(stream)], let now = nn.now else { continue }
            // F1 (B13): progress against the offset-shifted "now",
            // matching the snapshot's own offset-aware current pick.
            out.append(OnNowEntry(stream: stream, nowTitle: now.title, progress: now.progress(at: EPGOffsetStore.lookupNow(epgStore.nowDate))))
            if out.count == 15 { break }
        }
        return out
    }

    private var onNowShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("home.on_now")) {
                AllLiveView(playlist: playlist)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(onNowEntries) { entry in
                        LiveHeroMiniCard(stream: entry.stream, nowTitle: entry.nowTitle, progress: entry.progress) {
                            presentLiveSelectionFromHome(entry.stream)
                        }
                    }
                }
                .padding(.horizontal, AppTheme.spacingScreenMargin)
            }
            .scrollClipDisabled()
            .shelfEdgeFade()
        }
    }

    private func presentLiveSelectionFromHome(_ stream: DBLiveStream) {
        playerOverlay.present(playlistId: playlist.id) {
            LivePlayerShell(playlist: playlist, queue: homeLiveQueue, sections: homeLiveSections,
                            initialStream: stream, initialHistory: nil, subtitle: nil)
        }
    }

    // MARK: Tonight (C6)

    private struct TonightEntry: Identifiable {
        let stream: DBLiveStream
        let programme: EPGProgramme
        var id: String { "\(stream.streamId)|\(programme.id)" }
    }

    private func recomputeTonight() async {
        // Most-watched channels = the live channels appearing in real
        // watch history, most recent first, deduped, capped at 8.
        var seen: [Int] = []
        for item in recentHistory where item.type == "live" {
            if let sid = Int(item.streamId), !seen.contains(sid) { seen.append(sid) }
            if seen.count == 8 { break }
        }
        guard !seen.isEmpty else { tonightEntries = []; return }
        let streams = seen.compactMap { sid in homeLiveQueue.first(where: { $0.streamId == sid }) }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // F1 (B13): "tonight" is a DISPLAY window (19:00–23:00 as
        // shown), so the raw programme window shifts by −offset.
        guard let displayWindowStart = cal.date(bySettingHour: 19, minute: 0, second: 0, of: today),
              let displayWindowEnd = cal.date(bySettingHour: 23, minute: 0, second: 0, of: today) else { return }
        let windowStart = displayWindowStart.addingTimeInterval(-EPGOffsetStore.offsetSeconds)
        let windowEnd = displayWindowEnd.addingTimeInterval(-EPGOffsetStore.offsetSeconds)
        var entries: [TonightEntry] = []
        for stream in streams {
            guard let key = epgStore.storedKey(idKey: stream.epgChannelId, nameKey: stream.name) else { continue }
            let programmes = (try? await epgStore.programmes(playlistId: playlist.id, channelKey: key, from: windowStart, to: windowEnd)) ?? []
            for programme in programmes where programme.start >= windowStart && programme.start < windowEnd {
                entries.append(TonightEntry(stream: stream, programme: programme))
            }
        }
        tonightEntries = Array(entries.sorted { $0.programme.start < $1.programme.start }.prefix(12))
    }

    private var tonightShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("home.tonight")) {
                AllLiveView(playlist: playlist)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(tonightEntries) { entry in
                        LiveHeroMiniCard(stream: entry.stream, nowTitle: entry.programme.title,
                                         progress: nil, timeText: EPGTimeFormat.time(entry.programme.start)) {
                            presentLiveSelectionFromHome(entry.stream)
                        }
                    }
                }
                .padding(.horizontal, AppTheme.spacingScreenMargin)
            }
            .scrollClipDisabled()
            .shelfEdgeFade()
        }
    }

    // MARK: Because you watched (B6) / New episodes (C6) / New since visit (C6)

    private var becauseShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("home.because_you_watched")) {
                AllVODView(playlist: playlist)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(becauseYouWatched.indices, id: \.self) { index in
                        entryPosterLink(becauseYouWatched[index], queue: becauseYouWatched.compactMap { if case .movie(let m) = $0 { return m } else { return nil } })
                            .shelfEntrance(index: index)
                    }
                }
                .padding(.horizontal, AppTheme.spacingScreenMargin)
            }
            .scrollClipDisabled()
            .shelfEdgeFade()
        }
    }

    private var newEpisodesShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("home.new_episodes")) {
                AllSeriesView(playlist: playlist)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(newEpisodeSeries.indices, id: \.self) { index in
                        NavigationLink {
                            SeriesDetailView(playlist: playlist, series: newEpisodeSeries[index])
                        } label: {
                            SeriesCard(
                                playlistId: playlist.id,
                                stream: newEpisodeSeries[index],
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                imageLoadProfile: .shelf
                            )
                            .overlay(alignment: .topTrailing) {
                                // C6: "New episodes" badge — only for
                                // series whose lastModified is newer than
                                // the user's last watch (see recompute).
                                Text(L("home.new_episodes_badge"))
                                    .font(AppTheme.fontBadge)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Capsule().fill(AppTheme.accent))
                                    .padding(6)
                            }
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .shelfEntrance(index: index)
                    }
                }
                .padding(.horizontal, AppTheme.spacingScreenMargin)
            }
            .scrollClipDisabled()
            .shelfEdgeFade()
        }
    }

    private var newSinceVisitShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("home.new_since_visit")) {
                AllVODView(playlist: playlist)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(newSinceVisit.indices, id: \.self) { index in
                        entryPosterLink(newSinceVisit[index], queue: newSinceVisit.compactMap { if case .movie(let m) = $0 { return m } else { return nil } })
                            .shelfEntrance(index: index)
                    }
                }
                .padding(.horizontal, AppTheme.spacingScreenMargin)
            }
            .scrollClipDisabled()
            .shelfEdgeFade()
        }
    }

    @ViewBuilder
    private func entryPosterLink(_ entry: FeaturedEntry, queue: [DBVODStream] = []) -> some View {
        switch entry {
        case .movie(let movie):
            NavigationLink {
                // B1: detail opened from a Home shelf carries THAT
                // shelf's queue as its playlist context (prev/next).
                MovieDetailView(playlist: playlist, movie: movie, queue: queue.isEmpty ? [movie] : queue)
            } label: {
                VODStreamCard(playlistId: playlist.id, stream: movie,
                              posterWidth: posterMetrics.shelfPosterWidth,
                              posterHeight: posterMetrics.shelfPosterHeight,
                              imageLoadProfile: .shelf)
            }
            .buttonStyle(PressScaleButtonStyle())
        case .series(let series):
            NavigationLink {
                SeriesDetailView(playlist: playlist, series: series)
            } label: {
                SeriesCard(playlistId: playlist.id, stream: series,
                           posterWidth: posterMetrics.shelfPosterWidth,
                           posterHeight: posterMetrics.shelfPosterHeight,
                           imageLoadProfile: .shelf)
            }
            .buttonStyle(PressScaleButtonStyle())
        }
    }

    // MARK: Favorites row (B6)

    private var favoritesShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("favorites.title")) {
                FavoritesView(playlist: playlist, initialType: "live")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(favoriteLive.prefix(8)) { item in
                        LiveStreamCard(
                            playlistId: playlist.id, stream: item.stream,
                            width: posterMetrics.liveShelfLabelWidth,
                            iconSize: posterMetrics.liveShelfIcon,
                            imageLoadProfile: .shelf
                        ) { stream, _ in presentLiveSelectionFromHome(stream) }
                    }
                    ForEach(favoriteVODs.prefix(8)) { item in
                        NavigationLink {
                            MovieDetailView(playlist: playlist, movie: item.stream, queue: favoriteVODs.map(\.stream))
                        } label: {
                            VODStreamCard(playlistId: playlist.id, stream: item.stream,
                                          posterWidth: posterMetrics.shelfPosterWidth,
                                          posterHeight: posterMetrics.shelfPosterHeight,
                                          imageLoadProfile: .shelf)
                        }
                        .buttonStyle(PressScaleButtonStyle())
                    }
                    ForEach(favoriteSeries.prefix(8)) { item in
                        NavigationLink {
                            SeriesDetailView(playlist: playlist, series: item.series)
                        } label: {
                            SeriesCard(playlistId: playlist.id, stream: item.series,
                                       posterWidth: posterMetrics.shelfPosterWidth,
                                       posterHeight: posterMetrics.shelfPosterHeight,
                                       imageLoadProfile: .shelf)
                        }
                        .buttonStyle(PressScaleButtonStyle())
                    }
                }
                .padding(.horizontal, AppTheme.spacingScreenMargin)
            }
            .scrollClipDisabled()
            .shelfEdgeFade()
        }
    }

    // MARK: - B3 favorite toggle (context menus / cards)

    private func isFavoriteMovie(_ movie: DBVODStream) -> Bool {
        favoriteVODs.contains { $0.stream.streamId == movie.streamId }
    }
    private func isFavoriteSeries(_ series: DBSeries) -> Bool {
        favoriteSeries.contains { $0.series.seriesId == series.seriesId }
    }

    /// B3/B12: favorite toggle with the spec feedback (success haptic +
    /// UI sound). Writes the SAME DBFavorite rows the detail screens use.
    private func toggleFavorite(streamId: Int, type: String, currentlyFavorite: Bool) {
        Task {
            try? await AppDatabase.shared.write { db in
                if currentlyFavorite {
                    try DBFavorite
                        .filter(Column("streamId") == streamId && Column("playlistId") == playlist.id && Column("type") == type)
                        .deleteAll(db)
                } else {
                    try DBFavorite(streamId: streamId, playlistId: playlist.id, type: type).insert(db)
                }
            }
            if !currentlyFavorite {
                Haptics.success()
                AppSound.play(.favorite)
            }
        }
    }

    // MARK: - Artwork URLs

    private func moviePosterURL(_ movie: DBVODStream) -> URL? {
        guard let icon = movie.streamIcon?.trimmingCharacters(in: .whitespaces), !icon.isEmpty else { return nil }
        return URL(string: icon)
    }

    private func seriesPosterURL(_ series: DBSeries) -> URL? {
        guard let cover = series.cover?.trimmingCharacters(in: .whitespaces), !cover.isEmpty else { return nil }
        return URL(string: cover)
    }

    // MARK: - Continue Watching playback (same routing as the Live tab)

    private var homeLiveSections: [LiveChannelCategorySection] {
        contentStore.liveCategories
            .filter { !liveHiddenIds.contains($0.id) }
            .compactMap { category in
                let streams = (contentStore.liveStreamsByCategoryId[category.id] ?? []).map(\.stream)
                return streams.isEmpty ? nil : LiveChannelCategorySection(id: category.id, title: category.name, streams: streams)
            }
    }

    private var homeLiveQueue: [DBLiveStream] { homeLiveSections.flatMap(\.streams) }

    private func presentHistoryItem(_ item: DBWatchHistory) {
        guard let url = historyURL(for: item) else { return }
        if item.type == "series" {
            playerOverlay.present(playlistId: playlist.id) {
                HistorySeriesPlayerShell(playlist: playlist, history: item, url: url)
            }
        } else if item.type == "live" {
            let stream = liveStream(for: item) ?? DBLiveStream(
                streamId: Int(item.streamId) ?? 0,
                name: item.title,
                streamIcon: item.imageURL,
                categoryId: nil,
                sortIndex: 0,
                playlistId: item.playlistId
            )
            playerOverlay.present(playlistId: playlist.id) {
                LivePlayerShell(
                    playlist: playlist,
                    queue: homeLiveQueue,
                    sections: homeLiveSections,
                    initialStream: stream,
                    initialHistory: item,
                    subtitle: nil
                )
            }
        } else {
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

    private func historyURL(for item: DBWatchHistory) -> URL? {
        let builder = PlaybackURLBuilder(playlist: playlist)
        switch item.type {
        case "live":
            return builder.liveURL(streamId: Int(item.streamId) ?? 0)
        case "vod":
            return builder.movieURL(streamId: Int(item.streamId) ?? 0, containerExtension: nil)
        case "series":
            return builder.seriesURL(streamId: item.streamId, containerExtension: nil)
        default:
            return nil
        }
    }

    private func liveStream(for item: DBWatchHistory) -> DBLiveStream? {
        let streamId = Int(item.streamId) ?? 0
        if let match = homeLiveQueue.first(where: { $0.streamId == streamId }) {
            return match
        }
        return contentStore.liveStreamsByCategoryId.values
            .lazy
            .joined()
            .first(where: { $0.stream.streamId == streamId })?
            .stream
    }

    // MARK: - Recompute (off-main, mirrors the tabs' pattern)

    private func recompute() async {
        guard playlist.id == contentStore.activePlaylistId else {
            featured = []
            topRatedMovies = []
            topRatedSeries = []
            newMovies = []
            newSeries = []
            return
        }

        let vodCats = contentStore.vodCategories.filter { !vodHiddenIds.contains($0.id) }
        let seriesCats = contentStore.seriesCategories.filter { !seriesHiddenIds.contains($0.id) }
        let vodItems = contentStore.vodStreams
        let seriesList = contentStore.seriesItems

        let result = await Task.detached(priority: .userInitiated) { () -> HomeComputed in
            let visibleVODCatIds = Set(vodCats.map(\.id))
            let visibleSeriesCatIds = Set(seriesCats.map(\.id))

            // Round 7 (performance): ONE pass per content type. Round 5
            // ran four separate passes over each array (featured /
            // top-rated / newest / collage), and every pass re-parsed
            // every item's rating string and added timestamp — on the
            // owner's 22,318-movie catalog that is ~90k string parses
            // per recompute, multiplied again by the four duplicate
            // triggers. Now each item's score and timestamp are parsed
            // exactly once into prebuilt tuples; the sorts below only
            // compare the parsed values.
            //
            // Featured rule (unchanged): rated items WITH artwork, true
            // backdrops first, then by the round-3 normalized rating.
            // Note the catalog sync does not store backdrop paths (they
            // arrive with detail loads), so on a fresh catalog the pool
            // is poster-art items — always real catalog art, never
            // stock imagery.
            var featuredPool: [(entry: FeaturedEntry, hasBackdrop: Bool, score: Double)] = []
            var movieScores: [(DBVODStream, Double)] = []
            var movieNewest: [(DBVODStream, Int)] = []
            for item in vodItems where visibleVODCatIds.contains(item.stream.categoryId ?? "") {
                let movie = item.stream
                if let score = ContentRating.normalizedRating10(rating: movie.rating, rating5Based: movie.rating5Based) {
                    movieScores.append((movie, score))
                    let backdrop = movie.backdropPath?.trimmingCharacters(in: .whitespaces)
                    let poster = movie.streamIcon?.trimmingCharacters(in: .whitespaces)
                    let hasBackdrop = !(backdrop?.isEmpty ?? true)
                    if hasBackdrop || !(poster?.isEmpty ?? true) {
                        featuredPool.append((.movie(movie), hasBackdrop, score))
                    }
                }
                if let ts = movie.added.flatMap(Int.init) {
                    movieNewest.append((movie, ts))
                }
            }

            var seriesScores: [(DBSeries, Double)] = []
            var seriesNewest: [(DBSeries, Int)] = []
            for item in seriesList where visibleSeriesCatIds.contains(item.series.categoryId ?? "") {
                let series = item.series
                if let score = ContentRating.normalizedRating10(rating: series.rating, rating5Based: series.rating5Based) {
                    seriesScores.append((series, score))
                    let backdrop = series.backdropPath?.trimmingCharacters(in: .whitespaces)
                    let poster = series.cover?.trimmingCharacters(in: .whitespaces)
                    let hasBackdrop = !(backdrop?.isEmpty ?? true)
                    if hasBackdrop || !(poster?.isEmpty ?? true) {
                        featuredPool.append((.series(series), hasBackdrop, score))
                    }
                }
                if let ts = series.lastModified.flatMap(Int.init) {
                    seriesNewest.append((series, ts))
                }
            }

            // Sorts run over the prebuilt tuples only (no re-parsing in
            // comparators). Top Rated = the tabs' exact ranking,
            // rating-bearing items only, capped at 10 for the numerals.
            // New = the tabs' exact rule: only records whose added /
            // lastModified timestamp actually parses take part.
            let featured = featuredPool
                .sorted { a, b in
                    if a.hasBackdrop != b.hasBackdrop { return a.hasBackdrop }
                    return a.score > b.score
                }
                .prefix(8)
                .map(\.entry)
            let topMovies = movieScores
                .sorted { $0.1 > $1.1 }
                .prefix(10)
                .map(\.0)
            let topSeries = seriesScores
                .sorted { $0.1 > $1.1 }
                .prefix(10)
                .map(\.0)
            let newestMovies = movieNewest
                .sorted { $0.1 > $1.1 }
                .prefix(15)
                .map(\.0)
            let newestSeries = seriesNewest
                .sorted { $0.1 > $1.1 }
                .prefix(15)
                .map(\.0)

            return HomeComputed(
                featured: featured,
                topRatedMovies: topMovies,
                topRatedSeries: topSeries,
                newMovies: newestMovies,
                newSeries: newestSeries
            )
        }.value

        guard !Task.isCancelled else { return }
        featured = result.featured
        topRatedMovies = result.topRatedMovies
        topRatedSeries = result.topRatedSeries
        newMovies = result.newMovies
        newSeries = result.newSeries
        applySharedShelvesAndHistoryRules()
    }

    /// B6/B10/C6 post-pass (main actor, cheap set/array work only):
    /// shared store rankings preferred over this view's own pass;
    /// metadata-poor fallbacks (Top Rated merges with New under 3
    /// rated; hero falls back to newest-with-artwork); hero rotation
    /// (finished titles excluded, daily exposure cap 3, not-yet-shown
    /// preferred); Because-you-watched from real history genres; New
    /// episodes (lastModified newer than last watch); New since your
    /// last visit against the saved visit stamp.
    private func applySharedShelvesAndHistoryRules() {
        let visibleVOD = Set(contentStore.vodCategories.filter { !vodHiddenIds.contains($0.id) }.map(\.id))
        let visibleSeries = Set(contentStore.seriesCategories.filter { !seriesHiddenIds.contains($0.id) }.map(\.id))

        let sharedMovies = contentStore.sharedTopRatedMovies.filter { visibleVOD.contains($0.categoryId ?? "") }
        if !sharedMovies.isEmpty { topRatedMovies = Array(sharedMovies.prefix(10)) }
        let sharedSeries = contentStore.sharedTopRatedSeries.filter { visibleSeries.contains($0.categoryId ?? "") }
        if !sharedSeries.isEmpty { topRatedSeries = Array(sharedSeries.prefix(10)) }
        let sharedNewMovies = contentStore.sharedNewestMovies.filter { visibleVOD.contains($0.categoryId ?? "") }
        if !sharedNewMovies.isEmpty { newMovies = Array(sharedNewMovies.prefix(15)) }
        let sharedNewSeries = contentStore.sharedNewestSeries.filter { visibleSeries.contains($0.categoryId ?? "") }
        if !sharedNewSeries.isEmpty { newSeries = Array(sharedNewSeries.prefix(15)) }

        if topRatedMovies.count < 3 {
            let have = Set(topRatedMovies.map(\.streamId))
            topRatedMovies += newMovies.filter { !have.contains($0.streamId) }.prefix(10 - topRatedMovies.count)
        }
        if topRatedSeries.count < 3 {
            let have = Set(topRatedSeries.map(\.seriesId))
            topRatedSeries += newSeries.filter { !have.contains($0.seriesId) }.prefix(10 - topRatedSeries.count)
        }

        let finishedMovieIds = Set(recentHistory.filter {
            $0.type == "vod" && $0.durationMs > 0 && Double($0.lastTimeMs) / Double($0.durationMs) >= 0.98
        }.compactMap { Int($0.streamId) })
        let finishedSeriesIds = Set(recentHistory.filter {
            $0.type == "series" && $0.durationMs > 0 && Double($0.lastTimeMs) / Double($0.durationMs) >= 0.98
        }.compactMap { $0.seriesId.flatMap(Int.init) ?? Int($0.streamId) })
        featured = featured.filter { entry in
            switch entry {
            case .movie(let m): return !finishedMovieIds.contains(m.streamId)
            case .series(let s): return !finishedSeriesIds.contains(s.seriesId)
            }
        }
        if featured.count < 3 {
            let have = Set(featured.map(\.id))
            for movie in newMovies where !have.contains("movie_\(movie.playlistId)_\(movie.streamId)") {
                if movie.streamIcon?.isEmpty == false || movie.backdropPath?.isEmpty == false {
                    featured.append(.movie(movie))
                }
                if featured.count >= 5 { break }
            }
            if featured.count < 3 {
                for series in newSeries where !have.contains("series_\(series.playlistId)_\(series.seriesId)") {
                    if series.cover?.isEmpty == false || series.backdropPath?.isEmpty == false {
                        featured.append(.series(series))
                    }
                    if featured.count >= 5 { break }
                }
            }
        }
        let dayKey = "home.heroExposure." + String(Int(Date().timeIntervalSince1970) / 86_400)
        var exposure = UserDefaults.standard.dictionary(forKey: dayKey) as? [String: Int] ?? [:]
        let capped = featured.filter { (exposure[$0.id] ?? 0) < 3 }
        if !capped.isEmpty { featured = capped }
        featured.sort { (exposure[$0.id] ?? 0) < (exposure[$1.id] ?? 0) }
        for entry in featured { exposure[entry.id, default: 0] += 1 }
        UserDefaults.standard.set(exposure, forKey: dayKey)

        var genres = Set<String>()
        var watchedMovieIds = Set<Int>()
        var watchedSeriesIds = Set<Int>()
        for item in recentHistory {
            switch item.type {
            case "vod":
                if let id = Int(item.streamId) { watchedMovieIds.insert(id) }
                if let record = contentStore.vodStreams.first(where: { $0.stream.streamId == Int(item.streamId) })?.stream,
                   let genre = DetailFormatting.genreList(record.genre).first { genres.insert(genre) }
            case "series":
                if let sid = item.seriesId.flatMap(Int.init) ?? Int(item.streamId) { watchedSeriesIds.insert(sid) }
                if let record = contentStore.seriesItems.first(where: { "\($0.series.seriesId)" == (item.seriesId ?? item.streamId) })?.series,
                   let genre = DetailFormatting.genreList(record.genre).first { genres.insert(genre) }
            default: break
            }
        }
        if !genres.isEmpty {
            var picks: [FeaturedEntry] = []
            for item in contentStore.vodStreams where !watchedMovieIds.contains(item.stream.streamId) {
                if let genre = DetailFormatting.genreList(item.stream.genre).first, genres.contains(genre) {
                    picks.append(.movie(item.stream))
                }
                if picks.count >= 6 { break }
            }
            for item in contentStore.seriesItems where !watchedSeriesIds.contains(item.series.seriesId) {
                if let genre = DetailFormatting.genreList(item.series.genre).first, genres.contains(genre) {
                    picks.append(.series(item.series))
                }
                if picks.count >= 10 { break }
            }
            becauseYouWatched = picks
        } else {
            becauseYouWatched = []
        }

        var lastWatchedBySeries: [Int: Date] = [:]
        for item in recentHistory where item.type == "series" {
            guard let sid = item.seriesId.flatMap(Int.init) ?? Int(item.streamId) else { continue }
            if let existing = lastWatchedBySeries[sid] {
                if item.lastWatchedAt > existing { lastWatchedBySeries[sid] = item.lastWatchedAt }
            } else {
                lastWatchedBySeries[sid] = item.lastWatchedAt
            }
        }
        newEpisodeSeries = lastWatchedBySeries.compactMap { (sid, watchedAt) -> DBSeries? in
            guard let record = contentStore.seriesItems.first(where: { $0.series.seriesId == sid })?.series,
                  let modified = record.lastModified.flatMap(Int.init) else { return nil }
            return TimeInterval(modified) > watchedAt.timeIntervalSince1970 ? record : nil
        }

        let lastVisit = UserDefaults.standard.double(forKey: Self.lastVisitKey)
        if lastVisit > 0 {
            var fresh: [FeaturedEntry] = []
            for movie in contentStore.sharedNewestMovies where visibleVOD.contains(movie.categoryId ?? "") {
                if let added = movie.added.flatMap(Int.init), TimeInterval(added) > lastVisit {
                    fresh.append(.movie(movie))
                }
                if fresh.count >= 10 { break }
            }
            if fresh.count < 10 {
                for series in contentStore.sharedNewestSeries where visibleSeries.contains(series.categoryId ?? "") {
                    if let modified = series.lastModified.flatMap(Int.init), TimeInterval(modified) > lastVisit {
                        fresh.append(.series(series))
                    }
                    if fresh.count >= 10 { break }
                }
            }
            newSinceVisit = fresh
        } else {
            newSinceVisit = []
        }
    }
}

private struct HomeComputed {
    let featured: [FeaturedEntry]
    let topRatedMovies: [DBVODStream]
    let topRatedSeries: [DBSeries]
    let newMovies: [DBVODStream]
    let newSeries: [DBSeries]
}

/// The single recompute trigger token (round 7): one Equatable value
/// combining every input the Home pass depends on, so one change set
/// runs the pass exactly once.
private struct HomeRecomputeToken: Equatable {
    let loaded: Bool
    let liveCount: Int
    let vodCount: Int
    let seriesCount: Int
    let historyCount: Int
    let live: Set<String>
    let vod: Set<String>
    let series: Set<String>
}

// MARK: - Featured entries

enum FeaturedEntry: Identifiable, Equatable {
    case movie(DBVODStream)
    case series(DBSeries)

    var id: String {
        switch self {
        case .movie(let movie): return "movie_\(movie.playlistId)_\(movie.streamId)"
        case .series(let series): return "series_\(series.playlistId)_\(series.seriesId)"
        }
    }

    var title: String {
        switch self {
        case .movie(let movie): return movie.name
        case .series(let series): return series.name
        }
    }

    /// Backdrop art when the record carries it (detail-loaded items),
    /// otherwise the poster/cover — always the item's own catalog art.
    var artURL: URL? {
        switch self {
        case .movie(let movie):
            if let backdrop = movie.backdropPath?.trimmingCharacters(in: .whitespaces), !backdrop.isEmpty {
                return URL(string: backdrop)
            }
            if let icon = movie.streamIcon?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
                return URL(string: icon)
            }
            return nil
        case .series(let series):
            if let backdrop = series.backdropPath?.trimmingCharacters(in: .whitespaces), !backdrop.isEmpty {
                return URL(string: backdrop)
            }
            if let cover = series.cover?.trimmingCharacters(in: .whitespaces), !cover.isEmpty {
                return URL(string: cover)
            }
            return nil
        }
    }

    /// True when the record carries real backdrop art (16:9-shaped).
    /// Poster-only entries render CONTAINED in the carousel card
    /// (round 7 landscape rule: never fill-crop a 2:3 poster into a
    /// wide frame — it blows faces up to full-screen size).
    var hasBackdropArt: Bool {
        switch self {
        case .movie(let movie):
            if let backdrop = movie.backdropPath?.trimmingCharacters(in: .whitespaces), !backdrop.isEmpty {
                return true
            }
            return false
        case .series(let series):
            if let backdrop = series.backdropPath?.trimmingCharacters(in: .whitespaces), !backdrop.isEmpty {
                return true
            }
            return false
        }
    }

    var iconName: String {
        switch self {
        case .movie: return "film"
        case .series: return "play.tv"
        }
    }

    /// B6: the slide shows the item's REAL rating (normalized, the
    /// same rule as the ranked shelves); nil when the record has none.
    var ratingText: String? {
        switch self {
        case .movie(let movie):
            return ContentRating.normalizedDisplayText(rating: movie.rating, rating5Based: movie.rating5Based)
        case .series(let series):
            return ContentRating.normalizedDisplayText(rating: series.rating, rating5Based: series.rating5Based)
        }
    }

    /// "2024 • Action • 2h 5m" — only the parts the record actually
    /// carries; an item with no meta shows no line at all.
    var metaLine: String? {
        var parts: [String] = []
        switch self {
        case .movie(let movie):
            if let year = DetailFormatting.year(from: movie.releaseDate) { parts.append(year) }
            if let genre = DetailFormatting.genreList(movie.genre).first { parts.append(genre) }
            if let duration = movie.duration?.trimmingCharacters(in: .whitespaces), !duration.isEmpty {
                parts.append(duration)
            }
        case .series(let series):
            if let year = DetailFormatting.year(from: series.releaseDate) { parts.append(year) }
            if let genre = DetailFormatting.genreList(series.genre).first { parts.append(genre) }
            if let runtime = DetailFormatting.seriesRuntime(series.episodeRunTime) { parts.append(runtime) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

// MARK: - Featured slide

private struct FeaturedSlide: View {
    let entry: FeaturedEntry
    let isCurrent: Bool
    let width: CGFloat
    let onPlay: () -> Void
    let onDetails: () -> Void

    /// B12: title-block entrance, driven by slide change.
    @State private var textShown = false

    var body: some View {
        // B6: text/meta/buttons OVER the backdrop with a gradient —
        // the round-10 layout put the text block UNDER the art. B1:
        // tapping the backdrop itself opens the detail page (the
        // buttons keep their own actions).
        ZStack(alignment: .bottomLeading) {
            if !entry.hasBackdropArt {
                RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                    .fill(AppTheme.surface)
                CachedImage(
                    url: entry.artURL,
                    width: width,
                    height: width * 9 / 16,
                    cornerRadius: AppTheme.heroCornerRadius,
                    contentMode: .fill,
                    iconName: entry.iconName,
                    loadProfile: .standard
                )
                .scaleEffect(1.15)
                .blur(radius: 26)
                .overlay(Color.black.opacity(0.5))
            }

            CachedImage(
                url: entry.artURL,
                width: width,
                height: width * 9 / 16,
                cornerRadius: AppTheme.heroCornerRadius,
                contentMode: entry.hasBackdropArt ? .fill : .fit,
                iconName: entry.iconName,
                loadProfile: .high
            )

            // Gradient so the overlaid text stays readable on any art.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: AppTheme.background.opacity(0.92), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)

            Text(L("home.featured"))
                .font(AppTheme.fontBadge)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(AppTheme.accent))
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 8) {
                // Build 61 (Design-4, home panel 4): the hero title
                // is BIG and in the accent (the mockup's red-orange
                // headline over the art).
                Text(entry.title)
                    .font(.title.weight(.black))
                    .foregroundStyle(AppTheme.accent)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let ratingText = entry.ratingText {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AppTheme.ratingGold)
                            Text(ratingText)
                                .font(AppTheme.fontMetadata.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    if let metaLine = entry.metaLine {
                        Text(metaLine)
                            .font(AppTheme.fontMetadata)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 10) {
                    Button(action: onPlay) {
                        // Design-4 PLAY pill: solid accent, BLACK
                        // bold text (SPEC §2, as the gate's primary).
                        Label(L("home.play"), systemImage: "play.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppTheme.onAccent)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(AppTheme.accent))
                    }
                    .buttonStyle(PressScaleButtonStyle())

                    Button(action: onDetails) {
                        Text(L("home.details"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(AppTheme.elevated))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                }
            }
            .padding(.horizontal, AppTheme.spacingScreenMargin)
            .padding(.bottom, 14)
            .frame(width: width, alignment: .leading)
            // B12: slide change animates the title block
            // (transform/opacity only).
            // Round 16 (P4b): the block shows ONLY on the current
            // slide. During a page transition the outgoing slide's
            // title + Play/Details buttons used to stay fully
            // rendered next to the incoming slide's — two control
            // sets on screen at once. Non-current slides now render
            // artwork + gradient only, and their block takes no hits.
            .opacity(isCurrent && textShown ? 1 : 0)
            .offset(y: textShown ? 0 : 12)
            .allowsHitTesting(isCurrent)
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous))
        .onTapGesture { if isCurrent { onDetails() } }
        .onChange(of: isCurrent) { _, current in
            if current {
                textShown = false
                withAnimation(Motion.animate(.easeOut(duration: 0.4).delay(0.05))) { textShown = true }
            } else {
                // Round 16 (P4b): hide immediately on losing
                // currency so the entrance replays cleanly next
                // time and nothing of this slide's block lingers
                // into the transition.
                textShown = false
            }
        }
        .onAppear {
            withAnimation(Motion.animate(.easeOut(duration: 0.4).delay(0.05))) { textShown = true }
        }
    }
}


// MARK: - Category tile

/// Round 10: STRONG-style clean card — a colored circular icon, the
/// section name and the REAL count beneath, on the standard surface.
/// (Rounds 5–9 rendered catalog art here — a 2×2 collage, then one
/// representative image; the owner replaced the whole treatment with
/// this icon-card model on the build-46 list.)
private struct HomeCategoryTile: View {
    let title: String
    let countText: String
    let tint: Color
    let iconName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(tint)
                    Image(systemName: iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)

                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // C12: counts animate with numericText when the
                    // catalog totals change.
                    .contentTransition(.numericText())
                    .animation(Motion.animate(.easeOut(duration: 0.35)), value: countText)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous).fill(AppTheme.surface))
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
    }
}
