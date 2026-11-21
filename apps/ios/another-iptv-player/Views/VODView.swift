import Combine
import SwiftUI
import GRDBQuery
import GRDB

/// Combined recompute trigger for `VODView` (round 8, audit A2 — the
/// `HomeRecomputeToken` pattern): one Equatable token over both inputs
/// `recomputeFilter()` reads, so the two passes run once per real change
/// instead of once per `.task(id:)` modifier.
private struct VODRecomputeToken: Equatable {
    let loaded: Bool
    let hidden: Set<String>
    /// Round 20 (R20-5): the VOD row count, so the pass re-runs the
    /// moment the VOD fetch publishes (the store publishes live →
    /// vod → series progressively) instead of waiting for
    /// `streamsLoaded`, which only flips after the LAST type lands.
    var vodCount: Int = 0
    var rankingsStamp: String = ""
    /// Saved category drag order (CategoryOrderStore): a reorder in
    /// the picker must re-run the pass that sorts the shelves.
    var order: [String] = []
}

struct VODView: View {
    let playlist: Playlist
    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @ObservedObject private var orderStore = CategoryOrderStore.shared
    @ObservedObject private var watchlistStore = WatchlistStore.shared
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    @State private var pendingMovieDetail: DBVODStream?
    /// Round 15 (C12): bumped on every tab appearance so the identity
    /// shelves replay the LIGHT entrance on tab return (the shared
    /// ShelfEntranceModifier's replay token).
    @State private var shelfReplayToken = 0
    /// Round 15 (C7): franchise groups (≥2 members) computed in the
    /// recompute pass — base title, display title, members in
    /// release order.
    @State private var franchiseGroups: [FranchiseGroup] = []
    /// Full `added`-desc ordering (visible categories only) feeding
    /// the paginated Newest grid — round 14 (B7) lifts the old
    /// silent 60-item cap.
    @State private var newestAll: [DBVODStream] = []
    @State private var newestVisibleCount = 90
    private static let newestPageSize = 90

    private var pickerEntries: [CategoryPickerSheet.Entry] {
        // Build 61 (B8, Z6): empty categories are not jump targets
        // unless the user shows empty categories.
        let visible = EmptyCategoryVisibility.visible(contentStore.vodCategories) {
            contentStore.vodStreamsByCategoryId[$0.id]?.count ?? 0
        }
        return orderStore.applyOrder(visible, playlistId: playlist.id, type: "vod") { $0.id }.map { cat in
            CategoryPickerSheet.Entry(
                id: cat.id,
                name: cat.name,
                count: contentStore.vodStreamsByCategoryId[cat.id]?.count ?? 0
            )
        }
    }

    // Round 5: the native `.searchable` is GONE (same treatment Live got
    // in round 3) — the tab's ONE search entry is the HomeSearchBar in
    // the header, opening the global SearchView. In-tab shelf filtering
    // went with it; All Movies and the category screens keep their own
    // search fields.
    // Build 80 (item 4) SUPERSEDES the round-5 note: the header now
    // holds a REAL CatalogSearchField filtering this tab in place.

    // Round 5: unified content pattern — filter chips.
    // Round 8 (D-4/D-5): the Favorites and History chips were removed —
    // they duplicated the nav-bar star's FavoritesView and the Continue
    // Watching row, which are now the ONE entry for each. Remaining
    // chips are pure orderings: All (shelves) and Newest (the catalog's
    // `added` ordering, extended cut). Their grids/queries went too.
    @State private var selectedChip: ContentChip = .all
    /// Build 65 (inside-sections): the category chip selection —
    /// nil shows the shelf stack; a category id swaps it for that
    /// category's poster grid.
    @State private var selectedCategoryId: String? = nil
    @State private var categoryVisibleCount = 90

    // The filtering results are computed in the background; only the assignment is made on the main thread
    @State private var displayCategories: [DBCategory] = []
    @State private var displayItemsByCategory: [String: [VODWithCategory]] = [:]
    // Build 80 (item 12): the deduped SHELF presentation of the
    // category rails — chips and per-category grids keep the full
    // display data above; only the shelves render from these.
    @State private var shelfCategories: [DBCategory] = []
    @State private var shelfItemsByCategory: [String: [VODWithCategory]] = [:]
    @State private var recentlyAddedVODs: [DBVODStream] = []
    // Build 90: the old `newestVODs` state was removed — it was
    // computed every recompute pass and read NOWHERE (the Newest
    // grid paginates `newestAll`; the shelves use
    // recentlyAddedVODs). Dead state, dead per-pass work.
    @State private var topRatedVODs: [DBVODStream] = []
    /// Build 88: the NEW-chip membership — the newest-added slice
    /// of the catalog (the first 60 of the full `added`-desc
    /// ordering computed in recomputeFilter; plan D2: newest-added
    /// to the catalog, not release year).
    @State private var newMovieIds: Set<Int> = []

    init(playlist: Playlist) {
        self.playlist = playlist
    }

    @State private var showingCategoryPicker = false
    @State private var pendingScrollTarget: String? = nil
    // Build 61 fixer (O9): scroll restoration for the Movies shelf
    // list — the category shelf at the top anchor, persisted per
    // playlist via ScrollAnchorStore. Applies to the All (shelves)
    // chip only; the Newest grid keeps its own behaviour.
    @State private var scrollAnchorID: String? = nil
    // Build 80 (item 4): REAL in-tab search state. The tab's old
    // "search bar" was HomeSearchBar — a Button styled as a field
    // that only opened the global SearchView sheet; the tab itself
    // held no query and filtered nothing (owner: "البحث مو شغال").
    @State private var tabSearchText = ""
    @State private var tabDebouncedQuery = ""
    @State private var tabSearchResults: [VODWithCategory] = []
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
                        Text(contentStore.loadingMessage ?? L("vod.empty.preparing"))
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
                        Image(systemName: "film")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(L("live.empty.no_category"))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // Build 89 (item 3): the header (search field +
                // count + chips) is the FIRST element of the scroll
                // content — the owner ordered the top block to move
                // with scrolling. This is NOT the build-80 construct
                // that left the field dead in build 81:
                // (1) the header sits OUTSIDE the ScrollViewReader —
                // the reader wraps only the content branches below
                // it, so no scrollTo/anchor machinery touches it;
                // (2) the bound .scrollPosition(id:) anchor and
                // restoreScrollAnchor's position re-assertion are
                // GONE — restoration is a one-shot proxy.scrollTo
                // fired on appear / chip / category changes only,
                // and top-shelf persistence is a passive visibility
                // report (onScrollTargetVisibilityChange on the
                // shelves stack) that never moves the scroll view;
                // (3) the header's tree position is fixed — first
                // child of the content stack, outside every
                // conditional branch — so the recompute pass cannot
                // churn the field's identity. The search wiring
                // (the debounce + filter tasks on the outer Group)
                // is byte-identical to build 88.
                ScrollView {
                    VStack(spacing: 0) {
                        tabHeader

                        ScrollViewReader { proxy in
                        VStack(spacing: 0) {
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
                            // Round 14 (B7): the Movies identity —
                            // a featured movie hero at the very top
                            // of the tab.
                            if let featured = featuredMovie {
                                MovieFeaturedHero(playlist: playlist, movie: featured) {
                                    pendingMovieDetail = featured
                                } onPlay: {
                                    presentFeaturedPlayer(featured)
                                }
                            }

                            // Build 65 (inside-sections design):
                            // category chips under the hero — the
                            // REAL provider categories. A selection
                            // swaps the shelves for that category's
                            // poster grid (see below); All restores
                            // them.
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
                                typeFilter: "vod",
                                destination: {
                                    WatchHistoryListView(playlist: playlist, typeFilter: "vod") { item in
                                        presentHistoryPlayer(item)
                                    }
                                },
                                onPlay: { item in
                                    presentHistoryPlayer(item)
                                }
                            )

                            // Build 88 (plan Part 2-C): the catalog
                            // shelves lead with Recently Added, then
                            // Top Rated, then the per-category
                            // shelves below.
                            if !recentlyAddedVODs.isEmpty {
                                RecentlyAddedVODShelf(playlist: playlist, items: recentlyAddedVODs, newMovieIds: newMovieIds)
                            }

                            if topRatedVODs.count >= 3 {
                                TopMoviesShelf(playlist: playlist, items: topRatedVODs, replayToken: shelfReplayToken)
                            }

                            if !watchlistMovies.isEmpty {
                                WatchlistShelf(playlist: playlist, items: watchlistMovies, newMovieIds: newMovieIds)
                            }

                            if !franchiseGroups.isEmpty {
                                MovieCollectionsShelf(playlist: playlist, groups: franchiseGroups)
                            }

                            LazyVStack(spacing: 0) {
                                ForEach(shelfCategories) { category in
                                    VODCategoryShelfRow(
                                        playlist: playlist,
                                        category: category,
                                        items: shelfItemsByCategory[category.id] ?? [],
                                        isStreamsLoading: !contentStore.streamsLoaded,
                                        newMovieIds: newMovieIds
                                    )
                                    .equatable()
                                    .id(category.id)
                                }
                            }
                            .scrollTargetLayout()
                            // Build 89 (item 3): passive top-shelf
                            // tracking for the O9 restore — the first
                            // visible shelf id is saved exactly as
                            // the build-61 bound anchor saved it, but
                            // this report never moves the scroll view
                            // (the bound .scrollPosition(id:) is
                            // gone; see the note at the branch top).
                            // Guarded to the All chip, as the old
                            // save was — other branches never persist
                            // an anchor from this stack.
                            .onScrollTargetVisibilityChange(idType: String.self) { visibleIds in
                                if selectedChip == .all, let first = visibleIds.first {
                                    scrollAnchorID = first
                                    ScrollAnchorStore.save(first, surface: "movies", playlistId: playlist.id)
                                }
                            }
                            } // Build 65: end of the All (shelves) branch of the category-chip swap.
                        case .newest:
                            newestGrid
                        }
                        }
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
                        // Build 89 (item 3): O9 restoration — a
                        // one-shot scrollTo on appearance and on
                        // chip/category changes only; it never fires
                        // during scrolling, so it cannot fight the
                        // user or the search field (see the note at
                        // the top of this branch).
                        .onAppear { restoreScrollAnchor(proxy: proxy) }
                        .onChange(of: displayCategories.map(\.id)) { _, _ in restoreScrollAnchor(proxy: proxy) }
                        .onChange(of: selectedChip) { _, _ in restoreScrollAnchor(proxy: proxy) }
                        } // ScrollViewReader
                    }
                }
                .refreshable {
                    // Independent Task: so the refreshable cancellation doesn't propagate to the requests (see LiveStreamsView).
                    let work = Task { await contentStore.refreshFromNetwork(playlist: playlist, only: .vod) }
                    await work.value
                }
                // Build 88 (F3): bottom scroll clearance so the
                // floating tab bar never covers the last shelf /
                // grid row of this tab.
                .contentMargins(.bottom, 40, for: .scrollContent)
            }
        }
        .toolbar {
            // Round 8 (D-3): NO toolbar grid icon — AllVODView was
            // reachable twice from this tab (here + the Top Movies
            // shelf's "See all"). The shelf entry stays as the ONE path.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingCategoryPicker = true
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(.body.weight(.semibold))
                }
                .disabled(contentStore.vodCategories.isEmpty)
                .accessibilityLabel(L("list.jump_to_category"))
            }
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerSheet(
                title: L("category_picker.title"),
                entries: pickerEntries,
                playlistId: playlist.id,
                type: "vod"
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
        .task(id: VODRecomputeToken(
            loaded: contentStore.streamsLoaded,
            hidden: hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod"),
            vodCount: contentStore.vodStreams.count,
            // Round 14 (B10): the shared rankings land asynchronously
            // after the catalog — their arrival must re-run the pass
            // that filters them by visible categories.
            rankingsStamp: "\(contentStore.sharedTopRatedMovies.count)-\(contentStore.sharedNewestMovies.count)-\(contentStore.sharedTopRatedMovies.first?.streamId ?? -1)-\(contentStore.sharedNewestMovies.first?.streamId ?? -1)",
            order: orderStore.orderedIds(playlistId: playlist.id, type: "vod")
        )) { await recomputeFilter() }
        .onAppear { shelfReplayToken += 1 }
        // Build 80 (item 4): 280 ms debounce (the app pattern), then
        // the detached filter pass over the tab's display set.
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
        .navigationDestination(item: $pendingMovieDetail) { movie in
            MovieDetailView(playlist: playlist, movie: movie)
        }
        .cinematicBackground()
    }

    /// Build 80 (item 4): recompute triggers for the in-tab search —
    /// the query plus the display-set identity (catalog load / chip
    /// filters republishing display values re-run the filter).
    private var tabSearchToken: String {
        "\(tabDebouncedQuery)#\(displayCategories.count)#\(contentStore.vodStreams.count)#\(contentStore.streamsLoaded)"
    }

    /// Build 80 (item 4): filter the tab's OWN display set (the same
    /// items the shelves/grids show — hidden/parental rules already
    /// applied by recomputeFilter) by title, in ONE detached pass.
    private func recomputeTabSearch() async {
        let q = tabDebouncedQuery
        guard !q.isEmpty else { tabSearchResults = []; return }
        let categories = displayCategories
        let byCategory = displayItemsByCategory
        let result = await Task.detached(priority: .userInitiated) { () -> [VODWithCategory] in
            var seen = Set<Int>()
            var matches: [VODWithCategory] = []
            for category in categories {
                for item in byCategory[category.id] ?? [] {
                    guard seen.insert(item.stream.streamId).inserted else { continue }
                    if CatalogTextSearch.matchesSectionFuzzy(search: q, text: item.stream.name) {
                        matches.append(item)
                    }
                }
            }
            return matches
        }.value
        guard !Task.isCancelled, tabDebouncedQuery == q else { return }
        tabSearchResults = result
    }

    /// Build 90: when one of the tab's own grids (Newest,
    /// category, in-tab search) pages in its next slice, warm
    /// that slice's posters with the grid's exact render request
    /// (moviePosterCard's chain at grid size, .fill, .grid) —
    /// VODCategoryContent's grids always did this via loadMore;
    /// the tab's own grids paged in cold.
    private func prefetchGridPosters(_ movies: [DBVODStream], startingAt start: Int) {
        guard start < movies.count else { return }
        let urls = movies.dropFirst(start).prefix(ListImagePrefetch.maxBatch)
            .compactMap { ArtworkURL.url(from: $0.streamIcon) ?? ArtworkURL.url(from: $0.backdropPath) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.categoryGridPosterWidth,
            height: posterMetrics.categoryGridPosterHeight,
            contentMode: .fill,
            loadProfile: .grid
        )
    }

    /// Build 80 (item 4): the in-tab search results — the tab's own
    /// poster grid idiom (same cards, same detail destination,
    /// 90-per-page BrandedLoader pagination as the other grids).
    private var tabSearchResultsGrid: some View {
        Group {
            if tabSearchResults.isEmpty {
                ContentUnavailableView.search(text: tabDebouncedQuery)
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: posterGridColumns, spacing: posterMetrics.gridRowSpacing) {
                    ForEach(Array(tabSearchResults.prefix(tabSearchVisibleCount).enumerated()), id: \.element.id) { index, item in
                        NavigationLink {
                            MovieDetailView(playlist: playlist, movie: item.stream)
                        } label: {
                            moviePosterCard(
                                item.stream,
                                posterWidth: posterMetrics.categoryGridPosterWidth,
                                posterHeight: posterMetrics.categoryGridPosterHeight,
                                imageLoadProfile: .grid,
                                isNew: newMovieIds.contains(item.stream.streamId)
                            )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .onAppear {
                            if index >= tabSearchVisibleCount - 15 {
                                let oldCount = tabSearchVisibleCount
                                tabSearchVisibleCount = min(tabSearchVisibleCount + 90, tabSearchResults.count)
                                if tabSearchVisibleCount > oldCount {
                                    prefetchGridPosters(tabSearchResults.map(\.stream), startingAt: oldCount)
                                }
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
    /// the list. Build 89 (item 3): the jump is a one-shot
    /// `proxy.scrollTo` — the build-61 bound `.scrollPosition(id:)`
    /// assignment (which re-asserted the position on every publish)
    /// is gone, so the equality guard went with it; scrolling to
    /// the anchor already on screen is a visual no-op.
    private func restoreScrollAnchor(proxy: ScrollViewProxy) {
        guard selectedChip == .all,
              !displayCategories.isEmpty,
              let saved = ScrollAnchorStore.anchor(surface: "movies", playlistId: playlist.id),
              displayCategories.contains(where: { $0.id == saved })
        else { return }
        scrollAnchorID = saved
        proxy.scrollTo(saved, anchor: .top)
    }

    /// Round 5 elite header, reordered in round 7 by the owner's direct
    /// order ("search must be at the top"): the tab's ONE search entry
    /// is the FIRST element under the title, then the REAL visible
    /// movie total, then the filter chips.
    private var tabHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Build 80 (item 4): a REAL text field (CatalogSearchField,
            // the same field global search uses) bound to the tab's own
            // query — typing filters this tab's catalog below.
            // Build 89 (item 3): the header scrolls with the content
            // (owner's order); the screen-margin insets are unchanged
            // (the chips row and the count line already carry their
            // own 16pt insets).
            CatalogSearchField(text: $tabSearchText, placeholder: L("home.search_placeholder"))
            .padding(.top, 4)
            .padding(.horizontal, 16)

            Text(L("home.count_movies", CatalogCountFormatter.string(displayCategories.reduce(0) { $0 + (displayItemsByCategory[$1.id]?.count ?? 0) })))
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

    private var posterGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    @Environment(\.posterMetrics) private var posterMetrics

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
                    ForEach(Array(newestAll.prefix(newestVisibleCount).enumerated()), id: \.element.id) { index, movie in
                        NavigationLink {
                            MovieDetailView(playlist: playlist, movie: movie, queue: newestAll)
                        } label: {
                            moviePosterCard(
                                movie,
                                posterWidth: posterMetrics.categoryGridPosterWidth,
                                posterHeight: posterMetrics.categoryGridPosterHeight,
                                imageLoadProfile: .grid,
                                isNew: newMovieIds.contains(movie.streamId)
                            )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        // Round 14 (B7): paginate like
                        // VODCategoryContent — the next page loads
                        // as the end approaches, no silent cap.
                        .onAppear {
                            if index >= newestVisibleCount - 15 {
                                let oldCount = newestVisibleCount
                                newestVisibleCount = min(newestVisibleCount + Self.newestPageSize, newestAll.count)
                                if newestVisibleCount > oldCount {
                                    prefetchGridPosters(newestAll, startingAt: oldCount)
                                }
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

    /// Build 65 (inside-sections): the poster grid shown when a
    /// category chip is selected — the category's OWN items (the
    /// same `displayItemsByCategory` bucket its shelf renders),
    /// in the tab's grid language, paginated like the Newest grid.
    /// In-section search behavior is untouched (the tab's search
    /// sheet still searches the full catalog, build 63/64).
    private func categoryGrid(for category: DBCategory) -> some View {
        let items = displayItemsByCategory[category.id] ?? []
        let queue = items.map(\.stream)
        return Group {
            if items.isEmpty {
                ContentUnavailableView(
                    L("list.no_result"),
                    systemImage: "film.slash"
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: posterGridColumns, spacing: posterMetrics.gridRowSpacing) {
                    ForEach(Array(items.prefix(categoryVisibleCount).enumerated()), id: \.element.id) { index, item in
                        NavigationLink {
                            MovieDetailView(playlist: playlist, movie: item.stream, queue: queue)
                        } label: {
                            moviePosterCard(
                                item.stream,
                                posterWidth: posterMetrics.categoryGridPosterWidth,
                                posterHeight: posterMetrics.categoryGridPosterHeight,
                                imageLoadProfile: .grid,
                                isNew: newMovieIds.contains(item.stream.streamId)
                            )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .onAppear {
                            if index >= categoryVisibleCount - 15 {
                                let oldCount = categoryVisibleCount
                                categoryVisibleCount = min(categoryVisibleCount + 90, items.count)
                                if categoryVisibleCount > oldCount {
                                    prefetchGridPosters(items.map(\.stream), startingAt: oldCount)
                                }
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

    /// B7 featured hero pick: the top-rated movie that has artwork,
    /// else the newest movie with artwork (the B6 fallback rule) —
    /// real records only.
    private var featuredMovie: DBVODStream? {
        if let top = topRatedVODs.first(where: { $0.backdropPath != nil || $0.streamIcon != nil }) {
            return top
        }
        return recentlyAddedVODs.first(where: { $0.backdropPath != nil || $0.streamIcon != nil })
    }

    /// C7: the watchlist shelf's movies — the store's ids resolved
    /// against the loaded catalog, in watchlist order.
    private var watchlistMovies: [DBVODStream] {
        let ids = watchlistStore.movieIds(playlistId: playlist.id)
        guard !ids.isEmpty else { return [] }
        // One pass over the catalog collecting only the wanted ids
        // (the watchlist is small; the catalog may not be).
        let wanted = Set(ids)
        var found: [Int: DBVODStream] = [:]
        for item in contentStore.vodStreams where wanted.contains(item.stream.streamId) {
            found[item.stream.streamId] = item.stream
        }
        return ids.compactMap { found[$0] }
    }

    private func presentFeaturedPlayer(_ movie: DBVODStream) {
        playerOverlay.present(playlistId: playlist.id) {
            VODPlayerShell(
                playlist: playlist,
                queue: topRatedVODs.isEmpty ? [movie] : topRatedVODs,
                initialMovie: movie,
                initialResumeMs: nil
            )
        }
    }

    /// Round 5: with the native search bar removed there is no in-tab
    /// query anymore — the display set is simply every visible category
    /// with its streams, exactly what the old empty-query path produced
    /// (the same simplification Live got in round 3).
    private func recomputeFilter() async {
        guard playlist.id == contentStore.activePlaylistId else {
            displayCategories = []; displayItemsByCategory = [:]; recentlyAddedVODs = []; topRatedVODs = []; newestAll = []; newMovieIds = []; franchiseGroups = []; shelfCategories = []; shelfItemsByCategory = [:]; return
        }
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod")
        let allCats = orderStore.applyOrder(
            contentStore.vodCategories.filter { !hidden.contains($0.id) },
            playlistId: playlist.id, type: "vod"
        ) { $0.id }
        let allByCategory = contentStore.vodStreamsByCategoryId

        // Build 61 (B8, Z6): empty categories hidden by default once
        // the catalog is loaded (Appearance toggle restores them).
        displayCategories = contentStore.streamsLoaded
            ? EmptyCategoryVisibility.visible(allCats) { allByCategory[$0.id]?.count ?? 0 }
            : allCats
        displayItemsByCategory = allByCategory
        let visibleCatIds = Set(allCats.map(\.id))
        let allVODs = contentStore.vodStreams
        // Round 14 (B10): Top/Newest rankings are computed ONCE in
        // PlaylistContentStore; this view only filters the shared
        // arrays by visible categories. The Newest GRID keeps its own
        // full `added` ordering (below) because the shared array is
        // capped at 60 and the grid paginates past it (B7).
        let sharedTop = contentStore.sharedTopRatedMovies
        let sharedNewest = contentStore.sharedNewestMovies
        topRatedVODs = Array(sharedTop.filter { visibleCatIds.contains($0.categoryId ?? "") }.prefix(15))
        recentlyAddedVODs = Array(sharedNewest.filter { visibleCatIds.contains($0.categoryId ?? "") }.prefix(20))

        let byAddedDesc = await Task.detached(priority: .userInitiated) {
            allVODs
                .lazy
                .filter { visibleCatIds.contains($0.stream.categoryId ?? "") }
                .compactMap { vod -> (DBVODStream, Int)? in
                    guard let ts = vod.stream.added.flatMap(Int.init) else { return nil }
                    return (vod.stream, ts)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }.value
        guard !Task.isCancelled else { return }
        newestAll = byAddedDesc
        newestVisibleCount = min(Self.newestPageSize, byAddedDesc.count)
        // Build 88: the NEW slice is the head of THIS ordering —
        // the same full added-desc pass the Newest grid paginates.
        newMovieIds = Set(byAddedDesc.prefix(60).map(\.streamId))

        // Round 15 (C7): franchise groups. Two cheap passes — first
        // the bases that a marked title (number/roman/"part"/colon)
        // reduces to, then every title sharing one of those bases.
        let groups = await Task.detached(priority: .utility) { () -> [FranchiseGroup] in
            let visible = allVODs.lazy.filter { visibleCatIds.contains($0.stream.categoryId ?? "") }.map(\.stream)
            var markedBases = Set<String>()
            for movie in visible {
                let base = MovieCatalogNaming.franchiseBase(movie.name)
                if base != MovieCatalogNaming.normalizedTitle(movie.name), !base.isEmpty {
                    markedBases.insert(base)
                }
            }
            guard !markedBases.isEmpty else { return [] }
            var byBase: [String: [DBVODStream]] = [:]
            for movie in visible {
                let base = MovieCatalogNaming.franchiseBase(movie.name)
                if markedBases.contains(base) {
                    byBase[base, default: []].append(movie)
                }
            }
            return byBase
                .filter { $0.value.count >= 2 }
                .map { base, members in
                    let sorted = members.sorted { a, b in
                        let ya = DetailFormatting.releaseYear(from: a.releaseDate) ?? Int.max
                        let yb = DetailFormatting.releaseYear(from: b.releaseDate) ?? Int.max
                        if ya != yb { return ya < yb }
                        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    }
                    // Display title: the shortest member name (the
                    // plain first entry, e.g. "Dune").
                    let title = members.map(\.name).min(by: { $0.count < $1.count }) ?? base
                    return FranchiseGroup(base: base, title: title, movies: sorted)
                }
                .sorted { $0.movies.count > $1.movies.count }
                .prefix(10)
                .map { $0 }
        }.value
        guard !Task.isCancelled else { return }
        franchiseGroups = groups

        // Build 80 (item 12): dedupe the tab's catalog rails in
        // RENDER order, first rail wins (the build-77 Home rule):
        // Top → Recently Added → Collections → category shelves.
        // (a) duplicate category rails — same id, or the same NAME
        // listed twice by the provider (the audit's two "ANIME
        // SERIES - 2026" rails) — merge into the first rail of that
        // name; (b) an item shown in an earlier rail never repeats
        // in a later one; (c) exact repeats inside one rail (same
        // stream id) collapse. Different encodes ([FHD] vs [HD])
        // are different stream ids and stay. Personal lists (Watch-
        // list, Continue Watching) are not catalog rails and are
        // untouched. Detached, like the other heavy passes here.
        let catsSnapshot = displayCategories
        let itemsSnapshot = displayItemsByCategory
        let topSnapshot = topRatedVODs
        let recentSnapshot = recentlyAddedVODs
        let groupsSnapshot = franchiseGroups
        let deduped = await Task.detached(priority: .userInitiated) { () -> (top: [DBVODStream], recent: [DBVODStream], shelfCats: [DBCategory], shelfItems: [String: [VODWithCategory]]) in
            var seen = Set<Int>()
            func take(_ items: [DBVODStream]) -> [DBVODStream] {
                var out: [DBVODStream] = []
                for item in items where seen.insert(item.streamId).inserted { out.append(item) }
                return out
            }
            let top = take(topSnapshot)
            let recent = take(recentSnapshot)
            for group in groupsSnapshot { for movie in group.movies { seen.insert(movie.streamId) } }
            var shelfCats: [DBCategory] = []
            var shelfItems: [String: [VODWithCategory]] = [:]
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
                for item in itemsSnapshot[category.id] ?? [] where seen.insert(item.stream.streamId).inserted {
                    shelfItems[targetId, default: []].append(item)
                }
            }
            shelfCats = shelfCats.filter { !(shelfItems[$0.id]?.isEmpty ?? true) }
            return (top, recent, shelfCats, shelfItems)
        }.value
        guard !Task.isCancelled else { return }
        topRatedVODs = deduped.top
        recentlyAddedVODs = deduped.recent
        shelfCategories = deduped.shelfCats
        shelfItemsByCategory = deduped.shelfItems
    }

    private func presentHistoryPlayer(_ item: DBWatchHistory) {
        let streamIdInt = Int(item.streamId) ?? 0
        Task {
            let localURL = await DownloadManager.shared.localURL(
                forId: DownloadManager.idFor(vod: playlist.id, streamId: streamIdInt)
            )
            await MainActor.run {
                presentHistoryPlayer(item, localOverrideURL: localURL)
            }
        }
    }

    private func presentHistoryPlayer(_ item: DBWatchHistory, localOverrideURL: URL?) {
        let streamIdInt = Int(item.streamId) ?? 0
        let navigateToDetail: (String, String) -> Void = { type, id in
            Task {
                if type == "vod", let vId = Int(id),
                   let movie = try? await AppDatabase.shared.read({ db in
                    try DBVODStream.filter(Column("streamId") == vId && Column("playlistId") == playlist.id).fetchOne(db)
                }) {
                    await MainActor.run {
                        playerOverlay.dismiss()
                        pendingMovieDetail = movie
                    }
                }
            }
        }

        // If there is a downloaded file, skip the queue and play from the local file.
        if localOverrideURL == nil {
            var queue: [DBVODStream] = []
            var initialMovie: DBVODStream? = nil
            for items in contentStore.vodStreamsByCategoryId.values {
                if let found = items.first(where: { $0.stream.streamId == streamIdInt }) {
                    initialMovie = found.stream
                    queue = items.map(\.stream)
                    break
                }
            }

            if let movie = initialMovie, !queue.isEmpty {
                playerOverlay.present(playlistId: playlist.id) {
                    VODPlayerShell(
                        playlist: playlist,
                        queue: queue,
                        initialMovie: movie,
                        initialResumeMs: item.lastTimeMs,
                        onNavigateToDetail: navigateToDetail
                    )
                }
                return
            }
        }

        let url: URL? = localOverrideURL ?? buildURL(for: item)
        guard let url else { return }
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
                // Build 61 (B10, G2): playlist User-Agent to the engine load path.
                userAgent: playlist.playbackUserAgent(channelUserAgent: nil),
                // Build 61 (FA, F-2/G2): custom headers alongside the UA.
                customHeaders: playlist.customHeaders,
                onNavigateToDetail: navigateToDetail
            )
        }
    }

    private func buildURL(for item: DBWatchHistory) -> URL? {
        let builder = PlaybackURLBuilder(playlist: playlist)
        // Because it is the VOD tab, the vod assumption (we already fetch with typeFilter: "vod")
        let streamIdInt = Int(item.streamId) ?? 0
        return builder.movieURL(streamId: streamIdInt, containerExtension: item.containerExtension)
    }
}

// MARK: - Top Movies shelf

/// "Top Movies" row: the catalog's highest-rated movies (real panel
/// ratings only, computed in `recomputeFilter`). Poster cards are the
/// existing `VODStreamCard`; "See all" opens the existing All Movies grid.
struct TopMoviesShelf: View, Equatable {
    let playlist: Playlist
    let items: [DBVODStream]
    var replayToken: Int = 0

    static func == (lhs: TopMoviesShelf, rhs: TopMoviesShelf) -> Bool {
        lhs.playlist.id == rhs.playlist.id && lhs.items == rhs.items
            && lhs.replayToken == rhs.replayToken
    }

    @Environment(\.posterMetrics) private var posterMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Round 14 (B7): "See all" opens the browse grid sorted
            // by normalized rating (its default sort), not the plain
            // All Movies order.
            CinematicSectionHeader(title: L("home.top_movies")) {
                MovieGenreGridView(playlist: playlist)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items.indices, id: \.self) { index in
                        NavigationLink {
                            MovieDetailView(playlist: playlist, movie: items[index], queue: items)
                        } label: {
                            // Round 14 (B7): the Movies identity —
                            // RANKED cards: outlined numerals + the
                            // gold normalized rating as the shelf's
                            // signature (same card Home's Top Rated
                            // rows use).
                            RankedPosterCard(
                                rank: index + 1,
                                // Build 89 (item 7): the same
                                // artwork chain every other Movies
                                // card uses (moviePosterCard /
                                // VODStreamCard) — the record's
                                // stored backdrop is the fallback
                                // when the icon field is empty or
                                // unusable. This call site passed
                                // the icon ONLY, so a movie with a
                                // dead/empty icon but a real
                                // backdrop sat on the title card.
                                imageURL: ArtworkURL.url(from: items[index].streamIcon) ?? ArtworkURL.url(from: items[index].backdropPath),
                                title: items[index].name,
                                ratingText: ContentRating.normalizedDisplayText(
                                    rating: items[index].rating,
                                    rating5Based: items[index].rating5Based
                                ),
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                iconName: "film"
                            )
                        }
                        .buttonStyle(.plain)
                        // Build 89 (item 7): NO shelfEntrance here
                        // anymore. The B12 entrance rises each cell
                        // 28 pt with a per-index stagger — while the
                        // catalog is still publishing progressively,
                        // this shelf mounts mid-load and its rising
                        // cells render OVER the shelf below (the
                        // overlap/ghosting in the owner's Movies
                        // recording). The cells now render in place
                        // from the first frame; the only fade left
                        // is CachedImage's own in-place load
                        // transition. (The replayToken property is
                        // kept for the shelf's Equatable identity;
                        // it no longer drives an entrance.)
                    }
                }
                .padding(.horizontal, 16)
            }
            .shelfEdgeFade()
        }
        .padding(.vertical, 6)
        .onAppear { prefetchPosters() }
        .onDisappear { stopPrefetchPosters() }
    }

    /// Build 90: this shelf never prefetched — its ranked cards
    /// cold-loaded on every tab open while the category shelves
    /// below arrived warm. Warm exactly what the cards render:
    /// the same artwork chain the cells pass RankedPosterCard
    /// (icon, then the stored backdrop), at shelf size, .fill,
    /// .shelf — and retract the batch when the shelf leaves.
    private func prefetchPosters() {
        let urls = items.compactMap {
            ArtworkURL.url(from: $0.streamIcon) ?? ArtworkURL.url(from: $0.backdropPath)
        }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
    }

    private func stopPrefetchPosters() {
        let urls = items.compactMap {
            ArtworkURL.url(from: $0.streamIcon) ?? ArtworkURL.url(from: $0.backdropPath)
        }
        ListImagePrefetch.stop(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
    }
}

// MARK: - Recently Added shelf

struct RecentlyAddedVODShelf: View, Equatable {
    let playlist: Playlist
    let items: [DBVODStream]
    /// Build 88: NEW-chip membership (the tab's newest-added
    /// slice), passed down from VODView's recompute pass.
    var newMovieIds: Set<Int> = []

    static func == (lhs: RecentlyAddedVODShelf, rhs: RecentlyAddedVODShelf) -> Bool {
        lhs.playlist.id == rhs.playlist.id && lhs.items == rhs.items
            && lhs.newMovieIds == rhs.newMovieIds
    }

    @Environment(\.posterMetrics) private var posterMetrics

    var body: some View {
        // Build 88: the shared catalog shelf (CatalogComponents) —
        // same header style and destination as the hand-rolled
        // shelf it replaces; the cards are the shared PosterCard
        // with the NEW chip on the newest-added slice.
        CatalogShelfRow(
            title: L("recently_added.title"),
            items: items,
            rowHeight: posterMetrics.shelfRowTotalHeight
        ) {
            RecentlyAddedVODDetailView(playlist: playlist, items: items)
        } cell: { stream in
            NavigationLink {
                MovieDetailView(playlist: playlist, movie: stream, queue: items)
            } label: {
                moviePosterCard(
                    stream,
                    posterWidth: posterMetrics.shelfPosterWidth,
                    posterHeight: posterMetrics.shelfPosterHeight,
                    imageLoadProfile: .shelf,
                    isNew: newMovieIds.contains(stream.streamId)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Recently Added Detail View
struct RecentlyAddedVODDetailView: View {
    let playlist: Playlist
    /// The shelf's snapshot, used only until the store recompute
    /// lands (round 14, B7: "See all" recomputes from the store
    /// instead of freezing the shelf's 20 items).
    let items: [DBVODStream]

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @Environment(\.posterMetrics) private var posterMetrics
    @State private var recomputed: [VODWithCategory]?

    /// The full visible `added`-desc ordering as plain records
    /// (the recompute below fills it; the shelf's snapshot covers
    /// the window before it lands).
    private var fullStreams: [DBVODStream] {
        (recomputed ?? items.map { VODWithCategory(stream: $0, categoryName: "") }).map(\.stream)
    }

    /// Build 88: on an `added`-desc list, the newest-added slice
    /// is by construction its head — the NEW chip's membership
    /// on this page.
    private var pageNewIds: Set<Int> {
        Set(fullStreams.prefix(60).map(\.streamId))
    }

    var body: some View {
        // Build 88: the shared see-all grid (CatalogComponents) —
        // in-section search field, "N of N" count, the shared
        // PosterCard. It replaces this page's old `.searchable`
        // drawer + VODCategoryContent pairing; the full-ordering
        // recompute below is unchanged.
        CatalogGridView(
            title: L("recently_added.title"),
            items: fullStreams,
            searchPlaceholder: L("vod.search_placeholder"),
            itemTitle: { $0.name }
        ) { stream in
            NavigationLink {
                MovieDetailView(playlist: playlist, movie: stream, queue: fullStreams)
            } label: {
                moviePosterCard(
                    stream,
                    posterWidth: posterMetrics.categoryGridPosterWidth,
                    posterHeight: posterMetrics.categoryGridPosterHeight,
                    imageLoadProfile: .grid,
                    isNew: pageNewIds.contains(stream.streamId)
                )
            }
            .buttonStyle(PressScaleButtonStyle())
        }
        .task(id: contentStore.streamsLoaded) { await recompute() }
        .task(id: hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod")) { await recompute() }
    }

    /// The full visible `added`-desc ordering from the store (the
    /// shelf shows 20; this screen paginates the whole thing through
    /// VODCategoryContent).
    private func recompute() async {
        guard playlist.id == contentStore.activePlaylistId else { return }
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod")
        let source = contentStore.vodStreams
        let result = await Task.detached(priority: .userInitiated) {
            source
                .filter { !hidden.contains($0.stream.categoryId ?? "") }
                .compactMap { item -> (VODWithCategory, Int)? in
                    guard let ts = item.stream.added.flatMap(Int.init) else { return nil }
                    return (item, ts)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }.value
        guard !Task.isCancelled else { return }
        recomputed = result
    }
}

// MARK: - Category shelf
private enum VODCategoryShelf {
    /// Nuke prefetch for the first visible posters (scrolling `LazyHStack` + load when seen).
    static let prefetchHeadCount = 16 // Round 7: 32 → 16 (see ListImagePrefetch — bounds speculative decode work per shelf)
}

struct VODCategoryShelfRow: View, Equatable {
    let playlist: Playlist
    let category: DBCategory
    let items: [VODWithCategory]
    var isStreamsLoading: Bool = false
    /// Build 88: NEW-chip membership (the tab's newest-added
    /// slice), passed down from VODView's recompute pass.
    var newMovieIds: Set<Int> = []
    /// Build 90 (RC2a): every window batch this shelf handed to
    /// the shared prefetcher, so `onDisappear` can retract them
    /// too — build 89 and earlier retracted only the head batch,
    /// leaving a fast fling's worth of stale window requests
    /// queued ahead of the shelves actually on screen.
    @State private var windowPrefetchURLs: [URL] = []

    static func == (lhs: VODCategoryShelfRow, rhs: VODCategoryShelfRow) -> Bool {
        lhs.playlist.id == rhs.playlist.id &&
        lhs.category == rhs.category &&
        lhs.items == rhs.items &&
        lhs.isStreamsLoading == rhs.isStreamsLoading &&
        lhs.newMovieIds == rhs.newMovieIds
    }

    @Environment(\.posterMetrics) private var posterMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Round 8: the ONE shelf-header style — destination and the
            // real per-category count badge (round 5, elite pattern)
            // are unchanged; both now ride on CinematicSectionHeader.
            CinematicSectionHeader(title: category.name, count: items.isEmpty ? nil : items.count) {
                VODCategoryDetailView(playlist: playlist, category: category)
            }

            if items.isEmpty {
                if isStreamsLoading {
                    Color.clear.frame(height: posterMetrics.shelfRowTotalHeight)
                } else {
                    Text(L("vod.empty.no_in_category"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            } else {
                // Build the queue ONCE per shelf: the NavigationLink destination is evaluated at cell
                // render; leaving items.map inside was copying the whole category at every new
                // cell (an O(N²) scroll cost).
                let queue = items.map(\.stream)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            NavigationLink {
                                MovieDetailView(playlist: playlist, movie: item.stream, queue: queue)
                            } label: {
                                moviePosterCard(
                                    item.stream,
                                    posterWidth: posterMetrics.shelfPosterWidth,
                                    posterHeight: posterMetrics.shelfPosterHeight,
                                    imageLoadProfile: .shelf,
                                    isNew: newMovieIds.contains(item.stream.streamId)
                                )
                            }
                            .buttonStyle(.plain)
                            // Round 20 (R20-5): as each cell appears,
                            // warm the posters just ahead of it — the
                            // old head-only prefetch left every poster
                            // past the first 16 a cold request during
                            // fast horizontal scrolls.
                            .onAppear {
                                prefetchWindow(from: items, after: index)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: posterMetrics.shelfRowTotalHeight)
                .shelfEdgeFade()
                .onAppear {
                    prefetchIcons(from: items)
                }
                .onDisappear {
                    // Round 20 (R20-5): retract this shelf's
                    // not-yet-started head batch so a fast vertical
                    // fling doesn't leave the shared prefetch queue
                    // full of shelves the user already passed.
                    // Build 90 (RC2a): the per-cell window batches
                    // are retracted with it (see windowPrefetchURLs).
                    stopPrefetchIcons(from: items)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Build 90 (RC5): the ONE artwork resolution the shelf's
    /// cards render — the record's icon, then its stored
    /// backdrop (CatalogComponents' `moviePosterCard` chain).
    /// The prefetchers below resolve through this same chain:
    /// they used to warm the icon field only, so a movie living
    /// on its backdrop was never warmed and cold-loaded on
    /// first appearance even inside a "prefetched" shelf.
    private func artworkURL(for stream: DBVODStream) -> URL? {
        ArtworkURL.url(from: stream.streamIcon) ?? ArtworkURL.url(from: stream.backdropPath)
    }

    private func prefetchIcons(from list: [VODWithCategory]) {
        let urls = list.prefix(VODCategoryShelf.prefetchHeadCount)
            .compactMap { artworkURL(for: $0.stream) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
    }

    /// Round 20 (R20-5): the scroll window ahead of the cell at
    /// `index` (see ListImagePrefetch.scrollWindow).
    /// Build 90 (RC2a): the started URLs are remembered so the
    /// shelf's disappearance can retract them (see
    /// stopPrefetchIcons) instead of leaving them queued.
    private func prefetchWindow(from list: [VODWithCategory], after index: Int) {
        let start = index + 1
        guard start < list.count else { return }
        let urls = list[start..<min(start + ListImagePrefetch.scrollWindow, list.count)]
            .compactMap { artworkURL(for: $0.stream) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
        for url in urls where !windowPrefetchURLs.contains(url) {
            windowPrefetchURLs.append(url)
        }
    }

    private func stopPrefetchIcons(from list: [VODWithCategory]) {
        let urls = list.prefix(VODCategoryShelf.prefetchHeadCount)
            .compactMap { artworkURL(for: $0.stream) }
        ListImagePrefetch.stop(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
        // Build 90 (RC2a): retract the window batches too,
        // chunked to the prefetcher's own batch cap (its stop
        // slices to maxBatch per call).
        let windows = windowPrefetchURLs
        windowPrefetchURLs = []
        for chunkStart in stride(from: 0, to: windows.count, by: ListImagePrefetch.maxBatch) {
            ListImagePrefetch.stop(
                urls: Array(windows[chunkStart..<min(chunkStart + ListImagePrefetch.maxBatch, windows.count)]),
                width: posterMetrics.shelfPosterWidth,
                height: posterMetrics.shelfPosterHeight,
                contentMode: .fill,
                loadProfile: .shelf
            )
        }
    }
}

struct VODStreamCard: View {
    let playlistId: UUID
    let stream: DBVODStream
    var categoryName: String? = nil
    var posterWidth: CGFloat = 160
    var posterHeight: CGFloat = 240
    var imageLoadProfile: ImageLoadProfile = .standard
    /// Passed from the upper view instead of opening a @Query per card (nil = progress bar hidden)
    var watchProgress: Double? = nil

    /// "2024 • Thriller" — built only from fields the record actually
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

    var body: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                CachedImage(
                    // Build 81 (items 5b/5c): lenient artwork URL
                    // (the strict URL(string:) dropped posters whose
                    // paths carry spaces) + the title, so a movie
                    // with no usable image renders the designed
                    // title card instead of an anonymous blank tile.
                    // Build 82 (item 6): when the icon field itself
                    // is empty/unusable, fall back to the record's
                    // stored backdrop (filled by the detail-info
                    // fetch) before giving up to the title card —
                    // the same second field the heroes use.
                    url: ArtworkURL.url(from: stream.streamIcon) ?? ArtworkURL.url(from: stream.backdropPath),
                    width: posterWidth,
                    height: posterHeight,
                    contentMode: SwiftUI.ContentMode.fill,
                    iconName: "film",
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

                // Round 14 (B7): the badge shows the ONE normalized
                // value (rating5Based-aware), not the raw string.
                PosterRatingBadge(rating: ContentRating.normalizedDisplayText(
                    rating: stream.rating,
                    rating5Based: stream.rating5Based
                ))
                    .padding(6)
            }

            // Round 15 (C9): card titles are LEFT-aligned everywhere
            // (matching RankedPosterCard), on the shared font tokens.
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
struct VODCategoryDetailView: View {
    let playlist: Playlist
    let category: DBCategory

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var displayItems: [VODWithCategory] = []

    var body: some View {
        VODCategoryContent(playlist: playlist, items: displayItems, newMovieIds: Set(contentStore.sharedNewestMovies.map(\.streamId)))
            .equatable()
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.hidden, for: .tabBar)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: L("vod.search_placeholder"))
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
        let base = contentStore.vodStreamsByCategoryId[category.id] ?? []
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { displayItems = base; return }
        // Build 63 (item 15): a non-empty query searches the FULL
        // movies catalog (hidden categories excluded); the empty
        // query above keeps the category bucket untouched.
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod")
        let source = contentStore.vodStreams
        let result = await Task.detached(priority: .userInitiated) {
            let visible = source.filter { !hidden.contains($0.stream.categoryId ?? "") }
            let filtered = visible.filter { CatalogTextSearch.matchesSectionFuzzy(search: q, text: $0.stream.name) }
            return CatalogTextSearch.sortVODByRelevance(filtered, search: q)
        }.value
        guard !Task.isCancelled else { return }
        displayItems = result
    }
}

struct VODCategoryContent: View, Equatable {
    let playlist: Playlist
    let items: [VODWithCategory]
    /// Build 88: NEW-chip membership — the store's newest-added
    /// slice (sharedNewestMovies), passed by the hosting detail
    /// views; empty = no chips (the default for other hosts).
    var newMovieIds: Set<Int> = []

    /// Cheap signature compare so a parent re-render (e.g. `applyVODMetadata`'s
    /// @Published storm) doesn't force SwiftUI to re-process a 10k-item view — that
    /// scaled with catalog size and froze "All Movies" for seconds on return.
    /// Internal @State/@Query updates still invalidate normally, independent of this.
    static func == (lhs: VODCategoryContent, rhs: VODCategoryContent) -> Bool {
        lhs.playlist.id == rhs.playlist.id
            && lhs.items.count == rhs.items.count
            && lhs.items.first?.stream.id == rhs.items.first?.stream.id
            && lhs.items.last?.stream.id == rhs.items.last?.stream.id
            && lhs.newMovieIds == rhs.newMovieIds
    }

    @Environment(\.posterMetrics) private var posterMetrics
    @Query<WatchProgressMapRequest> private var progressMap: [String: Double]

    @AppStorage(VODSortOption.storageKey) private var sortOption: VODSortOption = .defaultOrder
    @State private var showSortSheet = false
    /// Screen-local: file types are specific to the currently shown list, so this
    /// intentionally does not persist across screens.
    @State private var fileTypeFilter: Set<String> = []
    // Build 61 (B8, C1): advanced facet selection + the facet values
    // actually present in this list (built in recompute, off-main).
    @State private var facetSelection = CatalogFacetSelection()
    @State private var facetGenres: [String] = []
    @State private var facetYears: [Int] = []
    @State private var facetCountries: [String] = []
    @State private var facetHasRatings = false
    /// Sort/filter output, recomputed off the main thread on input changes so large
    /// lists (e.g. "All Movies") don't re-sort on every body pass (watch-progress ticks).
    @State private var displayItems: [VODWithCategory] = []
    /// Prebuilt play queue matching `displayItems`, so body passes don't re-map a
    /// large array on every render (critical for "All Movies" with 10k+ items).
    @State private var streamQueue: [DBVODStream] = []
    /// File types present in the full list, precomputed to keep the menu O(1) to build.
    @State private var fileTypes: [String] = []
    /// Number of cells currently rendered. Paginated so a 10k-item catalog doesn't
    /// build one giant ForEach (froze on first load and when scrolling to the end).
    @State private var visibleCount = Self.pageSize

    private static let pageSize = 90
    private static let gridTopID = "vodGridTop"

    // Fix round 1 (build 88): this custom init suppresses the
    // memberwise initializer, so `newMovieIds` must be accepted
    // here explicitly — the property, its `==` handling and the
    // body's NEW-chip lookup already existed; only the init had
    // not been extended, so both hosts' calls failed to compile.
    init(playlist: Playlist, items: [VODWithCategory], newMovieIds: Set<Int> = []) {
        self.playlist = playlist
        self.items = items
        self.newMovieIds = newMovieIds
        _progressMap = Query(WatchProgressMapRequest(playlistId: playlist.id, type: "vod"), in: \.appDatabase)
    }

    private var categoryGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    /// Cheap O(1) change signal for `items`; avoids O(n) array equality in `.task(id:)`
    /// on every update pass, which froze navigation on huge lists.
    private var itemsToken: Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        hasher.combine(items.first?.stream.id)
        hasher.combine(items.last?.stream.id)
        return hasher.finalize()
    }

    private var isFilterActive: Bool {
        sortOption != .defaultOrder || !fileTypeFilter.isEmpty || !facetSelection.isEmpty
    }

    private func recompute() async {
        let source = items
        let sort = sortOption
        let filter = fileTypeFilter
        let facets = facetSelection
        let (result, queue, types, facetValues) = await Task.detached(priority: .userInitiated) { () -> ([VODWithCategory], [DBVODStream], [String], (genres: [String], years: [Int], countries: [String])) in
            let facetFiltered = facets.apply(to: VODFileType.filter(source, selection: filter))
            let sorted = sort.apply(to: facetFiltered)
            // Options come from the full list so toggling one doesn't hide the others.
            return (sorted, sorted.map(\.stream), VODFileType.available(in: source),
                    CatalogFacets.vodFacets(in: source.map(\.stream)))
        }.value
        guard !Task.isCancelled else { return }
        displayItems = result
        streamQueue = queue
        fileTypes = types
        facetGenres = facetValues.genres
        facetYears = facetValues.years
        facetCountries = facetValues.countries
        facetHasRatings = items.contains {
            ContentRating.normalizedRating10(rating: $0.stream.rating, rating5Based: $0.stream.rating5Based) != nil
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
        // first 24 posters (at recompute), so every paged-in page
        // painted cold during fast scrolling.
        prefetch(displayItems, startingAt: pageStart)
    }

    var body: some View {
        Group {
            if displayItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "film")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(L("vod.empty.no_movie"))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: categoryGridColumns, spacing: posterMetrics.gridRowSpacing) {
                            ForEach(Array(displayItems.prefix(visibleCount).enumerated()), id: \.element.stream.id) { index, item in
                                NavigationLink {
                                    MovieDetailView(playlist: playlist, movie: item.stream, queue: streamQueue)
                                } label: {
                                    moviePosterCard(
                                        item.stream,
                                        posterWidth: posterMetrics.categoryGridPosterWidth,
                                        posterHeight: posterMetrics.categoryGridPosterHeight,
                                        imageLoadProfile: .grid,
                                        isNew: newMovieIds.contains(item.stream.streamId),
                                        watchProgress: progressMap[String(item.stream.streamId)]
                                    )
                                }
                                .buttonStyle(.plain)
                                // Build 61 (B8, C2/J1): long-press —
                                // Watch Later + favorite groups.
                                .contextMenu {
                                    VODCardMenuItems(playlist: playlist, movie: item.stream)
                                }
                                // Load the next page while cells near the end scroll into view.
                                // Triggered from inside the lazy grid so onAppear is reliable.
                                .onAppear { if index >= visibleCount - 15 { loadMore() } }
                            }
                        }
                        .padding()
                        .id(Self.gridTopID)

                        if visibleCount < displayItems.count {
                            BrandedLoader(size: 28)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                    .onChange(of: sortOption) { _, _ in
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(Self.gridTopID, anchor: .top)
                        }
                    }
                    .onChange(of: fileTypeFilter) { _, _ in
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(Self.gridTopID, anchor: .top)
                        }
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
        .task(id: fileTypeFilter) { await recompute() }
        .task(id: facetSelection) { await recompute() }
        .cinematicBackground()
    }

    /// Build 61 (B8, C1): facet rows for the sort/filter sheet —
    /// genres, years, countries and rating floors, built ONLY from
    /// values present in this list (empty facet = no rows).
    private var facetRows: [SortFilterSheet.Row] {
        var rows: [SortFilterSheet.Row] = []
        for genre in facetGenres.prefix(12) {
            rows.append(SortFilterSheet.Row(
                id: "genre-\(genre)", title: genre,
                isSelected: facetSelection.genres.contains(genre)
            ) { toggleFacetGenre(genre) })
        }
        for year in facetYears.prefix(12) {
            rows.append(SortFilterSheet.Row(
                id: "year-\(year)", title: String(year),
                isSelected: facetSelection.years.contains(year)
            ) { toggleFacetYear(year) })
        }
        for country in facetCountries.prefix(12) {
            rows.append(SortFilterSheet.Row(
                id: "country-\(country)", title: country,
                isSelected: facetSelection.countries.contains(country)
            ) { toggleFacetCountry(country) })
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

    private func toggleFacetGenre(_ genre: String) {
        if facetSelection.genres.contains(genre) { facetSelection.genres.remove(genre) } else { facetSelection.genres.insert(genre) }
    }

    private func toggleFacetYear(_ year: Int) {
        if facetSelection.years.contains(year) { facetSelection.years.remove(year) } else { facetSelection.years.insert(year) }
    }

    private func toggleFacetCountry(_ country: String) {
        if facetSelection.countries.contains(country) { facetSelection.countries.remove(country) } else { facetSelection.countries.insert(country) }
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
                sortRows: VODSortOption.allCases.map { option in
                    SortFilterSheet.Row(
                        id: option.rawValue,
                        title: L(option.titleKey),
                        systemImage: option.systemImage,
                        isSelected: sortOption == option
                    ) { sortOption = option }
                },
                filterTitle: L("filter.title"),
                filterRows: (fileTypes.count > 1 ? fileTypes.map { ext in
                    SortFilterSheet.Row(
                        id: "type-\(ext)",
                        title: ext.uppercased(),
                        isSelected: fileTypeFilter.contains(ext)
                    ) { toggleFileType(ext) }
                } : []) + facetRows,
                // Round 14 (B1): Clear resets the SORT as well as the
                // file-type filter. B8: facets clear with them.
                onClearFilters: (sortOption == .defaultOrder && fileTypeFilter.isEmpty && facetSelection.isEmpty) ? nil : {
                    sortOption = .defaultOrder
                    fileTypeFilter.removeAll()
                    facetSelection.clear()
                }
            )
        }
    }

    private func toggleFileType(_ ext: String) {
        if fileTypeFilter.contains(ext) {
            fileTypeFilter.remove(ext)
        } else {
            fileTypeFilter.insert(ext)
        }
    }

    private func prefetch(_ list: [VODWithCategory], startingAt: Int = 0) {
        // Only a bounded slice is ever prefetched (start() caps to maxBatch); building URLs
        // for the whole 10k list first would be wasted O(n) work on the main thread.
        // Build 90 (RC5): resolve the same chain the grid cards
        // render (icon, then the stored backdrop — moviePosterCard)
        // instead of the icon field alone, so backdrop-only movies
        // are warmed too.
        let urls = list.dropFirst(startingAt).prefix(ListImagePrefetch.maxBatch)
            .compactMap { ArtworkURL.url(from: $0.stream.streamIcon) ?? ArtworkURL.url(from: $0.stream.backdropPath) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.categoryGridPosterWidth,
            height: posterMetrics.categoryGridPosterHeight,
            contentMode: .fill,
            loadProfile: .grid
        )
    }
}

// MARK: - All Movies (flat, sortable/filterable browse)

/// Flat grid of every movie across categories. Reuses `VODCategoryContent`, so it
/// inherits the sort menu and file-type filter for free.
struct AllVODView: View {
    let playlist: Playlist

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var displayItems: [VODWithCategory] = []

    var body: some View {
        VODCategoryContent(playlist: playlist, items: displayItems, newMovieIds: Set(contentStore.sharedNewestMovies.map(\.streamId)))
            .equatable()
            .navigationTitle(L("browse.all_movies"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.hidden, for: .tabBar)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: L("vod.search_placeholder"))
            .onChange(of: searchText) { _, new in
                debounceTask?.cancel()
                debounceTask = Task {
                    try? await Task.sleep(nanoseconds: 280_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { debouncedQuery = new }
                }
            }
            .onDisappear { debounceTask?.cancel(); debounceTask = nil }
            .task(id: debouncedQuery) { await recompute() }
            .task(id: contentStore.streamsLoaded) { await recompute() }
            .task(id: hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod")) { await recompute() }
            .cinematicBackground()
    }

    private func recompute() async {
        guard playlist.id == contentStore.activePlaylistId else { displayItems = []; return }
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod")
        let source = contentStore.vodStreams
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        // Everything (hidden-filter, search, relevance sort) runs off the main thread —
        // the catalog can be hundreds of thousands of rows, so even the hidden-filter
        // is too heavy to run on-main (it froze the "All" screen on open).
        let result = await Task.detached(priority: .userInitiated) {
            let base = source.filter { !hidden.contains($0.stream.categoryId ?? "") }
            if q.isEmpty { return base }
            let filtered = base.filter { CatalogTextSearch.matchesSectionFuzzy(search: q, text: $0.stream.name) }
            return CatalogTextSearch.sortVODByRelevance(filtered, search: q)
        }.value
        guard !Task.isCancelled else { return }
        displayItems = result
    }
}

// MARK: - VOD Player Shell

/// The player opened from the movie list; it provides prev/next movie support in the same queue as the source.
struct VODPlayerShell: View {
    let playlist: Playlist
    let queue: [DBVODStream]
    var onNavigateToDetail: ((String, String) -> Void)? = nil
    private let initialMovie: DBVODStream
    private let initialResumeMs: Int?

    @State private var currentMovie: DBVODStream
    @State private var resumeMs: Int?
    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @Environment(\.playerOverlayPresentationID) private var overlayPresentationID

    init(
        playlist: Playlist,
        queue: [DBVODStream],
        initialMovie: DBVODStream,
        initialResumeMs: Int?,
        onNavigateToDetail: ((String, String) -> Void)? = nil
    ) {
        self.playlist = playlist
        self.queue = queue
        self.onNavigateToDetail = onNavigateToDetail
        self.initialMovie = initialMovie
        self.initialResumeMs = initialResumeMs
        _currentMovie = State(initialValue: initialMovie)
        _resumeMs = State(initialValue: initialResumeMs)
    }

    private var currentIndex: Int? {
        queue.firstIndex(where: { $0.streamId == currentMovie.streamId })
    }

    var body: some View {
        if let url = PlaybackURLBuilder(playlist: playlist).movieURL(
            streamId: currentMovie.streamId,
            containerExtension: currentMovie.containerExtension
        ) {
            let parts = [currentMovie.genre, currentMovie.releaseDate]
                .compactMap { $0 }.filter { !$0.isEmpty }
            PlayerView(
                url: url,
                title: currentMovie.name,
                subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "),
                artworkURL: currentMovie.streamIcon.flatMap { ArtworkURL.url(from: $0) },
                isLiveStream: false,
                playlistId: playlist.id,
                streamId: String(currentMovie.streamId),
                type: "vod",
                resumeTimeMs: resumeMs,
                containerExtension: currentMovie.containerExtension,
                // Build 61 (B10, G2): playlist User-Agent to the engine load path.
                userAgent: playlist.playbackUserAgent(channelUserAgent: nil),
                // Build 61 (FA, F-2/G2): custom headers alongside the UA.
                customHeaders: playlist.customHeaders,
                canGoToPreviousChannel: (currentIndex ?? 0) > 0,
                canGoToNextChannel: {
                    guard let idx = currentIndex else { return false }
                    return idx < queue.count - 1
                }(),
                onPreviousChannel: { jump(by: -1) },
                onNextChannel: { jump(by: 1) },
                onNavigateToDetail: onNavigateToDetail
            )
            .onChange(of: overlayPresentationID) { _, _ in
                applyInitialSelectionIfNeeded()
            }
        } else {
            // Build 80 (item 13, F1 — build-68 faulthunt): when the
            // URL build fails, the pre-fix shell rendered NOTHING —
            // a silent empty overlay behind a dead "Watch Now" tap.
            // Now the shell shows the app's standard playback-failure
            // message with a dismiss that closes the overlay, the
            // same honesty the series path's alert provides.
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(AppTheme.accent)
                Text(L("playback.error.failed_to_start"))
                    .font(AppTheme.fontCardTitle)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button(L("common.ok")) { playerOverlay.dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
    }

    private func applyInitialSelectionIfNeeded() {
        guard currentMovie.streamId != initialMovie.streamId
                || resumeMs != initialResumeMs else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            currentMovie = initialMovie
            resumeMs = initialResumeMs
        }
    }

    private func jump(by offset: Int) {
        guard let idx = currentIndex else { return }
        let newIdx = idx + offset
        guard newIdx >= 0, newIdx < queue.count else { return }
        let movie = queue[newIdx]
        Task {
            let history = try? await AppDatabase.shared.read { db in
                try DBWatchHistory
                    .filter(
                        Column("streamId") == String(movie.streamId)
                            && Column("playlistId") == playlist.id
                            && Column("type") == "vod"
                    )
                    .fetchOne(db)
            }
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                currentMovie = movie
                resumeMs = history?.lastTimeMs
            }
        }
    }
}

// MARK: - Featured movie hero (round 14, B7)

/// The Movies tab's featured hero: the featured movie's real
/// backdrop (poster fallback), gradient, title, real year + gold
/// normalized rating, and Play / Details actions.
struct MovieFeaturedHero: View {
    let playlist: Playlist
    let movie: DBVODStream
    let onDetails: () -> Void
    let onPlay: () -> Void

    // Build 87 (item 16, owner-picked design 4): the Movies
    // tab hero is the design-4 poster card — the tab features
    // ONE item, so the card renders centered with no peek
    // neighbours (there is nothing to peek). HeroPosterCard
    // owns the art chain (backdrop → poster on failure → the
    // designed title card), the centered title/star/meta
    // block and the Play/Details actions; this composition
    // keeps the existing wiring (the same onPlay/onDetails
    // the wide hero ran) and the real rating/meta only.

    private var metaLine: String? {
        var parts: [String] = []
        if let genre = movie.genre?.split(separator: ",").first {
            parts.append(genre.trimmingCharacters(in: .whitespaces))
        }
        if let year = DetailFormatting.year(from: movie.releaseDate) {
            parts.append(year)
        }
        if let duration = movie.duration?.trimmingCharacters(in: .whitespaces), !duration.isEmpty {
            parts.append(duration)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    var body: some View {
        HeroPosterCard(
            title: movie.name,
            backdropURL: movie.backdropPath.flatMap { ArtworkURL.url(from: $0) },
            posterURL: movie.streamIcon.flatMap { ArtworkURL.url(from: $0) },
            ratingText: ContentRating.normalizedDisplayText(rating: movie.rating, rating5Based: movie.rating5Based),
            metaLine: metaLine,
            iconName: "film",
            width: (UIScreen.main.bounds.width - 32) * 0.78,
            onPlay: onPlay,
            onDetails: onDetails
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

// MARK: - Watchlist shelf + view (round 15, C7)

struct WatchlistShelf: View, Equatable {
    let playlist: Playlist
    let items: [DBVODStream]
    /// Build 88: NEW-chip membership (the tab's newest-added slice).
    var newMovieIds: Set<Int> = []
    /// Build 90 (RC2a): window batches started by this shelf,
    /// retracted on disappear (see VODCategoryShelfRow).
    @State private var windowPrefetchURLs: [URL] = []

    static func == (lhs: WatchlistShelf, rhs: WatchlistShelf) -> Bool {
        lhs.playlist.id == rhs.playlist.id && lhs.items == rhs.items
            && lhs.newMovieIds == rhs.newMovieIds
    }

    @Environment(\.posterMetrics) private var posterMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CinematicSectionHeader(title: L("watchlist.title")) {
                WatchlistView(playlist: playlist)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, movie in
                        NavigationLink {
                            MovieDetailView(playlist: playlist, movie: movie, queue: items)
                        } label: {
                            moviePosterCard(
                                movie,
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                imageLoadProfile: .shelf,
                                isNew: newMovieIds.contains(movie.streamId)
                            )
                        }
                        .buttonStyle(.plain)
                        // Build 90: warm the posters just ahead
                        // of the visible cell, as the category
                        // shelves do (this shelf never prefetched
                        // at all — every card cold-loaded).
                        .onAppear {
                            prefetchWindow(after: index)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: posterMetrics.shelfRowTotalHeight)
            .shelfEdgeFade()
            .onAppear {
                prefetchIcons()
            }
            .onDisappear {
                stopPrefetchIcons()
            }
        }
        .padding(.vertical, 6)
    }

    /// Build 90: head + window prefetch for this shelf, resolving
    /// the same artwork chain its cards render (moviePosterCard:
    /// icon, then the stored backdrop) at the shelf's own size.
    private func prefetchIcons() {
        let urls = items.prefix(VODCategoryShelf.prefetchHeadCount)
            .compactMap { ArtworkURL.url(from: $0.streamIcon) ?? ArtworkURL.url(from: $0.backdropPath) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
    }

    private func prefetchWindow(after index: Int) {
        let start = index + 1
        guard start < items.count else { return }
        let urls = items[start..<min(start + ListImagePrefetch.scrollWindow, items.count)]
            .compactMap { ArtworkURL.url(from: $0.streamIcon) ?? ArtworkURL.url(from: $0.backdropPath) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
        for url in urls where !windowPrefetchURLs.contains(url) {
            windowPrefetchURLs.append(url)
        }
    }

    private func stopPrefetchIcons() {
        let urls = items.prefix(VODCategoryShelf.prefetchHeadCount)
            .compactMap { ArtworkURL.url(from: $0.streamIcon) ?? ArtworkURL.url(from: $0.backdropPath) }
        ListImagePrefetch.stop(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
        let windows = windowPrefetchURLs
        windowPrefetchURLs = []
        for chunkStart in stride(from: 0, to: windows.count, by: ListImagePrefetch.maxBatch) {
            ListImagePrefetch.stop(
                urls: Array(windows[chunkStart..<min(chunkStart + ListImagePrefetch.maxBatch, windows.count)]),
                width: posterMetrics.shelfPosterWidth,
                height: posterMetrics.shelfPosterHeight,
                contentMode: .fill,
                loadProfile: .shelf
            )
        }
    }
}

/// The Watchlist's own list surface: every bookmarked movie for this
/// playlist, resolved against the loaded catalog.
struct WatchlistView: View {
    let playlist: Playlist

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var watchlistStore = WatchlistStore.shared
    @Environment(\.posterMetrics) private var posterMetrics

    private var movies: [DBVODStream] {
        let ids = watchlistStore.movieIds(playlistId: playlist.id)
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        var found: [Int: DBVODStream] = [:]
        for item in contentStore.vodStreams where wanted.contains(item.stream.streamId) {
            found[item.stream.streamId] = item.stream
        }
        return ids.compactMap { found[$0] }
    }

    /// Build 61 (B8, R6): watch-later entries whose catalog record
    /// has vanished — kept, rendered from their add-time snapshot,
    /// marked unavailable, removable. Never silently dropped.
    private var unavailableEntries: [(id: Int, title: String, imageURL: String?)] {
        let ids = watchlistStore.movieIds(playlistId: playlist.id)
        let available = Set(movies.map(\.streamId))
        let snapshots = watchlistStore.snapshots(playlistId: playlist.id)
        return ids.filter { !available.contains($0) }.map { id in
            let snap = snapshots["vod:\(id)"]
            return (id, snap?.first ?? L("groups.unavailable"), snap?.last.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    /// Build 90 (RC6): the NEW-chip membership set, built ONCE
    /// per body pass — the grid cells used to rebuild this Set
    /// from the store's array inside every cell's label closure.
    private var newestMovieIdSet: Set<Int> {
        Set(contentStore.sharedNewestMovies.map(\.streamId))
    }

    var body: some View {
        Group {
            if movies.isEmpty && unavailableEntries.isEmpty {
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
                        ForEach(movies) { movie in
                            NavigationLink {
                                MovieDetailView(playlist: playlist, movie: movie, queue: movies)
                            } label: {
                                moviePosterCard(
                                    movie,
                                    posterWidth: posterMetrics.categoryGridPosterWidth,
                                    posterHeight: posterMetrics.categoryGridPosterHeight,
                                    imageLoadProfile: .grid,
                                    isNew: newestMovieIdSet.contains(movie.streamId)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()

                    // Build 61 (B8, R6): unavailable entries stay.
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
                                        iconName: "film"
                                    )
                                    Text(entry.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(2)
                                    Spacer(minLength: 8)
                                    Button(role: .destructive) {
                                        watchlistStore.toggle(playlistId: playlist.id, streamId: entry.id)
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

// MARK: - Franchise collections (round 15, C7)

/// One franchise collection (round 15, C7): ≥2 catalog movies whose
/// titles share a normalized base.
struct FranchiseGroup: Identifiable, Equatable {
    let base: String
    let title: String
    let movies: [DBVODStream]
    var id: String { base }
}

struct MovieCollectionsShelf: View, Equatable {
    let playlist: Playlist
    let groups: [FranchiseGroup]

    static func == (lhs: MovieCollectionsShelf, rhs: MovieCollectionsShelf) -> Bool {
        lhs.playlist.id == rhs.playlist.id
            && lhs.groups.map(\.base) == rhs.groups.map(\.base)
            && lhs.groups.map(\.movies.count) == rhs.groups.map(\.movies.count)
    }

    @Environment(\.posterMetrics) private var posterMetrics

    /// Build 82 (item 6): the first group member whose stored
    /// poster URL is usable — the collection's best available
    /// artwork from its own items (the pattern the ranked rails
    /// already use for their representative pick).
    /// Build 89 (item 7): if NO member's icon parses, fall back
    /// to the first member backdrop that does — the same second
    /// field the poster cards use; the card only reaches its
    /// designed title card when the whole group carries no
    /// usable artwork in either field.
    private func collectionArtworkURL(_ group: FranchiseGroup) -> URL? {
        for movie in group.movies {
            if let url = ArtworkURL.url(from: movie.streamIcon) { return url }
        }
        for movie in group.movies {
            if let url = ArtworkURL.url(from: movie.backdropPath) { return url }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // No "see all" — the shelf IS the collections surface;
            // each card opens its collection grid.
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AppTheme.accent)
                    .frame(width: 3, height: 18)
                Text(L("home.collections"))
                    .font(AppTheme.fontSectionTitle)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(groups) { group in
                        NavigationLink {
                            MovieCollectionView(playlist: playlist, title: group.title, movies: group.movies)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .bottomTrailing) {
                                    CachedImage(
                                        // Build 82 (item 6): the
                                        // group's first USABLE
                                        // poster, not blindly its
                                        // first movie's — when the
                                        // first entry's icon is
                                        // empty/unusable the card
                                        // used to strand on the
                                        // film placeholder even
                                        // though sibling entries in
                                        // the same collection carry
                                        // real posters (the
                                        // owner's "WWE RAW"
                                        // collection card). And
                                        // the designed title card
                                        // (build 81 item 5c) is
                                        // passed the group title —
                                        // this call site never
                                        // passed `title:` at all.
                                        url: collectionArtworkURL(group),
                                        width: posterMetrics.shelfPosterWidth,
                                        height: posterMetrics.shelfPosterHeight,
                                        contentMode: .fill,
                                        iconName: "film",
                                        loadProfile: .shelf,
                                        title: group.title
                                    )
                                    Text("\(group.movies.count)")
                                        .font(AppTheme.fontBadge)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.black.opacity(0.6)))
                                        .padding(6)
                                }
                                Text(group.title)
                                    .font(AppTheme.fontCardTitle)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(width: posterMetrics.shelfPosterWidth, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .shelfEdgeFade()
            .onAppear { prefetchArtwork() }
            .onDisappear { stopPrefetchArtwork() }
        }
        .padding(.vertical, 6)
    }

    /// Build 90: the collection cards render through
    /// `collectionArtworkURL` at shelf size — warm those exact
    /// requests (the shelf never prefetched; ≤10 groups, so one
    /// bounded batch covers the whole shelf).
    private func prefetchArtwork() {
        let urls = groups.compactMap { collectionArtworkURL($0) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
    }

    private func stopPrefetchArtwork() {
        let urls = groups.compactMap { collectionArtworkURL($0) }
        ListImagePrefetch.stop(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
    }
}

/// One franchise collection: its movies in release order.
struct MovieCollectionView: View {
    let playlist: Playlist
    let title: String
    let movies: [DBVODStream]

    /// Build 88: observed only for the NEW-chip membership (the
    /// store's newest-added slice) on the shared poster cards.
    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @Environment(\.posterMetrics) private var posterMetrics

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    /// Build 90 (RC6): built once per body pass, not per cell.
    private var newestMovieIdSet: Set<Int> {
        Set(contentStore.sharedNewestMovies.map(\.streamId))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: posterMetrics.gridRowSpacing) {
                ForEach(movies) { movie in
                    NavigationLink {
                        MovieDetailView(playlist: playlist, movie: movie, queue: movies)
                    } label: {
                        moviePosterCard(
                            movie,
                            posterWidth: posterMetrics.categoryGridPosterWidth,
                            posterHeight: posterMetrics.categoryGridPosterHeight,
                            imageLoadProfile: .grid,
                            isNew: newestMovieIdSet.contains(movie.streamId)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .cinematicBackground()
    }
}

// MARK: - Genre / decade browse grid (round 14 B7 + round 15 C7)

/// The Movies browse grid behind Top Movies "See all" and the detail
/// pages' genre chips: chips of the catalog's REAL top genres, decade
/// chips with REAL counts, and a sort menu (rating / newest / release
/// year / name). Everything derives from the loaded catalog; the grid
/// paginates like VODCategoryContent.
struct MovieGenreGridView: View {
    let playlist: Playlist
    var initialGenre: String? = nil

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @Environment(\.posterMetrics) private var posterMetrics

    @State private var selectedGenre: String?
    @State private var selectedDecade: Int?
    @State private var sortMode: SortMode = .rating
    @State private var displayItems: [DBVODStream] = []
    @State private var genreCounts: [(name: String, count: Int)] = []
    @State private var decadeCounts: [(decade: Int, count: Int)] = []
    @State private var visibleCount = 90
    private static let pageSize = 90

    enum SortMode: String, CaseIterable {
        case rating, newest, releaseYear, name

        var titleKey: String {
            switch self {
            case .rating: return "sort.rating_desc"
            case .newest: return "sort.recently_added"
            case .releaseYear: return "sort.release_year"
            case .name: return "sort.name_asc"
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    /// Build 90 (RC6): built once per body pass, not per cell.
    private var newestMovieIdSet: Set<Int> {
        Set(contentStore.sharedNewestMovies.map(\.streamId))
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            grid
        }
        .navigationTitle(selectedGenre ?? L("home.top_movies"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .cinematicBackground()
        .onAppear {
            if selectedGenre == nil { selectedGenre = initialGenre }
        }
        .task(id: contentStore.streamsLoaded) { await recompute() }
        .task(id: selectedGenre) { await recompute() }
        .task(id: selectedDecade) { await recompute() }
        .task(id: sortMode) { await recompute() }
        .task(id: hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod")) { await recompute() }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !genreCounts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        genreChip(nil, count: nil)
                        ForEach(genreCounts, id: \.name) { entry in
                            genreChip(entry.name, count: entry.count)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            if !decadeCounts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(decadeCounts, id: \.decade) { entry in
                            Button {
                                selectedDecade = selectedDecade == entry.decade ? nil : entry.decade
                            } label: {
                                Text("\(entry.decade)s (\(entry.count))")
                                    .font(AppTheme.fontBadge)
                                    .foregroundStyle(selectedDecade == entry.decade ? Color.white : Color.primary.opacity(0.85))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(selectedDecade == entry.decade ? AppTheme.accent : AppTheme.elevated))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            HStack {
                Spacer()
                Menu {
                    ForEach(SortMode.allCases, id: \.self) { mode in
                        Button {
                            sortMode = mode
                        } label: {
                            if sortMode == mode {
                                Label(L(mode.titleKey), systemImage: "checkmark")
                            } else {
                                Text(L(mode.titleKey))
                            }
                        }
                    }
                } label: {
                    Label(L(sortMode.titleKey), systemImage: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .accessibilityLabel(L("sort.title"))
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
    }

    private func genreChip(_ genre: String?, count: Int?) -> some View {
        let isSelected = selectedGenre == genre
        return Button {
            selectedGenre = genre
        } label: {
            Text(count.map { "\(genre ?? L("home.chip_all")) (\($0))" } ?? (genre ?? L("home.chip_all")))
                .font(AppTheme.fontBadge)
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(isSelected ? AppTheme.accent : AppTheme.elevated))
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        Group {
            if displayItems.isEmpty {
                ContentUnavailableView(L("list.no_result"), systemImage: "film")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: posterMetrics.gridRowSpacing) {
                        ForEach(Array(displayItems.prefix(visibleCount).enumerated()), id: \.element.id) { index, movie in
                            NavigationLink {
                                MovieDetailView(playlist: playlist, movie: movie, queue: displayItems)
                            } label: {
                                moviePosterCard(
                                    movie,
                                    posterWidth: posterMetrics.categoryGridPosterWidth,
                                    posterHeight: posterMetrics.categoryGridPosterHeight,
                                    imageLoadProfile: .grid,
                                    isNew: newestMovieIdSet.contains(movie.streamId)
                                )
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if index >= visibleCount - 15 {
                                    visibleCount = min(visibleCount + Self.pageSize, displayItems.count)
                                }
                            }
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
    }

    private func recompute() async {
        guard playlist.id == contentStore.activePlaylistId else { return }
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod")
        let source = contentStore.vodStreams
        let genre = selectedGenre
        let decade = selectedDecade
        let sort = sortMode
        let result = await Task.detached(priority: .userInitiated) {
            () -> (items: [DBVODStream], genres: [(name: String, count: Int)], decades: [(decade: Int, count: Int)]) in
            let visible = source.lazy
                .filter { !hidden.contains($0.stream.categoryId ?? "") }
                .map(\.stream)

            // Facets count the WHOLE visible catalog (chips describe
            // the catalog, not the current filter result).
            var genreCount: [String: Int] = [:]
            var decadeCount: [Int: Int] = [:]
            for movie in visible {
                for g in DetailFormatting.genreList(movie.genre) {
                    genreCount[g, default: 0] += 1
                }
                if let year = DetailFormatting.releaseYear(from: movie.releaseDate) {
                    decadeCount[(year / 10) * 10, default: 0] += 1
                }
            }
            let genres = genreCount
                .sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
                .prefix(12)
                .map { (name: $0.key, count: $0.value) }
            let decades = decadeCount
                .sorted { $0.key > $1.key }
                .map { (decade: $0.key, count: $0.value) }

            var filtered = Array(visible.filter { movie in
                if let genre {
                    let mine = DetailFormatting.genreList(movie.genre)
                    if !mine.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame }) { return false }
                }
                if let decade {
                    guard let year = DetailFormatting.releaseYear(from: movie.releaseDate) else { return false }
                    if (year / 10) * 10 != decade { return false }
                }
                return true
            })
            switch sort {
            case .rating:
                filtered.sort { a, b in
                    let r1 = ContentRating.normalizedRating10(rating: a.rating, rating5Based: a.rating5Based) ?? -1
                    let r2 = ContentRating.normalizedRating10(rating: b.rating, rating5Based: b.rating5Based) ?? -1
                    if r1 != r2 { return r1 > r2 }
                    return a.sortIndex < b.sortIndex
                }
            case .newest:
                filtered.sort { a, b in
                    let t1 = a.added.flatMap(Int.init) ?? Int.min
                    let t2 = b.added.flatMap(Int.init) ?? Int.min
                    if t1 != t2 { return t1 > t2 }
                    return a.sortIndex < b.sortIndex
                }
            case .releaseYear:
                filtered.sort { a, b in
                    let y1 = DetailFormatting.releaseYear(from: a.releaseDate) ?? Int.min
                    let y2 = DetailFormatting.releaseYear(from: b.releaseDate) ?? Int.min
                    if y1 != y2 { return y1 > y2 }
                    let r1 = ContentRating.normalizedRating10(rating: a.rating, rating5Based: a.rating5Based) ?? -1
                    let r2 = ContentRating.normalizedRating10(rating: b.rating, rating5Based: b.rating5Based) ?? -1
                    if r1 != r2 { return r1 > r2 }
                    return a.sortIndex < b.sortIndex
                }
            case .name:
                filtered.sort {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
            return (Array(filtered), genres, decades)
        }.value
        guard !Task.isCancelled else { return }
        displayItems = result.items
        genreCounts = result.genres
        decadeCounts = result.decades
        visibleCount = min(Self.pageSize, result.items.count)
    }
}

// MARK: - People browsing (round 15, C7)

/// Every title in this catalog — movies and series — whose cast or
/// director list contains the tapped person. Matches run over the
/// loaded records' own people fields; titles whose metadata was never
/// fetched simply don't appear (nothing is invented).
struct PersonTitlesView: View {
    let playlist: Playlist
    let person: String

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @Environment(\.posterMetrics) private var posterMetrics
    @State private var movies: [DBVODStream] = []
    @State private var seriesList: [DBSeries] = []

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    /// Build 90 (RC6): built once per body pass, not per cell.
    private var newestMovieIdSet: Set<Int> {
        Set(contentStore.sharedNewestMovies.map(\.streamId))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !movies.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        DetailSectionHeader(title: L("dashboard.movies"))
                            .padding(.horizontal, 16)
                        LazyVGrid(columns: columns, spacing: posterMetrics.gridRowSpacing) {
                            ForEach(movies) { movie in
                                NavigationLink {
                                    MovieDetailView(playlist: playlist, movie: movie, queue: movies)
                                } label: {
                                    moviePosterCard(
                                        movie,
                                        posterWidth: posterMetrics.categoryGridPosterWidth,
                                        posterHeight: posterMetrics.categoryGridPosterHeight,
                                        imageLoadProfile: .grid,
                                        isNew: newestMovieIdSet.contains(movie.streamId)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                if !seriesList.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        DetailSectionHeader(title: L("dashboard.series"))
                            .padding(.horizontal, 16)
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
                        .padding(.horizontal, 16)
                    }
                }
                if movies.isEmpty && seriesList.isEmpty {
                    ContentUnavailableView(L("list.no_result"), systemImage: "person.crop.rectangle")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(person)
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .cinematicBackground()
        .task(id: contentStore.streamsLoaded) { await compute() }
    }

    private func compute() async {
        let target = person.lowercased()
        let vodSnapshot = contentStore.vodStreams.map(\.stream)
        let seriesSnapshot = contentStore.seriesItems.map(\.series)
        let result = await Task.detached(priority: .utility) { () -> ([DBVODStream], [DBSeries]) in
            func matches(cast: String?, director: String?) -> Bool {
                (DetailFormatting.peopleList(cast) + DetailFormatting.peopleList(director))
                    .contains { $0.lowercased() == target }
            }
            return (
                vodSnapshot.filter { matches(cast: $0.cast, director: $0.director) },
                seriesSnapshot.filter { matches(cast: $0.cast, director: $0.director) }
            )
        }.value
        guard !Task.isCancelled else { return }
        movies = result.0
        seriesList = result.1
    }
}
