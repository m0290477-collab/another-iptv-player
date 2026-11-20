import SwiftUI
import GRDB
import GRDBQuery

// MARK: - Home tab (round 5)

/// The Home tab — the app's front door, built entirely from the loaded
/// catalog (PlaylistContentStore) and the existing watch-history source.
/// Nothing here is hard-coded: the featured carousel ranks movies/series
/// that carry artwork by the round-3 normalized rating rule, and the
/// Most Popular rails reuse that same ranking (the catalog carries no
/// popularity metric — the normalized rating is the closest real
/// ordering the data offers). Build 77 (owner-picked Design A): Home
/// is exactly five sections in order — the hero, Match Results
/// (per-match cards from the real MatchesService payload), Most
/// Popular Movies, Most Popular Series, and ONE merged Continue
/// Watching rail of wide cards. A cross-section dedupe (hero first,
/// then the rails, then Continue) guarantees no movie/series/episode
/// appears twice on this screen. Every tap routes into an existing
/// detail view, player shell, or tab — no new navigation machinery.
struct HomeView: View {
    let playlist: Playlist
    let onOpenLive: () -> Void
    let onOpenMovies: () -> Void
    let onOpenSeries: () -> Void

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
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
    // Build 66 (W3): the "Because you watched" rail and the Home
    // "New episodes" shelf are REMOVED (Critic kills — the rail was
    // the cut "For You" recommendation engine; the shelf was
    // cut-adjacent to the removed new-episode alerts). No state,
    // no shelf, no recompute for either remains.
    @State private var newSinceVisit: [FeaturedEntry] = []
    // Round 10: the category tiles are icon cards now — the tile-art
    // state rounds 5–9 maintained for them is gone with the photos.
    // Build 77: the Tonight shelf is gone with the rest of the
    // pre-Design-A rows — Home renders five sections only.

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
    /// Build 80 (item 13, F2): Continue Watching failure alert.
    @State private var showHistoryPlayFailure = false

    // Build 77 (Design A): the J3 row-order / Edit-mode machinery is
    // gone — the five sections have a fixed order the owner picked,
    // and the floating "Customize Home" toggle went with it.

    // Build 77 (Design A): today's match RESULTS for the Match
    // Results section — live matches first, then the most recent
    // finished ones, from the real MatchesService payload only
    // (the same fetch the Matches tab runs). Empty until a fetch
    // lands, and empty again when today has no live/finished match.
    @State private var matchResults: [HomeMatchEntry] = []

    /// Build 77: seriesId → next-episode label ("S02 E05") for the
    /// merged Continue rail's finished-series cards, resolved off
    /// the history change exactly as ContinueSeriesRow resolved
    /// them — never per body pass.
    @State private var continueNextLabels: [String: String] = [:]

    private var liveHiddenIds: Set<String> { hiddenStore.hiddenIds(playlistId: playlist.id, type: "live") }
    private var vodHiddenIds: Set<String> { hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod") }
    private var seriesHiddenIds: Set<String> { hiddenStore.hiddenIds(playlistId: playlist.id, type: "series") }

    // MARK: - Build 77 (Design A): Match Results data

    /// One MatchesService pass for the Match Results section —
    /// sports in MatchesView's tab order (soccer → NFL → NBA),
    /// every league's payload, keeping only matches that HAVE a
    /// result to show: live now, or finished. Runs once per Home
    /// appearance and again when the app returns to the foreground
    /// (event-driven, no polling loop). When the user hid the
    /// Matches section (F6), the pass does not run and the section
    /// is not shown. Ordering: live matches first (earliest start
    /// first), then finished matches, most recent first; a match
    /// carried by two payloads appears once. Capped at 8 cards —
    /// the full day lives one tap away in MatchesView.
    private func loadMatchResults() async {
        guard !UserDefaults.standard.bool(forKey: "sections.hidden.matches") else {
            matchResults = []
            return
        }
        let dateParameter = MatchesService.todayParameter()
        var collected: [HomeMatchEntry] = []
        var seenIds = Set<String>()
        for sport in MatchSport.allCases {
            let outcomes = await MatchesService.fetchSport(sport, dateParameter: dateParameter)
            // fetchSport's outcomes are index-aligned with
            // sport.leaguePaths (the service sorts by league index),
            // so each match keeps the identity item 5 needs to open
            // ITS OWN detail page.
            for (index, outcome) in outcomes.enumerated() {
                guard case .loaded(let result) = outcome,
                      sport.leaguePaths.indices.contains(index) else { continue }
                let leaguePath = sport.leaguePaths[index]
                for match in result.matches
                where (match.state == .live || match.state == .finished)
                    && seenIds.insert(match.id).inserted {
                    collected.append(HomeMatchEntry(sport: sport, leaguePath: leaguePath, match: match))
                }
            }
        }
        let live = collected
            .filter { $0.match.state == .live }
            .sorted { ($0.match.startDate ?? .distantFuture) < ($1.match.startDate ?? .distantFuture) }
        let finished = collected
            .filter { $0.match.state == .finished }
            .sorted { ($0.match.startDate ?? .distantPast) > ($1.match.startDate ?? .distantPast) }
        matchResults = Array((live + finished).prefix(8))
    }

    // MARK: - Build 77 (Design A): cross-section dedupe
    //
    // The owner's standing rule for Home: the same movie, series or
    // episode NEVER appears in two sections of this screen (his
    // build-75 recording audit found one episode in three rails and
    // the hero films repeated in the Top 10 rail). Priority follows
    // the Design A section order — first section wins:
    //   1. Hero (featured) seeds the seen sets.
    //   2. Most Popular Movies drops hero movies.
    //   3. Most Popular Series drops hero series.
    //   5. The merged Continue rail drops anything sections 1/3/4
    //      already showed (see `mergedContinueItems`).
    // (Section 2, Match Results, carries matches — no catalog IDs.)
    // The recompute-time half runs in `applyCrossRowDedupe`, LAST in
    // the assembly, over the final hero/rail arrays; the Continue
    // half is a render-time filter over the same shown sets, because
    // the rail's data is the live history query.

    /// Movie IDs shown by the sections ABOVE the Continue rail:
    /// the hero's movies plus the (already deduped) Most Popular
    /// Movies rail.
    private var homeShownMovieIDs: Set<Int> {
        var ids = Set(topRatedMovies.map(\.streamId))
        for entry in featured {
            if case .movie(let movie) = entry { ids.insert(movie.streamId) }
        }
        return ids
    }

    /// Series IDs shown by the sections above the Continue rail.
    private var homeShownSeriesIDs: Set<Int> {
        var ids = Set(topRatedSeries.map(\.seriesId))
        for entry in featured {
            if case .series(let series) = entry { ids.insert(series.seriesId) }
        }
        return ids
    }

    /// The recompute-time dedupe: the hero wins, then Most Popular
    /// Movies, then Most Popular Series — each rail drops the IDs
    /// the earlier sections already show, then contributes its own.
    private func applyCrossRowDedupe() {
        var seenMovies = Set<Int>()
        var seenSeries = Set<Int>()
        for entry in featured {
            switch entry {
            case .movie(let movie): seenMovies.insert(movie.streamId)
            case .series(let series): seenSeries.insert(series.seriesId)
            }
        }
        topRatedMovies = topRatedMovies.filter { seenMovies.insert($0.streamId).inserted }
        topRatedSeries = topRatedSeries.filter { seenSeries.insert($0.seriesId).inserted }
    }

    /// The merged Continue rail's items: the UNION of the two rows
    /// Design A replaced, over this view's own history request.
    /// - Continue Watching's rule (one card per series from its
    ///   latest episode record; finished series dropped; movies
    ///   and live channels pass through), PLUS
    /// - Continue Series' rule (a series whose latest episode is
    ///   finished stays when a next episode exists — its card then
    ///   carries the next-episode label),
    /// then the cross-section dedupe (hero / popular rails win),
    /// capped at 10 cards like both source rows.
    private var mergedContinueItems: [DBWatchHistory] {
        var seenSeries = Set<String>()
        var candidates: [DBWatchHistory] = []
        for item in recentHistory {
            if item.type == "series", let seriesId = item.seriesId, !seriesId.isEmpty {
                guard seenSeries.insert(seriesId).inserted else { continue }
                let finished = item.durationMs > 0
                    && Double(item.lastTimeMs) / Double(item.durationMs) >= 0.98
                if finished && continueNextLabels[seriesId] == nil { continue }
            }
            candidates.append(item)
        }
        let shownMovies = homeShownMovieIDs
        let shownSeries = homeShownSeriesIDs
        return Array(candidates.filter { item in
            switch item.type {
            case "vod":
                guard let id = Int(item.streamId) else { return true }
                return !shownMovies.contains(id)
            case "series":
                guard let id = item.seriesId.flatMap(Int.init) ?? Int(item.streamId) else { return true }
                return !shownSeries.contains(id)
            default:
                return true
            }
        }.prefix(10))
    }

    /// For each series whose latest episode is finished, resolve
    /// the chain successor's label once (ContinueSeriesRow's exact
    /// resolution, over this view's identical history source).
    private func resolveContinueNextLabels() async {
        var seen = Set<String>()
        var targets: [(seriesId: String, streamId: String)] = []
        for item in recentHistory {
            guard let seriesId = item.seriesId, !seriesId.isEmpty, seen.insert(seriesId).inserted else { continue }
            let finished = item.durationMs > 0
                && Double(item.lastTimeMs) / Double(item.durationMs) >= 0.98
            if finished { targets.append((seriesId, item.streamId)) }
        }
        guard !targets.isEmpty else { continueNextLabels = [:]; return }
        let pid = playlist.id
        let resolved = await Task.detached(priority: .utility) { () -> [String: String] in
            var labels: [String: String] = [:]
            for target in targets {
                let ctx = try? await AppDatabase.shared.read { db in
                    try SeriesPlaybackOrdering.navigationContext(
                        playlistId: pid,
                        playbackStreamId: target.streamId,
                        seriesIdHint: target.seriesId,
                        db: db
                    )
                }
                if let ctx, let next = ctx.next {
                    let season = ctx.nextSeasonNumber ?? next.seasonId.split(separator: "_").last.flatMap { Int($0) }
                    let episode = ctx.nextEpisodeNumber ?? next.episodeNum
                    if let season, let episode {
                        labels[target.seriesId] = String(format: "S%02d E%02d", season, episode)
                    } else if let episode {
                        labels[target.seriesId] = String(format: "E%02d", episode)
                    }
                }
            }
            return labels
        }.value
        guard !Task.isCancelled else { return }
        continueNextLabels = resolved
    }

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
                    // Build 65: the row spacing is the Display
                    // screen's Home-density preference (default
                    // comfortable = the long-standing 26).
                    // Build 75 (performance): LAZY stack — the old
                    // eager VStack instantiated every Home row (and
                    // each row's @Query stores) on every Home
                    // appearance, however far below the fold the row
                    // sat; rows now instantiate as they approach
                    // the viewport. Same order, spacing and content.
                    LazyVStack(alignment: .leading, spacing: HomeDensityPreference.current.shelfSpacing) {
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

                        // Build 77 (Design A): the "What's New"
                        // banner is REMOVED (owner order — it was
                        // already cut once and kept surviving). Home
                        // below the top bar is the five picked
                        // sections and nothing else.

                        // Build 65 (Home v2 style 1 'Cinematic
                        // Hero'): the hero leads the screen.
                        // Build 77 (Design A): it is section 1 of
                        // five — hero cover only at the top.

                        // Build 66 (W3, Home-2): the owner-picked
                        // Cinematic Hero is the DEFAULT and PRIMARY
                        // hero — the tall featured carousel leads
                        // whenever it has entries (on any real
                        // playlist it does). Build 61's live-first
                        // priority (live match → live channel →
                        // carousel) stays inverted: live content
                        // never outranks the picked hero.
                        if !featured.isEmpty {
                            featuredCarousel
                        } else if !contentStore.streamsLoaded {
                            // B6: skeleton placeholders instead of the
                            // bare spinner while the catalog lands.
                            SkeletonShelf()
                        }

                        // Build 77 (Design A) — sections 2–5, in
                        // the owner's picked order. Everything that
                        // used to sit here is gone: the "Live now"
                        // rail, the sports shortcut tiles, the
                        // landscape Trending strip, the category
                        // tiles, the New / Favorites / Tonight /
                        // Recently Added rows and the floating
                        // "Customize Home" toggle.

                        // Section 2: Match Results — one card per
                        // match (live first, then latest finished),
                        // same F6 gate the sports strip had.
                        // Build 81 (item 9, owner): a Sports block
                        // sits DIRECTLY ABOVE Match Results — one
                        // entry per sport, each opening the existing
                        // Matches experience with that sport
                        // preselected (MatchesView(initialSport:),
                        // the build-63 deep link). No second sports
                        // system, no match lists duplicated on Home.
                        // Same F6 gate as Match Results.
                        if !UserDefaults.standard.bool(forKey: "sections.hidden.matches") {
                            homeSportsSection
                            matchResultsSection
                        }

                        // Section 3: Most Popular Movies — the
                        // catalog's normalized-rating ranking (see
                        // the header note), hero-deduped, F6-gated
                        // like the shelf it replaces.
                        if sectionVisibility.isVisible(.movies), topRatedMovies.count >= 3 {
                            popularMoviesRail
                        }

                        // Section 4: Most Popular Series — same
                        // ranking, same gates.
                        if sectionVisibility.isVisible(.series), topRatedSeries.count >= 3 {
                            popularSeriesRail
                        }

                        // Section 5: ONE Continue Watching rail of
                        // wide cards — Continue Watching and
                        // Continue Series merged, each item once.
                        mergedContinueRail

                        // Build 80 (item 11): the Support entry
                        // ordered in the build-74 round and never
                        // implemented — a slim row at the very end
                        // of the Home scroll.
                        homeSupportEntry

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
                // Build 64 (B2): Home opens the unified search on
                // the All tab.
                SearchView(playlist: playlist, searchText: $homeSearchText, initialFilter: .all)
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
        .alert(L("playback.error.failed_to_start"), isPresented: $showHistoryPlayFailure) {
            Button(L("common.ok")) { showHistoryPlayFailure = false }
        }
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
        // Build 77 (Design A): the Match Results pass, once per
        // Home appearance for this playlist.
        .task(id: playlist.id) {
            await loadMatchResults()
        }
        // Re-run when the app returns to the foreground, so a match
        // that kicked off (or finished) while the app was
        // backgrounded updates the results.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await loadMatchResults() }
            }
        }
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
                // X6 (B7): branded loader view swap only.
                BrandedLoader(size: 52)
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
                .foregroundStyle(.primary)

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

    private func topBarSquare(systemName: String, tint: Color = .primary) -> some View {
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

    // MARK: - Featured carousel

    /// Build 80 (item 6, owner-picked Option 3): the hero is a
    /// WIDE cinematic letterbox — 16:9 in BOTH orientations (the
    /// build-65 tall portrait hero with its stretched poster and
    /// blurred side pillars is gone). `heroHeight` is the BACKDROP
    /// height; the slide adds a small overflow below it for the
    /// overlapping poster thumbnail.
    private var heroHeight: CGFloat {
        cardWidth * 9 / 16
    }

    /// The full slide height: backdrop + the poster thumbnail's
    /// overflow below the backdrop's bottom edge.
    private var heroSlideHeight: CGFloat { heroHeight + 30 }

    /// Build 80 (items 3 + 6): the pager is a HORIZONTAL ScrollView
    /// with paging behavior — NOT a TabView. The old page-style
    /// TabView's gesture ate vertical drags that started on the
    /// hero, so the page would not scroll from the cover (item 3);
    /// a horizontal ScrollView inside the vertical page scroll
    /// negotiates by drag direction: vertical drags scroll the
    /// page, horizontal drags page the hero. The page dots sit at
    /// the RIGHT end of the current slide's button row (item 6's
    /// picked composition), overlaid on the frame.
    private var featuredCarousel: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(featured.indices, id: \.self) { index in
                        FeaturedSlide(
                            entry: featured[index],
                            isCurrent: index == featuredIndex,
                            width: cardWidth,
                            height: heroHeight,
                            onPlay: { playFeatured(featured[index]) },
                            onDetails: { showFeaturedDetails(featured[index]) }
                        )
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: featuredPosition)
            .frame(width: cardWidth, height: heroSlideHeight)
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

            // Page dots — at the right end of the button row
            // (item 6), tappable (manual jump; the onChange above
            // pauses auto-rotation after any manual move).
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
                            .fill(index == featuredIndex ? AppTheme.accent : Color.white.opacity(0.45))
                            .frame(width: index == featuredIndex ? 22 : 7, height: 7)
                            .frame(width: 22, height: 22)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .animation(Motion.animate(Motion.shelfSpring), value: featuredIndex)
                }
            }
            .padding(.trailing, AppTheme.spacingScreenMargin)
            // Aligned with the slide's button row, which sits 40 pt
            // above the slide's bottom edge (item 6 layout).
            .padding(.bottom, 44)
        }
        .task(id: featured.count) { await runCarouselTimer() }
    }

    /// scrollPosition's optional-id binding over the carousel's
    /// Int selection (auto-advance and dot taps write the Int; the
    /// pager writes back through here on user swipes).
    private var featuredPosition: Binding<Int?> {
        Binding(
            get: { featuredIndex },
            set: { if let value = $0 { featuredIndex = value } }
        )
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

    // Build 77 (Design A): the build-66 "Live now" rail is removed —
    // live matches live in section 2 (Match Results) now, and live
    // channels live on the Live TV tab, not on Home.

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

    // MARK: - Build 77 (Design A): sections 2–5

    private static let lastVisitKey = "home.lastVisitAt"

    // MARK: Sports entries (build 81, item 9)

    /// One card per covered sport (Soccer / NFL / NBA — the
    /// `MatchSport` cases, in the Matches picker's own order),
    /// deep-linking into the existing Matches destination with the
    /// sport preselected. Design A section language: the shared
    /// small-caps header (its See All opens Matches on the default
    /// sport) over a tidy row of equal cards.
    private var homeSportsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("home.sports")) {
                MatchesView()
            }
            HStack(spacing: 10) {
                ForEach(MatchSport.allCases) { sport in
                    NavigationLink {
                        MatchesView(initialSport: sport)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: sportSymbolName(sport))
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                            Text(L(sport.titleKey))
                                .font(AppTheme.fontCardTitle)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                                .fill(AppTheme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                                        .stroke(AppTheme.cardBorderColor, lineWidth: 1)
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
        .sectionAppear()
    }

    private func sportSymbolName(_ sport: MatchSport) -> String {
        switch sport {
        case .soccer: return "soccerball"
        case .nfl: return "americanfootball.fill"
        case .nba: return "basketball.fill"
        }
    }

    // MARK: Section 2 — Match Results

    /// One card per match, stacked (build 80, item 8: two team
    /// rows — logo + FULL name + that team's score per row — with
    /// the state chip on a slim header line). Build 80 (item 5):
    /// tapping a card opens THAT match's own detail page; only the
    /// header's See-all opens the full Matches screen. Renders
    /// nothing when today has no live or finished match.
    @ViewBuilder
    private var matchResultsSection: some View {
        if !matchResults.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                CinematicSectionHeader(title: L("home.match_results")) {
                    MatchesView()
                }
                VStack(spacing: 8) {
                    ForEach(matchResults) { entry in
                        NavigationLink {
                            MatchDetailView(sport: entry.sport, leaguePath: entry.leaguePath, match: entry.match)
                        } label: {
                            HomeMatchResultCard(match: entry.match)
                        }
                        // Build 81 (item 8): press feedback on the
                        // match cards.
                        .buttonStyle(PressScaleButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
            // Build 81 (item 8): one-shot section entrance.
            .sectionAppear()
        }
    }

    // MARK: Support entry (build 80, item 11)

    /// A slim Design A row opening the SAME Support destination
    /// the Settings hub opens — the exact `SupportSettingsSection`
    /// content (diagnostics, connection & speed test; NO contact
    /// row — the owner never named a support contact, and none is
    /// invented). The section resolves the speed-test target from
    /// the active playlist, which is the playlist Home already
    /// holds, so it is passed directly.
    private var homeSupportEntry: some View {
        NavigationLink {
            List {
                SupportSettingsSection(playlists: [playlist])
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(16)
            .cinematicScrollBackground()
            .navigationTitle(L("support.title"))
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.accent)
                Text(L("support.title"))
                    .font(AppTheme.fontSectionTitle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(AppTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                            .stroke(AppTheme.cardBorderColor, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        }
        // Build 81 (item 8): press feedback + section entrance.
        .buttonStyle(PressScaleButtonStyle())
        .padding(.horizontal, 16)
        .sectionAppear()
    }

    // MARK: Section 3 — Most Popular Movies

    /// The Most Popular Movies rail: the `topRatedMovies` list
    /// (the catalog's normalized-rating ranking — see the header
    /// note) after the hero dedupe, as plain poster cards. The
    /// header's See-all opens the full Movies list; a card opens
    /// the movie's detail page with the rail as its queue.
    private var popularMoviesRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("home.most_popular_movies")) {
                AllVODView(playlist: playlist)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(topRatedMovies.indices, id: \.self) { index in
                        NavigationLink {
                            MovieDetailView(playlist: playlist, movie: topRatedMovies[index], queue: topRatedMovies)
                        } label: {
                            VODStreamCard(
                                playlistId: playlist.id,
                                stream: topRatedMovies[index],
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                imageLoadProfile: .shelf
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

    // MARK: Section 4 — Most Popular Series

    /// The Most Popular Series rail: the same ranking over series,
    /// hero-deduped, as plain poster cards. The header's See-all
    /// opens the full Series list; a card opens the series' detail.
    private var popularSeriesRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            CinematicSectionHeader(title: L("home.most_popular_series")) {
                AllSeriesView(playlist: playlist)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(topRatedSeries.indices, id: \.self) { index in
                        NavigationLink {
                            SeriesDetailView(playlist: playlist, series: topRatedSeries[index])
                        } label: {
                            SeriesCard(
                                playlistId: playlist.id,
                                stream: topRatedSeries[index],
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                imageLoadProfile: .shelf
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

    // MARK: Section 5 — merged Continue Watching

    /// ONE Continue Watching rail of wide cards — the merged
    /// successor of the separate Continue Watching and Continue
    /// Series rows, fed by `mergedContinueItems` (each item once).
    /// The header's See-all opens the full watch-history list (the
    /// destination both source rows used); a card resumes through
    /// Home's existing history path; long-press removes the
    /// history entry, exactly as Continue Watching's cards did.
    @ViewBuilder
    private var mergedContinueRail: some View {
        let items = mergedContinueItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                CinematicSectionHeader(title: L("continue_watching.title")) {
                    WatchHistoryListView(playlist: playlist, typeFilter: nil) { item in
                        presentHistoryItem(item)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(items) { item in
                            HistoryCard(
                                item: item,
                                backdropURL: continueBackdropURL(for: item),
                                metaText: continueMetaText(for: item)
                            )
                            .onTapGesture {
                                presentHistoryItem(item)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    removeContinueHistoryItem(item)
                                } label: {
                                    Label(L("continue_watching.remove"), systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .padding(.vertical, 12)
            .task(id: recentHistory.map(\.id).joined()) { await resolveContinueNextLabels() }
        }
    }

    /// Deletes the history row backing a Continue card (the same
    /// real deletion ContinueWatchingRow's long-press performed).
    private func removeContinueHistoryItem(_ item: DBWatchHistory) {
        let id = item.id
        Task {
            try? await AppDatabase.shared.write { db in
                try DBWatchHistory.filter(Column("id") == id).deleteAll(db)
            }
        }
    }

    private func continueVODRecord(for item: DBWatchHistory) -> DBVODStream? {
        contentStore.vodStreams.first(where: { "\($0.stream.streamId)" == item.streamId })?.stream
    }

    private func continueSeriesRecord(for item: DBWatchHistory) -> DBSeries? {
        guard let seriesId = item.seriesId else { return nil }
        return contentStore.seriesItems.first(where: { "\($0.series.seriesId)" == seriesId })?.series
    }

    /// The item's real 16:9 backdrop when its catalog record
    /// carries one (ContinueWatchingRow's exact rule — backdrops
    /// arrive with detail loads, so this is nil for a fresh
    /// catalog and the card uses its poster treatment instead).
    private func continueBackdropURL(for item: DBWatchHistory) -> URL? {
        let backdrop: String?
        switch item.type {
        case "vod": backdrop = continueVODRecord(for: item)?.backdropPath
        case "series": backdrop = continueSeriesRecord(for: item)?.backdropPath
        default: backdrop = nil
        }
        guard let raw = backdrop?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// Card meta line: a series with a resolved successor shows
    /// its "Next • S02 E05" label (ContinueSeriesRow's rule);
    /// otherwise "2026 • Drama" from the record's own fields
    /// (ContinueWatchingRow's rule). Nothing is derived or invented.
    private func continueMetaText(for item: DBWatchHistory) -> String? {
        if item.type == "series", let seriesId = item.seriesId,
           let label = continueNextLabels[seriesId] {
            return L("series.continue.next_format", label)
        }
        let releaseDate: String?
        let genre: String?
        switch item.type {
        case "vod":
            releaseDate = continueVODRecord(for: item)?.releaseDate
            genre = continueVODRecord(for: item)?.genre
        case "series":
            releaseDate = continueSeriesRecord(for: item)?.releaseDate
            genre = continueSeriesRecord(for: item)?.genre
        default:
            return nil
        }
        var parts: [String] = []
        if let year = DetailFormatting.year(from: releaseDate) { parts.append(year) }
        if let first = DetailFormatting.genreList(genre).first { parts.append(first) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
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
        // Build 80 (item 13, F2): a nil resume URL used to return
        // SILENTLY — the tap did nothing. Surface the standard
        // playback-failure alert instead.
        guard let url = historyURL(for: item) else { showHistoryPlayFailure = true; return }
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
    /// hero fallback to newest-with-artwork; hero rotation
    /// (finished titles excluded, daily exposure cap 3, not-yet-shown
    /// preferred); New since your last visit against the saved
    /// visit stamp. Build 66 (W3): ranked pools are rating-only
    /// (no unrated top-up), and every pool is parental-filtered
    /// before the cross-row dedupe runs.
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

        // Build 66 (W3, Home-6): the unrated top-up merge is
        // REMOVED. Both ranked pools (this view's pass and the
        // shared store's) only ever contain items with a real
        // normalized rating; nothing unrated is merged in to fill
        // the rail. When fewer than 3 rated items remain, the
        // popular rails' body gates (count >= 3) hide the rail —
        // an honest short rail is never padded with unrated picks.

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

        // Build 66 (W3): the Because-you-watched picks block and
        // the New-episodes derivation that used to run here are
        // deleted with their shelves (Critic kills) — no genre
        // inference over watch history remains on Home.

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

        // Build 66 (W3, item 17 — Home half of the parental-lock
        // leak fix): every Home pool drops items whose category is
        // blocked by ParentalControlStore — the SAME verdict the
        // detail pages enforce (MovieDetailView's guard) — so a
        // locked category's titles/posters never render on Home at
        // all. One filter per pool, here in the recompute pass,
        // never per-cell. Session-unlocked categories pass (the
        // store's verdict already accounts for the unlock).
        let parental = ParentalControlStore.shared
        featured = featured.filter { entry in
            switch entry {
            case .movie(let movie):
                return !parental.isBlocked(playlistId: playlist.id, type: "vod", categoryId: movie.categoryId)
            case .series(let series):
                return !parental.isBlocked(playlistId: playlist.id, type: "series", categoryId: series.categoryId)
            }
        }
        topRatedMovies = topRatedMovies.filter {
            !parental.isBlocked(playlistId: playlist.id, type: "vod", categoryId: $0.categoryId)
        }
        topRatedSeries = topRatedSeries.filter {
            !parental.isBlocked(playlistId: playlist.id, type: "series", categoryId: $0.categoryId)
        }
        newMovies = newMovies.filter {
            !parental.isBlocked(playlistId: playlist.id, type: "vod", categoryId: $0.categoryId)
        }
        newSeries = newSeries.filter {
            !parental.isBlocked(playlistId: playlist.id, type: "series", categoryId: $0.categoryId)
        }
        newSinceVisit = newSinceVisit.filter { entry in
            switch entry {
            case .movie(let movie):
                return !parental.isBlocked(playlistId: playlist.id, type: "vod", categoryId: movie.categoryId)
            case .series(let series):
                return !parental.isBlocked(playlistId: playlist.id, type: "series", categoryId: series.categoryId)
            }
        }

        // Build 61 fixer (F-3): the O1 cross-row dedupe runs LAST in
        // the assembly, over the final shelf arrays.
        applyCrossRowDedupe()
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
    /// Build 81 (item 5b): built through the lenient ArtworkURL
    /// parser — the strict URL(string:) dropped artwork whose path
    /// carries spaces or other unencoded characters.
    var artURL: URL? {
        switch self {
        case .movie(let movie):
            if let backdrop = movie.backdropPath?.trimmingCharacters(in: .whitespaces), !backdrop.isEmpty {
                return ArtworkURL.url(from: backdrop)
            }
            if let icon = movie.streamIcon?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
                return ArtworkURL.url(from: icon)
            }
            return nil
        case .series(let series):
            if let backdrop = series.backdropPath?.trimmingCharacters(in: .whitespaces), !backdrop.isEmpty {
                return ArtworkURL.url(from: backdrop)
            }
            if let cover = series.cover?.trimmingCharacters(in: .whitespaces), !cover.isEmpty {
                return ArtworkURL.url(from: cover)
            }
            return nil
        }
    }

    /// The item's POSTER art (2:3) — the wide hero's small
    /// thumbnail (build 80, item 6). Distinct from `artURL`, which
    /// prefers the backdrop.
    var posterURL: URL? {
        switch self {
        case .movie(let movie):
            if let icon = movie.streamIcon?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
                return ArtworkURL.url(from: icon)
            }
            return nil
        case .series(let series):
            if let cover = series.cover?.trimmingCharacters(in: .whitespaces), !cover.isEmpty {
                return ArtworkURL.url(from: cover)
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

// MARK: - Match result card (Build 77, Design A)

/// One Match Results card: both teams (logo + name exactly as the
/// payload provides them), the score between them, and the state
/// chip — a red LIVE pill carrying the live clock while the match
/// is in play, a quiet FT chip once it is finished. Scores, names
/// and state come from the payload only; nothing is invented.
/// Build 80 (item 5): a Home Match Results entry — the match plus
/// the sport/league identity its own detail page needs (MatchEvent
/// itself carries neither; the Home loader recovers the league from
/// the fetchSport outcome's index alignment with leaguePaths).
private struct HomeMatchEntry: Identifiable {
    let sport: MatchSport
    let leaguePath: String
    let match: MatchEvent
    var id: String { match.id }
}

private struct HomeMatchResultCard: View {
    let match: MatchEvent

    var body: some View {
        // Build 80 (item 8): the build-77/79 ONE-ROW layout (2 logos
        // + 2 names + score + chip in a single row) still truncated
        // full names at phone width at ANY legible font size — the
        // owner's screenshots show "Indianapolis Co...", "Memphis
        // Gri..." even at build 79's 12 pt. The card is now TWO
        // team rows: each team gets the row's full width (logo +
        // FULL name + that team's own score at the right end), and
        // the state chip (LIVE + live clock, or FT) sits on a slim
        // header line. Same Design A surface/radius/padding family.
        // Build 81 (item 2, owner): the two-row layout was right but
        // the card was too tall — a few cards filled the screen.
        // Compacted: tighter padding/spacing, 22pt logos, headline
        // scores, slimmer chip — same two full-name rows, same tap
        // target, roughly 5–6 cards per screenful instead of ~3.
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer(minLength: 0)
                stateChip
            }
            teamRow(match.home)
            teamRow(match.away)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .fill(AppTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        .stroke(AppTheme.cardBorderColor, lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }

    /// Build 80 (item 8): one team's row — logo, FULL name (the
    /// row's whole width at build 79's team-name font; the scale
    /// factor remains only as a safety net), and that team's own
    /// score at the right end. A side the payload has not scored
    /// yet reads "0", the same rule Home's score lines used.
    private func teamRow(_ side: MatchTeamSide) -> some View {
        HStack(spacing: 8) {
            CachedImage(
                url: side.logoURL,
                width: 22,
                height: 22,
                cornerRadius: 11,
                iconName: "shield"
            )
            Text(side.name ?? "")
                .font(AppTheme.fontTeamName)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(side.score ?? "0")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    @ViewBuilder
    private var stateChip: some View {
        if match.state == .live {
            HStack(spacing: 4) {
                Circle()
                    .fill(.white)
                    .frame(width: 6, height: 6)
                Text(L("matches.live"))
                if let clock = liveClockText {
                    Text(clock)
                }
            }
            .font(AppTheme.fontBadge)
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(AppTheme.live))
            .fixedSize()
        } else {
            Text(L("matches.final"))
                .font(AppTheme.fontBadge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(AppTheme.overlayFill(0.10)))
                .fixedSize()
        }
    }

    /// Live clock from payload fields only — the same rule as the
    /// Matches rows: soccer's displayClock reads "67'"; NFL/NBA
    /// pair a period with the game clock ("Q3 2:14", period 5+ =
    /// "OT"). Nil when the payload carries neither.
    private var liveClockText: String? {
        let clock = match.displayClock?.trimmingCharacters(in: .whitespaces)
        let hasClock = clock != nil && clock != "0.0" && !(clock?.isEmpty ?? true)
        guard let period = match.period, period > 0 else {
            return hasClock ? clock : nil
        }
        let periodLabel = period <= 4 ? "Q\(period)" : "OT"
        return hasClock ? "\(periodLabel) \(clock!)" : periodLabel
    }
}

// MARK: - Featured slide

private struct FeaturedSlide: View {
    let entry: FeaturedEntry
    let isCurrent: Bool
    let width: CGFloat
    /// Build 80 (item 6): the BACKDROP height (16:9 wide, computed
    /// by the carousel); the slide adds a 30 pt overflow below it
    /// for the overlapping poster thumbnail.
    let height: CGFloat
    let onPlay: () -> Void
    let onDetails: () -> Void

    /// B12: title-block entrance, driven by slide change.
    @State private var textShown = false

    var body: some View {
        // Build 80 (item 6, owner-picked Option 3): the WIDE
        // letterbox composition — full-bleed backdrop; a SMALL
        // poster thumbnail overlapping the backdrop's bottom-left
        // corner (hanging 30 pt into the slide's overflow zone);
        // the title beside the poster with the meta line under it;
        // Play + Details under the title; the carousel's page dots
        // overlay the right end of the button row. Poster-only
        // entries get a plain surface backdrop — the build-65
        // blurred-pillar / stretched-poster presentation is GONE.
        // B1: tapping the backdrop itself opens the detail page
        // (the buttons keep their own actions).
        ZStack(alignment: .bottomLeading) {
            backdropView

            HStack(alignment: .bottom, spacing: 12) {
                posterThumb
                    // The overlap: the thumb's layout bottom sits
                    // on the backdrop's bottom edge; the offset
                    // hangs it 30 pt into the overflow zone.
                    .offset(y: 30)

                textColumn
            }
            .padding(.horizontal, AppTheme.spacingScreenMargin)
            // Row bottom = 10 pt above the backdrop's bottom edge
            // (30 overflow + 10), so title/meta/buttons all live
            // over the backdrop's gradient in both themes.
            .padding(.bottom, 40)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width, height: height + 30)
        .contentShape(Rectangle())
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

    /// The wide backdrop: real 16:9 art full-bleed when the record
    /// carries it. Build 81 (item 4, owner): catalog records
    /// almost never carry a backdropPath (only detail-info fetches
    /// fill it), so build 80's gate left nearly EVERY slide on the
    /// plain-surface branch — the owner's hero was a black slab
    /// with only the small poster thumb showing. Now the poster
    /// artwork itself fills the wide frame when no backdrop
    /// exists — the same fallback the Movies/Series tab heroes
    /// already use (backdrop ?? streamIcon, aspect-fill) and the
    /// reason those heroes showed images while Home's did not.
    /// No blurred pillars (the owner rejected those); the bottom
    /// gradient keeps the overlaid text readable on any art.
    private var backdropView: some View {
        ZStack {
            if entry.hasBackdropArt {
                CachedImage(
                    url: entry.artURL,
                    width: width,
                    height: height,
                    cornerRadius: AppTheme.heroCornerRadius,
                    contentMode: .fill,
                    iconName: entry.iconName,
                    loadProfile: .high
                )
            } else if let poster = entry.posterURL {
                CachedImage(
                    url: poster,
                    width: width,
                    height: height,
                    cornerRadius: AppTheme.heroCornerRadius,
                    contentMode: .fill,
                    iconName: entry.iconName,
                    loadProfile: .high
                )
            } else {
                RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                    .fill(AppTheme.surface)
                    .frame(width: width, height: height)
            }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: AppTheme.background.opacity(0.92), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous))
        .onTapGesture { if isCurrent { onDetails() } }
    }

    /// The small poster thumbnail overlapping the backdrop's
    /// bottom-left corner (the item-6 signature element).
    private var posterThumb: some View {
        CachedImage(
            url: entry.posterURL,
            width: 54,
            height: 81,
            cornerRadius: 8,
            contentMode: .fill,
            iconName: entry.iconName,
            loadProfile: .standard
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
    }

    /// Title + meta + actions beside the poster. Round 16 (P4b)
    /// gating kept: only the CURRENT slide's block shows and takes
    /// hits, so a page transition never shows two control sets.
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
                .font(.title3.weight(.black))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.45), radius: 6, y: 2)

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
                    // Design-4 PLAY pill: solid accent, BLACK bold
                    // text (SPEC §2, as the gate's primary).
                    Label(L("home.play"), systemImage: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.onAccent)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(AppTheme.accent))
                        // ST2 (B7): the signature glow lives ONLY
                        // under primary/hero actions like this one.
                        .signatureGlow()
                }
                .buttonStyle(PressScaleButtonStyle())

                Button(action: onDetails) {
                    // The mockup's ghost action beside Play — a
                    // translucent capsule with a hairline border
                    // and the info glyph.
                    Label(L("home.details"), systemImage: "info.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(PressScaleButtonStyle())
            }
        }
        .opacity(isCurrent && textShown ? 1 : 0)
        .offset(y: textShown ? 0 : 12)
        .allowsHitTesting(isCurrent)
    }
}
