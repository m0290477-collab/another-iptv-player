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
    // Build 68 (W-E): Home no longer holds an EPGStore — the TV
    // Guide / EPG feature is removed from the app entirely, and
    // nothing on Home reads guide data anymore (see live rail).
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
    // Round 14/15 (B6/C6) extra shelves, all from real store/history data.
    // Build 66 (W3): the "Because you watched" rail and the Home
    // "New episodes" shelf are REMOVED (Critic kills — the rail was
    // the cut "For You" recommendation engine; the shelf was
    // cut-adjacent to the removed new-episode alerts). No state,
    // no shelf, no recompute for either remains.
    @State private var newSinceVisit: [FeaturedEntry] = []
    // Build 68 (W-E): the C6 "Tonight" shelf state is gone with
    // the EPG feature — it was built entirely from guide
    // programmes for a 19:00-23:00 window.
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
    // Build 69 (F2): Continue Watching's visible Play failure —
    // the same alert the detail paths use.
    @State private var showPlayFailure = false

    // Build 68 (W-E, Home Style 3 'Focus Rows'): the J3
    // reorderable-rows assembly is GONE from Home — the owner
    // picked a FIXED rail order (hero → sports → Continue
    // Watching → Live Channels → Movies → Series, nothing else),
    // so there is no Edit/Customize mode on this screen anymore.
    // Build 68 (W-G): the Customize Home store itself is now
    // deleted too (owner order: it "doesn't work properly,
    // pointless") — no live code anywhere reads a stored Home
    // row order.

    // Build 61 fixer (Z12, M-pack variant): the first LIVE
    // match found in the real MatchesService data for today, plus
    // its league name. Nil until a fetch finds one — and nil again
    // when none is live. Build 66 (W3): this no longer drives the
    // hero — it leads the "Live now" rail below the Cinematic
    // Hero. No placeholder data: this is only ever set from a
    // decoded ESPN payload.
    @State private var heroLiveMatch: MatchEvent?
    @State private var heroLiveMatchLeague: String?

    /// Build 64 (B1): per-sport highlight for the dashboard tiles —
    /// the sport's first LIVE match today, else its next upcoming
    /// match today. Real MatchesService data only; a sport with
    /// neither simply shows no score line on its tile.
    @State private var sportHighlights: [MatchSport: MatchEvent] = [:]

    /// Build 64 (B1): the Top 10 rail's selected genre chip (nil =
    /// All). Filters the rail's own top-rated list — no new data.
    @State private var top10Genre: String?

    private var liveHiddenIds: Set<String> { hiddenStore.hiddenIds(playlistId: playlist.id, type: "live") }
    private var vodHiddenIds: Set<String> { hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod") }
    private var seriesHiddenIds: Set<String> { hiddenStore.hiddenIds(playlistId: playlist.id, type: "series") }

    // MARK: - Live rail lead + Matches probes

    /// The Live Channels rail's lead channel — the first live
    /// channel in the catalog. Build 68 (W-E): this used to prefer
    /// the first channel with a programme on air right now (the
    /// EPG On-now set); with the TV Guide / EPG removed, the rail
    /// is catalog-ordered and carries no programme data at all.
    /// Nil only when the playlist carries no live channels at all.
    private var heroLiveStream: DBLiveStream? {
        contentStore.liveStreams.first?.stream
    }

    /// Z12 (fixer): one MatchesService pass for the live match —
    /// sports in MatchesView's tab order (soccer → NFL → NBA),
    /// leagues in payload order, first `.live` match wins; the
    /// pass stops at the first hit. Runs once per Home appearance
    /// and again when the app returns to the foreground
    /// (event-driven, no polling loop). When the user hid the
    /// Matches section (F6), the probe does not run and no match
    /// card is shown. Build 66 (W3): the result feeds the "Live
    /// now" rail, not the hero.
    private func loadHeroLiveMatch() async {
        guard !UserDefaults.standard.bool(forKey: "sections.hidden.matches") else {
            heroLiveMatch = nil
            heroLiveMatchLeague = nil
            return
        }
        let dateParameter = MatchesService.todayParameter()
        for sport in MatchSport.allCases {
            let outcomes = await MatchesService.fetchSport(sport, dateParameter: dateParameter)
            for outcome in outcomes {
                guard case .loaded(let result) = outcome,
                      let match = result.matches.first(where: { $0.state == .live })
                else { continue }
                heroLiveMatch = match
                heroLiveMatchLeague = result.leagueName
                return
            }
        }
        heroLiveMatch = nil
        heroLiveMatchLeague = nil
    }

    /// Build 64 (B1): one MatchesService pass per sport for the
    /// dashboard tiles — first LIVE match across the sport's
    /// leagues, else the earliest upcoming match today. Same
    /// event-driven cadence as the hero probe (appearance +
    /// foreground), no polling. Hidden Matches section (F6) →
    /// no probe, no score lines.
    private func loadSportHighlights() async {
        guard !UserDefaults.standard.bool(forKey: "sections.hidden.matches") else {
            sportHighlights = [:]
            return
        }
        let dateParameter = MatchesService.todayParameter()
        var highlights: [MatchSport: MatchEvent] = [:]
        for sport in MatchSport.allCases {
            let outcomes = await MatchesService.fetchSport(sport, dateParameter: dateParameter)
            var firstLive: MatchEvent?
            var firstUpcoming: MatchEvent?
            for outcome in outcomes {
                guard case .loaded(let result) = outcome else { continue }
                if firstLive == nil {
                    firstLive = result.matches.first(where: { $0.state == .live })
                }
                if firstUpcoming == nil {
                    firstUpcoming = result.matches
                        .filter { $0.state == .upcoming }
                        .min(by: { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) })
                }
            }
            if let highlight = firstLive ?? firstUpcoming {
                highlights[sport] = highlight
            }
        }
        sportHighlights = highlights
    }

    /// The tile score line for a sport's highlight: live →
    /// "Cavaliers 103 – 102 Grizzlies" (team nicknames = the last
    /// word of ESPN's full names; full names do not fit a tile),
    /// upcoming → "Arsenal – Chelsea • 20:00". Nil when the sport
    /// has no highlight.
    private func sportHighlightLine(for sport: MatchSport) -> (line: String, isLive: Bool)? {
        guard let match = sportHighlights[sport] else { return nil }
        let home = Self.teamShortName(match.home.name)
        let away = Self.teamShortName(match.away.name)
        switch match.state {
        case .live:
            return ("\(home) \(match.home.score ?? "0") – \(match.away.score ?? "0") \(away)", true)
        case .upcoming:
            if let date = match.startDate {
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                formatter.dateStyle = .none
                return ("\(home) – \(away) • \(formatter.string(from: date))", false)
            }
            return ("\(home) – \(away)", false)
        case .finished:
            return nil
        }
    }

    private static func teamShortName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "—" }
        return name.split(separator: " ").last.map(String.init) ?? name
    }

    // MARK: - Build 61 fixer (F-3): O1 cross-row dedupe
    //
    // SPEC §4.5-O1 mandates ONE shared seen-IDs set threaded through
    // the Home rows in O1 order — earlier rows win, later rows drop
    // what was already shown. B7 assembled the rows in O1 order but
    // never imposed the set, so an in-progress movie rendered in
    // Continue Watching AND again in Top Rated / New (critic F-3).
    //
    // The seen set is built from the EARLIER rows' own data sources,
    // replicated exactly:
    // - Continue Watching (row 1): the row's own display algorithm
    //   (one card per series, finished series dropped, cap 10) run
    //   over the same history request this view already loads.
    // - Continue Series (row 2): the latest history record per
    //   series — the row's source set (its in-progress series are
    //   already in row 1's set; finished-with-next series join here).
    // - Recent Channels (row 3): live history deduped by channel,
    //   resolved against the catalog, cap 15 — the row's algorithm.
    // The Live rail, the Movies/Series discovery shelves and
    // Recently Added then exclude these IDs (see
    // `applyCrossRowDedupe`, `recentlyAddedExclusionKeys`).
    // Priority follows the canonical O1 order. The hero and the
    // banners are NOT rows and are unaffected; the Favorites
    // shelf (user-curated) is not a catalog shelf and keeps its
    // own contents. Build 68 (W-E): the Focus Rows screen no
    // longer renders the Recent Channels / Recently Added rows,
    // but their ID sets still seed this dedupe exactly as
    // before, so the rendered rails dedupe identically.

    /// Row 1's display items, replicated from
    /// `ContinueWatchingRow.displayItems` over this view's identical
    /// history source (its limit-50 fetch covers the row's 30).
    private var continueWatchingDisplayItems: [DBWatchHistory] {
        var seenSeries = Set<String>()
        var result: [DBWatchHistory] = []
        for item in recentHistory.prefix(30) {
            if item.type == "series", let seriesId = item.seriesId, !seriesId.isEmpty {
                guard seenSeries.insert(seriesId).inserted else { continue }
                if item.durationMs > 0,
                   Double(item.lastTimeMs) / Double(item.durationMs) >= 0.98 {
                    continue
                }
            }
            result.append(item)
            if result.count >= 10 { break }
        }
        return result
    }

    /// Movie IDs already shown by the earlier O1 rows.
    private var homeSeenMovieIDs: Set<Int> {
        Set(continueWatchingDisplayItems.filter { $0.type == "vod" }
            .compactMap { Int($0.streamId) })
    }

    /// Series IDs already shown by rows 1–2 (Continue Watching's
    /// series cards + Continue Series' source set).
    private var homeSeenSeriesIDs: Set<Int> {
        var ids = Set(continueWatchingDisplayItems.filter { $0.type == "series" }
            .compactMap { $0.seriesId.flatMap(Int.init) ?? Int($0.streamId) })
        var seenSeries = Set<String>()
        for item in recentHistory where item.type == "series" {
            guard let seriesId = item.seriesId, !seriesId.isEmpty,
                  seenSeries.insert(seriesId).inserted else { continue }
            if let value = Int(seriesId) { ids.insert(value) }
        }
        return ids
    }

    /// Live channel IDs already shown by row 3 (Recent Channels).
    private var homeSeenLiveIDs: Set<Int> {
        var seen = Set<Int>()
        var result = Set<Int>()
        for item in recentHistory where item.type == "live" {
            guard let streamId = Int(item.streamId), seen.insert(streamId).inserted else { continue }
            guard contentStore.liveStreams.contains(where: { $0.stream.streamId == streamId }) else { continue }
            result.insert(streamId)
            if result.count >= 15 { break }
        }
        return result
    }

    /// Filters a discovery shelf pair (FeaturedEntry lists) against
    /// the running seen sets, adding what survives.
    private func dedupeEntries(_ entries: [FeaturedEntry],
                               seenMovies: inout Set<Int>,
                               seenSeries: inout Set<Int>) -> [FeaturedEntry] {
        entries.filter { entry in
            switch entry {
            case .movie(let movie): return seenMovies.insert(movie.streamId).inserted
            case .series(let series): return seenSeries.insert(series.seriesId).inserted
            }
        }
    }

    /// The cross-row dedupe pass over the discovery shelves, in
    /// their RENDERED order (`shelfOrder`): each shelf drops IDs the
    /// earlier O1 rows — or an earlier shelf in the same block —
    /// already showed, then contributes its own IDs to the set.
    private func applyCrossRowDedupe() {
        var seenMovies = homeSeenMovieIDs
        var seenSeries = homeSeenSeriesIDs
        for kind in shelfOrder {
            switch kind {
            case .topMovies:
                topRatedMovies = topRatedMovies.filter { seenMovies.insert($0.streamId).inserted }
            case .topSeries:
                topRatedSeries = topRatedSeries.filter { seenSeries.insert($0.seriesId).inserted }
            case .newMovies:
                newMovies = newMovies.filter { seenMovies.insert($0.streamId).inserted }
            case .newSeries:
                newSeries = newSeries.filter { seenSeries.insert($0.seriesId).inserted }
            case .newSinceVisit:
                newSinceVisit = dedupeEntries(newSinceVisit, seenMovies: &seenMovies, seenSeries: &seenSeries)
            case .favorites:
                // Not a catalog shelf: Favorites is the user's own
                // curated set.
                break
            }
        }
    }

    /// The Live Channels rail's channels after dedupe (the rail
    /// drops channels the earlier history rows already showed).
    /// Build 68 (W-E): this was the EPG On-now shelf's entry set;
    /// with the guide removed it is the rail's own catalog set
    /// (`liveRailChannels`) filtered by the same seen set.
    private var liveRailDedupedChannels: [DBLiveStream] {
        liveRailChannels.filter { !homeSeenLiveIDs.contains($0.streamId) }
    }

    /// Recently Added (row 6) exclusions, in the resolver's key
    /// space ("vod:<id>" / "series:<id>" / "live:<id>"): everything
    /// rows 1–5 show — Continue rows, the Live shelf and the
    /// (already deduped) discovery shelves.
    private var recentlyAddedExclusionKeys: Set<String> {
        var keys = Set<String>()
        for item in continueWatchingDisplayItems {
            switch item.type {
            case "vod":
                if let id = Int(item.streamId) { keys.insert("vod:\(id)") }
            case "series":
                if let id = item.seriesId.flatMap(Int.init) ?? Int(item.streamId) { keys.insert("series:\(id)") }
            case "live":
                if let id = Int(item.streamId) { keys.insert("live:\(id)") }
            default:
                break
            }
        }
        for id in homeSeenSeriesIDs { keys.insert("series:\(id)") }
        for id in homeSeenLiveIDs { keys.insert("live:\(id)") }
        for stream in liveRailDedupedChannels { keys.insert("live:\(stream.streamId)") }
        for movie in topRatedMovies + newMovies { keys.insert("vod:\(movie.streamId)") }
        for series in topRatedSeries + newSeries { keys.insert("series:\(series.seriesId)") }
        for entry in newSinceVisit {
            switch entry {
            case .movie(let movie): keys.insert("vod:\(movie.streamId)")
            case .series(let series): keys.insert("series:\(series.seriesId)")
            }
        }
        return keys
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
                    // Build 68 (W-E, Home Style 3 'Focus Rows'):
                    // GENEROUS fixed spacing between the six rails
                    // — the picked style is calm and uncluttered.
                    // The Display density preference still scales
                    // it (comfortable 26 + 10 = 36, compact 16 + 10
                    // = 26), so the preference keeps a real effect
                    // while every density reads generous.
                    VStack(alignment: .leading, spacing: HomeDensityPreference.current.shelfSpacing + 10) {
                        // Minimal top bar (Focus Rows): flame mark
                        // + SUPER X wordmark on one side, the search
                        // action on the other — the existing
                        // `homeTopBar`, whose remaining square
                        // buttons are all REAL destinations
                        // (Favorites / Refresh / Downloads /
                        // Notifications). No profile button is
                        // added: the app has no profile destination
                        // on Home (account lives in the Settings
                        // tab), and a dead profile icon would be
                        // fake UI.
                        homeTopBar
                            .padding(.horizontal, 16)

                        // Build 61 (S4): subscription-expiry banner —
                        // real ProviderExpiryStore data for the ACTIVE
                        // playlist only. A banner, not a rail: it
                        // keeps its place above the hero.
                        if let expiryBanner = expiryBannerModel {
                            expiryBannerView(expiryBanner)
                                .padding(.horizontal, 16)
                        }

                        // Build 61 (F7, B13): new-version banner —
                        // only when the iTunes lookup found a newer
                        // store version that was not dismissed.
                        // A banner, not a rail: above the hero.
                        if let update = updateService.availableUpdate {
                            updateBannerView(update)
                                .padding(.horizontal, 16)
                        }

                        // Build 61 (B8, R4): what's-new banner — one
                        // per refresh batch, real counts, never
                        // stacked; a BANNER (not a rail), so it
                        // stays above the hero exactly as before.
                        WhatsNewBanner(playlist: playlist)
                            .padding(.horizontal, 16)

                        // FOCUS ROWS — the owner's picked order,
                        // fixed, with NOTHING else between or after
                        // the rails (no category tiles, no Top 10 /
                        // Trending strip, no Favorites / Tonight /
                        // New-since-visit / Recently Added /
                        // Recent Channels rows, and no recommended
                        // or "Because you watched" rail — the last
                        // two stay CUT, as in build 66).

                        // Rail 1 — Hero (medium height; see
                        // `heroHeight`). Same featured-carousel
                        // data and selection logic as build 66.
                        if !featured.isEmpty {
                            featuredCarousel
                        } else if !contentStore.streamsLoaded {
                            // B6: skeleton placeholders instead of the
                            // bare spinner while the catalog lands.
                            SkeletonShelf()
                        }

                        // Rail 2 — Live Sports score tiles: the
                        // Matches sports strip that already lived
                        // on Home (real ESPN data via
                        // `sportHighlights` / MatchesService), with
                        // the same F6 Matches gate as before.
                        if !UserDefaults.standard.bool(forKey: "sections.hidden.matches") {
                            VStack(alignment: .leading, spacing: 12) {
                                CinematicSectionHeader(title: L("home.sports_dashboard")) {
                                    MatchesView()
                                }
                                sportTileRow
                            }
                        }

                        // Rail 3 — Continue Watching: the existing
                        // Continue Watching row, with Continue
                        // Series directly under it (both rows keep
                        // their own history data sources, headers,
                        // destinations and `presentHistoryItem`
                        // routing, exactly as the old O1 rows 1–2).
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
                        ContinueSeriesRow(playlist: playlist) { item in
                            presentHistoryItem(item)
                        }

                        // Rail 4 — Live Channels: the existing
                        // live-now rail (`liveNowRail`) — the live
                        // match card first when a match is live,
                        // then the catalog live channels, parental
                        // filtering and first-channel preview
                        // unchanged. Renders nothing when nothing
                        // is live.
                        liveNowRail

                        // Rail 5 — Movies: the existing Movies
                        // shelves (Top 10 Today, then New Movies),
                        // F6-gated, deduped and parental-filtered
                        // by the unchanged recompute pass.
                        focusMoviesRails

                        // Rail 6 — Series: the existing Series
                        // shelves (Top Rated Series, then New
                        // Series), same gates and data as Movies.
                        focusSeriesRails

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
        .alert(L("offline.title"), isPresented: $showOfflineAlert) {
            Button(L("common.try_again")) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { runHomeRefresh() }
            }
            Button(L("common.cancel"), role: .cancel) { }
        } message: {
            Text(L("offline.message"))
        }
        // Build 69 (F2): the play-failure alert (existing
        // playback error copy — no new strings).
        .alert(L("playback.error.failed_to_start"), isPresented: $showPlayFailure) {
            Button(L("common.ok")) { showPlayFailure = false }
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
        // Build 61 fixer (Z12): the live-match hero probe, once per
        // Home appearance for this playlist.
        // Build 64 (B1): the sport-tile highlights load alongside.
        .task(id: playlist.id) {
            await loadHeroLiveMatch()
            await loadSportHighlights()
        }
        // Z12: re-probe when the app returns to the foreground, so a
        // match that kicked off while the app was backgrounded can
        // take the hero (and a finished one releases it).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await loadHeroLiveMatch()
                    await loadSportHighlights()
                }
            }
        }
        // Build 68 (W-E): the C6 Tonight task is gone — it
        // rebuilt an EPG-programme shelf on every guide snapshot
        // change, and the guide feature is removed entirely.
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

    /// Build 68 (W-E, Home Style 3 'Focus Rows'): the hero is
    /// MEDIUM height — the picked panel's single wide banner, not
    /// build 65/66's tall Cinematic Hero (which filled roughly the
    /// top half of the screen at `cardWidth * 1.08`, capped at 52%
    /// of the screen height). Portrait is now ~0.68× the card
    /// width, capped at 36% of the screen height (≈243 pt on a
    /// 390×844 phone, down from ≈387 pt); the slide's title, meta
    /// and Play/Details block still fit inside it. Landscape keeps
    /// the 16:9 cinematic frame (the height-capped `cardWidth`
    /// already bounds it there). Same carousel, same slides, same
    /// featured-selection logic — only the frame height changed.
    private var heroHeight: CGFloat {
        let bounds = UIScreen.main.bounds
        if bounds.width > bounds.height {
            return cardWidth * 9 / 16
        }
        return min(cardWidth * 0.68, bounds.height * 0.36)
    }

    private var featuredCarousel: some View {
        VStack(spacing: 10) {
            TabView(selection: $featuredIndex) {
                ForEach(featured.indices, id: \.self) { index in
                    FeaturedSlide(
                        entry: featured[index],
                        isCurrent: index == featuredIndex,
                        width: cardWidth,
                        height: heroHeight,
                        onPlay: { playFeatured(featured[index]) },
                        onDetails: { showFeaturedDetails(featured[index]) }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: cardWidth, height: heroHeight)
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

    // MARK: - Live Channels rail (Build 66 W3; Build 68 W-E)

    /// The rail's live channels: the catalog's live channels in
    /// catalog order (the lead channel first), deduped, capped at
    /// 8. Parental-blocked live categories are excluded here too
    /// (item 17): a locked channel must not surface in the rail
    /// even though the player path also gates it. Session-unlocked
    /// categories pass, per the store verdict.
    ///
    /// Build 68 (W-E, EPG removal): this set used to be the EPG
    /// On-now set — channels with a programme on air, in guide
    /// order, each card carrying its current programme title.
    /// The TV Guide / EPG is removed from the app entirely, so
    /// the rail is now catalog-ordered and its cards show logo +
    /// name + LIVE badge only — no now/next programme lines.
    private var liveRailChannels: [DBLiveStream] {
        var channels: [DBLiveStream] = []
        var seen = Set<Int>()
        func appendIfAllowed(_ stream: DBLiveStream) {
            guard seen.insert(stream.streamId).inserted,
                  !ParentalControlStore.shared.isBlocked(playlistId: playlist.id, type: "live", categoryId: stream.categoryId)
            else { return }
            channels.append(stream)
        }
        if let hero = heroLiveStream { appendIfAllowed(hero) }
        for item in contentStore.liveStreams { appendIfAllowed(item.stream) }
        return Array(channels.prefix(8))
    }

    /// Build 68 (W-E): Focus Rows rail 4 — the "Live now" rail
    /// from build 66 (W3), kept with its tap behaviour unchanged:
    /// the live match card first when a match is live (tap →
    /// MatchesView; ESPN data, not guide data), then the live
    /// channels (tap → the live player via the same Home path).
    /// Renders nothing when nothing is live. The cards carry NO
    /// guide-derived text anymore (see `liveRailChannels`).
    @ViewBuilder
    private var liveNowRail: some View {
        let channels = liveRailChannels
        if heroLiveMatch != nil || !channels.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                CinematicSectionHeader(title: L("home.live_now")) {
                    AllLiveView(playlist: playlist)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        if let heroMatch = heroLiveMatch {
                            NavigationLink {
                                MatchesView()
                            } label: {
                                LiveMatchHeroCard(match: heroMatch, leagueName: heroLiveMatchLeague)
                                    .frame(width: 300)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(channels, id: \.streamId) { stream in
                            LiveHeroCard(
                                stream: stream,
                                // No `nowProgramTitle`: the card's
                                // programme line was EPG-derived and
                                // is dropped with the guide removal;
                                // the card shows logo + name + LIVE.
                                previewURL: PlaybackURLBuilder(playlist: playlist).liveURL(streamId: stream.streamId),
                                // Home-8 safety: the live preview
                                // decodes ONLY while no player is
                                // presented — the same gate the
                                // carousel timer already uses. Only
                                // the rail's FIRST channel previews;
                                // the rest show their channel art, so
                                // the rail never runs parallel decodes.
                                previewActive: isVisible && scenePhase == .active
                                    && playerOverlay.presentation == nil
                                    && stream.streamId == channels.first?.streamId,
                                userAgent: playlist.trimmedUserAgent
                            ) {
                                presentLiveSelectionFromHome(stream)
                            }
                            .frame(width: 300)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollClipDisabled()
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

    // MARK: - Sports tiles (Focus Rows rail 2)

    private var sportTileRow: some View {
        HStack(alignment: .top, spacing: 12) {
            HomeSportTile(
                title: L("matches.tab.soccer"),
                subtitle: L("matches.subtitle"),
                tint: AppTheme.accent,
                iconName: "soccerball",
                sport: .soccer,
                liveLine: sportHighlightLine(for: .soccer)?.line,
                isLive: sportHighlightLine(for: .soccer)?.isLive ?? false
            )
            HomeSportTile(
                title: L("matches.tab.nfl"),
                subtitle: L("matches.subtitle"),
                tint: AppTheme.live,
                iconName: "football.fill",
                sport: .nfl,
                liveLine: sportHighlightLine(for: .nfl)?.line,
                isLive: sportHighlightLine(for: .nfl)?.isLive ?? false
            )
            HomeSportTile(
                title: L("matches.tab.nba"),
                subtitle: L("matches.subtitle"),
                tint: SectionTheme.series,
                iconName: "basketball.fill",
                sport: .nba,
                liveLine: sportHighlightLine(for: .nba)?.line,
                isLive: sportHighlightLine(for: .nba)?.isLive ?? false
            )
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shelves

    /// Build 64 (B1): the Top 10 rail's genre chips — the distinct
    /// genres of the rail's own top-rated list (capped for the
    /// chip row), in the records' own wording.
    private var top10Genres: [String] {
        var seen = Set<String>()
        var genres: [String] = []
        for movie in topRatedMovies {
            for genre in DetailFormatting.genreList(movie.genre) where seen.insert(genre).inserted {
                genres.append(genre)
            }
        }
        return Array(genres.prefix(6))
    }

    /// The Top 10 rail's displayed list: the full top-rated list,
    /// or its members carrying the selected genre. Used as the
    /// detail queue — order only, no ranks derived from it.
    private var top10Displayed: [DBVODStream] {
        guard let genre = top10Genre else { return topRatedMovies }
        return topRatedMovies.filter { DetailFormatting.genreList($0.genre).contains(genre) }
    }

    /// Build 66 (W3, Home-6): the rail's rendered rows WITH their
    /// ORIGINAL ranks — rank is the position in the UNFILTERED
    /// top-10 list, computed before any genre filtering, so a
    /// genre-filtered #4 still renders as 4, never renumbered to 1.
    private var top10Ranked: [(rank: Int, movie: DBVODStream)] {
        let ranked = topRatedMovies.enumerated().map { (rank: $0.offset + 1, movie: $0.element) }
        guard let genre = top10Genre else { return ranked }
        return ranked.filter { DetailFormatting.genreList($0.movie.genre).contains(genre) }
    }

    private var topRatedMoviesShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Build 64 (B1, Home style 2): this shelf IS the
            // dashboard's Top 10 rail (the list is capped at 10 by
            // the recompute) — retitled, with the mockup's genre
            // chips filtering it.
            CinematicSectionHeader(title: L("home.top10_today")) {
                AllVODView(playlist: playlist)
            }
            if top10Genres.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        PillChipButton(title: L("search.all"), isSelected: top10Genre == nil) {
                            top10Genre = nil
                        }
                        ForEach(top10Genres, id: \.self) { genre in
                            PillChipButton(title: genre, isSelected: top10Genre == genre) {
                                top10Genre = genre
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollClipDisabled()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(top10Ranked.indices, id: \.self) { index in
                        let ranked = top10Ranked[index]
                        NavigationLink {
                            MovieDetailView(playlist: playlist, movie: ranked.movie, queue: top10Displayed)
                        } label: {
                            RankedPosterCard(
                                rank: ranked.rank,
                                imageURL: moviePosterURL(ranked.movie),
                                title: ranked.movie.name,
                                ratingText: ContentRating.normalizedDisplayText(rating: ranked.movie.rating, rating5Based: ranked.movie.rating5Based),
                                metaText: cardMetaLine(year: DetailFormatting.year(from: ranked.movie.releaseDate), genre: ranked.movie.genre),
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                iconName: "film"
                            )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .shelfEntrance(index: index)
                        .contextMenu {
                            Button {
                                toggleFavorite(streamId: ranked.movie.streamId, type: "vod",
                                               currentlyFavorite: isFavoriteMovie(ranked.movie))
                            } label: {
                                Label(isFavoriteMovie(ranked.movie) ? L("favorites.remove") : L("favorites.add"), systemImage: "star")
                            }
                            if let categoryId = ranked.movie.categoryId {
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
        .onChange(of: top10Genres) { _, genres in
            // A recompute can retire the selected genre — fall
            // back to All instead of an empty rail.
            if let genre = top10Genre, !genres.contains(genre) {
                top10Genre = nil
            }
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
        case favorites, newSinceVisit
    }

    /// C6: shelf order varies by time-of-day bucket DERIVED FROM
    /// WATCH-HISTORY TIMESTAMPS: the modal bucket of the user's own
    /// `lastWatchedAt` hours (morning 5-11, afternoon 11-17, evening
    /// 17-23, night 23-5). No history -> the current hour's bucket.
    /// Build 68 (W-E): this order no longer drives RENDERING —
    /// Focus Rows renders the Movies rail then the Series rail in
    /// a fixed order (`focusMoviesRails` / `focusSeriesRails`).
    /// It survives as the cross-row dedupe's priority order only
    /// (`applyCrossRowDedupe`), unchanged, so dedupe outcomes are
    /// identical to build 66. (The .tonight case is gone with the
    /// EPG removal — its shelf was guide programmes.)
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
        let discovery: [HomeShelfKind] = [.topMovies, .topSeries, .newMovies, .newSeries, .favorites, .newSinceVisit]
        let veteran: [HomeShelfKind] = [.favorites, .topMovies, .topSeries, .newMovies, .newSeries, .newSinceVisit]
        let evening: [HomeShelfKind] = [.favorites, .topMovies, .newSeries, .topSeries, .newMovies, .newSinceVisit]
        let morning: [HomeShelfKind] = [.newMovies, .newSeries, .newSinceVisit, .topMovies, .topSeries, .favorites]
        if !isVeteranHome { return discovery }
        switch bucket {
        case 0: return morning
        case 2: return evening
        default: return veteran
        }
    }

    // MARK: - Focus Rows rails 5-6 (Build 68, W-E)

    /// Rail 5 — Movies: the existing Movies shelves in fixed
    /// order (Top 10 Today, then New Movies), with the SAME F6
    /// visibility gates and emptiness rules the old shelf dispatch
    /// applied. Each shelf keeps its own header, destination,
    /// cards and context menus.
    @ViewBuilder
    private var focusMoviesRails: some View {
        if sectionVisibility.isVisible(.movies) {
            VStack(alignment: .leading, spacing: 26) {
                if topRatedMovies.count >= 3 { topRatedMoviesShelf }
                if !newMovies.isEmpty { newMoviesShelf }
            }
        }
    }

    /// Rail 6 — Series: the existing Series shelves in fixed
    /// order (Top Rated Series, then New Series), same F6 gates
    /// and emptiness rules as the old dispatch.
    @ViewBuilder
    private var focusSeriesRails: some View {
        if sectionVisibility.isVisible(.series) {
            VStack(alignment: .leading, spacing: 26) {
                if topRatedSeries.count >= 3 { topRatedSeriesShelf }
                if !newSeries.isEmpty { newSeriesShelf }
            }
        }
    }

    private func presentLiveSelectionFromHome(_ stream: DBLiveStream) {
        playerOverlay.present(playlistId: playlist.id) {
            LivePlayerShell(playlist: playlist, queue: homeLiveQueue, sections: homeLiveSections,
                            initialStream: stream, initialHistory: nil, subtitle: nil)
        }
    }

    // Build 68 (W-E): the Tonight shelf (C6, EPG programmes),
    // the New-since-visit shelf and the Favorites shelf that used
    // to render in the old discovery block are NOT part of Focus
    // Rows (rails are hero / sports / Continue / Live / Movies /
    // Series only), so their renderers are removed. Their DATA
    // still exists where other logic needs it: favorites feed the
    // top-bar Favorites entry and the shelves' context menus, and
    // `newSinceVisit` still participates in the cross-row dedupe.

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
        // Build 69 (F2): was a silent return — a Continue
        // Watching tap whose URL failed to build looked dead.
        // Surface the plain failure instead.
        guard let url = historyURL(for: item) else {
            showPlayFailure = true
            return
        }
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
            // Build 69 (F2): the history record's REAL container
            // extension — nil here forced .mp4, so non-mp4 movies
            // resumed against a wrong-extension URL.
            return builder.movieURL(streamId: Int(item.streamId) ?? 0, containerExtension: item.containerExtension)
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
        // rail gates in the Focus rails (count >= 3) hide it —
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

// MARK: - Live match hero (Z12, fixer)

/// The M-pack hero variant: a match that is LIVE right now, from
/// the real MatchesService payload only — league name (when the
/// payload carries one), both teams' logos/names/scores exactly as
/// provided, the LIVE badge and the live clock. M-pack discipline
/// holds: scores and state only, nothing invented; the whole card
/// is the tap target into MatchesView (wired by the caller).
private struct LiveMatchHeroCard: View {
    let match: MatchEvent
    let leagueName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 8, height: 8)
                Text(L("matches.live"))
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(AppTheme.accent)
                if let clock = liveClockText {
                    Text(clock)
                        .font(AppTheme.fontMetadata.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .monospacedDigit()
                }
                Spacer()
                if let leagueName, !leagueName.isEmpty {
                    Text(leagueName)
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(.secondary)
            }

            teamRow(match.home)
            teamRow(match.away)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .fill(AppTheme.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        .stroke(AppTheme.cardBorderColor, lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }

    private func teamRow(_ side: MatchTeamSide) -> some View {
        HStack(spacing: 12) {
            CachedImage(
                url: side.logoURL,
                width: 34,
                height: 34,
                cornerRadius: 17,
                iconName: "shield"
            )
            // Team name EXACTLY as the payload provides it (M6).
            Text(side.name ?? "")
                .font(AppTheme.fontCardTitle)
                .lineLimit(1)
            Spacer()
            if let score = side.score {
                Text(score)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
            }
        }
    }

    /// Live clock from payload fields only — the same rule as
    /// MatchesView's rows: soccer's displayClock reads "67'";
    /// NFL/NBA pair a period with the game clock ("Q3 2:14",
    /// period 5+ = "OT"). Nil when the payload carries neither.
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
    /// Build 65 (Cinematic Hero): the slide's frame height — tall
    /// in portrait, 16:9 in landscape (computed by the carousel).
    let height: CGFloat
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
                    height: height,
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
                height: height,
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

            // Build 65 (Cinematic Hero): the mockup carries NO
            // badge over the art — the backdrop, the big title and
            // the actions are the whole treatment.

            VStack(alignment: .leading, spacing: 8) {
                // Build 65 (Home v2 style 1): the hero title is BIG
                // and WHITE over the art (the build-61 accent
                // headline gives way to the cinematic treatment);
                // the accent lives in the Play pill.
                Text(entry.title)
                    .font(.largeTitle.weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(2)

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
                            // ST2 (B7): the signature glow lives ONLY
                            // under primary/hero actions like this one.
                            .signatureGlow()
                    }
                    .buttonStyle(PressScaleButtonStyle())

                    Button(action: onDetails) {
                        // Build 65: the mockup's ghost action beside
                        // Play — a translucent capsule with a hairline
                        // border (its "+ Watchlist"; ours opens the
                        // same detail page as before).
                        Text(L("home.details"))
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
            .padding(.horizontal, AppTheme.spacingScreenMargin)
            .padding(.bottom, 18)
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
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous))
        // X4 (B7): subtle shine across the hero art while pressed.
        .posterShine()
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


/// Build 63 (owner, item 7): a sport shortcut tile — tinted icon
/// disc + bold label + secondary sublabel on the shared surface
/// card (the visual language of the old category tiles, which
/// Build 68 W-E removed with the Focus Rows rebuild), as a
/// NavigationLink — each sport lands on its own Matches tab.
private struct HomeSportTile: View {
    let title: String
    let subtitle: String
    let tint: Color
    let iconName: String
    let sport: MatchSport
    /// Build 64 (B1): the sport's live score / next fixture line
    /// (real MatchesService data), nil when the sport has neither
    /// today — the tile then shows only its subtitle, as in 63.
    var liveLine: String? = nil
    var isLive: Bool = false

    var body: some View {
        NavigationLink {
            MatchesView(initialSport: sport)
        } label: {
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
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let liveLine {
                    HStack(spacing: 4) {
                        if isLive {
                            Circle()
                                .fill(AppTheme.live)
                                .frame(width: 6, height: 6)
                        }
                        Text(liveLine)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isLive ? AppTheme.live : .secondary)
                            .lineLimit(1)
                    }
                }
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
