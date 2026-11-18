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
    @State private var homeSearchText = ""
    @State private var showSearchSheet = false

    // Round 5: unified content pattern — filter chips.
    // Round 8 (D-4/D-5): the Favorites and History chips were removed —
    // they duplicated the nav-bar star's FavoritesView and the Continue
    // Watching row, which are now the ONE entry for each. Remaining
    // chips are pure orderings: All (shelves) and Newest (the catalog's
    // `added` ordering, extended cut). Their grids/queries went too.
    @State private var selectedChip: ContentChip = .all

    // The filtering results are computed in the background; only the assignment is made on the main thread
    @State private var displayCategories: [DBCategory] = []
    @State private var displayItemsByCategory: [String: [VODWithCategory]] = [:]
    @State private var recentlyAddedVODs: [DBVODStream] = []
    @State private var newestVODs: [DBVODStream] = []
    @State private var topRatedVODs: [DBVODStream] = []

    init(playlist: Playlist) {
        self.playlist = playlist
    }

    @State private var showingCategoryPicker = false
    @State private var pendingScrollTarget: String? = nil

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
                        ProgressView()
                            .scaleEffect(1.2)
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
                ScrollViewReader { proxy in
                    ScrollView {
                        tabHeader

                        // The chips swap the scroll content — All keeps
                        // the shelves; Newest renders its grid.
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

                            if topRatedVODs.count >= 3 {
                                TopMoviesShelf(playlist: playlist, items: topRatedVODs, replayToken: shelfReplayToken)
                            }

                            if !recentlyAddedVODs.isEmpty {
                                RecentlyAddedVODShelf(playlist: playlist, items: recentlyAddedVODs)
                            }

                            if !watchlistMovies.isEmpty {
                                WatchlistShelf(playlist: playlist, items: watchlistMovies)
                            }

                            if !franchiseGroups.isEmpty {
                                MovieCollectionsShelf(playlist: playlist, groups: franchiseGroups)
                            }

                            LazyVStack(spacing: 0) {
                                ForEach(displayCategories) { category in
                                    VODCategoryShelfRow(
                                        playlist: playlist,
                                        category: category,
                                        items: displayItemsByCategory[category.id] ?? [],
                                        isStreamsLoading: !contentStore.streamsLoaded
                                    )
                                    .equatable()
                                    .id(category.id)
                                }
                            }
                        case .newest:
                            newestGrid
                        }
                    }
                    .refreshable {
                        // Independent Task: so the refreshable cancellation doesn't propagate to the requests (see LiveStreamsView).
                        let work = Task { await contentStore.refreshFromNetwork(playlist: playlist, only: .vod) }
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
                }
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
        .sheet(isPresented: $showSearchSheet) {
            NavigationStack {
                // Round 10: SearchView owns its big title — the
                // wrapper's inline title was removed.
                SearchView(playlist: playlist, searchText: $homeSearchText)
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
        .transaction { $0.animation = nil }
        .navigationDestination(item: $pendingMovieDetail) { movie in
            MovieDetailView(playlist: playlist, movie: movie)
        }
        .cinematicBackground()
    }

    /// Round 5 elite header, reordered in round 7 by the owner's direct
    /// order ("search must be at the top"): the tab's ONE search entry
    /// is the FIRST element under the title, then the REAL visible
    /// movie total, then the filter chips.
    private var tabHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSearchBar(placeholder: L("home.search_placeholder")) {
                showSearchSheet = true
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

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
                            VODStreamCard(
                                playlistId: playlist.id,
                                stream: movie,
                                posterWidth: posterMetrics.categoryGridPosterWidth,
                                posterHeight: posterMetrics.categoryGridPosterHeight,
                                imageLoadProfile: .grid
                            )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        // Round 14 (B7): paginate like
                        // VODCategoryContent — the next page loads
                        // as the end approaches, no silent cap.
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
                    ProgressView()
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
            displayCategories = []; displayItemsByCategory = [:]; recentlyAddedVODs = []; newestVODs = []; topRatedVODs = []; newestAll = []; franchiseGroups = []; return
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
        newestVODs = Array(sharedNewest.filter { visibleCatIds.contains($0.categoryId ?? "") }.prefix(60))

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
                artworkURL: item.imageURL.flatMap { URL(string: $0) },
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
                                imageURL: items[index].streamIcon.flatMap { URL(string: $0) },
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
                        .shelfEntrance(index: index, replayToken: replayToken)
                    }
                }
                .padding(.horizontal, 16)
            }
            .shelfEdgeFade()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Recently Added shelf

struct RecentlyAddedVODShelf: View, Equatable {
    let playlist: Playlist
    let items: [DBVODStream]

    static func == (lhs: RecentlyAddedVODShelf, rhs: RecentlyAddedVODShelf) -> Bool {
        lhs.playlist.id == rhs.playlist.id && lhs.items == rhs.items
    }

    @Environment(\.posterMetrics) private var posterMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Round 8: the ONE shelf-header style (was headline +
            // chevron); destination unchanged.
            CinematicSectionHeader(title: L("recently_added.title")) {
                RecentlyAddedVODDetailView(playlist: playlist, items: items)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { stream in
                        NavigationLink {
                            MovieDetailView(playlist: playlist, movie: stream, queue: items)
                        } label: {
                            VODStreamCard(
                                playlistId: playlist.id,
                                stream: stream,
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                imageLoadProfile: .shelf
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: posterMetrics.shelfRowTotalHeight)
            .shelfEdgeFade()
        }
        .padding(.vertical, 6)
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
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var recomputed: [VODWithCategory]?

    private var wrapped: [VODWithCategory] {
        recomputed ?? items.map { VODWithCategory(stream: $0, categoryName: "") }
    }

    private var displayItems: [VODWithCategory] {
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return wrapped }
        return wrapped.filter { CatalogTextSearch.matches(search: q, text: $0.stream.name) }
    }

    var body: some View {
        VODCategoryContent(playlist: playlist, items: displayItems)
            .equatable()
            .navigationTitle(L("recently_added.title"))
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

    static func == (lhs: VODCategoryShelfRow, rhs: VODCategoryShelfRow) -> Bool {
        lhs.playlist.id == rhs.playlist.id &&
        lhs.category == rhs.category &&
        lhs.items == rhs.items &&
        lhs.isStreamsLoading == rhs.isStreamsLoading
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
                                VODStreamCard(
                                    playlistId: playlist.id,
                                    stream: item.stream,
                                    posterWidth: posterMetrics.shelfPosterWidth,
                                    posterHeight: posterMetrics.shelfPosterHeight,
                                    imageLoadProfile: .shelf
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
                    stopPrefetchIcons(from: items)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func prefetchIcons(from list: [VODWithCategory]) {
        let urls = list.prefix(VODCategoryShelf.prefetchHeadCount)
            .compactMap { $0.stream.streamIcon }
            .compactMap { URL(string: $0) }
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
    private func prefetchWindow(from list: [VODWithCategory], after index: Int) {
        let start = index + 1
        guard start < list.count else { return }
        let urls = list[start..<min(start + ListImagePrefetch.scrollWindow, list.count)]
            .compactMap { $0.stream.streamIcon }
            .compactMap { URL(string: $0) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
    }

    private func stopPrefetchIcons(from list: [VODWithCategory]) {
        let urls = list.prefix(VODCategoryShelf.prefetchHeadCount)
            .compactMap { $0.stream.streamIcon }
            .compactMap { URL(string: $0) }
        ListImagePrefetch.stop(
            urls: urls,
            width: posterMetrics.shelfPosterWidth,
            height: posterMetrics.shelfPosterHeight,
            contentMode: .fill,
            loadProfile: .shelf
        )
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
                    url: stream.streamIcon.flatMap { URL(string: $0) },
                    width: posterWidth,
                    height: posterHeight,
                    contentMode: SwiftUI.ContentMode.fill,
                    iconName: "film",
                    loadProfile: imageLoadProfile
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
                .font(AppTheme.fontCardTitle)
                .lineLimit(2)
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
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var displayItems: [VODWithCategory] = []

    var body: some View {
        VODCategoryContent(playlist: playlist, items: displayItems)
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
        let result = await Task.detached(priority: .userInitiated) {
            let filtered = base.filter { CatalogTextSearch.matches(search: q, text: $0.stream.name) }
            return CatalogTextSearch.sortVODByRelevance(filtered, search: q)
        }.value
        guard !Task.isCancelled else { return }
        displayItems = result
    }
}

struct VODCategoryContent: View, Equatable {
    let playlist: Playlist
    let items: [VODWithCategory]

    /// Cheap signature compare so a parent re-render (e.g. `applyVODMetadata`'s
    /// @Published storm) doesn't force SwiftUI to re-process a 10k-item view — that
    /// scaled with catalog size and froze "All Movies" for seconds on return.
    /// Internal @State/@Query updates still invalidate normally, independent of this.
    static func == (lhs: VODCategoryContent, rhs: VODCategoryContent) -> Bool {
        lhs.playlist.id == rhs.playlist.id
            && lhs.items.count == rhs.items.count
            && lhs.items.first?.stream.id == rhs.items.first?.stream.id
            && lhs.items.last?.stream.id == rhs.items.last?.stream.id
    }

    @Environment(\.posterMetrics) private var posterMetrics
    @Query<WatchProgressMapRequest> private var progressMap: [String: Double]

    @AppStorage(VODSortOption.storageKey) private var sortOption: VODSortOption = .defaultOrder
    @State private var showSortSheet = false
    /// Screen-local: file types are specific to the currently shown list, so this
    /// intentionally does not persist across screens.
    @State private var fileTypeFilter: Set<String> = []
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

    init(playlist: Playlist, items: [VODWithCategory]) {
        self.playlist = playlist
        self.items = items
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
        sortOption != .defaultOrder || !fileTypeFilter.isEmpty
    }

    private func recompute() async {
        let source = items
        let sort = sortOption
        let filter = fileTypeFilter
        let (result, queue, types) = await Task.detached(priority: .userInitiated) { () -> ([VODWithCategory], [DBVODStream], [String]) in
            let sorted = sort.apply(to: VODFileType.filter(source, selection: filter))
            // Options come from the full list so toggling one doesn't hide the others.
            return (sorted, sorted.map(\.stream), VODFileType.available(in: source))
        }.value
        guard !Task.isCancelled else { return }
        displayItems = result
        streamQueue = queue
        fileTypes = types
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
                                    VODStreamCard(
                                        playlistId: playlist.id,
                                        stream: item.stream,
                                        posterWidth: posterMetrics.categoryGridPosterWidth,
                                        posterHeight: posterMetrics.categoryGridPosterHeight,
                                        imageLoadProfile: .grid,
                                        watchProgress: progressMap[String(item.stream.streamId)]
                                    )
                                }
                                .buttonStyle(.plain)
                                // Load the next page while cells near the end scroll into view.
                                // Triggered from inside the lazy grid so onAppear is reliable.
                                .onAppear { if index >= visibleCount - 15 { loadMore() } }
                            }
                        }
                        .padding()
                        .id(Self.gridTopID)

                        if visibleCount < displayItems.count {
                            ProgressView()
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
                sortRows: VODSortOption.allCases.map { option in
                    SortFilterSheet.Row(
                        id: option.rawValue,
                        title: L(option.titleKey),
                        systemImage: option.systemImage,
                        isSelected: sortOption == option
                    ) { sortOption = option }
                },
                filterTitle: fileTypes.count > 1 ? L("filter.file_type") : nil,
                filterRows: fileTypes.count > 1 ? fileTypes.map { ext in
                    SortFilterSheet.Row(
                        id: "type-\(ext)",
                        title: ext.uppercased(),
                        isSelected: fileTypeFilter.contains(ext)
                    ) { toggleFileType(ext) }
                } : [],
                // Round 14 (B1): Clear resets the SORT as well as the
                // file-type filter.
                onClearFilters: (sortOption == .defaultOrder && fileTypeFilter.isEmpty) ? nil : {
                    sortOption = .defaultOrder
                    fileTypeFilter.removeAll()
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
        let urls = list.dropFirst(startingAt).prefix(ListImagePrefetch.maxBatch)
            .compactMap { $0.stream.streamIcon }
            .compactMap { URL(string: $0) }
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
        VODCategoryContent(playlist: playlist, items: displayItems)
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
            let filtered = base.filter { CatalogTextSearch.matches(search: q, text: $0.stream.name) }
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
                artworkURL: currentMovie.streamIcon.flatMap { URL(string: $0) },
                isLiveStream: false,
                playlistId: playlist.id,
                streamId: String(currentMovie.streamId),
                type: "vod",
                resumeTimeMs: resumeMs,
                containerExtension: currentMovie.containerExtension,
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

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedImage(
                url: movie.backdropPath.flatMap { URL(string: $0) } ?? movie.streamIcon.flatMap { URL(string: $0) },
                width: UIScreen.main.bounds.width - 32,
                height: 210,
                cornerRadius: AppTheme.heroCornerRadius,
                contentMode: .fill,
                iconName: "film",
                loadProfile: .high
            )
            LinearGradient(
                colors: [.clear, AppTheme.background.opacity(0.88)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(L("home.featured"))
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(AppTheme.accent)
                Text(movie.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 10) {
                    if let rating = ContentRating.normalizedDisplayText(rating: movie.rating, rating5Based: movie.rating5Based) {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(AppTheme.ratingGold)
                            Text(rating)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    if let year = DetailFormatting.year(from: movie.releaseDate) {
                        Text(year)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    if let genre = movie.genre?.split(separator: ",").first {
                        Text(genre.trimmingCharacters(in: .whitespaces))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 10) {
                    Button(action: onPlay) {
                        Label(L("home.play"), systemImage: "play.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(AppTheme.accent))
                    }
                    .buttonStyle(.plain)
                    Button(action: onDetails) {
                        Label(L("home.details"), systemImage: "info.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                .strokeBorder(AppTheme.cardBorderColor, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        // Section identity (round 14, A7): the Movies hero carries
        // the section's own accent token.
        .tint(SectionTheme.movies)
    }
}

// MARK: - Watchlist shelf + view (round 15, C7)

struct WatchlistShelf: View, Equatable {
    let playlist: Playlist
    let items: [DBVODStream]

    static func == (lhs: WatchlistShelf, rhs: WatchlistShelf) -> Bool {
        lhs.playlist.id == rhs.playlist.id && lhs.items == rhs.items
    }

    @Environment(\.posterMetrics) private var posterMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CinematicSectionHeader(title: L("watchlist.title")) {
                WatchlistView(playlist: playlist)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { movie in
                        NavigationLink {
                            MovieDetailView(playlist: playlist, movie: movie, queue: items)
                        } label: {
                            VODStreamCard(
                                playlistId: playlist.id,
                                stream: movie,
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                imageLoadProfile: .shelf
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: posterMetrics.shelfRowTotalHeight)
            .shelfEdgeFade()
        }
        .padding(.vertical, 6)
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

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    var body: some View {
        Group {
            if movies.isEmpty {
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
                                VODStreamCard(
                                    playlistId: playlist.id,
                                    stream: movie,
                                    posterWidth: posterMetrics.categoryGridPosterWidth,
                                    posterHeight: posterMetrics.categoryGridPosterHeight,
                                    imageLoadProfile: .grid
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
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
                                        url: group.movies.first?.streamIcon.flatMap { URL(string: $0) },
                                        width: posterMetrics.shelfPosterWidth,
                                        height: posterMetrics.shelfPosterHeight,
                                        contentMode: .fill,
                                        iconName: "film",
                                        loadProfile: .shelf
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
        }
        .padding(.vertical, 6)
    }
}

/// One franchise collection: its movies in release order.
struct MovieCollectionView: View {
    let playlist: Playlist
    let title: String
    let movies: [DBVODStream]

    @Environment(\.posterMetrics) private var posterMetrics

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: posterMetrics.gridRowSpacing) {
                ForEach(movies) { movie in
                    NavigationLink {
                        MovieDetailView(playlist: playlist, movie: movie, queue: movies)
                    } label: {
                        VODStreamCard(
                            playlistId: playlist.id,
                            stream: movie,
                            posterWidth: posterMetrics.categoryGridPosterWidth,
                            posterHeight: posterMetrics.categoryGridPosterHeight,
                            imageLoadProfile: .grid
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
                                VODStreamCard(
                                    playlistId: playlist.id,
                                    stream: movie,
                                    posterWidth: posterMetrics.categoryGridPosterWidth,
                                    posterHeight: posterMetrics.categoryGridPosterHeight,
                                    imageLoadProfile: .grid
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
                        ProgressView()
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
                                    VODStreamCard(
                                        playlistId: playlist.id,
                                        stream: movie,
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
