import SwiftUI
import Foundation
import Combine
import GRDB
import GRDBQuery

/// Combined recompute trigger for `SeriesView` (round 8, audit A2 — the
/// `HomeRecomputeToken` pattern): one Equatable token over both inputs
/// `recomputeFilter()` reads, so the two passes run once per real change
/// instead of once per `.task(id:)` modifier.
private struct SeriesRecomputeToken: Equatable {
    let loaded: Bool
    let hidden: Set<String>
    /// Round 20 (R20-5): the series row count, so the pass re-runs
    /// the moment the series fetch publishes (the store publishes
    /// live → vod → series progressively) instead of waiting for
    /// `streamsLoaded`, which only flips after the LAST type lands.
    var seriesCount: Int = 0
    var rankingsStamp: String = ""
    /// Saved category drag order (CategoryOrderStore): a reorder in
    /// the picker must re-run the pass that sorts the shelves.
    var order: [String] = []
}

/// Round 14 (B8): per-series in-progress state for the Series tab
/// shelves, derived from REAL watch history in one DB pass — the
/// latest episode's progress fraction and its season/episode numbers
/// for the "S# • E#" position line.
struct SeriesProgressInfo: Equatable {
    let progress: Double
    let seasonNumber: Int?
    let episodeNumber: Int?

    var positionText: String? {
        guard let episodeNumber else { return nil }
        if let seasonNumber {
            return "S\(seasonNumber) • E\(episodeNumber)"
        }
        return "E\(episodeNumber)"
    }
}

struct SeriesView: View {
    let playlist: Playlist
    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @ObservedObject private var orderStore = CategoryOrderStore.shared
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    @State private var pendingSeriesDetail: DBSeries?

    private var pickerEntries: [CategoryPickerSheet.Entry] {
        // Build 61 (B8, Z6): empty categories are not jump targets
        // unless the user shows empty categories.
        let visible = EmptyCategoryVisibility.visible(contentStore.seriesCategories) {
            contentStore.seriesItemsByCategoryId[$0.id]?.count ?? 0
        }
        return orderStore.applyOrder(visible, playlistId: playlist.id, type: "series") { $0.id }.map { cat in
            CategoryPickerSheet.Entry(
                id: cat.id,
                name: cat.name,
                count: contentStore.seriesItemsByCategoryId[cat.id]?.count ?? 0
            )
        }
    }

    // Round 5: the native `.searchable` is GONE (same treatment Live got
    // in round 3 and Movies got this round) — the tab's ONE search entry
    // is the HomeSearchBar in the header, opening the global SearchView.
    // Build 80 (item 4) SUPERSEDES this: a REAL CatalogSearchField in
    // the header now filters this tab in place.

    // Round 5: unified content pattern — filter chips.
    // Round 8 (D-4/D-5): the Favorites and History chips were removed —
    // they duplicated the nav-bar star's FavoritesView and the Continue
    // Watching row, now the ONE entry for each. Remaining chips are
    // pure orderings: All (shelves) and Newest (the catalog's
    // `lastModified` ordering, extended cut). Their grids/queries went.
    @State private var selectedChip: ContentChip = .all
    /// Build 65 (inside-sections): category chip selection — nil
    /// shows the shelf stack; a category id swaps it for that
    /// category's poster grid.
    @State private var selectedCategoryId: String? = nil
    @State private var categoryVisibleCount = 90

    @State private var displayCategories: [DBCategory] = []
    @State private var displayItemsByCategory: [String: [SeriesWithCategory]] = [:]
    // Build 80 (item 12): deduped SHELF presentation (see VODView).
    @State private var shelfCategories: [DBCategory] = []
    @State private var shelfItemsByCategory: [String: [SeriesWithCategory]] = [:]
    @State private var recentlyAddedSeries: [DBSeries] = []
    @State private var newestSeries: [DBSeries] = []
    @State private var topRatedSeries: [DBSeries] = []
    /// B8: seriesId (string key) → in-progress state for shelf cards.
    @State private var progressBySeriesId: [String: SeriesProgressInfo] = [:]
    /// Build 61 (B8, C5): per-series watched % over loaded episodes.
    @State private var watchedPercentBySeriesId: [String: Int] = [:]
    /// Build 61 (B8, C2): the series Watch Later list, resolved
    /// against the loaded catalog in watchlist order.
    @ObservedObject private var watchlistStore = WatchlistStore.shared

    private var watchlistSeries: [DBSeries] {
        let ids = watchlistStore.seriesIds(playlistId: playlist.id)
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        var found: [Int: DBSeries] = [:]
        for item in contentStore.seriesItems where wanted.contains(item.series.seriesId) {
            found[item.series.seriesId] = item.series
        }
        return ids.compactMap { found[$0] }
    }
    /// Full `lastModified`-desc ordering for the paginated Newest
    /// grid (the shared ranking is capped at 60).
    @State private var newestAll: [DBSeries] = []
    @State private var newestVisibleCount = 90
    private static let newestPageSize = 90
    // Build 88 (Part 2-B): the round-15 shelf replay token is
    // gone with the shelves it fed — the shared CatalogShelfRow
    // owns its entrance animation now.

    init(playlist: Playlist) {
        self.playlist = playlist
    }

    @State private var showingCategoryPicker = false
    @State private var pendingScrollTarget: String? = nil
    // Build 61 fixer (O9): scroll restoration for the Series shelf
    // list — the category shelf at the top anchor, persisted per
    // playlist via ScrollAnchorStore. Applies to the All (shelves)
    // chip only; the Newest grid keeps its own behaviour.
    @State private var scrollAnchorID: String? = nil
    // Build 80 (item 4): REAL in-tab search state — same fix as the
    // Movies tab (the old bar was a fake field opening a sheet; the
    // tab itself filtered nothing).
    @State private var tabSearchText = ""
    @State private var tabDebouncedQuery = ""
    @State private var tabSearchResults: [SeriesWithCategory] = []
    @State private var tabSearchVisibleCount = 90

    var body: some View {
        Group {
            if displayCategories.isEmpty {
                // Round 20 (R20-5): the Home tab's round-12 guard,
                // which this tab never got. Phase 1 of the catalog
                // load sets isLoading=false with categories only,
                // while streamsLoaded stays false until ALL of phase
                // 2 lands — the old condition fell through to
                // "No category found" for that whole window on every
                // cold open (owner recording, build 54). Until the
                // streams have actually loaded (and there is no error
                // to show instead), an empty display set means
                // LOADING, not empty.
                if contentStore.isLoading || playlist.id != contentStore.activePlaylistId
                    || (!contentStore.streamsLoaded && contentStore.loadError == nil) {
                    VStack(spacing: 16) {
                        BrandedLoader()
                        Text(contentStore.loadingMessage ?? L("series.empty.preparing"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError = contentStore.loadError {
                    CatalogLoadErrorView(message: loadError) {
                        Task { await contentStore.loadPlaylist(playlist) }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "play.tv")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(L("live.empty.no_category"))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // Build 81 (item 7): the header (search field + count
                // + chips) is a FIXED block ABOVE the scroll view —
                // the same placement as every working CatalogSearchField
                // in the app (Favorites, Search, Live grid header).
                // Build 80 put the real field as the first element
                // INSIDE this ScrollView (inside the ScrollViewReader,
                // under the bound .scrollPosition(id:) anchor, with
                // restoreScrollAnchor + the recompute pass rebuilding
                // the scroll content — header included — on every
                // store publish): on the owner's device the field
                // never took focus at all ("مايستجيب" — no keyboard,
                // no focus ring). Out here its identity is never
                // churned by the scroll container, and a tap focuses
                // it exactly like the proven surfaces.
                VStack(spacing: 0) {
                    tabHeader

                    ScrollViewReader { proxy in
                    ScrollView {
                        // The chips swap the scroll content — All keeps
                        // the shelves; Newest renders its grid.
                        // Build 80 (item 4): an active in-tab search
                        // replaces the chip content entirely; clearing
                        // the field restores it exactly.
                        if !tabDebouncedQuery.isEmpty {
                            tabSearchResultsGrid
                        } else {
                        switch selectedChip {
                        case .all:
                            // Build 65 (inside-sections design):
                            // the Series tab gains the featured
                            // hero it never had (the Movies tab's
                            // B7 hero is the model), then the
                            // category chips; a chip selection
                            // swaps the shelves for that category's
                            // poster grid.
                            if let featured = featuredSeries {
                                SeriesFeaturedHero(playlist: playlist, series: featured) {
                                    pendingSeriesDetail = featured
                                } onPlay: {
                                    presentFeaturedSeriesPlayer(featured)
                                }
                            }

                            if displayCategories.count > 1 {
                                SectionCategoryChips(
                                    categories: displayCategories,
                                    selectedCategoryId: $selectedCategoryId
                                )
                                .padding(.bottom, 4)
                            }

                            if let selectedCategoryId,
                               let category = displayCategories.first(where: { $0.id == selectedCategoryId }) {
                                categoryGrid(for: category)
                            } else {
                            ContinueWatchingRow(
                                playlist: playlist,
                                typeFilter: "series",
                                destination: {
                                    WatchHistoryListView(playlist: playlist, typeFilter: "series") { item in
                                        presentSeriesHistoryItem(item)
                                    }
                                },
                                onPlay: { item in
                                    presentSeriesHistoryItem(item)
                                }
                            )

                            // Build 88 (Part 2-B): the tab's shelves
                            // are the SHARED catalog components
                            // (Views/CatalogComponents.swift) — the
                            // same PosterCardView / CatalogShelfRow
                            // the Movies tab renders. Data inputs
                            // (rankings, dedupe, progress) are the
                            // unchanged build-87 state above; only
                            // the rendering moved.
                            if topRatedSeries.count >= 3 {
                                CatalogShelfRow(
                                    title: L("home.popular_series"),
                                    items: topRatedSeries,
                                    rowHeight: posterMetrics.shelfRowTotalHeight + 18,
                                    destination: { AllSeriesView(playlist: playlist) },
                                    cell: { series in
                                        NavigationLink {
                                            SeriesDetailView(playlist: playlist, series: series)
                                        } label: {
                                            // Ranked shelf: the ranked
                                            // card (the mockup's big
                                            // numerals), as before —
                                            // rank, real season/episode
                                            // counts, normalized rating.
                                            RankedPosterCard(
                                                rank: (topRatedSeries.firstIndex(of: series) ?? 0) + 1,
                                                imageURL: series.cover.flatMap { ArtworkURL.url(from: $0) },
                                                title: series.name,
                                                ratingText: ContentRating.normalizedDisplayText(
                                                    rating: series.rating,
                                                    rating5Based: series.rating5Based
                                                ),
                                                metaText: contentStore.seriesSeasonEpisodeCounts[series.seriesId].map {
                                                    "\(L("series.seasons_count_format", $0.seasons)) • \(L("series.episode_count_format", $0.episodes))"
                                                },
                                                posterWidth: posterMetrics.shelfPosterWidth,
                                                posterHeight: posterMetrics.shelfPosterHeight,
                                                iconName: "play.tv"
                                            )
                                            .tint(SectionTheme.series)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                )
                            }

                            if !recentlyAddedSeries.isEmpty {
                                CatalogShelfRow(
                                    title: L("recently_added.title"),
                                    items: recentlyAddedSeries,
                                    rowHeight: posterMetrics.shelfRowTotalHeight + 18,
                                    destination: { RecentlyAddedSeriesDetailView(playlist: playlist, items: recentlyAddedSeries) },
                                    cell: { series in
                                        NavigationLink {
                                            SeriesDetailView(playlist: playlist, series: series)
                                        } label: {
                                            seriesPosterCard(
                                                series,
                                                posterWidth: posterMetrics.shelfPosterWidth,
                                                posterHeight: posterMetrics.shelfPosterHeight,
                                                imageLoadProfile: .shelf,
                                                isNew: true,
                                                captionText: seriesShelfCaption(series),
                                                watchProgress: progressBySeriesId[String(series.seriesId)]?.progress
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                )
                            }

                            // Build 61 (B8, C2): series Watch Later shelf.
                            if !watchlistSeries.isEmpty {
                                CatalogShelfRow(
                                    title: L("watchlist.title"),
                                    items: watchlistSeries,
                                    rowHeight: posterMetrics.shelfRowTotalHeight,
                                    destination: { WatchlistSeriesView(playlist: playlist) },
                                    cell: { series in
                                        NavigationLink {
                                            SeriesDetailView(playlist: playlist, series: series)
                                        } label: {
                                            seriesPosterCard(
                                                series,
                                                posterWidth: posterMetrics.shelfPosterWidth,
                                                posterHeight: posterMetrics.shelfPosterHeight,
                                                imageLoadProfile: .shelf,
                                                isNew: newestSliceIds.contains(series.seriesId)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                )
                            }

                            LazyVStack(spacing: 0) {
                                ForEach(shelfCategories) { category in
                                    let categoryItems = shelfItemsByCategory[category.id] ?? []
                                    let seriesItems = categoryItems.map(\.series)
                                    CatalogShelfRow(
                                        title: category.name,
                                        count: seriesItems.isEmpty ? nil : seriesItems.count,
                                        items: seriesItems,
                                        rowHeight: posterMetrics.shelfRowTotalHeight + 18,
                                        destination: { SeriesCategoryDetailView(playlist: playlist, category: category) },
                                        cell: { series in
                                            NavigationLink {
                                                SeriesDetailView(playlist: playlist, series: series)
                                            } label: {
                                                seriesPosterCard(
                                                    series,
                                                    posterWidth: posterMetrics.shelfPosterWidth,
                                                    posterHeight: posterMetrics.shelfPosterHeight,
                                                    imageLoadProfile: .shelf,
                                                    isNew: newestSliceIds.contains(series.seriesId),
                                                    captionText: seriesShelfCaption(series),
                                                    watchProgress: progressBySeriesId[String(series.seriesId)]?.progress
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            // Round 20 (R20-5): warm the
                                            // covers just ahead of the
                                            // visible cell.
                                            .onAppear {
                                                if let index = seriesItems.firstIndex(of: series) {
                                                    prefetchSeriesWindow(seriesItems, after: index)
                                                }
                                            }
                                        }
                                    )
                                    .id(category.id)
                                    .onAppear { prefetchSeriesCovers(seriesItems) }
                                    .onDisappear { stopSeriesPrefetch(seriesItems) }
                                }
                            }
                            } // Build 65: end of the All (shelves) branch of the category-chip swap.
                        case .newest:
                            newestGrid
                        }
                        }

                        // Build 88 (F3): bottom clearance — the
                        // floating tab bar must never cover the
                        // last rows of any content branch above
                        // (shelves, Newest grid, category grid,
                        // in-tab search results).
                        Color.clear
                            .frame(height: 84)
                    }
                    .refreshable {
                        // Independent Task: so the refreshable cancellation doesn't propagate to the requests (see LiveStreamsView).
                        let work = Task { await contentStore.refreshFromNetwork(playlist: playlist, only: .series) }
                        await work.value
                    }
                    .onChange(of: pendingScrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            pendingScrollTarget = nil
                        }
                    }
                    // Build 61 fixer (O9): persisted first-visible
                    // shelf anchor (see ScrollAnchorStore). Setting
                    // the binding jumps without animation. Guarded
                    // to the All chip — in the Newest grid the same
                    // ScrollView tracks series IDs, which must never
                    // be persisted as the shelf anchor.
                    .scrollPosition(id: $scrollAnchorID, anchor: .top)
                    .onChange(of: scrollAnchorID) { _, newValue in
                        if selectedChip == .all, let newValue {
                            ScrollAnchorStore.save(newValue, surface: "series", playlistId: playlist.id)
                        }
                    }
                    .onAppear { restoreScrollAnchor() }
                    .onChange(of: displayCategories.map(\.id)) { _, _ in restoreScrollAnchor() }
                    .onChange(of: selectedChip) { _, _ in restoreScrollAnchor() }
                    } // ScrollViewReader
                } // Build 81 (item 7): fixed-header VStack
            }
        }
        .toolbar {
            // Round 8 (D-3): NO toolbar grid icon — AllSeriesView was
            // reachable twice from this tab (here + the Popular Series
            // shelf's "See all"). The shelf entry stays as the ONE path.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingCategoryPicker = true
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(.body.weight(.semibold))
                }
                .disabled(contentStore.seriesCategories.isEmpty)
                .accessibilityLabel(L("list.jump_to_category"))
            }
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerSheet(
                title: L("category_picker.title"),
                entries: pickerEntries,
                playlistId: playlist.id,
                type: "series"
            ) { id in
                showingCategoryPicker = false
                pendingScrollTarget = id
            }
        }
        // Round 8 (audit A2): ONE recompute trigger — the same combined
        // token round 7 gave Home. The two separate `.task(id:)` modifiers
        // that used to sit here (streamsLoaded + the hidden set) fired
        // back-to-back at catalog load, so the two full-catalog passes
        // inside recomputeFilter ran twice in a row. One token change =
        // one run; the outputs are rule-identical.
        .task(id: SeriesRecomputeToken(
            loaded: contentStore.streamsLoaded,
            hidden: hiddenStore.hiddenIds(playlistId: playlist.id, type: "series"),
            seriesCount: contentStore.seriesItems.count,
            rankingsStamp: "\(contentStore.sharedTopRatedSeries.count)-\(contentStore.sharedNewestSeries.count)-\(contentStore.sharedTopRatedSeries.first?.seriesId ?? -1)-\(contentStore.sharedNewestSeries.first?.seriesId ?? -1)",
            order: orderStore.orderedIds(playlistId: playlist.id, type: "series")
        )) { await recomputeFilter() }
        // Build 80 (item 4): 280 ms debounce, then the detached
        // filter pass over the tab's display set.
        .task(id: tabSearchText) {
            let text = tabSearchText
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, tabSearchText == text else { return }
            tabDebouncedQuery = text.trimmingCharacters(in: .whitespacesAndNewlines)
            tabSearchVisibleCount = 90
        }
        .task(id: tabSearchToken) { await recomputeTabSearch() }
        .onChange(of: selectedCategoryId) { _, _ in categoryVisibleCount = 90 }
        .transaction { $0.animation = nil }
        .navigationDestination(item: $pendingSeriesDetail) { series in
            SeriesDetailView(playlist: playlist, series: series)
        }
        .cinematicBackground()
    }

    /// Build 80 (item 4): in-tab search recompute triggers.
    private var tabSearchToken: String {
        "\(tabDebouncedQuery)#\(displayCategories.count)#\(contentStore.seriesItems.count)#\(contentStore.streamsLoaded)"
    }

    /// Build 80 (item 4): filter the tab's OWN display set by title
    /// in ONE detached pass (same pattern as the Movies tab).
    private func recomputeTabSearch() async {
        let q = tabDebouncedQuery
        guard !q.isEmpty else { tabSearchResults = []; return }
        let categories = displayCategories
        let byCategory = displayItemsByCategory
        let result = await Task.detached(priority: .userInitiated) { () -> [SeriesWithCategory] in
            var seen = Set<Int>()
            var matches: [SeriesWithCategory] = []
            for category in categories {
                for item in byCategory[category.id] ?? [] {
                    guard seen.insert(item.series.seriesId).inserted else { continue }
                    if CatalogTextSearch.matchesSectionFuzzy(search: q, text: item.series.name) {
                        matches.append(item)
                    }
                }
            }
            return matches
        }.value
        guard !Task.isCancelled, tabDebouncedQuery == q else { return }
        tabSearchResults = result
    }

    /// Build 80 (item 4): in-tab search results grid (the tab's own
    /// cards + detail destination, 90-per-page pagination).
    private var tabSearchResultsGrid: some View {
        Group {
            if tabSearchResults.isEmpty {
                ContentUnavailableView.search(text: tabDebouncedQuery)
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: posterGridColumns, spacing: posterMetrics.gridRowSpacing) {
                    ForEach(Array(tabSearchResults.prefix(tabSearchVisibleCount).enumerated()), id: \.element.id) { index, item in
                        NavigationLink {
                            SeriesDetailView(playlist: playlist, series: item.series)
                        } label: {
                            SeriesCard(
                                playlistId: playlist.id,
                                stream: item.series,
                                posterWidth: posterMetrics.categoryGridPosterWidth,
                                posterHeight: posterMetrics.categoryGridPosterHeight,
                                imageLoadProfile: .grid
                            )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .onAppear {
                            if index >= tabSearchVisibleCount - 15 {
                                tabSearchVisibleCount = min(tabSearchVisibleCount + 90, tabSearchResults.count)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if tabSearchVisibleCount < tabSearchResults.count {
                    BrandedLoader(size: 28)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
        }
    }

    /// O9 restore: once the shelves exist (All chip), jump back to
    /// the persisted first-visible shelf — only when it is still in
    /// the list and the position is not already there.
    private func restoreScrollAnchor() {
        guard selectedChip == .all,
              !displayCategories.isEmpty,
              let saved = ScrollAnchorStore.anchor(surface: "series", playlistId: playlist.id),
              saved != scrollAnchorID,
              displayCategories.contains(where: { $0.id == saved })
        else { return }
        scrollAnchorID = saved
    }

    /// Round 5 elite header, reordered in round 7 by the owner's direct
    /// order ("search must be at the top"): the tab's ONE search entry
    /// is the FIRST element under the title, then the REAL visible
    /// series total, then the filter chips.
    private var tabHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Build 80 (item 4): REAL text field bound to the tab's
            // own query (see VODView) — typing filters this tab.
            // Build 81 (item 7): screen-margin inset in the fixed
            // header, matching the count line and chips below.
            CatalogSearchField(text: $tabSearchText, placeholder: L("home.search_placeholder"))
            .padding(.top, 4)
            .padding(.horizontal, 16)

            Text(L("home.count_series", CatalogCountFormatter.string(displayCategories.reduce(0) { $0 + (displayItemsByCategory[$1.id]?.count ?? 0) })))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // Round 15 (C12): animated numeric counter.
                .contentTransition(.numericText())
                .animation(Motion.tabFade, value: displayItemsByCategory.values.reduce(0) { $0 + $1.count })
                .padding(.horizontal, 16)

            ContentChipsRow(chips: [.all, .newest], selection: $selectedChip)
        }
        .padding(.bottom, 6)
    }

    /// Build 88 (Part 2-B, decision D2): the NEW-chip slice —
    /// the series on the Recently Added shelf (the catalog's
    /// newest-added ordering, after the build-80 dedupe) carry
    /// the chip wherever they render.
    private var newestSliceIds: Set<Int> {
        Set(recentlyAddedSeries.map(\.seriesId))
    }

    /// The shared poster card's caption override for one
    /// series on the tab's shelves: the in-progress position
    /// when there is one (the live signal SeriesCard always
    /// prioritised); nil lets the card show the record's own
    /// "year • first genre" line.
    private func seriesShelfCaption(_ series: DBSeries) -> String? {
        progressBySeriesId[String(series.seriesId)]?.positionText
    }

    // Build 88 (Part 2-B): cover prefetch for the category
    // shelves, carried over from the deleted
    // SeriesCategoryShelfRow (rounds 7/9/20 behaviour) — the
    // shared shelf owns no prefetch, so the tab keeps warming
    // exactly what its cells render: the cover at shelf size,
    // head batch + the window ahead of the visible cell, with
    // the head batch retracted when the shelf leaves.
    private func prefetchSeriesCovers(_ list: [DBSeries]) {
        let urls = list.prefix(16)
            .compactMap { $0.cover }
            .compactMap { ArtworkURL.url(from: $0) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
    }

    private func prefetchSeriesWindow(_ list: [DBSeries], after index: Int) {
        let start = index + 1
        guard start < list.count else { return }
        let urls = list[start..<min(start + ListImagePrefetch.scrollWindow, list.count)]
            .compactMap { $0.cover }
            .compactMap { ArtworkURL.url(from: $0) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
    }

    private func stopSeriesPrefetch(_ list: [DBSeries]) {
        let urls = list.prefix(16)
            .compactMap { $0.cover }
            .compactMap { ArtworkURL.url(from: $0) }
        ListImagePrefetch.stop(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
    }

    @Environment(\.posterMetrics) private var posterMetrics

    private var posterGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    private var newestGrid: some View {
        Group {
            if newestAll.isEmpty {
                ContentUnavailableView(
                    L("list.no_result"),
                    systemImage: "clock.badge.xmark"
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: posterGridColumns, spacing: posterMetrics.gridRowSpacing) {
                    ForEach(Array(newestAll.prefix(newestVisibleCount).enumerated()), id: \.element.id) { index, series in
                        NavigationLink {
                            SeriesDetailView(playlist: playlist, series: series)
                        } label: {
                            SeriesCard(
                                playlistId: playlist.id,
                                stream: series,
                                posterWidth: posterMetrics.categoryGridPosterWidth,
                                posterHeight: posterMetrics.categoryGridPosterHeight,
                                imageLoadProfile: .grid,
                                watchProgress: progressBySeriesId[String(series.seriesId)]?.progress,
                                seasonEpisodeCounts: contentStore.seriesSeasonEpisodeCounts[series.seriesId],
                                positionText: progressBySeriesId[String(series.seriesId)]?.positionText,
                                watchedPercent: watchedPercentBySeriesId[String(series.seriesId)]
                            )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .onAppear {
                            if index >= newestVisibleCount - 15 {
                                newestVisibleCount = min(newestVisibleCount + Self.newestPageSize, newestAll.count)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if newestVisibleCount < newestAll.count {
                    BrandedLoader(size: 28)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
        }
    }

    /// Build 65: the Series hero pick — the top-rated series
    /// with artwork, else the newest with artwork (the Movies
    /// hero's B6/B7 fallback rule, real records only).
    private var featuredSeries: DBSeries? {
        if let top = topRatedSeries.first(where: { $0.backdropPath != nil || $0.cover != nil }) {
            return top
        }
        return recentlyAddedSeries.first(where: { $0.backdropPath != nil || $0.cover != nil })
    }

    /// Build 65: the hero's Play runs the SAME episode pipeline
    /// Home's featured Play uses (SeriesPlayShell: resume the
    /// in-progress episode, else next unwatched, else S1E1).
    private func presentFeaturedSeriesPlayer(_ series: DBSeries) {
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

    /// Build 65 (inside-sections): the poster grid for a selected
    /// category chip — the category's own bucket, paginated like
    /// the Newest grid, cells identical to it.
    private func categoryGrid(for category: DBCategory) -> some View {
        let items = displayItemsByCategory[category.id] ?? []
        return Group {
            if items.isEmpty {
                ContentUnavailableView(
                    L("list.no_result"),
                    systemImage: "play.tv.slash"
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: posterGridColumns, spacing: posterMetrics.gridRowSpacing) {
                    ForEach(Array(items.prefix(categoryVisibleCount).enumerated()), id: \.element.id) { index, item in
                        NavigationLink {
                            SeriesDetailView(playlist: playlist, series: item.series)
                        } label: {
                            SeriesCard(
                                playlistId: playlist.id,
                                stream: item.series,
                                posterWidth: posterMetrics.categoryGridPosterWidth,
                                posterHeight: posterMetrics.categoryGridPosterHeight,
                                imageLoadProfile: .grid,
                                watchProgress: progressBySeriesId[String(item.series.seriesId)]?.progress,
                                seasonEpisodeCounts: contentStore.seriesSeasonEpisodeCounts[item.series.seriesId],
                                positionText: progressBySeriesId[String(item.series.seriesId)]?.positionText,
                                watchedPercent: watchedPercentBySeriesId[String(item.series.seriesId)]
                            )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .onAppear {
                            if index >= categoryVisibleCount - 15 {
                                categoryVisibleCount = min(categoryVisibleCount + 90, items.count)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if categoryVisibleCount < items.count {
                    BrandedLoader(size: 28)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
        }
    }

    private func presentSeriesHistoryItem(_ item: DBWatchHistory) {
        Task {
            let localURL = await DownloadManager.shared.localURL(
                forId: DownloadManager.idFor(episode: playlist.id, episodeId: item.streamId)
            )
            await MainActor.run {
                presentSeriesHistoryItem(item, localOverrideURL: localURL)
            }
        }
    }

    private func presentSeriesHistoryItem(_ item: DBWatchHistory, localOverrideURL: URL?) {
        let url: URL? = localOverrideURL ?? buildURL(for: item)
        guard let url else { return }
        let navigateToDetail: (String, String) -> Void = { type, id in
            Task {
                if let sId = Int(id),
                   let series = try? await AppDatabase.shared.read({ db in
                    try DBSeries.filter(Column("seriesId") == sId && Column("playlistId") == playlist.id).fetchOne(db)
                }) {
                    await MainActor.run {
                        playerOverlay.dismiss()
                        pendingSeriesDetail = series
                    }
                }
            }
        }
        if item.type == "series" {
            playerOverlay.present(skipDownloadCheck: localOverrideURL != nil, playlistId: playlist.id) {
                HistorySeriesPlayerShell(playlist: playlist, history: item, url: url, onNavigateToDetail: navigateToDetail)
            }
        } else {
            playerOverlay.present(skipDownloadCheck: localOverrideURL != nil, playlistId: playlist.id) {
                PlayerView(
                    url: url,
                    title: item.title,
                    subtitle: item.secondaryTitle,
                    artworkURL: item.imageURL.flatMap { ArtworkURL.url(from: $0) },
                    isLiveStream: false,
                    playlistId: playlist.id,
                    streamId: item.streamId,
                    type: item.type,
                    seriesId: item.seriesId,
                    resumeTimeMs: item.lastTimeMs,
                    containerExtension: item.containerExtension,
                    onNavigateToDetail: navigateToDetail
                )
            }
        }
    }

    /// Round 5: with the native search bar removed there is no in-tab
    /// query anymore — the display set is simply every visible category
    /// with its series, exactly what the old empty-query path produced
    /// (the same simplification Live got in round 3).
    private func recomputeFilter() async {
        guard playlist.id == contentStore.activePlaylistId else {
            displayCategories = []; displayItemsByCategory = [:]; recentlyAddedSeries = []; newestSeries = []; topRatedSeries = []; newestAll = []; progressBySeriesId = [:]; shelfCategories = []; shelfItemsByCategory = [:]; return
        }
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "series")
        let allCats = orderStore.applyOrder(
            contentStore.seriesCategories.filter { !hidden.contains($0.id) },
            playlistId: playlist.id, type: "series"
        ) { $0.id }
        let allByCategory = contentStore.seriesItemsByCategoryId

        // Build 61 (B8, Z6): empty categories hidden by default once
        // the catalog is loaded (Appearance toggle restores them).
        displayCategories = contentStore.streamsLoaded
            ? EmptyCategoryVisibility.visible(allCats) { allByCategory[$0.id]?.count ?? 0 }
            : allCats
        displayItemsByCategory = allByCategory
        let visibleCatIds = Set(allCats.map(\.id))
        let allSeries = contentStore.seriesItems
        // Round 14 (B10): rankings come from the store's shared
        // arrays (computed once), filtered by visible categories.
        // The store's Newest ordering already uses the tolerant
        // `lastModified` parser (round 15, C8).
        let sharedTop = contentStore.sharedTopRatedSeries
        let sharedNewest = contentStore.sharedNewestSeries
        topRatedSeries = Array(sharedTop.filter { visibleCatIds.contains($0.categoryId ?? "") }.prefix(15))
        recentlyAddedSeries = Array(sharedNewest.filter { visibleCatIds.contains($0.categoryId ?? "") }.prefix(20))
        newestSeries = Array(sharedNewest.filter { visibleCatIds.contains($0.categoryId ?? "") }.prefix(60))

        // The Newest GRID paginates past the shared cap, so it keeps
        // a full ordering (tolerant timestamp parsing, C8).
        let byModifiedDesc = await Task.detached(priority: .userInitiated) {
            allSeries
                .lazy
                .filter { visibleCatIds.contains($0.series.categoryId ?? "") }
                .compactMap { item -> (DBSeries, Int)? in
                    guard let ts = CatalogTimestampParsing.epochSeconds(from: item.series.lastModified) else { return nil }
                    return (item.series, ts)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }.value
        guard !Task.isCancelled else { return }
        newestAll = byModifiedDesc
        newestVisibleCount = min(Self.newestPageSize, byModifiedDesc.count)

        // Build 80 (item 12): dedupe the tab's catalog rails in
        // RENDER order, first rail wins (Top → Recently Added →
        // category shelves) — same rules as the Movies tab: same-id
        // or same-NAME duplicate category rails merge into the
        // first rail of that name, an item shown in an earlier rail
        // never repeats later, exact repeats inside one rail
        // collapse; different encodes are different ids and stay.
        // Chips and per-category grids keep the full display data.
        let catsSnapshot = displayCategories
        let itemsSnapshot = displayItemsByCategory
        let topSnapshot = topRatedSeries
        let recentSnapshot = recentlyAddedSeries
        let deduped = await Task.detached(priority: .userInitiated) { () -> (top: [DBSeries], recent: [DBSeries], shelfCats: [DBCategory], shelfItems: [String: [SeriesWithCategory]]) in
            var seen = Set<Int>()
            func take(_ items: [DBSeries]) -> [DBSeries] {
                var out: [DBSeries] = []
                for item in items where seen.insert(item.seriesId).inserted { out.append(item) }
                return out
            }
            let top = take(topSnapshot)
            let recent = take(recentSnapshot)
            var shelfCats: [DBCategory] = []
            var shelfItems: [String: [SeriesWithCategory]] = [:]
            var firstIdByName: [String: String] = [:]
            for category in catsSnapshot {
                let nameKey = category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let targetId: String
                if let existing = firstIdByName[nameKey] {
                    targetId = existing
                } else {
                    firstIdByName[nameKey] = category.id
                    targetId = category.id
                    shelfCats.append(category)
                    shelfItems[category.id] = []
                }
                for item in itemsSnapshot[category.id] ?? [] where seen.insert(item.series.seriesId).inserted {
                    shelfItems[targetId, default: []].append(item)
                }
            }
            shelfCats = shelfCats.filter { !(shelfItems[$0.id]?.isEmpty ?? true) }
            return (top, recent, shelfCats, shelfItems)
        }.value
        guard !Task.isCancelled else { return }
        topRatedSeries = deduped.top
        recentlyAddedSeries = deduped.recent
        shelfCategories = deduped.shelfCats
        shelfItemsByCategory = deduped.shelfItems

        await loadProgressBySeries()
    }

    /// B8: one DB pass — the latest history row per series, joined to
    /// its episode record for the real season/episode numbers.
    private func loadProgressBySeries() async {
        let pid = playlist.id
        let result = try? await AppDatabase.shared.read { db -> [String: SeriesProgressInfo] in
            let rows = try DBWatchHistory
                .filter(Column("playlistId") == pid && Column("type") == "series" && Column("durationMs") > 0)
                .order(Column("lastWatchedAt").desc)
                .fetchAll(db)
            var latest: [String: DBWatchHistory] = [:]
            for row in rows {
                guard let sid = row.seriesId, latest[sid] == nil else { continue }
                latest[sid] = row
            }
            var out: [String: SeriesProgressInfo] = [:]
            for (sid, history) in latest {
                let progress = min(max(Double(history.lastTimeMs) / Double(history.durationMs), 0), 1)
                guard progress > 0.02, progress < 0.98 else { continue }
                let episode = try DBEpisode
                    .filter(Column("episodeId") == history.streamId || Column("id") == history.streamId)
                    .fetchOne(db)
                let seasonNumber = episode.flatMap { ep in
                    ep.seasonId.split(separator: "_").last.flatMap { Int($0) }
                }
                out[sid] = SeriesProgressInfo(
                    progress: progress,
                    seasonNumber: seasonNumber,
                    episodeNumber: episode?.episodeNum
                )
            }
            return out
        }
        guard !Task.isCancelled else { return }
        progressBySeriesId = result ?? [:]
        await loadWatchedPercents()
    }

    /// Build 61 (B8, C5): watched % per series over its LOADED
    /// episodes (episodes land in the DB when a series is opened or
    /// refreshed). Series with no loaded episodes get no entry —
    /// their cards show no percentage rather than a fabricated 0%.
    private func loadWatchedPercents() async {
        let pid = playlist.id
        let result = try? await AppDatabase.shared.read { db -> [String: Int] in
            let seasons = try DBSeason.filter(Column("playlistId") == pid).fetchAll(db)
            guard !seasons.isEmpty else { return [:] }
            let seasonSeries = Dictionary(seasons.map { ($0.id, $0.seriesId) }, uniquingKeysWith: { first, _ in first })
            let episodes = try DBEpisode.filter(seasonSeries.keys.contains(Column("seasonId"))).fetchAll(db)
            let history = try DBWatchHistory
                .filter(Column("playlistId") == pid && Column("type") == "series")
                .fetchAll(db)
            let historyByKey = Dictionary(history.map { ($0.streamId, $0) }, uniquingKeysWith: { first, _ in first })
            var totals: [Int: Int] = [:]
            var watchedCounts: [Int: Int] = [:]
            for episode in episodes {
                guard let seriesId = seasonSeries[episode.seasonId] else { continue }
                totals[seriesId, default: 0] += 1
                let key = episode.episodeId ?? episode.id
                let row = historyByKey[key]
                let manual = EpisodeWatchStore.manualVerdict(playlistId: pid, episodeKey: key)
                if EpisodeWatched.isWatched(manual: manual, lastTimeMs: row?.lastTimeMs ?? 0, durationMs: row?.durationMs ?? 0) {
                    watchedCounts[seriesId, default: 0] += 1
                }
            }
            var out: [String: Int] = [:]
            for (seriesId, total) in totals where total > 0 {
                let watched = watchedCounts[seriesId] ?? 0
                if watched > 0 {
                    out[String(seriesId)] = Int((Double(watched) / Double(total) * 100).rounded())
                }
            }
            return out
        }
        guard !Task.isCancelled else { return }
        watchedPercentBySeriesId = result ?? [:]
    }

    private func buildURL(for item: DBWatchHistory) -> URL? {
        let builder = PlaybackURLBuilder(playlist: playlist)
        // Because it is the Series tab, the series assumption
        return builder.seriesURL(streamId: item.streamId, containerExtension: item.containerExtension)
    }
}

// MARK: - Build 88: shared catalog poster card (series)

/// The Series tab's poster card for one record — the shared
/// PosterCardView fed exactly as `moviePosterCard` feeds the
/// Movies tab: the artwork chain resolved to ONE url (cover,
/// then the stored backdrop — build 82 item 6), the normalized
/// rating, and the caller's NEW-slice flag. The caption is the
/// caller's line when it passes one (the in-progress position
/// on the tab's shelves); otherwise the record's own
/// "year • first genre" line, as SeriesCard always showed.
func seriesPosterCard(
    _ series: DBSeries,
    posterWidth: CGFloat,
    posterHeight: CGFloat,
    imageLoadProfile: ImageLoadProfile,
    isNew: Bool,
    captionText: String? = nil,
    watchProgress: Double? = nil
) -> PosterCardView {
    var captionParts: [String] = []
    if let year = DetailFormatting.year(from: series.releaseDate) {
        captionParts.append(year)
    }
    if let genre = series.genre?.split(separator: ",").first {
        let trimmed = genre.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { captionParts.append(trimmed) }
    }
    return PosterCardView(
        imageURL: ArtworkURL.url(from: series.cover) ?? ArtworkURL.url(from: series.backdropPath),
        title: series.name,
        yearText: captionText ?? (captionParts.isEmpty ? nil : captionParts.joined(separator: " • ")),
        ratingText: ContentRating.normalizedDisplayText(rating: series.rating, rating5Based: series.rating5Based),
        isNew: isNew,
        iconName: "play.tv",
        posterWidth: posterWidth,
        posterHeight: posterHeight,
        imageLoadProfile: imageLoadProfile,
        watchProgress: watchProgress
    )
}

// MARK: - Series featured hero

/// Build 65: the Series tab's featured hero — the exact visual
/// language of the Movies tab's `MovieFeaturedHero` (backdrop,
/// gradient, badge, big title, real rating/year/genre line, Play
/// + Details), over the series' own artwork and data.
struct SeriesFeaturedHero: View {
    let playlist: Playlist
    let series: DBSeries
    let onDetails: () -> Void
    let onPlay: () -> Void

    // Build 87 (item 16, owner-picked design 4): the Series
    // tab hero is the design-4 poster card, centered (the
    // tab features ONE item — no peek neighbours exist).
    // HeroPosterCard owns the art chain (backdrop → poster
    // on failure → the designed title card), the centered
    // title/star/meta block and the Play/Details actions;
    // the existing onPlay/onDetails wiring is unchanged.

    private var metaLine: String? {
        var parts: [String] = []
        if let genre = series.genre?.split(separator: ",").first {
            parts.append(genre.trimmingCharacters(in: .whitespaces))
        }
        if let year = DetailFormatting.year(from: series.releaseDate) {
            parts.append(year)
        }
        if let runtime = DetailFormatting.seriesRuntime(series.episodeRunTime) {
            parts.append(runtime)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    var body: some View {
        HeroPosterCard(
            title: series.name,
            backdropURL: series.backdropPath.flatMap { ArtworkURL.url(from: $0) },
            posterURL: series.cover.flatMap { ArtworkURL.url(from: $0) },
            ratingText: ContentRating.normalizedDisplayText(rating: series.rating, rating5Based: series.rating5Based),
            metaLine: metaLine,
            iconName: "play.tv",
            width: (UIScreen.main.bounds.width - 32) * 0.78,
            onPlay: onPlay,
            onDetails: onDetails
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .tint(SectionTheme.series)
    }
}

// Build 88 (Part 2-B): PopularSeriesShelf was replaced by the shared
// CatalogShelfRow (ranked) in SeriesView — see Views/CatalogComponents.swift.

// MARK: - Recently Added shelf

// Build 88 (Part 2-B): RecentlyAddedSeriesShelf was replaced by the shared
// CatalogShelfRow in SeriesView — see Views/CatalogComponents.swift.

// MARK: - Recently Added Detail View
/// Build 88 (Part 2-B): the "See all" page is the shared
/// CatalogGridView — poster grid, in-section search and the
/// "N of N" count line; the grid owns the header, the search,
/// the navigation chrome and the bottom clearance.
struct RecentlyAddedSeriesDetailView: View {
    let playlist: Playlist
    let items: [DBSeries]

    @Environment(\.posterMetrics) private var posterMetrics

    var body: some View {
        CatalogGridView(
            title: L("recently_added.title"),
            items: items,
            searchPlaceholder: L("series.search_placeholder"),
            itemTitle: { $0.name },
            emptySystemImage: "tv",
            cell: { series in
                NavigationLink {
                    SeriesDetailView(playlist: playlist, series: series)
                } label: {
                    seriesPosterCard(
                        series,
                        posterWidth: posterMetrics.categoryGridPosterWidth,
                        posterHeight: posterMetrics.categoryGridPosterHeight,
                        imageLoadProfile: .grid,
                        isNew: true
                    )
                }
                .buttonStyle(.plain)
            }
        )
    }
}

// MARK: - Category shelf
// Build 88 (Part 2-B): SeriesCategoryShelfRow (+ its prefetch helpers) was
// replaced by the shared CatalogShelfRow in SeriesView — the shared shelf
// owns poster prefetch at shelf size. See Views/CatalogComponents.swift.

struct SeriesCard: View {
    let playlistId: UUID
    let stream: DBSeries
    var categoryName: String? = nil
    var posterWidth: CGFloat = 160
    var posterHeight: CGFloat = 240
    var imageLoadProfile: ImageLoadProfile = .standard
    /// Passed from the upper view instead of opening a @Query per card (nil = progress bar hidden)
    var watchProgress: Double? = nil
    /// Round 14 (B8): real season/episode counts computed by
    /// PlaylistContentStore — nil (entry absent) shows NOTHING, never
    /// a fabricated 0.
    var seasonEpisodeCounts: SeriesSeasonEpisodeCounts? = nil
    /// B8: "S# • E#" of the latest in-progress episode, from real
    /// watch history; nil when the series isn't in progress.
    var positionText: String? = nil
    /// Build 61 (B8, C5): watched-episode percentage over the
    /// series' loaded episodes; nil when unknown or nothing watched.
    var watchedPercent: Int? = nil

    /// "2024 • Fantasy" — built only from fields the record actually
    /// carries (release year, first genre); nil when neither exists.
    private var metaLine: String? {
        var parts: [String] = []
        if let year = DetailFormatting.year(from: stream.releaseDate) {
            parts.append(year)
        }
        if let genre = stream.genre?.split(separator: ",").first {
            let g = genre.trimmingCharacters(in: .whitespaces)
            if !g.isEmpty { parts.append(g) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    /// The one extra line under the meta line: the in-progress
    /// position when there is one (it is the more useful signal),
    /// else the real season/episode counts.
    private var extraLine: String? {
        if let positionText { return positionText }
        if let counts = seasonEpisodeCounts {
            return "\(L("series.seasons_count_format", counts.seasons)) • \(L("series.episode_count_format", counts.episodes))"
        }
        return nil
    }

    var body: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                CachedImage(
                    // Build 81 (items 5b/5c): lenient artwork URL +
                    // title card fallback — see VODStreamCard.
                    // Build 82 (item 6, symmetric): the record's
                    // stored backdrop is the fallback when the
                    // cover field is empty/unusable.
                    url: ArtworkURL.url(from: stream.cover) ?? ArtworkURL.url(from: stream.backdropPath),
                    width: posterWidth,
                    height: posterHeight,
                    contentMode: SwiftUI.ContentMode.fill,
                    iconName: "play.tv",
                    loadProfile: imageLoadProfile,
                    title: stream.name
                )

                if let progress = watchProgress, progress > 0 {
                    Rectangle()
                        .fill(AppTheme.accent)
                        .frame(height: 4)
                        .frame(width: posterWidth * progress)
                        .frame(maxWidth: posterWidth, alignment: .leading)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(2)
                        .padding(.bottom, 2)
                        .padding(.horizontal, 4)
                }

                // B7: badge shows the ONE normalized rating value.
                PosterRatingBadge(rating: ContentRating.normalizedDisplayText(
                    rating: stream.rating,
                    rating5Based: stream.rating5Based
                ))
                    .padding(6)
            }

            // Round 15 (C9): left-aligned card titles on the shared
            // font tokens (matching RankedPosterCard).
            Text(stream.name)
                .font(AppTheme.fontPosterTitle)
                .lineLimit(2, reservesSpace: true)
                .minimumScaleFactor(0.9)
                .multilineTextAlignment(.leading)
                .frame(width: posterWidth, alignment: .leading)
                .foregroundColor(.primary)

            if let metaLine {
                Text(metaLine)
                    .font(AppTheme.fontMetadata)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: posterWidth, alignment: .leading)
            }

            if let extraLine {
                Text(extraLine)
                    .font(AppTheme.fontMetadata)
                    .foregroundColor(positionText != nil ? AppTheme.accent : .secondary)
                    .lineLimit(1)
                    .frame(width: posterWidth, alignment: .leading)
            }

            // Build 61 (B8, C5): per-series watched percentage.
            if let watchedPercent, watchedPercent > 0 {
                Text(L("series.progress.percent_format", watchedPercent))
                    .font(AppTheme.fontMetadata)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: posterWidth, alignment: .leading)
            }

            if let catName = categoryName {
                Text(catName)
                    .font(AppTheme.fontMetadata)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: posterWidth, alignment: .leading)
            }
        }
    }
}

// MARK: - Category Detail View
struct SeriesCategoryDetailView: View {
    let playlist: Playlist
    let category: DBCategory

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var displayItems: [SeriesWithCategory] = []

    var body: some View {
        SeriesCategoryContent(playlist: playlist, items: displayItems)
            .equatable()
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.hidden, for: .tabBar)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: L("series.search_placeholder"))
            .onChange(of: searchText) { _, new in
                debounceTask?.cancel()
                debounceTask = Task {
                    try? await Task.sleep(nanoseconds: 280_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { debouncedQuery = new }
                }
            }
            .onDisappear { debounceTask?.cancel(); debounceTask = nil }
            .task(id: debouncedQuery) { await recomputeItems() }
            .task(id: contentStore.streamsLoaded) { await recomputeItems() }
    }

    private func recomputeItems() async {
        guard playlist.id == contentStore.activePlaylistId else { displayItems = []; return }
        let base = contentStore.seriesItemsByCategoryId[category.id] ?? []
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { displayItems = base; return }
        // Build 63 (item 15): a non-empty query searches the FULL
        // series catalog (hidden categories excluded, exactly as
        // AllSeriesView) — a title filed under another category
        // can now surface from this category's search; the empty
        // query above keeps the category bucket untouched.
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "series")
        let source = contentStore.seriesItems
        let result = await Task.detached(priority: .userInitiated) {
            let visible = source.filter { !hidden.contains($0.series.categoryId ?? "") }
            let filtered = visible.filter { CatalogTextSearch.matchesSectionFuzzy(search: q, text: $0.series.name) }
            return CatalogTextSearch.sortSeriesByRelevance(filtered, search: q)
        }.value
        guard !Task.isCancelled else { return }
        displayItems = result
    }
}

struct SeriesCategoryContent: View, Equatable {
    let playlist: Playlist
    let items: [SeriesWithCategory]
    /// Round 14 (B1): a genre chip on a series detail page lands
    /// here with that genre pre-applied to the existing genre filter.
    var initialGenre: String? = nil

    /// Cheap signature compare so a parent @Published re-render doesn't force SwiftUI
    /// to re-process a huge item list. Internal @State/@Query updates still invalidate.
    static func == (lhs: SeriesCategoryContent, rhs: SeriesCategoryContent) -> Bool {
        lhs.playlist.id == rhs.playlist.id
            && lhs.items.count == rhs.items.count
            && lhs.items.first?.series.seriesId == rhs.items.first?.series.seriesId
            && lhs.items.last?.series.seriesId == rhs.items.last?.series.seriesId
    }

    @Environment(\.posterMetrics) private var posterMetrics
    @Query<WatchProgressMapRequest> private var progressMap: [String: Double]
    @ObservedObject private var contentStore = PlaylistContentStore.shared

    @AppStorage(SeriesSortOption.storageKey) private var sortOption: SeriesSortOption = .defaultOrder
    @State private var showSortSheet = false
    /// Screen-local: genres are specific to the currently shown list.
    @State private var genreFilter: Set<String> = []
    /// Sort/filter output, recomputed off the main thread on input changes.
    @State private var displayItems: [SeriesWithCategory] = []
    /// Genres present in the full list, precomputed to keep the menu O(1) to build.
    @State private var genres: [String] = []
    /// Paginated render count so a huge catalog doesn't build one giant ForEach.
    @State private var visibleCount = Self.pageSize

    private static let pageSize = 90

    init(playlist: Playlist, items: [SeriesWithCategory], initialGenre: String? = nil) {
        self.playlist = playlist
        self.items = items
        self.initialGenre = initialGenre
        _progressMap = Query(WatchProgressMapRequest(playlistId: playlist.id, type: "series"), in: \.appDatabase)
    }

    private var categoryGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    /// Cheap O(1) change signal for `items`; avoids O(n) array equality in `.task(id:)`.
    private var itemsToken: Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        hasher.combine(items.first?.series.seriesId)
        hasher.combine(items.last?.series.seriesId)
        return hasher.finalize()
    }

    // Build 61 (B8, C1): year + rating facets (genre already lives
    // in `genreFilter` above; countries don't exist on series
    // records, so no country facet is offered — honestly absent).
    @State private var facetSelection = CatalogFacetSelection()
    @State private var facetYears: [Int] = []
    @State private var facetHasRatings = false

    private var isFilterActive: Bool {
        sortOption != .defaultOrder || !genreFilter.isEmpty || !facetSelection.isEmpty
    }

    private func recompute() async {
        let source = items
        let sort = sortOption
        let filter = genreFilter
        let facets = facetSelection
        let (result, allGenres, years) = await Task.detached(priority: .userInitiated) { () -> ([SeriesWithCategory], [String], [Int]) in
            let genreFiltered = SeriesGenre.filter(source, selection: filter)
            let sorted = sort.apply(to: facets.apply(to: genreFiltered))
            return (sorted, SeriesGenre.available(in: source),
                    CatalogFacets.seriesFacets(in: source.map(\.series)).years)
        }.value
        displayItems = result
        genres = allGenres
        facetYears = years
        facetHasRatings = items.contains {
            ContentRating.normalizedRating10(rating: $0.series.rating, rating5Based: $0.series.rating5Based) != nil
        }
        visibleCount = min(Self.pageSize, result.count)
        prefetch(result)
    }

    private func loadMore() {
        guard visibleCount < displayItems.count else { return }
        let pageStart = visibleCount
        visibleCount = min(visibleCount + Self.pageSize, displayItems.count)
        // Round 20 (R20-5): warm the page that is about to be
        // revealed — the old flow only ever prefetched the grid's
        // first 24 covers (at recompute), so every paged-in page
        // painted cold during fast scrolling.
        prefetch(displayItems, startingAt: pageStart)
    }

    var body: some View {
        Group {
            if displayItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "play.tv")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(L("series.empty.no_series"))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: categoryGridColumns, spacing: posterMetrics.gridRowSpacing) {
                        ForEach(Array(displayItems.prefix(visibleCount).enumerated()), id: \.element.series.seriesId) { index, item in
                            NavigationLink(destination: SeriesDetailView(playlist: playlist, series: item.series)) {
                                SeriesCard(
                                    playlistId: playlist.id,
                                    stream: item.series,
                                    posterWidth: posterMetrics.categoryGridPosterWidth,
                                    posterHeight: posterMetrics.categoryGridPosterHeight,
                                    imageLoadProfile: .grid,
                                    watchProgress: progressMap[String(item.series.seriesId)],
                                    seasonEpisodeCounts: contentStore.seriesSeasonEpisodeCounts[item.series.seriesId]
                                )
                            }
                            // Build 61 (B8, C2/J1): long-press —
                            // Watch Later + favorite groups.
                            .contextMenu {
                                SeriesCardMenuItems(playlist: playlist, series: item.series)
                            }
                            .onAppear { if index >= visibleCount - 15 { loadMore() } }
                        }
                    }
                    .padding()

                    if visibleCount < displayItems.count {
                        BrandedLoader(size: 28)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                sortFilterMenu
            }
        }
        .task(id: itemsToken) { await recompute() }
        .task(id: sortOption) { await recompute() }
        .task(id: genreFilter) { await recompute() }
        .task(id: facetSelection) { await recompute() }
        .task(id: initialGenre) {
            if let initialGenre, genreFilter.isEmpty {
                genreFilter = [initialGenre]
            }
        }
        .cinematicBackground()
    }

    /// Round 10 (point 13): the raw popover `Menu` is now the
    /// styled `SortFilterSheet` bottom sheet — same state, same
    /// options, same toggle/clear behavior.
    private var sortFilterMenu: some View {
        Button {
            showSortSheet = true
        } label: {
            Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.body.weight(.semibold))
        }
        .accessibilityLabel(L("sort.title"))
        .sheet(isPresented: $showSortSheet) {
            SortFilterSheet(
                sortRows: SeriesSortOption.allCases.map { option in
                    SortFilterSheet.Row(
                        id: option.rawValue,
                        title: L(option.titleKey),
                        systemImage: option.systemImage,
                        isSelected: sortOption == option
                    ) { sortOption = option }
                },
                filterTitle: L("filter.title"),
                filterRows: genres.map { genre in
                    SortFilterSheet.Row(
                        id: "genre-\(genre)",
                        title: genre,
                        isSelected: genreFilter.contains(genre)
                    ) { toggleGenre(genre) }
                } + facetRows,
                // Round 14 (B1): Clear resets the SORT as well as the
                // genre filter. B8: facets clear with them.
                onClearFilters: (sortOption == .defaultOrder && genreFilter.isEmpty && facetSelection.isEmpty) ? nil : {
                    sortOption = .defaultOrder
                    genreFilter.removeAll()
                    facetSelection.clear()
                }
            )
        }
    }

    /// Build 61 (B8, C1): year + rating-floor rows, built only from
    /// values present in this list.
    private var facetRows: [SortFilterSheet.Row] {
        var rows: [SortFilterSheet.Row] = []
        for year in facetYears.prefix(12) {
            rows.append(SortFilterSheet.Row(
                id: "year-\(year)", title: String(year),
                isSelected: facetSelection.years.contains(year)
            ) {
                if facetSelection.years.contains(year) { facetSelection.years.remove(year) } else { facetSelection.years.insert(year) }
            })
        }
        if facetHasRatings {
            for floor in [7.0, 8.0, 9.0] {
                rows.append(SortFilterSheet.Row(
                    id: "rating-\(floor)", title: L("filter.rating_min_format", Int(floor)),
                    isSelected: facetSelection.minRating == floor
                ) { facetSelection.minRating = facetSelection.minRating == floor ? nil : floor })
            }
        }
        return rows
    }

    private func toggleGenre(_ genre: String) {
        if genreFilter.contains(genre) {
            genreFilter.remove(genre)
        } else {
            genreFilter.insert(genre)
        }
    }

    private func prefetch(_ list: [SeriesWithCategory], startingAt: Int = 0) {
        let urls = list.dropFirst(startingAt).prefix(ListImagePrefetch.maxBatch)
            .compactMap { $0.series.cover }
            .compactMap { ArtworkURL.url(from: $0) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.categoryGridPosterWidth,
            height: posterMetrics.categoryGridPosterHeight,
            contentMode: .fill,
            loadProfile: .grid
        )
    }
}

// MARK: - All Series (flat browse)

/// Flat grid of every series across categories — the Top Rated
/// shelf's "See all". Build 88 (Part 2-B): renders through the
/// shared CatalogGridView (poster grid, in-section search,
/// "N of N"); this view keeps only the data rule it always had
/// (hidden categories excluded). The grid's own search replaces
/// the page's old searchable + relevance-sort plumbing.
struct AllSeriesView: View {
    let playlist: Playlist

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @State private var displayItems: [DBSeries] = []
    @Environment(\.posterMetrics) private var posterMetrics

    /// The NEW-chip slice, from the store's shared newest
    /// ordering (the tab derives its slice from its own deduped
    /// shelf state; the ids agree on the newest head).
    private var newSliceIds: Set<Int> {
        Set(contentStore.sharedNewestSeries.prefix(20).map(\.seriesId))
    }

    var body: some View {
        CatalogGridView(
            title: L("browse.all_series"),
            items: displayItems,
            searchPlaceholder: L("series.search_placeholder"),
            itemTitle: { $0.name },
            emptySystemImage: "tv",
            cell: { series in
                NavigationLink {
                    SeriesDetailView(playlist: playlist, series: series)
                } label: {
                    seriesPosterCard(
                        series,
                        posterWidth: posterMetrics.categoryGridPosterWidth,
                        posterHeight: posterMetrics.categoryGridPosterHeight,
                        imageLoadProfile: .grid,
                        isNew: newSliceIds.contains(series.seriesId)
                    )
                }
                .buttonStyle(.plain)
            }
        )
        .task(id: contentStore.streamsLoaded) { await recompute() }
        .task(id: hiddenStore.hiddenIds(playlistId: playlist.id, type: "series")) { await recompute() }
    }

    private func recompute() async {
        guard playlist.id == contentStore.activePlaylistId else { displayItems = []; return }
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "series")
        let source = contentStore.seriesItems
        // All work off the main thread; the catalog can be very large.
        let result = await Task.detached(priority: .userInitiated) {
            source.filter { !hidden.contains($0.series.categoryId ?? "") }.map(\.series)
        }.value
        guard !Task.isCancelled else { return }
        displayItems = result
    }
}

// MARK: - Series Detail View (Lazy Loading Seasons)
struct SeriesDetailView: View {
    let playlist: Playlist
    var series: DBSeries

    @Environment(\.posterMetrics) private var posterMetrics
    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedSeasonId: String?
    @State private var enlargedImage: IdentifiableURL?
    @State private var showNavTitle: Bool = false
    @State private var selectedEpisode: (DBEpisode, DBWatchHistory?)?
    @State private var episodeNavPrevious: DBEpisode?
    @State private var episodeNavNext: DBEpisode?
    /// The episode the watch history points at (for the
    /// "Continue • Episode N" label and the download row) and the
    /// series' first episode (the no-history download target) —
    /// both resolved from the database, never assumed.
    @State private var resumeEpisode: DBEpisode?
    @State private var firstEpisode: DBEpisode?
    /// Build 82 (item 3): the first episode of the season the
    /// user has SELECTED with the season chips — the Play
    /// button's target whenever the on-screen season is not
    /// the resume episode's own season.
    @State private var selectedSeasonFirstEpisode: DBEpisode?
    /// Round 14 (B1): series Play surfaces a VISIBLE failure when no
    /// episode resolves — never a silent no-op.
    @State private var showPlayFailure = false
    /// Round 14 (B3): the "Play next unwatched" target — the episode
    /// after the latest watched one in chain order, when one exists.
    @State private var nextUnwatchedEpisode: DBEpisode?
    /// Round 15 (C8): episodes present in the DB that weren't in the
    /// known-ID set from the previous detail open (first open only
    /// records the baseline).
    @State private var newEpisodeCount = 0
    // Build 61 (B8): C5 watched progress, J2 More Like This, C2
    // watch-later store, parental guard state.
    @State private var seriesWatchedProgress: (watched: Int, total: Int)?
    @State private var moreLikeThisSeries: [DBSeries] = []
    @State private var pendingSeriesDetail: DBSeries?
    @State private var parentalBlocked = false
    @State private var showParentalPIN = false
    @ObservedObject private var watchlistStore = WatchlistStore.shared
    @ObservedObject private var episodeWatchStore = EpisodeWatchStore.shared
    @ObservedObject private var contentStore = PlaylistContentStore.shared
    /// One navigation route for genre + people browsing (single
    /// destination registration per type, as SwiftUI requires).
    @State private var pendingRoute: MovieDetailRoute?
    @Query<SeriesByIDRequest> private var seriesRecord: DBSeries?
    @Query<SeasonsRequest> private var seasons: [DBSeason]
    @Query<IsFavoriteRequest> private var isFavorite: Bool
    @Query<LatestSeriesWatchHistoryRequest> private var watchHistory: DBWatchHistory?

    init(playlist: Playlist, series: DBSeries) {
        self.playlist = playlist
        self.series = series
        _seriesRecord = Query(SeriesByIDRequest(seriesId: series.seriesId, playlistId: playlist.id), in: \.appDatabase)
        _seasons = Query(SeasonsRequest(seriesId: series.seriesId, playlistId: playlist.id), in: \.appDatabase)
        _isFavorite = Query(IsFavoriteRequest(streamId: series.seriesId, playlistId: playlist.id, type: "series"), in: \.appDatabase)
        _watchHistory = Query(LatestSeriesWatchHistoryRequest(seriesId: String(series.seriesId), playlistId: playlist.id), in: \.appDatabase)
    }

    private var currentSeries: DBSeries {
        seriesRecord ?? series
    }

    private var heroConfig: DetailHeroConfig {
        DetailHeroConfig(
            title: currentSeries.name,
            backdropURL: ArtworkURL.url(from: currentSeries.backdropPath),
            posterURL: currentSeries.cover.flatMap { ArtworkURL.url(from: $0) },
            year: DetailFormatting.year(from: currentSeries.releaseDate),
            releaseDate: currentSeries.releaseDate,
            runtime: DetailFormatting.seriesRuntime(currentSeries.episodeRunTime),
            // B7: the hero reads the ONE rating normalization point.
            rating10: ContentRating.normalizedRating10(
                rating: currentSeries.rating,
                rating5Based: currentSeries.rating5Based
            ),
            ratingText: currentSeries.rating,
            posterIconName: "play.tv",
            backdropIconName: "play.tv"
        )
    }

    private var trailerURL: URL? {
        // C7 validation, same rule as the movie side: only a real
        // YouTube URL or a bare 11-char video id produces a trailer.
        guard let raw = currentSeries.youtubeTrailer?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if raw.lowercased().hasPrefix("http") {
            guard let url = URL(string: raw),
                  let host = url.host?.lowercased(),
                  host.contains("youtube.com") || host.contains("youtu.be") else { return nil }
            return url
        }
        let idCharset = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard raw.count == 11, raw.unicodeScalars.allSatisfy({ idCharset.contains($0) }) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(raw)")
    }

    private var hasResume: Bool {
        guard let h = watchHistory else { return false }
        return h.lastTimeMs > 5000
    }

    /// Round 14 (B8): the ONE finished threshold — ≥98% — matching
    /// SeriesPlayShell. A finished latest episode means the primary
    /// action moves to the NEXT episode, not a resume into the last
    /// seconds.
    private var resumeIsFinished: Bool {
        guard let h = watchHistory, h.durationMs > 0 else { return false }
        return Double(h.lastTimeMs) / Double(h.durationMs) >= 0.98
    }

    /// Seasons in chain order (season 0 last — see
    /// SeriesPlaybackOrdering): the first entry is the first REGULAR
    /// season whenever one exists.
    private var orderedSeasons: [DBSeason] {
        SeriesPlaybackOrdering.orderedSeasons(seasons)
    }

    private var resumeProgress: Double? {
        guard let h = watchHistory, h.durationMs > 0 else { return nil }
        let p = Double(h.lastTimeMs) / Double(h.durationMs)
        return (p > 0.02 && p < 0.98) ? p : nil
    }

    private var resumeSubtitle: String? {
        guard let h = watchHistory, hasResume else { return nil }
        let time = DetailFormatting.formatMs(h.lastTimeMs)
        return h.title.isEmpty ? time : "\(h.title) · \(time)"
    }

    var body: some View {
        Group {
            if isLoading && !currentSeries.seasonsLoaded {
                VStack(spacing: 12) {
                    BrandedLoader()
                    Text(L("detail.loading_series"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                errorView(error)
            } else {
                contentScroll
            }
        }
        .navigationTitle(showNavTitle ? currentSeries.name : "")
        .navigationBarTitleDisplayMode(.inline)
        // Round 10 / build 78: the favorite action lives in the
        // glass action row under the Play button
        // (DetailGlassActionsRow) — the toolbar star is gone so
        // the action exists exactly once on this page.
        .fullScreenCover(item: $enlargedImage) { wrapper in
            FullscreenImageViewer(url: wrapper.url)
        }
        // Round 14 (B1): the visible Play failure.
        .alert(L("series.no_seasons_info"), isPresented: $showPlayFailure) {
            Button(L("common.ok"), role: .cancel) {}
        }
        .navigationDestination(item: $pendingRoute) { route in
            switch route {
            case .genre(let genre):
                SeriesGenreGridView(playlist: playlist, genre: genre)
            case .person(let person):
                PersonTitlesView(playlist: playlist, person: person)
            }
        }
        // Build 61 (B8, J2): More Like This target.
        .navigationDestination(item: $pendingSeriesDetail) { next in
            SeriesDetailView(playlist: playlist, series: next)
        }
        .task {
            // Build 61 (B8): parental guard for the series
            // detail-open path + NEW-badge clearing (R2/R5).
            if ParentalControlStore.shared.isBlocked(
                playlistId: playlist.id, type: "series", categoryId: currentSeries.categoryId
            ) {
                parentalBlocked = true
                showParentalPIN = true
            }
            FirstSeenStore.shared.markOpened(playlistId: playlist.id, itemKey: "series:\(currentSeries.seriesId)")
            if !currentSeries.seasonsLoaded {
                await fetchSeriesInfo()
            }
        }
        .task(id: currentSeries.seasonsLoaded) { await loadSeriesWatchedProgress() }
        .task(id: episodeWatchStore.version) { await loadSeriesWatchedProgress() }
        .task(id: currentSeries.seriesId) { await computeMoreLikeThis() }
        .sheet(isPresented: $showParentalPIN) {
            PINEntrySheet(message: L("parental.locked.enter_pin")) {
                if let categoryId = currentSeries.categoryId {
                    ParentalControlStore.shared.unlockForSession(
                        playlistId: playlist.id, type: "series", categoryId: categoryId
                    )
                }
                parentalBlocked = false
            }
        }
        .overlay {
            if parentalBlocked {
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(L("parental.locked.title"))
                        .font(.headline)
                    Button(L("parental.locked.enter_pin")) { showParentalPIN = true }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
            }
        }
        .task(id: watchHistory?.streamId) { await loadResumeEpisode() }
        .task(id: seasonPlayTargetKey) { await loadSelectedSeasonFirstEpisode() }
        .task(id: watchHistory?.streamId) { await loadNextUnwatched() }
        .task(id: seasons.first?.id) { await loadFirstEpisode() }
        .task(id: currentSeries.seasonsLoaded) {
            if currentSeries.seasonsLoaded {
                await detectNewEpisodes()
            }
        }
        .cinematicBackground()
    }

    /// Build 82 (item 3): the season currently on screen (the
    /// chip selection), when one is selected.
    private var selectedSeason: DBSeason? {
        guard let sid = selectedSeasonId else { return nil }
        return seasons.first { $0.id == sid }
    }

    /// Whether the saved resume point belongs to the season on
    /// screen. While the resume episode is still resolving, the
    /// answer stays "yes" — the legacy resume behaviour holds
    /// until the record proves it points at another season.
    private var resumeAppliesToSelectedSeason: Bool {
        guard hasResume else { return false }
        guard let sid = selectedSeasonId, let resume = resumeEpisode else { return true }
        return resume.seasonId == sid
    }

    /// Build 82 (item 3): Play targets the SELECTED season
    /// whenever the on-screen season is not the resume
    /// episode's season — the button must never silently play
    /// a different season than the one the user is looking at
    /// (the owner's build-81 video: chips on Season 3, the
    /// button still played Season 1 Episode 1).
    private var playTargetsSelectedSeason: Bool {
        selectedSeason != nil && !resumeAppliesToSelectedSeason
    }

    /// The big Play button's label (point 20): "Continue • Episode
    /// N" with the REAL episode number from the resumed episode's
    /// record; "Play Episode 1" when there is no history but the
    /// series has seasons; the previous generic labels otherwise.
    /// Round 14 (B8): a FINISHED latest episode (≥98%) labels the
    /// button with the NEXT episode instead of "Continue".
    /// Build 82 (item 3): when the on-screen season is not the
    /// resume season, the label names the SELECTED season and
    /// its first episode ("Play S3 · Episode 1").
    private var primaryActionTitle: String {
        if playTargetsSelectedSeason, let season = selectedSeason {
            if let ep = selectedSeasonFirstEpisode, let num = ep.episodeNum {
                return L("detail.play_season_episode", season.seasonNumber, num)
            }
            return L("detail.play_season", season.seasonNumber)
        }
        if hasResume {
            if resumeIsFinished {
                if let num = nextUnwatchedEpisode?.episodeNum {
                    return L("detail.continue_episode", num)
                }
                return L("detail.play_next_unwatched")
            }
            if let num = resumeEpisode?.episodeNum {
                return L("detail.continue_episode", num)
            }
            return L("detail.resume")
        }
        return seasons.isEmpty ? L("detail.watch") : L("detail.play_episode_1")
    }

    /// The download row's target: the resumed episode when there is
    /// one, else the first episode — nil (row omitted) until one
    /// actually resolves from the database.
    private var downloadTargetEpisode: DBEpisode? {
        resumeEpisode ?? firstEpisode
    }

    private func loadResumeEpisode() async {
        guard let history = watchHistory else { resumeEpisode = nil; return }
        let streamId = history.streamId
        let ep = try? await AppDatabase.shared.read { db in
            try DBEpisode.filter(Column("episodeId") == streamId || Column("id") == streamId).fetchOne(db)
        }
        resumeEpisode = ep ?? nil
    }

    private func loadFirstEpisode() async {
        // Round 14 (B8): the first episode comes from the chain
        // ordering — season 0 is skipped whenever a season ≥ 1
        // exists (it stays manually reachable in the episode list).
        let ep = try? await AppDatabase.shared.read { db in
            try SeriesPlaybackOrdering.firstEpisode(
                seriesId: currentSeries.seriesId,
                playlistId: playlist.id,
                db: db
            )
        }
        firstEpisode = ep ?? nil
    }

    /// B3: the next unwatched episode = the chain successor of the
    /// latest watched episode.
    private func loadNextUnwatched() async {
        guard let history = watchHistory else { nextUnwatchedEpisode = nil; return }
        let ctx = try? await AppDatabase.shared.read { db in
            try SeriesPlaybackOrdering.navigationContext(
                playlistId: playlist.id,
                playbackStreamId: history.streamId,
                seriesIdHint: String(currentSeries.seriesId),
                db: db
            )
        }
        nextUnwatchedEpisode = ctx?.next ?? nil
    }

    private func playNextUnwatched() {
        guard let next = nextUnwatchedEpisode else {
            // B1: a Play tap that resolves nothing must SAY so.
            showPlayFailure = true
            return
        }
        selectedEpisode = (next, nil)
        presentEpisodeOverlay(ep: next, history: nil)
    }

    /// Round 15 (C8): new-episode detection by episode-ID diff at
    /// detail open. The known set lives in UserDefaults per playlist
    /// + series; the FIRST open only records the baseline.
    private func detectNewEpisodes() async {
        let key = "series.known_episode_ids.\(playlist.id.uuidString).\(currentSeries.seriesId)"
        let sid = currentSeries.seriesId
        let pid = playlist.id
        let current = try? await AppDatabase.shared.read { db -> Set<String> in
            let seasonIds = try DBSeason
                .filter(Column("seriesId") == sid && Column("playlistId") == pid)
                .fetchAll(db)
                .map(\.id)
            guard !seasonIds.isEmpty else { return [] }
            let episodes = try DBEpisode
                .filter(seasonIds.contains(Column("seasonId")))
                .fetchAll(db)
            return Set(episodes.map { $0.episodeId ?? $0.id })
        }
        guard let current, !current.isEmpty else { return }
        let known = UserDefaults.standard.stringArray(forKey: key).map(Set.init)
        if let known {
            newEpisodeCount = current.subtracting(known).count
        } else {
            newEpisodeCount = 0
        }
        UserDefaults.standard.set(Array(current), forKey: key)
    }

    /// Round 14 (B8): enqueue EVERY episode of a season through the
    /// existing DownloadManager queue (the same call the per-episode
    /// DownloadButton makes).
    private func downloadSeason(_ season: DBSeason) {
        let pid = playlist.id
        let seriesName = currentSeries.name
        let seriesCover = currentSeries.cover
        let seriesIdString = String(currentSeries.seriesId)
        Task {
            let episodes = (try? await AppDatabase.shared.read { db in
                try DBEpisode
                    .filter(Column("seasonId") == season.id)
                    .fetchAll(db)
            }) ?? []
            for episode in SeriesPlaybackOrdering.orderedEpisodes(episodes) {
                let streamId = episode.episodeId ?? episode.id
                guard let url = PlaybackURLBuilder(playlist: playlist).seriesURL(
                    streamId: streamId,
                    containerExtension: episode.containerExtension
                ) else { continue }
                await DownloadManager.shared.enqueue(
                    id: DownloadManager.idFor(episode: pid, episodeId: streamId),
                    playlistId: pid,
                    streamId: streamId,
                    type: "episode",
                    title: episode.title ?? seriesName,
                    secondaryTitle: seriesName,
                    imageURL: episode.cover ?? seriesCover,
                    remoteURL: url,
                    containerExtension: episode.containerExtension,
                    seriesId: seriesIdString,
                    seasonNumber: season.seasonNumber,
                    episodeNumber: episode.episodeNum
                )
            }
        }
    }

    private func presentEpisodeOverlay(ep: DBEpisode, history: DBWatchHistory?) {
        Task {
            // Build 63 (item 6): bounded lookup, same rule as the
            // movie Play path — the tap can never die silently
            // inside this await again.
            async let localURLTask = DownloadManager.shared.localURL(
                forId: DownloadManager.idFor(episode: playlist.id, episodeId: ep.episodeId ?? ep.id),
                timeout: 1.5
            )
            // Build 64 (A3-ii): the navigation context is resolved
            // BEFORE presenting, in parallel with the download
            // lookup — the presented player's prev/next flags are
            // correct from the first frame and an episode tap
            // produces exactly ONE presentation / ONE engine load.
            // (Build 63 loaded neighbors in the presented player's
            // `.task` and RE-PRESENTED the same episode when they
            // landed — always, on first tap — paying the bounded
            // race twice and arming the retry ladder on a fresh
            // load; with churn teardown the second load could
            // no-op silently.)
            async let neighborsTask = fetchEpisodeNavigationContext(for: ep)
            let localURL = await localURLTask
            let ctx = await neighborsTask
            await MainActor.run {
                episodeNavPrevious = ctx?.previous
                episodeNavNext = ctx?.next
                presentEpisodeOverlay(ep: ep, history: history, localOverrideURL: localURL)
            }
        }
    }

    /// The DB navigation-context fetch, shared by the
    /// pre-presentation resolution and the state-only refresh.
    private func fetchEpisodeNavigationContext(for ep: DBEpisode) async -> SeriesPlaybackOrdering.NavigationContext? {
        let playId = ep.episodeId ?? ep.id
        return try? await AppDatabase.shared.read { db in
            try SeriesPlaybackOrdering.navigationContext(
                playlistId: playlist.id,
                playbackStreamId: playId,
                seriesIdHint: String(currentSeries.seriesId),
                db: db
            )
        }
    }

    private func presentEpisodeOverlay(ep: DBEpisode, history: DBWatchHistory?, localOverrideURL: URL?) {
        // A new episode's player must never render the PREVIOUS
        // episode's next-episode numbers: clear the pair here; the
        // presented player's neighbor load fills in this episode's.
        let remoteURL = PlaybackURLBuilder(playlist: playlist).seriesURL(
            streamId: ep.episodeId ?? ep.id, containerExtension: ep.containerExtension
        )
        // Build 63 (item 16): this guard was the episode path's
        // last silent death — a switch tap (episode list, next /
        // previous) whose URL failed to build vanished with no
        // feedback at all, the exact failure shape B1 outlawed on
        // the neighbouring paths. It now surfaces the same
        // play-failure alert they use.
        guard let url = localOverrideURL ?? remoteURL else {
            showPlayFailure = true
            return
        }
        let cover = ep.cover.flatMap { ArtworkURL.url(from: $0) } ?? currentSeries.cover.flatMap { ArtworkURL.url(from: $0) }
        playerOverlay.present(onDismiss: { selectedEpisode = nil }, skipDownloadCheck: localOverrideURL != nil, playlistId: playlist.id) {
            PlayerView(
                url: url,
                title: ep.title ?? L("detail.episode_fallback"),
                subtitle: currentSeries.name,
                artworkURL: cover,
                isLiveStream: false,
                playlistId: playlist.id,
                streamId: ep.episodeId ?? ep.id,
                type: "series",
                seriesId: String(currentSeries.seriesId),
                resumeTimeMs: history?.lastTimeMs,
                containerExtension: ep.containerExtension,
                canGoToPreviousEpisode: episodeNavPrevious != nil,
                canGoToNextEpisode: episodeNavNext != nil,
                onPreviousEpisode: { selectAdjacentEpisode(goBack: true) },
                onNextEpisode: { selectAdjacentEpisode(goBack: false) },
                // Round 8 (F-7): the inert `onNavigateToDetail: { _, _ in }`
                // that used to sit here is REMOVED, not wired — this
                // player is presented FROM SeriesDetailView, so the
                // title tap's "go to detail" has nowhere to go: closing
                // the player already lands on this series' detail. With
                // the parameter nil the title tap is inert by design
                // (the history/VOD shells pass real closures because
                // they are NOT already on the detail screen).
            )
            .task(id: ep.id) {
                await loadEpisodeNeighbors(for: ep)
            }
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Text(L("common.error"))
                .font(.headline)
            Text(error)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(L("common.try_again")) {
                Task { await fetchSeriesInfo() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contentScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHero(config: heroConfig, heroHeight: 380) { url in
                    enlargedImage = IdentifiableURL(url: url)
                }
                // Build 88 (Part 2-B): the approved mockup's
                // ambient accent under-glow beneath the hero —
                // a soft shadow only; the hero's own art chain
                // (DetailHero) is untouched.
                .shadow(color: AppTheme.accent.opacity(0.16), radius: 28, y: 14)

                // Round 14 (B1): genre chips navigate to the Series
                // tab's genre-filtered grid.
                GenreChipRow(genres: DetailFormatting.genreList(currentSeries.genre)) { genre in
                    pendingRoute = .genre(genre)
                }

                DetailActionBar(
                    primaryTitle: primaryActionTitle,
                    // Build 82 (item 3): in selected-season mode the
                    // resume subtitle/progress/icon do not apply —
                    // the button plays that season's first episode.
                    primarySubtitle: (playTargetsSelectedSeason || resumeIsFinished) ? nil : resumeSubtitle,
                    primaryIcon: hasResume && !playTargetsSelectedSeason ? "play.circle.fill" : "play.fill",
                    progress: (playTargetsSelectedSeason || resumeIsFinished) ? nil : resumeProgress,
                    onPrimary: {
                        if playTargetsSelectedSeason {
                            playSelectedSeasonFirstEpisode()
                        } else if hasResume && resumeIsFinished {
                            playNextUnwatched()
                        } else if hasResume {
                            resumeLatestEpisode()
                        } else {
                            playFirstEpisode()
                        }
                    },
                    trailerURL: trailerURL
                )

                // Round 14 (B3): "Play next unwatched" — shown while
                // the primary button resumes the current episode;
                // once that episode is finished the primary button
                // itself becomes this action (B8), so the row hides.
                if hasResume, !resumeIsFinished, let next = nextUnwatchedEpisode {
                    Button {
                        selectedEpisode = (next, nil)
                        presentEpisodeOverlay(ep: next, history: nil)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "forward.end.fill")
                                .font(.footnote.weight(.semibold))
                            Text(L("detail.play_next_unwatched"))
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                        }
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                                .fill(AppTheme.elevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                                .strokeBorder(AppTheme.cardBorderColor, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, -10)
                }

                // Build 78 (Style 1): favorite / download /
                // watchlist as the picked mockup's round glass
                // trio — the same three actions the square row, the
                // download button and the full-width Watch Later
                // row performed (Watch Later stays the SAME
                // WatchlistStore as movies, separate from
                // Favorites, with its own surface on the Series
                // tab). The download targets the resumed episode,
                // else episode 1 — and the slot stays empty until
                // one resolves, never a dead button.
                DetailGlassActionsRow(
                    isFavorite: isFavorite,
                    onToggleFavorite: { Task { await toggleFavorite() } },
                    isWatchlisted: watchlistStore.containsSeries(playlistId: playlist.id, seriesId: currentSeries.seriesId),
                    onToggleWatchlist: {
                        watchlistStore.toggleSeries(
                            playlistId: playlist.id, seriesId: currentSeries.seriesId,
                            title: currentSeries.name, imageURL: currentSeries.cover
                        )
                    }
                ) {
                    if let ep = downloadTargetEpisode,
                       let remoteURL = PlaybackURLBuilder(playlist: playlist).seriesURL(
                           streamId: ep.episodeId ?? ep.id,
                           containerExtension: ep.containerExtension
                       ) {
                        DownloadButton(
                            id: DownloadManager.idFor(episode: playlist.id, episodeId: ep.episodeId ?? ep.id),
                            playlistId: playlist.id,
                            streamId: ep.episodeId ?? ep.id,
                            type: "episode",
                            title: ep.title ?? currentSeries.name,
                            secondaryTitle: currentSeries.name,
                            imageURL: ep.cover ?? currentSeries.cover,
                            remoteURL: remoteURL,
                            containerExtension: ep.containerExtension,
                            seriesId: String(currentSeries.seriesId),
                            seasonNumber: ep.seasonId.split(separator: "_").last.flatMap { Int($0) },
                            episodeNumber: ep.episodeNum,
                            glassCircle: true
                        )
                    } else {
                        EmptyView()
                    }
                }
                .padding(.top, -10)

                // Build 61 (B8, J1): add to a custom favorite group.
                FavoriteGroupMenuItems(
                    playlist: playlist,
                    item: FavoriteGroupStore.Item(
                        type: "series",
                        itemId: String(currentSeries.seriesId),
                        title: currentSeries.name,
                        imageURL: currentSeries.cover
                    )
                )
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, -6)

                // Build 61 (B8, C5): watched-episode progress for
                // this series (auto ≥90% + manual toggles), shown
                // only when the series has episodes and at least one
                // is watched — otherwise nothing is claimed.
                if let progress = seriesWatchedProgress, progress.watched > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L("series.progress.title"))
                                .font(.footnote.weight(.semibold))
                            Spacer()
                            Text(L("series.progress.format", progress.watched, progress.total))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(progress.watched) / Double(max(progress.total, 1)))
                            .tint(AppTheme.accent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, -4)
                }

                // Build 78 (Style 1): the round-10 Episodes/About
                // segmented picker is GONE — the picked family is
                // one scroll, like the movie page: seasons +
                // episode cards first, then the About blocks
                // (Story, Director, Cast) below them. Nothing the
                // About tab held is lost; it renders under the
                // episodes whenever the record carries any of its
                // fields.
                // Build 81 (item 8): detail sections fade/rise in
                // once as the page assembles.
                seasonsSection
                    .sectionAppear()

                if hasAboutContent {
                    aboutSection
                        .sectionAppear()
                }

                // Build 61 (B8, J2): More Like This — same-genre
                // series from the loaded catalog, excluding this
                // one; hidden below 3 matches.
                if moreLikeThisSeries.count >= 3 {
                    moreLikeThisSection
                        // Build 81 (item 8): section entrance.
                        .sectionAppear()
                }
            }
            // Build 88 (F3): 48 → 96 — this page does not hide
            // the floating tab bar, so the last episode / More
            // Like This rows need full clearance under it.
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y > 240
        } action: { _, newValue in
            if showNavTitle != newValue {
                withAnimation(.easeInOut(duration: 0.18)) { showNavTitle = newValue }
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    /// Build 78: the About blocks render below the episode list
    /// when the record carries any of their fields (each block
    /// still omits itself when its own field is empty).
    private var hasAboutContent: Bool {
        func nonEmpty(_ s: String?) -> Bool {
            !(s?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        return nonEmpty(currentSeries.plot) || nonEmpty(currentSeries.director) || nonEmpty(currentSeries.cast)
    }

    /// The About content: Story / Director / Cast from the series
    /// record's own fields — each block omitted when its field is
    /// empty, exactly as before the tabs existed.
    @ViewBuilder
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let plot = currentSeries.plot?.trimmingCharacters(in: .whitespacesAndNewlines), !plot.isEmpty {
                DetailPlotBlock(plot: plot)
            }

            if let director = currentSeries.director?.trimmingCharacters(in: .whitespacesAndNewlines), !director.isEmpty {
                // C7: people names are tappable, as on movie detail.
                DetailInfoTextBlock(label: L("movie.director"), value: director) { person in
                    pendingRoute = .person(person)
                }
            }

            if let cast = currentSeries.cast?.trimmingCharacters(in: .whitespacesAndNewlines), !cast.isEmpty {
                // Build 78: cast renders as the family's shared
                // monogram row (as on the movie page), not name
                // chips — names stay tappable (C7 person route).
                DetailCastRow(names: DetailFormatting.peopleList(cast)) { person in
                    pendingRoute = .person(person)
                }
            }
        }
    }

    // MARK: - Build 61 (B8): watched progress, More Like This
    // (The C2 Watch Later toggle moved into the build-78 glass
    // action row — same WatchlistStore call, round form.)

    private var moreLikeThisSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader(title: L("detail.more_like_this"))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(moreLikeThisSeries) { item in
                        Button {
                            pendingSeriesDetail = item
                        } label: {
                            SeriesCard(
                                playlistId: playlist.id,
                                stream: item,
                                posterWidth: posterMetrics.searchCardWidth,
                                posterHeight: posterMetrics.searchCardHeight,
                                imageLoadProfile: .shelf
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
            .shelfEdgeFade()
        }
    }

    /// J2: same-genre series from the loaded catalog (genre overlap
    /// scored like the movie side), excluding this series.
    private func computeMoreLikeThis() async {
        let snapshot = contentStore.seriesItems.map(\.series)
        let source = currentSeries
        let result = await Task.detached(priority: .utility) { () -> [DBSeries] in
            let myGenres = Set(DetailFormatting.genreList(source.genre).map { $0.lowercased() })
            guard !myGenres.isEmpty else { return [] }
            var scored: [(series: DBSeries, score: Int, rating: Double)] = []
            for candidate in snapshot where candidate.seriesId != source.seriesId {
                let genres = Set(DetailFormatting.genreList(candidate.genre).map { $0.lowercased() })
                let overlap = genres.intersection(myGenres).count
                guard overlap > 0 else { continue }
                scored.append((
                    candidate, overlap,
                    ContentRating.normalizedRating10(rating: candidate.rating, rating5Based: candidate.rating5Based) ?? -1
                ))
            }
            scored.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.rating > b.rating
            }
            return Array(scored.prefix(15).map(\.series))
        }.value
        guard !Task.isCancelled else { return }
        moreLikeThisSeries = result
    }

    /// C5 (+R5): watched/total over the series' CURRENT episode set
    /// (the post-refresh DB rows — episodes added by a refresh count
    /// in the denominator as soon as they land). Watched = history
    /// ≥90% or a manual EpisodeWatchStore verdict.
    private func loadSeriesWatchedProgress() async {
        let pid = playlist.id
        let sid = currentSeries.seriesId
        let data = try? await AppDatabase.shared.read { db -> (episodes: [DBEpisode], history: [DBWatchHistory]) in
            let seasonIds = try DBSeason
                .filter(Column("seriesId") == sid && Column("playlistId") == pid)
                .fetchAll(db)
                .map(\.id)
            let episodes = seasonIds.isEmpty ? [] : try DBEpisode
                .filter(seasonIds.contains(Column("seasonId")))
                .fetchAll(db)
            let history = try DBWatchHistory
                .filter(Column("playlistId") == pid && Column("type") == "series" && Column("seriesId") == String(sid))
                .fetchAll(db)
            return (episodes, history)
        }
        guard let data else { return }
        let historyByKey = Dictionary(data.history.map { ($0.streamId, $0) }, uniquingKeysWith: { first, _ in first })
        var watched = 0
        for episode in data.episodes {
            let key = episode.episodeId ?? episode.id
            let manual = EpisodeWatchStore.shared.manualVerdict(playlistId: pid, episodeKey: key)
            let row = historyByKey[key]
            if EpisodeWatched.isWatched(manual: manual, lastTimeMs: row?.lastTimeMs ?? 0, durationMs: row?.durationMs ?? 0) {
                watched += 1
            }
        }
        guard !Task.isCancelled else { return }
        seriesWatchedProgress = data.episodes.isEmpty ? nil : (watched, data.episodes.count)
    }

    @ViewBuilder
    private var seasonsSection: some View {
        if seasons.isEmpty {
            Text(currentSeries.seasonsLoaded ? L("series.no_seasons_info") : L("series.loading_seasons"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("series.seasons"))
                        .font(.title3.weight(.bold))
                    // Round 15 (C8): new-episode badge from the
                    // episode-ID diff at detail open.
                    if newEpisodeCount > 0 {
                        Text(L("series.new_episodes_format", newEpisodeCount))
                            .font(AppTheme.fontBadge)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(AppTheme.accent))
                    }
                    Spacer()
                    if let sid = selectedSeasonId,
                       let s = seasons.first(where: { $0.id == sid }) {
                        // Build 78: the episode count moved to the
                        // Episodes header (counted from the loaded
                        // episode cards, as in the picked mockup) —
                        // it no longer shows twice on this page.
                        // Round 14 (B8): download the whole season
                        // through the existing download queue.
                        Button {
                            downloadSeason(s)
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("series.download_season"))
                    }
                }
                .padding(.horizontal, 16)

                DetailSeasonTabBar(seasons: seasons, selectedId: $selectedSeasonId)
                    .onAppear {
                        if selectedSeasonId == nil {
                            Task { selectedSeasonId = await resolveInitialSeasonId(from: seasons) }
                        }
                    }
                    .onChange(of: seasons) { _, newSeasons in
                        if selectedSeasonId == nil {
                            Task { selectedSeasonId = await resolveInitialSeasonId(from: newSeasons) }
                        }
                    }

                if let sid = selectedSeasonId {
                    // Round 11 (owner, build 47): the season `overview`
                    // line that used to render here is DELETED. On real
                    // panels that field carries the season's cover URL,
                    // so the page showed a raw `http://…_small.jpg`
                    // string as text under the season pill. The owner
                    // ordered it gone entirely — not rendered as text
                    // and not turned into an image in its place.
                    EpisodesPanel(
                        seasonId: sid,
                        playlist: playlist,
                        seriesId: String(currentSeries.seriesId),
                        seriesName: currentSeries.name,
                        seriesCover: currentSeries.cover
                    ) { ep, history in
                        selectedEpisode = (ep, history)
                        presentEpisodeOverlay(ep: ep, history: history)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func resumeLatestEpisode() {
        guard let history = watchHistory else {
            showPlayFailure = true
            return
        }
        Task {
            if let ep = try? await AppDatabase.shared.read({ db in
                try DBEpisode.filter(Column("episodeId") == history.streamId || Column("id") == history.streamId).fetchOne(db)
            }) {
                await MainActor.run {
                    selectedEpisode = (ep, history)
                    presentEpisodeOverlay(ep: ep, history: history)
                }
            } else {
                // B1: the resume target no longer resolves — say so
                // visibly instead of swallowing the tap.
                await MainActor.run { showPlayFailure = true }
            }
        }
    }

    /// Build 82 (item 3): the Play button's season target —
    /// reloads with the chip selection, and again once the
    /// series info lands (seasonsLoaded), which is when the
    /// season's episode rows reach the database.
    private var seasonPlayTargetKey: String {
        "\(selectedSeasonId ?? "none")|\(currentSeries.seasonsLoaded)"
    }

    private func loadSelectedSeasonFirstEpisode() async {
        guard let sid = selectedSeasonId else {
            selectedSeasonFirstEpisode = nil
            return
        }
        let ep = try? await AppDatabase.shared.read { db in
            let episodes = try DBEpisode
                .filter(Column("seasonId") == sid)
                .fetchAll(db)
            return SeriesPlaybackOrdering.orderedEpisodes(episodes).first
        }
        selectedSeasonFirstEpisode = ep ?? nil
    }

    /// Build 82 (item 3): Play in selected-season mode — plays
    /// the SELECTED season's first episode, and only that. If
    /// the season's episodes have not resolved yet it resolves
    /// at tap time; a season with no episodes fails VISIBLY
    /// (the B1 no-silent-failure surface) — it never falls
    /// back to another season's episode.
    private func playSelectedSeasonFirstEpisode() {
        if let ep = selectedSeasonFirstEpisode {
            selectedEpisode = (ep, nil)
            presentEpisodeOverlay(ep: ep, history: nil)
            return
        }
        guard let sid = selectedSeasonId else {
            showPlayFailure = true
            return
        }
        Task {
            let ep = try? await AppDatabase.shared.read { db in
                let episodes = try DBEpisode
                    .filter(Column("seasonId") == sid)
                    .fetchAll(db)
                return SeriesPlaybackOrdering.orderedEpisodes(episodes).first
            }
            await MainActor.run {
                if let ep {
                    selectedSeasonFirstEpisode = ep
                    selectedEpisode = (ep, nil)
                    presentEpisodeOverlay(ep: ep, history: nil)
                } else {
                    showPlayFailure = true
                }
            }
        }
    }

    private func playFirstEpisode() {
        Task {
            // B8: chain ordering — season 0 skipped when a regular
            // season exists.
            let first = try? await AppDatabase.shared.read { db in
                try SeriesPlaybackOrdering.firstEpisode(
                    seriesId: currentSeries.seriesId,
                    playlistId: playlist.id,
                    db: db
                )
            }
            await MainActor.run {
                if let first {
                    selectedEpisode = (first, nil)
                    presentEpisodeOverlay(ep: first, history: nil)
                } else {
                    // B1: visible failure, never a silent no-op.
                    showPlayFailure = true
                }
            }
        }
    }

    // Season covers are not rendered anywhere; prefetching them was only wasting network
    // traffic and battery (see the review finding). If the covers are shown in the future,
    // a prefetch exactly matching the render parameters must be re-added.

    /// Returns the season of the most recently watched episode; if there is no watched episode, it returns the first season.
    /// Round 15 (C8): "first" means the first REGULAR season — season
    /// 0's tab sits last and is never the landing tab when a regular
    /// season exists.
    private func resolveInitialSeasonId(from seasons: [DBSeason]) async -> String? {
        guard let history = watchHistory else {
            return SeriesPlaybackOrdering.orderedSeasons(seasons).first?.id
        }
        let streamId = history.streamId
        if let episode = try? await AppDatabase.shared.read({ db in
            try DBEpisode
                .filter(Column("episodeId") == streamId || Column("id") == streamId)
                .fetchOne(db)
        }), seasons.contains(where: { $0.id == episode.seasonId }) {
            return episode.seasonId
        }
        return seasons.first?.id
    }

    /// Build 64 (A3-ii): STATE-ONLY neighbor refresh for the
    /// already-presented player. Build 63 re-presented the same
    /// episode whenever the neighbors changed (always on first
    /// tap) — a second presentation and a second engine load for
    /// one tap. Neighbors are now resolved BEFORE presentation
    /// (see `presentEpisodeOverlay`); this refresh only keeps the
    /// state the prev/next closures read (`selectAdjacentEpisode`)
    /// current, and never presents.
    private func loadEpisodeNeighbors(for ep: DBEpisode) async {
        let ctx = await fetchEpisodeNavigationContext(for: ep)
        await MainActor.run {
            episodeNavPrevious = ctx?.previous
            episodeNavNext = ctx?.next
        }
    }

    private func selectAdjacentEpisode(goBack: Bool) {
        let target = goBack ? episodeNavPrevious : episodeNavNext
        guard let ep = target else { return }
        Task {
            let sid = ep.episodeId ?? ep.id
            let hist: DBWatchHistory? = try? await AppDatabase.shared.read { db in
                try DBWatchHistory
                    .filter(
                        Column("streamId") == sid && Column("playlistId") == playlist.id && Column("type") == "series"
                    )
                    .fetchOne(db)
            }
            await MainActor.run {
                selectedEpisode = (ep, hist)
                presentEpisodeOverlay(ep: ep, history: hist)
            }
        }
    }

    private func fetchSeriesInfo() async {
        isLoading = true
        errorMessage = nil
        let client = XtreamAPIClient(playlist: playlist)
        do {
            let info = try await client.getSeriesInfo(seriesId: series.seriesId)
            
            try await AppDatabase.shared.write { db in
                let episodesBySeason = info.episodesBySeasonNumber

                // Round 15 (C8): the fetched episode-ID set, for the
                // ghost cleanup after the saves below.
                var fetchedEpisodeIds = Set<String>()

                for (seasonNum, apiSeason) in info.resolvedSeasons {
                    let seasonId = DBSeason.scopedId(playlistId: playlist.id, seriesId: series.seriesId, seasonNumber: seasonNum)
                    let eps = episodesBySeason[seasonNum] ?? []

                    let dbSeason = DBSeason(
                        id: seasonId,
                        seasonNumber: seasonNum,
                        name: apiSeason?.name,
                        overview: apiSeason?.overview,
                        cover: apiSeason?.cover,
                        airDate: apiSeason?.airDate,
                        episodeCount: eps.isEmpty ? apiSeason?.episodeCount : eps.count,
                        voteAverage: apiSeason?.voteAverage,
                        seriesId: series.seriesId,
                        playlistId: playlist.id
                    )
                    try dbSeason.save(db)

                    for ep in eps {
                        let dbEp = DBEpisode(
                            id: DBEpisode.scopedId(playlistId: playlist.id, panelEpisodeId: ep.id),
                            episodeId: ep.id,
                            episodeNum: ep.episodeNum,
                            title: ep.title,
                            containerExtension: ep.containerExtension,
                            info: ep.info?.plot,
                            cover: ep.stillURLString,
                            duration: ep.info?.duration,
                            rating: ep.info?.rating,
                            seasonId: seasonId
                        )
                        fetchedEpisodeIds.insert(dbEp.id)
                        try dbEp.save(db)
                    }
                }

                // Round 15 (C8): ghost-episode cleanup — stored
                // episodes of THIS series (any of its seasons,
                // including seasons the panel no longer returns) that
                // are absent from the fetched set are deleted in the
                // same transaction, so a panel-side removal stops
                // haunting the episode list and prev/next chain.
                let storedSeasonIds = try DBSeason
                    .filter(Column("seriesId") == series.seriesId && Column("playlistId") == playlist.id)
                    .fetchAll(db)
                    .map(\.id)
                if !storedSeasonIds.isEmpty {
                    let stored = try DBEpisode
                        .filter(storedSeasonIds.contains(Column("seasonId")))
                        .fetchAll(db)
                    for stale in stored where !fetchedEpisodeIds.contains(stale.id) {
                        try stale.delete(db)
                    }
                }

                // Update series metadata in DB
                var updatedSeries = series
                updatedSeries.seasonsLoaded = true
                if let i = info.info {
                    updatedSeries.cast = i.cast
                    updatedSeries.director = i.director
                    updatedSeries.genre = i.genre
                    updatedSeries.plot = i.plot
                    updatedSeries.releaseDate = i.releaseDate
                    updatedSeries.rating = i.rating
                    updatedSeries.lastModified = i.lastModified
                    updatedSeries.rating5Based = i.rating5Based
                    updatedSeries.backdropPath = i.backdropPath?.first
                    updatedSeries.youtubeTrailer = i.youtubeTrailer
                    updatedSeries.episodeRunTime = i.episodeRunTime
                }
                try updatedSeries.update(db)
            }

            // B8: the store's season/episode counts now include this
            // series — refresh them for the tab shelves.
            await PlaylistContentStore.shared.refreshSeriesSeasonEpisodeCounts()
            // Build 61 (B8, R1/R5): record episode first-seen from
            // this fetched set — new episodes badge the series.
            let episodeKeys = (info.episodes ?? [:]).values.flatMap { eps in
                eps.compactMap { ep in ep.id.map { "episode:\(series.seriesId):\($0)" } }
            }
            if !episodeKeys.isEmpty {
                await FirstSeenStore.shared.record(playlistId: playlist.id, itemKeys: episodeKeys)
            }
            await MainActor.run { self.isLoading = false }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func toggleFavorite() async {
        do {
            try await AppDatabase.shared.write { db in
                if isFavorite {
                    try DBFavorite
                        .filter(Column("streamId") == series.seriesId && Column("playlistId") == playlist.id && Column("type") == "series")
                        .deleteAll(db)
                } else {
                    let fav = DBFavorite(streamId: series.seriesId, playlistId: playlist.id, type: "series")
                    try fav.insert(db)
                }
            }
            // Build 61 (B8, R6): snapshot for the unavailable state.
            if isFavorite {
                FavoriteSnapshotStore.shared.remove(playlistId: playlist.id, type: "series", streamId: series.seriesId)
            } else {
                FavoriteSnapshotStore.shared.record(playlistId: playlist.id, type: "series", streamId: series.seriesId, title: series.name, imageURL: series.cover)
            }
        } catch {
            Log.error("Series", "Failed to toggle favorite: \(error.localizedDescription)")
        }
    }

}

/// @Query + `.id(seasonId)` was resetting the ScrollView scroll position; when the season changes, the subscription is renewed in the same panel.
private final class SeasonEpisodesObserver: ObservableObject {
    @Published private(set) var episodes: [DBEpisode] = []
    /// It does not become true until the first publication arrives — so the "no episodes in this season" text doesn't
    /// flicker during loading, the panel first shows the loading state.
    @Published private(set) var hasLoaded = false
    private var cancellable: AnyCancellable?

    func load(seasonId: String, db: AppDatabase) {
        cancellable?.cancel()
        hasLoaded = false
        episodes = []
        cancellable = EpisodesRequest(seasonId: seasonId)
            .publisher(in: db)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in
                self?.episodes = list
                self?.hasLoaded = true
            }
    }

    deinit {
        cancellable?.cancel()
    }
}

/// Build 78 (Style 1): the wide-card episode thumbnail size —
/// ONE 16:9 size for the card render and the panel's prefetch, so
/// the Nuke request matches the surface exactly (the old portrait
/// 100×150 poster-metrics size belonged to the pre-card row).
private enum EpisodeCardMetrics {
    static let thumbWidth: CGFloat = 128
    static let thumbHeight: CGFloat = 72
}

struct EpisodesPanel: View {
    let seasonId: String
    let playlist: Playlist
    let seriesId: String
    let seriesName: String
    let seriesCover: String?
    var onEpisodeSelected: (DBEpisode, DBWatchHistory?) -> Void

    @Environment(\.appDatabase) private var appDatabase
    @StateObject private var observer = SeasonEpisodesObserver()

    var body: some View {
        Group {
            if !observer.hasLoaded {
                BrandedLoader(size: 28)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if observer.episodes.isEmpty {
                Text(L("series.no_episodes_in_season"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    // Build 78 (Style 1): the picked mockup's
                    // Episodes header — the title and the season's
                    // REAL episode count, counted from the loaded
                    // cards themselves.
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("detail.episodes"))
                            .font(.title3.weight(.bold))
                        Spacer()
                        Text(L("detail.episode_count_plural", observer.episodes.count))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    .padding(.horizontal, 16)

                    // Build 78: episodes are wide CARDS now —
                    // spaced surfaces, no divider rows.
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(observer.episodes, id: \.id) { episode in
                            EpisodeDetailRow(
                                playlist: playlist,
                                episode: episode,
                                seriesId: seriesId,
                                seriesName: seriesName,
                                seriesCover: seriesCover
                            ) { ep, history in
                                onEpisodeSelected(ep, history)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onChange(of: observer.episodes) { _, newValue in
                    let urls = newValue.compactMap(\.cover).compactMap { ArtworkURL.url(from: $0) }
                    ListImagePrefetch.start(urls: urls, width: EpisodeCardMetrics.thumbWidth, height: EpisodeCardMetrics.thumbHeight, contentMode: .fill, loadProfile: .grid)
                }
                .onAppear {
                    let urls = observer.episodes.compactMap(\.cover).compactMap { ArtworkURL.url(from: $0) }
                    ListImagePrefetch.start(urls: urls, width: EpisodeCardMetrics.thumbWidth, height: EpisodeCardMetrics.thumbHeight, contentMode: .fill, loadProfile: .grid)
                }
            }
        }
        .onAppear {
            observer.load(seasonId: seasonId, db: appDatabase)
        }
        .onChange(of: seasonId) { _, newId in
            observer.load(seasonId: newId, db: appDatabase)
        }
    }
}

private struct EpisodeDetailRow: View {
    let playlist: Playlist
    let episode: DBEpisode
    let seriesId: String
    let seriesName: String
    let seriesCover: String?
    var onStreamSelected: (DBEpisode, DBWatchHistory?) -> Void

    @Query<WatchHistoryRequest> private var watchHistory: DBWatchHistory?

    init(
        playlist: Playlist,
        episode: DBEpisode,
        seriesId: String,
        seriesName: String,
        seriesCover: String?,
        onStreamSelected: @escaping (DBEpisode, DBWatchHistory?) -> Void
    ) {
        self.playlist = playlist
        self.episode = episode
        self.seriesId = seriesId
        self.seriesName = seriesName
        self.seriesCover = seriesCover
        self.onStreamSelected = onStreamSelected
        _watchHistory = Query(WatchHistoryRequest(streamId: episode.episodeId ?? episode.id, playlistId: playlist.id, type: "series"), in: \.appDatabase)
    }

    private var remoteURL: URL? {
        PlaybackURLBuilder(playlist: playlist).seriesURL(
            streamId: episode.episodeId ?? episode.id,
            containerExtension: episode.containerExtension
        )
    }

    // Build 61 (B8, C5): watched verdict + manual toggle.
    @ObservedObject private var episodeWatchStore = EpisodeWatchStore.shared

    private var episodeKey: String { episode.episodeId ?? episode.id }

    private var historyWatched: Bool {
        guard let history = watchHistory else { return false }
        return EpisodeWatched.historyWatched(lastTimeMs: history.lastTimeMs, durationMs: history.durationMs)
    }

    private var isWatched: Bool {
        EpisodeWatched.isWatched(
            manual: episodeWatchStore.manualVerdict(playlistId: playlist.id, episodeKey: episodeKey),
            lastTimeMs: watchHistory?.lastTimeMs ?? 0,
            durationMs: watchHistory?.durationMs ?? 0
        )
    }

    /// Build 78 (Style 1): the thumbnail is the episode's OWN
    /// still. Build 81 (item 5a, owner override): an episode with
    /// NO still of its own now falls back to the SERIES cover —
    /// the owner explicitly ordered pictures on the cards ("كل
    /// الصور ماكو") over build 78's no-fallback rule; the styled
    /// number + title card renders only when the series has no
    /// cover either. (The parse side also widened — see
    /// XtreamEpisode.stillURLString — so far fewer episodes reach
    /// this fallback than in build 80.)
    private var stillURL: URL? {
        ArtworkURL.url(from: episode.cover)
    }

    /// Build 81 (item 5a): the series-cover fallback image.
    private var seriesCoverURL: URL? {
        ArtworkURL.url(from: seriesCover)
    }

    /// "EP 3" — a code, not prose: identical in every language
    /// (the same treatment the old S01E03 code had).
    private var episodeBadgeText: String? {
        episode.episodeNum.map { "EP \($0)" }
    }

    /// The record's own duration string ("42m"), when it has one.
    private var durationText: String? {
        guard let d = episode.duration?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return nil }
        return d
    }

    /// In-progress fraction for the card's progress bar — the
    /// same 2%…98% window the resume logic uses (a finished
    /// episode shows the Watched label instead, never a full bar).
    private var watchProgress: Double? {
        guard let history = watchHistory, history.durationMs > 0 else { return nil }
        let p = Double(history.lastTimeMs) / Double(history.durationMs)
        return (p > 0.02 && p < 0.98) ? p : nil
    }

    /// The episode's own title, unprefixed — the number rides the
    /// meta line and the fallback card now, not the title text.
    private var rawEpisodeTitle: String {
        let raw = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? L("detail.episode_fallback") : raw
    }

    var body: some View {
        // Build 78 (Style 1): the episode is a wide CARD — a
        // surface holding the episode's own 16:9 still, the
        // mockup's meta line and progress, and the same tap
        // targets, download button and watched context menu the
        // divider row had.
        HStack(alignment: .top, spacing: 12) {
            thumbnail

            textColumn

            if let remoteURL {
                DownloadButton(
                    id: DownloadManager.idFor(episode: playlist.id, episodeId: episode.episodeId ?? episode.id),
                    playlistId: playlist.id,
                    streamId: episode.episodeId ?? episode.id,
                    type: "episode",
                    title: rawEpisodeTitle,
                    secondaryTitle: seriesName,
                    imageURL: episode.cover ?? seriesCover,
                    remoteURL: remoteURL,
                    containerExtension: episode.containerExtension,
                    seriesId: seriesId,
                    // seasonId "<playlistUUID>_<seriesId>_<seasonNum>" — the last component
                    // is the season number. When it wasn't parsed, DownloadsView was sorting S02E01
                    // ahead of S01E02 (all of them counted as season 0).
                    seasonNumber: episode.seasonId.split(separator: "_").last.flatMap { Int($0) },
                    episodeNumber: episode.episodeNum,
                    compact: true
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .fill(AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(
                    watchProgress != nil ? AppTheme.accent.opacity(0.45) : AppTheme.cardBorderColor,
                    lineWidth: watchProgress != nil ? 1 : 0.5
                )
        )
        // Build 88 (Part 2-B): the approved mockup's lifted
        // card — a soft drop shadow under every episode card;
        // an in-progress episode additionally carries the
        // accent edge above (its progress bar rides the text
        // column, as before).
        .shadow(color: .black.opacity(0.30), radius: 10, y: 4)
        // Build 61 (B8, C5): manual watched toggle on the episode card.
        .contextMenu {
            Button {
                episodeWatchStore.setWatched(
                    !isWatched, playlistId: playlist.id,
                    episodeKey: episodeKey, historyWatched: historyWatched
                )
            } label: {
                Label(
                    isWatched ? L("series.mark_unwatched") : L("series.mark_watched"),
                    systemImage: isWatched ? "eye.slash" : "checkmark.circle"
                )
            }
        }
    }

    /// The card's 16:9 still box. With the episode's OWN still
    /// (or, build 81, the series cover standing in for it): the
    /// image + the mockup's accent-ringed play badge. With
    /// neither: the styled fallback — the episode's NUMBER +
    /// TITLE on the elevated surface. The EP badge/label rides
    /// the card's meta line in every variant.
    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            if let thumbURL = stillURL ?? seriesCoverURL {
                CachedImage(
                    url: thumbURL,
                    width: EpisodeCardMetrics.thumbWidth,
                    height: EpisodeCardMetrics.thumbHeight,
                    cornerRadius: AppTheme.smallCornerRadius,
                    contentMode: .fill,
                    iconName: "play.rectangle.fill",
                    loadProfile: .grid
                )

                ZStack {
                    Circle().fill(Color.black.opacity(0.35))
                    Circle().strokeBorder(AppTheme.accent, lineWidth: 1.5)
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                }
                .frame(width: 34, height: 34)
            } else {
                RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                    .fill(AppTheme.elevated)
                VStack(spacing: 3) {
                    if let episodeBadgeText {
                        Text(episodeBadgeText)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    Text(rawEpisodeTitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(width: EpisodeCardMetrics.thumbWidth, height: EpisodeCardMetrics.thumbHeight)
        // Round 14 (B1): the thumbnail is a tap target, like the
        // text block — the download button stays separate.
        .contentShape(Rectangle())
        .onTapGesture {
            onStreamSelected(episode, watchHistory)
        }
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            // The mockup's meta line: "EP 1 • 42m" — the episode
            // code in the accent, the record's own duration after
            // it, and the episode's real rating when it has one
            // (the old FlowMetaRow's contents, in card order).
            HStack(spacing: 6) {
                if let episodeBadgeText {
                    Text(episodeBadgeText)
                        .foregroundStyle(AppTheme.accent)
                }
                if let durationText {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(durationText)
                        .foregroundStyle(.secondary)
                }
                if ContentRating.displayText(episode.rating) != nil {
                    RatingLabel(rating: episode.rating, style: .compact)
                }
            }
            .font(.caption.weight(.semibold))

            // Build 88 (Part 2-B): the mockup's numbered title
            // ("1. Pilot") — the episode number leads, in the
            // accent; skipped when the record's own title already
            // starts with that number (some panels bake it in).
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let num = episode.episodeNum, !rawEpisodeTitle.hasPrefix("\(num).") {
                    Text("\(num).")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                }
                Text(rawEpisodeTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            // In-progress: the mockup's progress bar under the
            // title (it rode the thumbnail's bottom edge before).
            if let watchProgress {
                ProgressView(value: watchProgress)
                    .tint(AppTheme.accent)
            }

            // Build 61 (B8, C5): the WATCHED mark uses the
            // C5 rule — history at ≥90% or a manual toggle in
            // EpisodeWatchStore (context menu above). This is
            // deliberately separate from the ≥98% resume/
            // finished threshold used by the player shells.
            if isWatched {
                Label(L("detail.watched"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else if let history = watchHistory, history.durationMs > 0 {
                let progress = Double(history.lastTimeMs) / Double(history.durationMs)
                if progress > 0.02 {
                    let remainingMs = history.durationMs - history.lastTimeMs
                    Label(L("detail.remaining_format", formatWatchMs(remainingMs)), systemImage: "play.circle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.accent)
                        .labelStyle(.titleAndIcon)
                }
            }

            if let plot = episode.info?.trimmingCharacters(in: .whitespacesAndNewlines), !plot.isEmpty {
                Text(plot)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            onStreamSelected(episode, watchHistory)
        }
    }

    private func formatWatchMs(_ ms: Int) -> String {
        let totalSeconds = max(ms, 0) / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}


// MARK: - Series genre grid (round 14, B1)

/// Landing surface for a series detail page's genre chip: the whole
/// visible series catalog in the standard category grid, with the
/// tapped genre pre-applied to its existing genre filter.
struct SeriesGenreGridView: View {
    let playlist: Playlist
    let genre: String

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @State private var displayItems: [SeriesWithCategory] = []

    var body: some View {
        SeriesCategoryContent(playlist: playlist, items: displayItems, initialGenre: genre)
            .equatable()
            .navigationTitle(genre)
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.hidden, for: .tabBar)
            .task(id: contentStore.streamsLoaded) { await recompute() }
            .task(id: hiddenStore.hiddenIds(playlistId: playlist.id, type: "series")) { await recompute() }
            .cinematicBackground()
    }

    private func recompute() async {
        guard playlist.id == contentStore.activePlaylistId else { displayItems = []; return }
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "series")
        displayItems = contentStore.seriesItems.filter { !hidden.contains($0.series.categoryId ?? "") }
    }
}

// MARK: - Build 61 (B8, C2): Series Watch Later shelf + surface

/// The Series tab's Watch Later shelf — the mirror of the Movies
/// tab's `WatchlistShelf`, fed by the SAME `WatchlistStore`.
// Build 88 (Part 2-B): WatchlistSeriesShelf was replaced by the shared
// CatalogShelfRow in SeriesView — see Views/CatalogComponents.swift.

/// Every watch-later series for this playlist, resolved against the
/// loaded catalog — plus the R6 unavailable entries (vanished from
/// the catalog, kept from their snapshots, marked, removable).
struct WatchlistSeriesView: View {
    let playlist: Playlist

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var watchlistStore = WatchlistStore.shared
    @Environment(\.posterMetrics) private var posterMetrics

    private var seriesList: [DBSeries] {
        let ids = watchlistStore.seriesIds(playlistId: playlist.id)
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        var found: [Int: DBSeries] = [:]
        for item in contentStore.seriesItems where wanted.contains(item.series.seriesId) {
            found[item.series.seriesId] = item.series
        }
        return ids.compactMap { found[$0] }
    }

    private var unavailableEntries: [(id: Int, title: String, imageURL: String?)] {
        let ids = watchlistStore.seriesIds(playlistId: playlist.id)
        let available = Set(seriesList.map(\.seriesId))
        let snapshots = watchlistStore.snapshots(playlistId: playlist.id)
        return ids.filter { !available.contains($0) }.map { id in
            let snap = snapshots["series:\(id)"]
            return (id, snap?.first ?? L("groups.unavailable"), snap?.last.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    var body: some View {
        Group {
            if seriesList.isEmpty && unavailableEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bookmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(L("watchlist.empty"))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: posterMetrics.gridRowSpacing) {
                        ForEach(seriesList) { series in
                            NavigationLink {
                                SeriesDetailView(playlist: playlist, series: series)
                            } label: {
                                SeriesCard(
                                    playlistId: playlist.id,
                                    stream: series,
                                    posterWidth: posterMetrics.categoryGridPosterWidth,
                                    posterHeight: posterMetrics.categoryGridPosterHeight,
                                    imageLoadProfile: .grid
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()

                    if !unavailableEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("groups.unavailable"))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.secondary)
                            ForEach(unavailableEntries, id: \.id) { entry in
                                HStack(spacing: 12) {
                                    CachedImage(
                                        url: entry.imageURL.flatMap { ArtworkURL.url(from: $0) },
                                        width: 44, height: 44,
                                        cornerRadius: AppTheme.smallCornerRadius,
                                        iconName: "play.tv"
                                    )
                                    Text(entry.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(2)
                                    Spacer(minLength: 8)
                                    Button(role: .destructive) {
                                        watchlistStore.toggleSeries(playlistId: playlist.id, seriesId: entry.id)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .navigationTitle(L("watchlist.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .cinematicBackground()
    }
}
