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
///
/// Build 64 (B2, Search style 2 'Instant Overlay' — the owner's
/// pick): compact brand header instead of the big title, an All
/// tab unifying the three types into one relevance-merged rich-
/// row list, rich rows (thumbnail / year • genre / real rating /
/// type badge) on every tab, and an empty-query discovery state
/// (recent searches + a Trending Now strip from the shared
/// top-rated lists).
struct SearchView: View {
    let playlist: Playlist
    @Binding var searchText: String
    /// Build 63 (item 15): the section the user opened search FROM.
    /// The pill row used to ALWAYS start on Movies, so searching
    /// from the Series tab hunted through the movies and "found
    /// nothing" for series titles until the user noticed and tapped
    /// the Series pill by hand — the owner's "I type a series name
    /// and it barely shows up". Each section's search entry passes
    /// its own filter (build 64, A4 completes the wiring: Movies
    /// passes .movies too); Home passes .all (build 64, B2).
    var initialFilter: SearchFilter = .movies
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var selectedFilter: SearchFilter

    init(playlist: Playlist, searchText: Binding<String>, initialFilter: SearchFilter = .movies) {
        self.playlist = playlist
        self.initialFilter = initialFilter
        self._searchText = searchText
        self._selectedFilter = State(initialValue: initialFilter)
    }
    /// Build 61 (B10, Q14): persisted recent queries (the ONE
    /// SearchHistoryStore — the same store Settings ▸ Storage
    /// clears), shown while the field is empty/short.
    @State private var historyQueries: [String] = SearchHistoryStore.queries
    @State private var historyRecordTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    /// The section pills: All / Movie / Series / Live, plus
    /// Programmes (build 61, B1 item 4 — EPG programme-title
    /// search through the same core as the guide's programme
    /// search). Build 64 (B2) adds the All tab — the unified
    /// instant search the owner picked (Search style 2).
    enum SearchFilter: String, CaseIterable {
        case all, movies, series, live, programmes

        var displayName: String {
            switch self {
            case .all:    return L("search.all")
            case .movies: return L("dashboard.movies")
            case .series: return L("dashboard.series")
            case .live:   return L("dashboard.live")
            case .programmes: return L("epgsearch.programmes")
            }
        }
    }

    /// Build 64 (B2): the trending strip's source — the store's
    /// shared top-rated lists (existing data only, nothing
    /// invented), merged by their real normalized scores.
    @ObservedObject private var contentStore = PlaylistContentStore.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // Build 64 (B2, Search style 2 'Instant Overlay'):
                // compact brand header — the same flame + wordmark
                // treatment as Home's top bar — instead of the old
                // big page title; the field + pills sit directly
                // under it and results update as the user types.
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.brandGradient)
                    Text("Super")
                    Text("X")
                        .foregroundColor(AppTheme.accent)
                }
                .font(.system(size: 20, weight: .black))
                .latinBrandTracking(-0.5)
                .foregroundStyle(.white)

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
                if historyQueries.isEmpty && trendingItems.isEmpty {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary.opacity(0.4))
                        .padding(.bottom, 8)
                    Text(L("search.min_chars"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    // Build 64 (B2): the empty-query state is a
                    // scrollable discovery surface — recent
                    // searches (Q14, unchanged store/semantics) and
                    // the Trending Now poster strip from the
                    // catalog's real top-rated lists.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if !historyQueries.isEmpty {
                                recentsSection
                            }
                            if !trendingItems.isEmpty {
                                trendingSection
                            }
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 16)
                    }
                }
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
        .onChange(of: debouncedQuery) { _, q in
            // Q14: a query is recorded only after it SETTLES
            // (unchanged for 1.5 s) — intermediate keystroke
            // prefixes never land in the history.
            historyRecordTask?.cancel()
            guard q.count >= 2 else { return }
            historyRecordTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    SearchHistoryStore.record(q)
                    historyQueries = SearchHistoryStore.queries
                }
            }
        }
        .onAppear { historyQueries = SearchHistoryStore.queries }
        .onDisappear {
            debounceTask?.cancel()
            historyRecordTask?.cancel()
        }
        .cinematicBackground()
    }

    // MARK: - Empty-query discovery (B2)

    /// Q14: recent searches, tap to re-run, one clear for the whole
    /// list (same store the Settings row clears).
    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("searchhistory.title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    SearchHistoryStore.clear()
                    historyQueries = []
                } label: {
                    Text(L("searchhistory.clear"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            ForEach(historyQueries, id: \.self) { item in
                Button {
                    searchText = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        Text(item)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(L("searchhistory.rerun.hint"))
            }
        }
    }

    /// One trending entry: a top-rated movie or series from the
    /// store's shared rankings (real records, real scores only).
    private enum TrendingItem: Identifiable {
        case movie(DBVODStream)
        case series(DBSeries)

        var id: String {
            switch self {
            case .movie(let movie): return "vod:\(movie.streamId)"
            case .series(let series): return "series:\(series.seriesId)"
            }
        }

        var score: Double {
            switch self {
            case .movie(let movie):
                return ContentRating.normalizedRating10(rating: movie.rating, rating5Based: movie.rating5Based) ?? 0
            case .series(let series):
                return ContentRating.normalizedRating10(rating: series.rating, rating5Based: series.rating5Based) ?? 0
            }
        }
    }

    private var trendingItems: [TrendingItem] {
        let movies = contentStore.sharedTopRatedMovies.prefix(10).map(TrendingItem.movie)
        let series = contentStore.sharedTopRatedSeries.prefix(10).map(TrendingItem.series)
        return Array((movies + series).sorted { $0.score > $1.score }.prefix(12))
    }

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("search.trending"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(trendingItems.enumerated()), id: \.element.id) { index, item in
                        trendingCard(item, rank: index + 1)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private func trendingCard(_ item: TrendingItem, rank: Int) -> some View {
        switch item {
        case .movie(let movie):
            NavigationLink {
                MovieDetailView(playlist: playlist, movie: movie, queue: contentStore.sharedTopRatedMovies)
            } label: {
                RankedPosterCard(
                    rank: rank,
                    imageURL: movie.streamIcon.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                    title: movie.name,
                    ratingText: ContentRating.normalizedDisplayText(rating: movie.rating, rating5Based: movie.rating5Based),
                    metaText: searchMetaLine(year: DetailFormatting.year(from: movie.releaseDate), genre: movie.genre),
                    posterWidth: 110,
                    posterHeight: 165,
                    iconName: "film"
                )
            }
            .buttonStyle(.plain)
        case .series(let series):
            NavigationLink {
                SeriesDetailView(playlist: playlist, series: series)
            } label: {
                RankedPosterCard(
                    rank: rank,
                    imageURL: series.cover.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                    title: series.name,
                    ratingText: ContentRating.normalizedDisplayText(rating: series.rating, rating5Based: series.rating5Based),
                    metaText: searchMetaLine(year: DetailFormatting.year(from: series.releaseDate), genre: series.genre),
                    posterWidth: 110,
                    posterHeight: 165,
                    iconName: "play.tv"
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// "2026 • Drama" from the record's own fields (same rule as
    /// Home's card meta line); nil when the record carries neither.
    private func searchMetaLine(year: String?, genre: String?) -> String? {
        var parts: [String] = []
        if let year { parts.append(year) }
        if let first = DetailFormatting.genreList(genre).first { parts.append(first) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
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

/// Build 61 (B1, item 4): one EPG programme match in global search.
/// Carries everything `EPGProgrammeDetailSheet` needs, resolved
/// with the same channel-key logic the guide uses.
private struct EPGProgrammeSearchResult: Identifiable {
    let programme: EPGProgramme
    let channelName: String
    let channelIcon: URL?
    let liveStream: DBLiveStream?
    var id: String { programme.id }
}

/// Build 64 (B2): one result on the All tab — a movie, series or
/// channel, rendered as a rich row with a type badge.
private enum UnifiedSearchResult: Identifiable {
    case movie(VODWithCategory)
    case series(SeriesWithCategory)
    case live(LiveStreamWithCategory)

    var id: String {
        switch self {
        case .movie(let item): return "vod:\(item.stream.streamId)"
        case .series(let item): return "series:\(item.series.seriesId)"
        case .live(let item): return "live:\(item.stream.streamId)"
        }
    }

    var title: String {
        switch self {
        case .movie(let item): return item.stream.name
        case .series(let item): return item.series.name
        case .live(let item): return item.stream.name
        }
    }
}

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
    /// Build 64 (B2): the All tab's merged results (one rich-row
    /// list across movies/series/live, relevance-merged).
    @State private var allResults: [UnifiedSearchResult] = []
    @State private var epgResults: [EPGProgrammeSearchResult] = []
    @State private var epgSearchRunning = false
    @State private var selectedProgramme: EPGProgrammeSearchResult?

    /// The play queue handed to the player shell: every live result.
    private var liveQueue: [DBLiveStream] { liveResults.map(\.stream) }

    /// Category sections for the player's channel browser, grouped
    /// in result order (single O(N) pass at tap time).
    private var liveSections: [LiveChannelCategorySection] {
        Self.liveSections(for: liveResults)
    }

    /// Build 64 (B2): parameterized so the All tab builds its
    /// queue/sections from ITS live subset, not `liveResults`.
    private static func liveSections(for items: [LiveStreamWithCategory]) -> [LiveChannelCategorySection] {
        var seen = Set<String>()
        var ids: [String] = []
        for item in items {
            let cid = item.stream.categoryId ?? "other"
            if seen.insert(cid).inserted { ids.append(cid) }
        }
        let grouped = Dictionary(grouping: items) { $0.stream.categoryId ?? "other" }
        return ids.compactMap { cid -> LiveChannelCategorySection? in
            guard let items = grouped[cid], let first = items.first else { return nil }
            return LiveChannelCategorySection(id: cid, title: first.categoryName, streams: items.map(\.stream))
        }
    }

    /// Whether the SELECTED section has no matches (the empty
    /// state is per-section, matching the pill model).
    private var selectedIsEmpty: Bool {
        switch filter {
        case .all:    return allResults.isEmpty
        case .movies: return movieResults.isEmpty
        case .series: return seriesResults.isEmpty
        case .live:   return liveResults.isEmpty
        case .programmes: return epgResults.isEmpty
        }
    }

    var body: some View {
        Group {
            if filter == .programmes {
                epgContent
            } else if selectedIsEmpty {
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
                case .all:    allList
                case .movies: movieList
                case .series: seriesList
                case .live:   liveList
                case .programmes: epgContent
                }
            }
        }
        .task(id: query) { await runSearch() }
        .task(id: filter) { await runSearch() }
        .task(id: hiddenStore.version) { await runSearch() }
        .task(id: contentStore.streamsLoaded) { await runSearch() }
        .sheet(item: $selectedProgramme) { result in
            EPGProgrammeDetailSheet(
                playlist: playlist,
                programme: result.programme,
                channelName: result.channelName,
                channelIcon: result.channelIcon,
                liveStream: result.liveStream
            )
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: EPG programmes section (build 61, B1 item 4)

    /// Programme-title results over the guide data loaded for
    /// TODAY and TOMORROW — the header discloses that scope, the
    /// same honesty pattern as the guide's own programme search
    /// (which discloses its selected-day scope).
    @ViewBuilder
    private var epgContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("epgsearch.scope"))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            if epgResults.isEmpty {
                if epgSearchRunning {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(epgResults) { result in
                            epgRow(result)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    /// A programme row: title, channel + time range; tap opens the
    /// programme detail sheet (reminders / play / catch-up live
    /// there, exactly as from the guide).
    private func epgRow(_ result: EPGProgrammeSearchResult) -> some View {
        Button {
            selectedProgramme = result
        } label: {
            HStack(spacing: 12) {
                CachedImage(
                    url: result.channelIcon,
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
                    Text(result.programme.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(result.channelName) · \(EPGTimeFormat.range(result.programme.start, result.programme.stop))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Result lists (build 64, B2 — rich rows)

    /// Build 64 (B2): Search style 2 replaces the poster grids
    /// with rich rows everywhere — thumbnail, title, year • genre
    /// meta, real rating badge, and (on the All tab) a type badge.
    private var allList: some View {
        let liveItems = allResults.compactMap { result -> LiveStreamWithCategory? in
            if case .live(let item) = result { return item } else { return nil }
        }
        let movieQueue = allResults.compactMap { result -> DBVODStream? in
            if case .movie(let item) = result { return item.stream } else { return nil }
        }
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(allResults) { result in
                    switch result {
                    case .movie(let item):
                        movieRow(item, queue: movieQueue, typeBadge: SearchView.SearchFilter.movies.displayName)
                    case .series(let item):
                        seriesRow(item, typeBadge: SearchView.SearchFilter.series.displayName)
                    case .live(let item):
                        liveRow(item, queue: liveItems.map(\.stream), sections: Self.liveSections(for: liveItems), typeBadge: SearchView.SearchFilter.live.displayName)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var movieList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(movieResults) { item in
                    movieRow(item, queue: movieResults.map(\.stream), typeBadge: nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var seriesList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(seriesResults) { item in
                    seriesRow(item, typeBadge: nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var liveList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(liveResults) { item in
                    liveRow(item, queue: liveQueue, sections: liveSections, typeBadge: nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: Rows

    /// The landscape thumbnail URL for a rich row: the record's
    /// backdrop when it carries one, else its poster/cover.
    private func backdropURL(backdrop: String?, poster: String?) -> URL? {
        if let backdrop = backdrop?.trimmingCharacters(in: .whitespaces), !backdrop.isEmpty {
            return URL(string: backdrop)
        }
        guard let poster = poster?.trimmingCharacters(in: .whitespaces), !poster.isEmpty else { return nil }
        return URL(string: poster)
    }

    /// The ★ rating capsule (real normalized score only — rows
    /// without a valid score show nothing, never an invented one).
    @ViewBuilder
    private func ratingBadge(rating: String?, rating5Based: Double?) -> some View {
        if let text = ContentRating.normalizedDisplayText(rating: rating, rating5Based: rating5Based) {
            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppTheme.ratingGold)
                Text(text)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(AppTheme.surface, in: Capsule())
        }
    }

    /// The All tab's type capsule (Movie / Series / Live).
    private func typeBadge(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(AppTheme.accent.opacity(0.15), in: Capsule())
    }

    /// "2026 • Drama" from the record's own fields; nil when it
    /// carries neither.
    private func rowMetaLine(year: String?, genre: String?) -> String? {
        var parts: [String] = []
        if let year { parts.append(year) }
        if let first = DetailFormatting.genreList(genre).first { parts.append(first) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    /// A movie rich row; tap opens the detail page with the
    /// result list as its player queue (round 14, B1 — unchanged).
    private func movieRow(_ item: VODWithCategory, queue: [DBVODStream], typeBadge badge: String?) -> some View {
        NavigationLink {
            MovieDetailView(playlist: playlist, movie: item.stream, queue: queue)
        } label: {
            HStack(spacing: 12) {
                CachedImage(
                    url: backdropURL(backdrop: item.stream.backdropPath, poster: item.stream.streamIcon),
                    width: 84,
                    height: 62,
                    cornerRadius: AppTheme.smallCornerRadius,
                    contentMode: .fill,
                    iconName: "film",
                    loadProfile: .grid
                )
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                        .fill(AppTheme.surface)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.stream.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let meta = rowMetaLine(year: DetailFormatting.year(from: item.stream.releaseDate), genre: item.stream.genre) {
                        Text(meta)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Text(item.categoryName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    ratingBadge(rating: item.stream.rating, rating5Based: item.stream.rating5Based)
                    if let badge { typeBadge(badge) }
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A series rich row; tap opens the series detail page.
    private func seriesRow(_ item: SeriesWithCategory, typeBadge badge: String?) -> some View {
        NavigationLink {
            SeriesDetailView(playlist: playlist, series: item.series)
        } label: {
            HStack(spacing: 12) {
                CachedImage(
                    url: backdropURL(backdrop: item.series.backdropPath, poster: item.series.cover),
                    width: 84,
                    height: 62,
                    cornerRadius: AppTheme.smallCornerRadius,
                    contentMode: .fill,
                    iconName: "play.tv",
                    loadProfile: .grid
                )
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                        .fill(AppTheme.surface)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.series.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let meta = rowMetaLine(year: DetailFormatting.year(from: item.series.releaseDate), genre: item.series.genre) {
                        Text(meta)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Text(item.categoryName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    ratingBadge(rating: item.series.rating, rating5Based: item.series.rating5Based)
                    if let badge { typeBadge(badge) }
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A channel row: the logo WHOLE (aspect-fit — the same clarity
    /// rule as Continue Watching), name + category, tap to play.
    /// Build 64 (B2): the LIVE capsule marks the Live TV type; on
    /// the All tab a type badge replaces it (same slot).
    private func liveRow(_ item: LiveStreamWithCategory, queue: [DBLiveStream], sections: [LiveChannelCategorySection], typeBadge badge: String?) -> some View {
        Button {
            onPlayLive(item, queue, sections)
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
                if let badge {
                    typeBadge(badge)
                } else {
                    Text("LIVE")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppTheme.accent, in: Capsule())
                }
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
    /// Round 15 (C7) + build 61 (Q13): the per-type searches,
    /// extracted verbatim (build 64) so the single-type tabs and
    /// the All tab share ONE implementation. Title matching is
    /// typo-tolerant (fuzzy tier per Z8); people names match too —
    /// a movie/series whose cast/director list contains the query
    /// joins after the title matches.
    private static func searchMovies(source: [VODWithCategory], hidden: Set<String>, q: String) -> [VODWithCategory] {
        let titleMatches = source.filter {
            !hidden.contains($0.stream.categoryId ?? "")
                && CatalogTextSearch.matchesFuzzy(search: q, text: $0.stream.name)
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
    }

    private static func searchSeries(source: [SeriesWithCategory], hidden: Set<String>, q: String) -> [SeriesWithCategory] {
        let titleMatches = source.filter {
            !hidden.contains($0.series.categoryId ?? "")
                && CatalogTextSearch.matchesFuzzy(search: q, text: $0.series.name)
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
    }

    private static func searchLive(source: [LiveStreamWithCategory], hidden: Set<String>, q: String) -> [LiveStreamWithCategory] {
        // H5 search half: the multi-field fuzzy matcher
        // (`matchesFuzzyAny`) is in CatalogTextSearch ready for
        // the provider channel number, but this base tree's stream
        // models carry no number field yet (B8 owns
        // capture/display) — nothing is matched against a number
        // that does not exist.
        let filtered = source.filter {
            !hidden.contains($0.stream.categoryId ?? "")
                && CatalogTextSearch.matchesFuzzy(search: q, text: $0.stream.name)
        }
        return Array(CatalogTextSearch.sortLiveByRelevance(filtered, search: q).prefix(Self.resultCap))
    }

    private func runSearch() async {
        let q = query
        switch filter {
        case .all:
            // Build 64 (B2): one detached pass runs the three
            // per-type searches (the same helpers the tabs use)
            // and merges them by the catalog's own relevance
            // tiering — exact → prefix → fuzzy — with each type's
            // internal order as the final tiebreak, so the unified
            // list is deterministic.
            let vodSource = contentStore.vodStreams
            let seriesSource = contentStore.seriesItems
            let liveSource = contentStore.liveStreams
            let vodHidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod")
            let seriesHidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "series")
            let liveHidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "live")
            let result = await Task.detached(priority: .userInitiated) { () -> [UnifiedSearchResult] in
                let movies = Self.searchMovies(source: vodSource, hidden: vodHidden, q: q)
                let series = Self.searchSeries(source: seriesSource, hidden: seriesHidden, q: q)
                let live = Self.searchLive(source: liveSource, hidden: liveHidden, q: q)
                var combined: [(result: UnifiedSearchResult, seq: Int)] = []
                var seq = 0
                for item in movies { combined.append((.movie(item), seq)); seq += 1 }
                for item in series { combined.append((.series(item), seq)); seq += 1 }
                for item in live { combined.append((.live(item), seq)); seq += 1 }
                let merged = combined.sorted { a, b in
                    let tierA = CatalogTextSearch.rankingTier(search: q, text: a.result.title)
                    let tierB = CatalogTextSearch.rankingTier(search: q, text: b.result.title)
                    if tierA != tierB { return tierA < tierB }
                    let scoreA = CatalogTextSearch.fuzzyScore(search: q, text: a.result.title) ?? .max
                    let scoreB = CatalogTextSearch.fuzzyScore(search: q, text: b.result.title) ?? .max
                    if scoreA != scoreB { return scoreA < scoreB }
                    return a.seq < b.seq
                }
                return Array(merged.prefix(Self.resultCap).map(\.result))
            }.value
            guard !Task.isCancelled else { return }
            allResults = result
            movieResults = []
            seriesResults = []
            liveResults = []
        case .movies:
            let source = contentStore.vodStreams
            let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "vod")
            let result = await Task.detached(priority: .userInitiated) {
                Self.searchMovies(source: source, hidden: hidden, q: q)
            }.value
            guard !Task.isCancelled else { return }
            movieResults = result
            liveResults = []
            seriesResults = []
            allResults = []
        case .series:
            let source = contentStore.seriesItems
            let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "series")
            let result = await Task.detached(priority: .userInitiated) {
                Self.searchSeries(source: source, hidden: hidden, q: q)
            }.value
            guard !Task.isCancelled else { return }
            seriesResults = result
            liveResults = []
            movieResults = []
            allResults = []
        case .live:
            let source = contentStore.liveStreams
            let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "live")
            let result = await Task.detached(priority: .userInitiated) {
                Self.searchLive(source: source, hidden: hidden, q: q)
            }.value
            guard !Task.isCancelled else { return }
            liveResults = result
            movieResults = []
            seriesResults = []
            allResults = []
        case .programmes:
            // Build 61 (B1, item 4): programme-TITLE search over
            // the guide programmes stored for today + tomorrow —
            // the same matching core as the guide's programme
            // search (precomputed `searchTitle`, case-insensitive
            // contains), with channel identity resolved through
            // the same key logic `EPGGuideViewModel.buildRows`
            // uses. Programmes on channels the catalog doesn't
            // know are skipped, as in the guide.
            epgSearchRunning = true
            let calendar = Calendar.current
            let windowStart = calendar.startOfDay(for: Date())
            let windowEnd = calendar.date(byAdding: .day, value: 2, to: windowStart) ?? windowStart
            let byKey = (try? await EPGStore.shared.programmes(
                playlistId: playlist.id, from: windowStart, to: windowEnd)) ?? [:]
            // Channel directory in catalog order: key → display
            // info. Kept on the main actor (DBLiveStream is not
            // Sendable); only keys + programmes cross into the
            // detached matching pass.
            var infoByKey: [String: (name: String, icon: URL?, stream: DBLiveStream?)] = [:]
            var orderedKeys: [String] = []
            let epg = EPGStore.shared
            if playlist.kind == .m3u {
                for channel in M3UContentStore.shared.channels {
                    let idKey = EPGConstants.normalizeChannelKey(channel.tvgId)
                    let nameKey = EPGConstants.normalizeChannelKey(channel.tvgName ?? channel.name)
                    let key = epg.storedKey(idKey: idKey, nameKey: nameKey) ?? idKey ?? nameKey ?? channel.id
                    if infoByKey[key] == nil { orderedKeys.append(key) }
                    infoByKey[key] = (name: channel.name,
                                      icon: channel.tvgLogo.flatMap { URL(string: $0) },
                                      stream: nil)
                }
            } else {
                for entry in contentStore.liveStreams {
                    let stream = entry.stream
                    let idKey = EPGConstants.normalizeChannelKey(stream.epgChannelId)
                    let nameKey = EPGConstants.normalizeChannelKey(stream.name)
                    let key = epg.storedKey(idKey: idKey, nameKey: nameKey) ?? idKey ?? nameKey ?? "#stream:\(stream.streamId)"
                    if infoByKey[key] == nil { orderedKeys.append(key) }
                    infoByKey[key] = (name: stream.name,
                                      icon: stream.streamIcon.flatMap { URL(string: $0) },
                                      stream: stream)
                }
            }
            // Build 61 (B10, Q13 + Z8): programme matching is
            // the SAME fuzzy core as the other sections, and the
            // ordering is the SAME deterministic tiering — exact
            // title → prefix → fuzzy (typo tolerance only inside
            // the fuzzy tier) — with start time as the tiebreak
            // inside a tier.
            let matches = await Task.detached(priority: .userInitiated) { () -> [EPGProgramme] in
                var found: [EPGProgramme] = []
                for key in orderedKeys {
                    guard let programmes = byKey[key] else { continue }
                    for programme in programmes
                    where CatalogTextSearch.matchesFuzzy(search: query, text: programme.title) {
                        found.append(programme)
                    }
                }
                found.sort { a, b in
                    let tierA = CatalogTextSearch.rankingTier(search: query, text: a.title)
                    let tierB = CatalogTextSearch.rankingTier(search: query, text: b.title)
                    if tierA != tierB { return tierA < tierB }
                    let scoreA = CatalogTextSearch.fuzzyScore(search: query, text: a.title) ?? .max
                    let scoreB = CatalogTextSearch.fuzzyScore(search: query, text: b.title) ?? .max
                    if scoreA != scoreB { return scoreA < scoreB }
                    return a.start < b.start
                }
                return Array(found.prefix(Self.resultCap))
            }.value
            guard !Task.isCancelled else { epgSearchRunning = false; return }
            epgResults = matches.map { programme in
                let info = infoByKey[programme.channelKey]
                return EPGProgrammeSearchResult(
                    programme: programme,
                    channelName: info?.name ?? programme.channelKey,
                    channelIcon: info?.icon,
                    liveStream: info?.stream
                )
            }
            liveResults = []
            movieResults = []
            seriesResults = []
            allResults = []
            epgSearchRunning = false
        }
    }
}
