import SwiftUI

/// The app's ONE search system (opened from every tab's search
/// entry and from Home's top bar).
///
/// Round 10 redesign (owner, build 46 — the STRONG model): a big
/// Search title, ONE in-view search field, section pills
/// (Movie / Series / Live) and results in the app's card
/// language — poster cards for movies/series, logo rows for
/// channels. The old build used `.searchable`, whose field mounted
/// TWICE on focus (the doubled-field glitch in the owner's
/// recording); the field is now the shared `CatalogSearchField`.
/// Tapping a movie/series result opens its DETAIL page; tapping a
/// channel plays it and dismisses the search sheet cleanly.
struct SearchView: View {
    let playlist: Playlist
    @Binding var searchText: String
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var selectedFilter: SearchFilter = .movies

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    /// The section pills exactly as specified: Movie / Series /
    /// Live. (The old build's extra "All" grouping is gone.)
    enum SearchFilter: String, CaseIterable {
        case movies, series, live

        var displayName: String {
            switch self {
            case .movies: return L("dashboard.movies")
            case .series: return L("dashboard.series")
            case .live:   return L("dashboard.live")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("search.title"))
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)

                CatalogSearchField(text: $searchText, placeholder: L("search.placeholder"))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SearchFilter.allCases, id: \.self) { filter in
                            PillChipButton(
                                title: filter.displayName,
                                isSelected: selectedFilter == filter
                            ) {
                                selectedFilter = filter
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Divider()

            if debouncedQuery.count < 2 {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary.opacity(0.4))
                    .padding(.bottom, 8)
                Text(L("search.min_chars"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                SearchResultsView(
                    playlist: playlist,
                    query: debouncedQuery,
                    filter: selectedFilter,
                    onPlayLive: { item, queue, sections in
                        playLive(item, queue: queue, sections: sections)
                    }
                )
            }
        }
        .onChange(of: searchText) { _, raw in
            debounceTask?.cancel()
            let q = raw.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { debouncedQuery = ""; return }
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { debouncedQuery = q }
            }
        }
        .onDisappear { debounceTask?.cancel() }
        .cinematicBackground()
    }

    /// Play a channel result: present the player on the dashboard
    /// overlay, then dismiss the search sheet — the player is never
    /// left hidden behind the sheet (the old build presented without
    /// dismissing).
    private func playLive(
        _ item: LiveStreamWithCategory,
        queue: [DBLiveStream],
        sections: [LiveChannelCategorySection]
    ) {
        playerOverlay.present(playlistId: playlist.id) {
            LivePlayerShell(
                playlist: playlist,
                queue: queue,
                sections: sections,
                initialStream: item.stream,
                initialHistory: nil,
                subtitle: nil
            )
        }
        dismiss()
    }
}

// MARK: - Results

private struct SearchResultsView: View {
    let playlist: Playlist
    let query: String
    let filter: SearchView.SearchFilter
    let onPlayLive: (LiveStreamWithCategory, [DBLiveStream], [LiveChannelCategorySection]) -> Void

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @Environment(\.posterMetrics) private var posterMetrics

    @State private var liveResults: [LiveStreamWithCategory] = []
    @State private var movieResults: [VODWithCategory] = []
    @State private var seriesResults: [SeriesWithCategory] = []

    /// The play queue handed to the player shell: every live result.
    private var liveQueue: [DBLiveStream] { liveResults.map(\.stream) }

    /// Category sections for the player's channel browser, grouped
    /// in result order (single O(N) pass at tap time).
    private var liveSections: [LiveChannelCategorySection] {
        var seen = Set<String>()
        var ids: [String] = []
        for item in liveResults {
            let cid = item.stream.categoryId ?? "other"
            if seen.insert(cid).inserted { ids.append(cid) }
        }
        let grouped = Dictionary(grouping: liveResults) { $0.stream.categoryId ?? "other" }
        return ids.compactMap { cid -> LiveChannelCategorySection? in
            guard let items = grouped[cid], let first = items.first else { return nil }
            return LiveChannelCategorySection(id: cid, title: first.categoryName, streams: items.map(\.stream))
        }
    }

    private var posterColumns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    /// Whether the SELECTED section has no matches (the empty
    /// state is per-section, matching the pill model).
    private var selectedIsEmpty: Bool {
        switch filter {
        case .movies: return movieResults.isEmpty
        case .series: return seriesResults.isEmpty
        case .live:   return liveResults.isEmpty
        }
    }

    var body: some View {
        Group {
            if selectedIsEmpty {
                if !contentStore.streamsLoaded {
                    // The catalog is still loading: showing a false "no results" makes it look to the user
                    // as if the content has disappeared. When streamsLoaded [becomes true], the [real state] below
                    // .task tekrar arar.
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L("common.loading"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                switch filter {
                case .movies: movieGrid
                case .series: seriesGrid
                case .live:   liveList
                }
            }
        }
        .task(id: query) { await runSearch() }
        .task(id: filter) { await runSearch() }
        .task(id: hiddenStore.version) { await runSearch() }
        .task(id: contentStore.streamsLoaded) { await runSearch() }
    }

    // MARK: Single-type sections

    private var movieGrid: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: posterMetrics.gridRowSpacing) {
                ForEach(movieResults) { item in
                    NavigationLink {
                        // Round 14 (B1): pass the search-result list
                        // as the player queue — the same context the
                        // category grids pass — so prev/next in the
                        // player walk the results the user came from,
                        // not a single isolated movie.
                        MovieDetailView(
                            playlist: playlist,
                            movie: item.stream,
                            queue: movieResults.map(\.stream)
                        )
                    } label: {
                        VODStreamCard(
                            playlistId: playlist.id,
                            stream: item.stream,
                            categoryName: item.categoryName,
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

    private var seriesGrid: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: posterMetrics.gridRowSpacing) {
                ForEach(seriesResults) { item in
                    NavigationLink {
                        SeriesDetailView(playlist: playlist, series: item.series)
                    } label: {
                        SeriesCard(
                            playlistId: playlist.id,
                            stream: item.series,
                            categoryName: item.categoryName,
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

    private var liveList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(liveResults) { item in
                    liveRow(item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: Rows

    /// A channel row: the logo WHOLE (aspect-fit — the same clarity
    /// rule as Continue Watching), name + category, tap to play.
    private func liveRow(_ item: LiveStreamWithCategory) -> some View {
        Button {
            onPlayLive(item, liveQueue, liveSections)
        } label: {
            HStack(spacing: 12) {
                CachedImage(
                    url: item.stream.streamIcon.flatMap { URL(string: $0) },
                    width: 64,
                    height: 44,
                    cornerRadius: AppTheme.smallCornerRadius,
                    contentMode: .fit,
                    iconName: "tv",
                    loadProfile: .grid
                )
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                        .fill(AppTheme.surface)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.stream.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(item.categoryName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.accent)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Search engine

    /// Round 14 (B10): result cap for the selected section. The grids
    /// render lazily, but an uncapped match list on a ~100k-row
    /// catalog still costs a full sort + array per keystroke.
    private static var resultCap: Int { 300 }

    /// Round 14 (B10): only the SELECTED content type is searched
    /// (the old engine filtered and alphabetically sorted all three
    /// types on every keystroke, then showed one). Matching and
    /// ordering now use the catalog's existing relevance machinery
    /// (`CatalogTextSearch` — exact/prefix matches first), the same
    /// sort the store's per-category search applies, and results are
    /// capped at `resultCap`. Hidden categories stay excluded.
    private func runSearch() async {
        let q = query
        switch filter {
        case .movies:
            let source = contentStore.vodStreams
            let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod")
            let result = await Task.detached(priority: .userInitiated) {
                // Round 15 (C7): people names match too — a movie
                // whose cast/director list contains the query joins
                // the results after the title matches (relevance
                // sort still leads with title hits).
                let titleMatches = source.filter {
                    !hidden.contains($0.stream.categoryId ?? "")
                        && CatalogTextSearch.matches(search: q, text: $0.stream.name)
                }
                let titleIds = Set(titleMatches.map(\.stream.streamId))
                let peopleMatches = source.filter { item in
                    !hidden.contains(item.stream.categoryId ?? "")
                        && !titleIds.contains(item.stream.streamId)
                        && (DetailFormatting.peopleList(item.stream.cast) + DetailFormatting.peopleList(item.stream.director))
                            .contains { CatalogTextSearch.matches(search: q, text: $0) }
                }
                let ordered = CatalogTextSearch.sortVODByRelevance(titleMatches, search: q) + peopleMatches
                return Array(ordered.prefix(Self.resultCap))
            }.value
            guard !Task.isCancelled else { return }
            movieResults = result
            liveResults = []
            seriesResults = []
        case .series:
            let source = contentStore.seriesItems
            let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "series")
            let result = await Task.detached(priority: .userInitiated) {
                // Round 15 (C7): people names match too, as above.
                let titleMatches = source.filter {
                    !hidden.contains($0.series.categoryId ?? "")
                        && CatalogTextSearch.matches(search: q, text: $0.series.name)
                }
                let titleIds = Set(titleMatches.map(\.series.seriesId))
                let peopleMatches = source.filter { item in
                    !hidden.contains(item.series.categoryId ?? "")
                        && !titleIds.contains(item.series.seriesId)
                        && (DetailFormatting.peopleList(item.series.cast) + DetailFormatting.peopleList(item.series.director))
                            .contains { CatalogTextSearch.matches(search: q, text: $0) }
                }
                let ordered = CatalogTextSearch.sortSeriesByRelevance(titleMatches, search: q) + peopleMatches
                return Array(ordered.prefix(Self.resultCap))
            }.value
            guard !Task.isCancelled else { return }
            seriesResults = result
            liveResults = []
            movieResults = []
        case .live:
            let source = contentStore.liveStreams
            let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "live")
            let result = await Task.detached(priority: .userInitiated) {
                let filtered = source.filter {
                    !hidden.contains($0.stream.categoryId ?? "")
                        && CatalogTextSearch.matches(search: q, text: $0.stream.name)
                }
                return Array(CatalogTextSearch.sortLiveByRelevance(filtered, search: q).prefix(Self.resultCap))
            }.value
            guard !Task.isCancelled else { return }
            liveResults = result
            movieResults = []
            seriesResults = []
        }
    }
}
