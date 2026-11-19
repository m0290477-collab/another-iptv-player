import Foundation
import GRDB
import Combine

/// Content-type scope for catalog sync/refresh: pull-to-refresh syncs only the
/// pulled tab's data instead of the whole catalog.
enum CatalogContentType {
    case live, vod, series
}

/// Round 14 (B8): season/episode counts for one series, aggregated in
/// `PlaylistContentStore` from the season/episode tables. An entry exists
/// ONLY for a series whose seasons are actually loaded in the local DB —
/// a series with no loaded seasons has NO entry (never a fabricated 0).
struct SeriesSeasonEpisodeCounts: Equatable {
    let seasons: Int
    let episodes: Int
}

/// Round 15 (C8): tolerant timestamp parsing for panel date fields.
/// Accepts a unix-epoch string first (the common case), then the
/// string date formats panels actually send ("2024-05-01 12:30:00",
/// ISO-8601, bare "2024-05-01"). Unparseable values return nil — the
/// record simply doesn't join the Newest ordering, exactly as before.
nonisolated enum CatalogTimestampParsing {
    static func epochSeconds(from raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let value = Int(raw) { return value }
        if let date = isoFormatter.date(from: raw) {
            return Int(date.timeIntervalSince1970)
        }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return Int(date.timeIntervalSince1970)
            }
        }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Keeps the active playlist catalog in memory; loads it from the database at launch and fills it via the API if needed.
@MainActor
final class PlaylistContentStore: ObservableObject {
    static let shared = PlaylistContentStore()

    @Published private(set) var activePlaylistId: UUID?
    @Published var isLoading = false
    @Published var loadingMessage: String?
    @Published var loadError: String?
    /// Categories are loaded but the content (stream) data is not loaded yet
    @Published private(set) var streamsLoaded = false

    @Published private(set) var liveCategories: [DBCategory] = []
    @Published private(set) var vodCategories: [DBCategory] = []
    @Published private(set) var seriesCategories: [DBCategory] = []
    @Published private(set) var liveStreams: [LiveStreamWithCategory] = []
    @Published private(set) var vodStreams: [VODWithCategory] = []
    @Published private(set) var seriesItems: [SeriesWithCategory] = []

    @Published private(set) var liveStreamsByCategoryId: [String: [LiveStreamWithCategory]] = [:]
    @Published private(set) var vodStreamsByCategoryId: [String: [VODWithCategory]] = [:]
    @Published private(set) var seriesItemsByCategoryId: [String: [SeriesWithCategory]] = [:]

    // MARK: - Round 14 (B10) shared rankings + (B8) series counts
    //
    // Computed ONCE here whenever the in-memory catalog changes (load,
    // reload, scoped reload, VOD-metadata application) instead of once
    // per view (Home + Movies + Series each used to re-sort the whole
    // catalog). Semantics match the views' existing computations
    // exactly: Top Rated keeps only records whose rating normalizes
    // via `ContentRating.normalizedRating10` (unrated/junk ratings
    // never qualify — no invented scores); Newest keeps only records
    // whose `added` (movies) / `lastModified` (series) timestamp
    // parses. Both are catalog-wide: hidden-category filtering stays
    // a view-side concern, exactly as the per-view passes did it.
    // Capped at `sharedRankingLimit` (60) so the Movies/Series
    // "Newest" grids (60) and every shelf (10–20) can prefix them.
    @Published private(set) var sharedTopRatedMovies: [DBVODStream] = []
    @Published private(set) var sharedTopRatedSeries: [DBSeries] = []
    @Published private(set) var sharedNewestMovies: [DBVODStream] = []
    @Published private(set) var sharedNewestSeries: [DBSeries] = []

    /// B8: seriesId → real season/episode counts (see
    /// `SeriesSeasonEpisodeCounts`). Refreshed from the DB after each
    /// catalog load/reload and on demand via
    /// `refreshSeriesSeasonEpisodeCounts()`.
    @Published private(set) var seriesSeasonEpisodeCounts: [Int: SeriesSeasonEpisodeCounts] = [:]

    private static let sharedRankingLimit = 60
    private var rankingsGeneration = 0
    private var rankingsTask: Task<Void, Never>?

    private var loadToken: UUID?
    private init() {}

    private func clearLists() {
        liveCategories = []
        vodCategories = []
        seriesCategories = []
        liveStreams = []
        vodStreams = []
        seriesItems = []
        liveStreamsByCategoryId = [:]
        vodStreamsByCategoryId = [:]
        seriesItemsByCategoryId = [:]
        streamsLoaded = false
        // Round 14 (B10/B8): derived data dies with the catalog it was
        // computed from; the generation bump voids any in-flight pass.
        rankingsTask?.cancel()
        rankingsGeneration += 1
        sharedTopRatedMovies = []
        sharedTopRatedSeries = []
        sharedNewestMovies = []
        sharedNewestSeries = []
        seriesSeasonEpisodeCounts = [:]
    }

    // MARK: - Round 14 (B10/B8) shared derived data

    /// Recomputes the four shared rankings from the CURRENT in-memory
    /// catalog, off the main actor, and publishes them once. A
    /// generation counter voids stale passes when the catalog changes
    /// again mid-computation. Sorts are stable and the inputs are in
    /// catalog (sortIndex) order, so ties resolve exactly as the old
    /// per-view passes resolved them.
    private func scheduleSharedRankingsRecompute() {
        rankingsGeneration += 1
        let generation = rankingsGeneration
        let vodSnapshot = vodStreams.map(\.stream)
        let seriesSnapshot = seriesItems.map(\.series)
        rankingsTask?.cancel()
        rankingsTask = Task.detached(priority: .utility) { [weak self] in
            let topMovies: [DBVODStream] = vodSnapshot
                .compactMap { movie -> (DBVODStream, Double)? in
                    guard let value = ContentRating.normalizedRating10(
                        rating: movie.rating, rating5Based: movie.rating5Based
                    ) else { return nil }
                    return (movie, value)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(Self.sharedRankingLimit)
                .map(\.0)
            let topSeries: [DBSeries] = seriesSnapshot
                .compactMap { series -> (DBSeries, Double)? in
                    guard let value = ContentRating.normalizedRating10(
                        rating: series.rating, rating5Based: series.rating5Based
                    ) else { return nil }
                    return (series, value)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(Self.sharedRankingLimit)
                .map(\.0)
            let newestMovies: [DBVODStream] = vodSnapshot
                .compactMap { movie -> (DBVODStream, Int)? in
                    guard let ts = movie.added.flatMap(Int.init) else { return nil }
                    return (movie, ts)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(Self.sharedRankingLimit)
                .map(\.0)
            let newestSeries: [DBSeries] = seriesSnapshot
                .compactMap { series -> (DBSeries, Int)? in
                    // Round 15 (C8): `lastModified` arrives as an epoch
                    // string on most panels but as a formatted date
                    // string on others; the tolerant parser keeps the
                    // Newest shelf from silently dropping those series.
                    guard let ts = CatalogTimestampParsing.epochSeconds(from: series.lastModified) else { return nil }
                    return (series, ts)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(Self.sharedRankingLimit)
                .map(\.0)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.rankingsGeneration == generation else { return }
                self.sharedTopRatedMovies = topMovies
                self.sharedTopRatedSeries = topSeries
                self.sharedNewestMovies = newestMovies
                self.sharedNewestSeries = newestSeries
            }
        }
    }

    /// B8: (re)aggregates season/episode counts for the active
    /// playlist from the season/episode tables. Only series with at
    /// least one loaded season appear — the count is always computed
    /// from real rows, never assumed. Safe to call after a series'
    /// seasons are (re)fetched into the DB.
    func refreshSeriesSeasonEpisodeCounts() async {
        guard let pid = activePlaylistId else {
            seriesSeasonEpisodeCounts = [:]
            return
        }
        let counts = try? await AppDatabase.shared.read { db in
            try Self.fetchSeriesSeasonEpisodeCounts(playlistId: pid, db: db)
        }
        guard activePlaylistId == pid, let counts else { return }
        seriesSeasonEpisodeCounts = counts
    }

    nonisolated private static func fetchSeriesSeasonEpisodeCounts(
        playlistId: UUID, db: Database
    ) throws -> [Int: SeriesSeasonEpisodeCounts] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT season.seriesId AS seriesId,
                   COUNT(DISTINCT season.id) AS seasonCount,
                   COUNT(episode.id) AS episodeCount
            FROM season
            LEFT JOIN episode ON episode.seasonId = season.id
            WHERE season.playlistId = ?
            GROUP BY season.seriesId
            """, arguments: [playlistId])
        var result: [Int: SeriesSeasonEpisodeCounts] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            let seriesId: Int = row["seriesId"]
            result[seriesId] = SeriesSeasonEpisodeCounts(
                seasons: row["seasonCount"],
                episodes: row["episodeCount"]
            )
        }
        return result
    }

    // MARK: - Filtreleme (UI)

    /// The old approach that did an O(n) full-array scan instead of an O(1) dictionary lookup was removed.
    func liveStreams(inCategoryId categoryId: String, searchText: String) -> [LiveStreamWithCategory] {
        let base = liveStreamsByCategoryId[categoryId] ?? []
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        let filtered = base.filter { CatalogTextSearch.matchesSection(search: q, text: $0.stream.name) }
        return CatalogTextSearch.sortLiveByRelevance(filtered, search: q)
    }

    func vodStreams(inCategoryId categoryId: String, searchText: String) -> [VODWithCategory] {
        let base = vodStreamsByCategoryId[categoryId] ?? []
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        let filtered = base.filter { CatalogTextSearch.matchesSection(search: q, text: $0.stream.name) }
        return CatalogTextSearch.sortVODByRelevance(filtered, search: q)
    }

    func seriesItems(inCategoryId categoryId: String, searchText: String) -> [SeriesWithCategory] {
        let base = seriesItemsByCategoryId[categoryId] ?? []
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        let filtered = base.filter { CatalogTextSearch.matchesSection(search: q, text: $0.series.name) }
        return CatalogTextSearch.sortSeriesByRelevance(filtered, search: q)
    }

    func liveStreams(searchText: String) -> [LiveStreamWithCategory] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        // Build 61 (B10, Q13): the global-search API is typo-tolerant.
        let filtered = liveStreams.filter { CatalogTextSearch.matchesFuzzy(search: q, text: $0.stream.name) }
        return CatalogTextSearch.sortLiveByRelevance(filtered, search: q)
    }

    func vodStreams(searchText: String) -> [VODWithCategory] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        // Build 61 (B10, Q13): the global-search API is typo-tolerant.
        let filtered = vodStreams.filter { CatalogTextSearch.matchesFuzzy(search: q, text: $0.stream.name) }
        return CatalogTextSearch.sortVODByRelevance(filtered, search: q)
    }

    func seriesItems(searchText: String) -> [SeriesWithCategory] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        // Build 61 (B10, Q13): the global-search API is typo-tolerant.
        let filtered = seriesItems.filter { CatalogTextSearch.matchesFuzzy(search: q, text: $0.series.name) }
        return CatalogTextSearch.sortSeriesByRelevance(filtered, search: q)
    }

    // MARK: - Launch

    func loadPlaylist(_ playlist: Playlist) async {
        let token = UUID()
        loadToken = token
        loadError = nil
        loadingMessage = nil

        if activePlaylistId != playlist.id {
            clearLists()
            activePlaylistId = playlist.id
            isLoading = true
        } else if liveCategories.isEmpty {
            isLoading = true
        }

        do {
            let needsSync = try await Self.needsNetworkBootstrap(playlistId: playlist.id)
            if needsSync {
                isLoading = true
                loadingMessage = L("phase.preparing")
                try await syncFromNetworkReplacingLocal(playlist: playlist) { msg in
                    guard self.loadToken == token else { return }
                    self.loadingMessage = msg
                }
                guard loadToken == token else { return }
                loadingMessage = L("phase.preparing_list")
            }

            // Phase 1: Categories only (very fast – usually < 5 ms)
            let cats = try await AppDatabase.shared.read { db in
                try Self.fetchCategoriesOnly(playlistId: playlist.id, db: db)
            }
            guard loadToken == token else { return }
            liveCategories = cats.live
            vodCategories = cats.vod
            seriesCategories = cats.series
            streamsLoaded = false
            loadingMessage = nil
            isLoading = false   // ← UI kategorilerle hemen gösterilir

            // Phase 2: Contents are loaded in parallel (in the background)
            async let liveTask   = AppDatabase.shared.read { db in try Self.fetchLiveStreamsData(playlistId: playlist.id, db: db) }
            async let vodTask    = AppDatabase.shared.read { db in try Self.fetchVODStreamsData(playlistId: playlist.id, db: db) }
            async let seriesTask = AppDatabase.shared.read { db in try Self.fetchSeriesData(playlistId: playlist.id, db: db) }

            // Round 12 (point 3): publish each type the moment ITS
            // fetch lands instead of holding all three hostage to
            // the slowest one. The fetches still run concurrently
            // (async let), but Home renders live channels as soon as
            // they arrive — on the owner's ~103k-row playlist the
            // old all-at-end assignment kept Home's catalog "empty"
            // (and its empty state / spinner up) until the LAST of
            // the three giant fetches finished.
            let ls = try await liveTask
            guard loadToken == token else { return }
            liveStreams = ls.streams
            liveStreamsByCategoryId = ls.byCategory
            let vs = try await vodTask
            guard loadToken == token else { return }
            vodStreams = vs.streams
            vodStreamsByCategoryId = vs.byCategory
            let si = try await seriesTask
            guard loadToken == token else { return }
            seriesItems = si.items
            seriesItemsByCategoryId = si.byCategory
            streamsLoaded = true
            // Build 61 (B8, R1): first-seen recording — ONLY on the
            // network-bootstrap path; plain DB loads never stamp.
            // The store's baseline rule keeps the first-ever batch
            // silent.
            if needsSync {
                FirstSeenStore.shared.recordCatalog(
                    playlistId: playlist.id,
                    liveIds: liveStreams.map(\.stream.streamId),
                    vodIds: vodStreams.map(\.stream.streamId),
                    seriesIds: seriesItems.map(\.series.seriesId)
                )
            }
            // Round 14 (B10/B8): the catalog is complete — derive the
            // shared rankings once and aggregate series counts.
            scheduleSharedRankingsRecompute()
            await refreshSeriesSeasonEpisodeCounts()
        } catch {
            guard loadToken == token else { return }
            loadError = error.localizedDescription
            loadingMessage = nil
            isLoading = false
        }
    }

    /// Build 61 (B8, R1): record first-seen for the in-memory
    /// catalog after a network refresh reloaded it. No-op when this
    /// playlist is not the active one (the arrays would be another
    /// playlist's).
    private func recordFirstSeenIfActive(playlistId: UUID) {
        guard activePlaylistId == playlistId, streamsLoaded else { return }
        FirstSeenStore.shared.recordCatalog(
            playlistId: playlistId,
            liveIds: liveStreams.map(\.stream.streamId),
            vodIds: vodStreams.map(\.stream.streamId),
            seriesIds: seriesItems.map(\.series.seriesId)
        )
    }

    /// After a movie detail fetch is written to the DB, also update the copy in the memory catalog —
    /// otherwise the same movie looked metadataLoaded=false on every re-entry and
    /// caused an unnecessary network request and a spinner flash.
    func applyVODMetadata(_ updated: DBVODStream) {
        guard activePlaylistId == updated.playlistId else { return }
        if let i = vodStreams.firstIndex(where: { $0.stream.streamId == updated.streamId }) {
            vodStreams[i] = VODWithCategory(stream: updated, categoryName: vodStreams[i].categoryName)
        }
        // Because of the Uncategorized remap, the bucket key may differ from categoryId.
        for key in [updated.categoryId ?? "", Self.uncategorizedCategoryId] {
            if var bucket = vodStreamsByCategoryId[key],
               let j = bucket.firstIndex(where: { $0.stream.streamId == updated.streamId }) {
                bucket[j] = VODWithCategory(stream: updated, categoryName: bucket[j].categoryName)
                vodStreamsByCategoryId[key] = bucket
                break
            }
        }
        // Round 14 (B10): a metadata fetch can change the movie's
        // rating — the shared rankings must follow the catalog.
        scheduleSharedRankingsRecompute()
    }

    /// Called when returning from the Dashboard to the playlist picker: the catalog copies of hundreds of thousands of rows
    /// (flat + category dictionaries) should not stay in the singleton.
    /// On re-entry, `loadPlaylist` already loads from scratch.
    func unload() {
        loadToken = nil
        activePlaylistId = nil
        clearLists()
        loadError = nil
        loadingMessage = nil
        isLoading = false
    }

    /// Pull-to-refresh: full network sync + memory refresh. The same path as "Refresh All" in Settings;
    /// the error is written to loadError (because the sync is atomic, on failure
    /// the local content is preserved).
    func refreshFromNetwork(playlist: Playlist) async {
        do {
            try await syncFromNetworkReplacingLocal(playlist: playlist) { [weak self] msg in
                self?.loadingMessage = msg
            }
            await reloadFromDatabaseIfActive(playlistId: playlist.id)
        } catch {
            loadError = error.localizedDescription
        }
        loadingMessage = nil
    }

    /// Scoped pull-to-refresh: only the pulled tab's content type is refetched and
    /// rewritten (e.g. the Movies tab syncs VOD categories + streams); the other
    /// types keep their local data untouched.
    func refreshFromNetwork(playlist: Playlist, only type: CatalogContentType) async {
        do {
            try await syncFromNetworkReplacingLocal(playlist: playlist, only: type) { [weak self] msg in
                self?.loadingMessage = msg
            }
            await reloadFromDatabaseIfActive(playlistId: playlist.id, only: type)
        } catch {
            loadError = error.localizedDescription
        }
        loadingMessage = nil
    }

    /// Update the memory after a full refresh from Settings.
    func reloadFromDatabaseIfActive(playlistId: UUID) async {
        guard activePlaylistId == playlistId else { return }
        do {
            try await reloadFromDatabase(playlistId: playlistId)
            // Build 61 (B8, R1): every caller of this funnel is a
            // post-sync reload — stamp first-seen for the refreshed
            // catalog here so no sync path can skip it.
            recordFirstSeenIfActive(playlistId: playlistId)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Scoped in-memory reload: refreshes only one content type's categories and
    /// items, applying the same uncategorized merge as the full reload.
    func reloadFromDatabaseIfActive(playlistId: UUID, only type: CatalogContentType) async {
        guard activePlaylistId == playlistId else { return }
        do {
            switch type {
            case .live:
                async let catsTask = AppDatabase.shared.read { db in
                    try Self.fetchCategories(playlistId: playlistId, type: "live", db: db)
                }
                async let dataTask = AppDatabase.shared.read { db in
                    try Self.fetchLiveStreamsData(playlistId: playlistId, db: db)
                }
                let (cats, ls) = try await (catsTask, dataTask)
                // Build 63 (item 14, S2): merge off the main actor;
                // only the finished values are published here.
                let merged = await Task.detached(priority: .userInitiated) {
                    let by = Self.mergeUncategorized(ls.byCategory, validIds: Set(cats.map(\.id)))
                    let categories = Self.appendingUncategorized(cats, byCategory: by, type: "live", playlistId: playlistId)
                    return (categories, by)
                }.value
                liveCategories = merged.0
                liveStreams = ls.streams
                liveStreamsByCategoryId = merged.1
            case .vod:
                async let catsTask = AppDatabase.shared.read { db in
                    try Self.fetchCategories(playlistId: playlistId, type: "vod", db: db)
                }
                async let dataTask = AppDatabase.shared.read { db in
                    try Self.fetchVODStreamsData(playlistId: playlistId, db: db)
                }
                let (cats, vs) = try await (catsTask, dataTask)
                // Build 63 (item 14, S2): merge off the main actor.
                let merged = await Task.detached(priority: .userInitiated) {
                    let by = Self.mergeUncategorized(vs.byCategory, validIds: Set(cats.map(\.id)))
                    let categories = Self.appendingUncategorized(cats, byCategory: by, type: "vod", playlistId: playlistId)
                    return (categories, by)
                }.value
                vodCategories = merged.0
                vodStreams = vs.streams
                vodStreamsByCategoryId = merged.1
            case .series:
                async let catsTask = AppDatabase.shared.read { db in
                    try Self.fetchCategories(playlistId: playlistId, type: "series", db: db)
                }
                async let dataTask = AppDatabase.shared.read { db in
                    try Self.fetchSeriesData(playlistId: playlistId, db: db)
                }
                let (cats, si) = try await (catsTask, dataTask)
                // Build 63 (item 14, S2): merge off the main actor.
                let merged = await Task.detached(priority: .userInitiated) {
                    let by = Self.mergeUncategorized(si.byCategory, validIds: Set(cats.map(\.id)))
                    let categories = Self.appendingUncategorized(cats, byCategory: by, type: "series", playlistId: playlistId)
                    return (categories, by)
                }.value
                seriesCategories = merged.0
                seriesItems = si.items
                seriesItemsByCategoryId = merged.1
            }
            // Round 14 (B10): one of the catalog arrays changed.
            scheduleSharedRankingsRecompute()
            // Build 61 (B8, R1): scoped post-sync reload — stamp too.
            recordFirstSeenIfActive(playlistId: playlistId)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static func needsNetworkBootstrap(playlistId: UUID) async throws -> Bool {
        try await AppDatabase.shared.read { db in
            let cat = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM category WHERE playlistId = ?", arguments: [playlistId]) ?? 0
            return cat == 0
        }
    }

    func reloadFromDatabase(playlistId: UUID) async throws {
        // Phase 1: Categories (fast)
        let cats = try await AppDatabase.shared.read { db in
            try Self.fetchCategoriesOnly(playlistId: playlistId, db: db)
        }
        liveCategories = cats.live
        vodCategories = cats.vod
        seriesCategories = cats.series
        streamsLoaded = false

        // Phase 2: Contents in parallel
        async let liveTask   = AppDatabase.shared.read { db in try Self.fetchLiveStreamsData(playlistId: playlistId, db: db) }
        async let vodTask    = AppDatabase.shared.read { db in try Self.fetchVODStreamsData(playlistId: playlistId, db: db) }
        async let seriesTask = AppDatabase.shared.read { db in try Self.fetchSeriesData(playlistId: playlistId, db: db) }

        // Round 12 (point 3): progressive per-type publish, same as
        // loadPlaylist — each type (with its uncategorized merge)
        // lands as soon as its own fetch completes instead of
        // waiting for all three.
        // Collect orphaned/uncategorized streams in the synthetic "Uncategorized" bucket and
        // add a visible entry to the category list when needed.
        let ls = try await liveTask
        // Build 63 (item 14, S2): merges off the main actor; the
        // per-type publish order and values are unchanged.
        let liveMerged = await Task.detached(priority: .userInitiated) {
            let by = Self.mergeUncategorized(ls.byCategory, validIds: Set(cats.live.map(\.id)))
            let categories = Self.appendingUncategorized(cats.live, byCategory: by, type: "live", playlistId: playlistId)
            return (categories, by)
        }.value
        liveCategories = liveMerged.0
        liveStreams = ls.streams
        liveStreamsByCategoryId = liveMerged.1
        let vs = try await vodTask
        let vodMerged = await Task.detached(priority: .userInitiated) {
            let by = Self.mergeUncategorized(vs.byCategory, validIds: Set(cats.vod.map(\.id)))
            let categories = Self.appendingUncategorized(cats.vod, byCategory: by, type: "vod", playlistId: playlistId)
            return (categories, by)
        }.value
        vodCategories = vodMerged.0
        vodStreams = vs.streams
        vodStreamsByCategoryId = vodMerged.1
        let si = try await seriesTask
        let seriesMerged = await Task.detached(priority: .userInitiated) {
            let by = Self.mergeUncategorized(si.byCategory, validIds: Set(cats.series.map(\.id)))
            let categories = Self.appendingUncategorized(cats.series, byCategory: by, type: "series", playlistId: playlistId)
            return (categories, by)
        }.value
        seriesCategories = seriesMerged.0
        seriesItems = si.items
        seriesItemsByCategoryId = seriesMerged.1
        streamsLoaded = true
        // Round 14 (B10/B8): same derivation as the initial load.
        scheduleSharedRankingsRecompute()
        await refreshSeriesSeasonEpisodeCounts()
    }

    // MARK: - DB Fetch Helpers

    private struct CategoriesBundle {
        let live: [DBCategory]
        let vod: [DBCategory]
        let series: [DBCategory]
    }

    private struct LiveStreamsData {
        let streams: [LiveStreamWithCategory]
        let byCategory: [String: [LiveStreamWithCategory]]
    }

    private struct VODStreamsData {
        let streams: [VODWithCategory]
        let byCategory: [String: [VODWithCategory]]
    }

    private struct SeriesData {
        let items: [SeriesWithCategory]
        let byCategory: [String: [SeriesWithCategory]]
    }

    // Runs inside GRDB read closures (async let) off the main actor.
    nonisolated private static func fetchCategories(playlistId: UUID, type: String, db: Database) throws -> [DBCategory] {
        try DBCategory
            .filter(Column("playlistId") == playlistId && Column("type") == type)
            .order(Column("sortIndex"))
            .fetchAll(db)
    }

    private static func fetchCategoriesOnly(playlistId: UUID, db: Database) throws -> CategoriesBundle {
        CategoriesBundle(
            live: try fetchCategories(playlistId: playlistId, type: "live", db: db),
            vod: try fetchCategories(playlistId: playlistId, type: "vod", db: db),
            series: try fetchCategories(playlistId: playlistId, type: "series", db: db)
        )
    }

    /// The synthetic category id where streams with no category / orphaned streams are collected.
    /// Fixed so HiddenCategoryStore can persist by this id.
    nonisolated static let uncategorizedCategoryId = "__uncategorized__"

    // Xtream panelleri category_id'si null/'0'/kategori listesinde olmayan streamler
    // can return. An INNER JOIN was silently dropping these from every screen; with LEFT JOIN +
    // COALESCE they are preserved and shown under the "Uncategorized" heading.
    nonisolated private static func fetchLiveStreamsData(playlistId: UUID, db: Database) throws -> LiveStreamsData {
        // Round 14 (B10): explicit column list instead of `liveStream.*`
        // (the live table carries no heavy text columns, so every column
        // is a real card column: name/icon/epg id/category/archive flags).
        let sql = """
        SELECT liveStream.streamId, liveStream.name, liveStream.streamIcon,
               liveStream.epgChannelId, liveStream.categoryId, liveStream.sortIndex,
               liveStream.playlistId, liveStream.tvArchive, liveStream.tvArchiveDuration,
               COALESCE(category.name, ?) AS categoryName
        FROM liveStream
        LEFT JOIN category ON liveStream.categoryId = category.id
                     AND liveStream.playlistId = category.playlistId
                     AND category.type = 'live'
        WHERE liveStream.playlistId = ?
        ORDER BY liveStream.sortIndex
        """
        let streams = try LiveStreamWithCategory.fetchAll(db, sql: sql, arguments: [L("content.uncategorized"), playlistId])
        return LiveStreamsData(streams: streams, byCategory: Dictionary(grouping: streams) { $0.stream.categoryId ?? "" })
    }

    nonisolated private static func fetchVODStreamsData(playlistId: UUID, db: Database) throws -> VODStreamsData {
        // Round 14 (B10): list query narrowed to the columns cards and
        // shelves actually display (name/poster/rating/year/genre/
        // category/backdrop/duration/added). The heavy text columns
        // (plot/cast/director) and detail-only fields are returned as
        // NULL / false so the record shape is unchanged; the detail
        // screen fetches the full record on demand via
        // `VODByIDRequest` / its metadata fetch, exactly as before.
        let sql = """
        SELECT vodStream.streamId, vodStream.name, vodStream.streamIcon,
               vodStream.categoryId, vodStream.rating, vodStream.containerExtension,
               NULL AS director, NULL AS cast, NULL AS plot,
               vodStream.genre, vodStream.releaseDate, vodStream.rating5Based,
               vodStream.backdropPath, NULL AS youtubeTrailer, vodStream.duration,
               NULL AS tmdbId, NULL AS kinopoiskURL, 0 AS metadataLoaded,
               vodStream.added, vodStream.sortIndex, vodStream.playlistId,
               COALESCE(category.name, ?) AS categoryName
        FROM vodStream
        LEFT JOIN category ON vodStream.categoryId = category.id
                     AND vodStream.playlistId = category.playlistId
                     AND category.type = 'vod'
        WHERE vodStream.playlistId = ?
        ORDER BY vodStream.sortIndex
        """
        let streams = try VODWithCategory.fetchAll(db, sql: sql, arguments: [L("content.uncategorized"), playlistId])
        return VODStreamsData(streams: streams, byCategory: Dictionary(grouping: streams) { $0.stream.categoryId ?? "" })
    }

    nonisolated private static func fetchSeriesData(playlistId: UUID, db: Database) throws -> SeriesData {
        // Round 14 (B10): same narrowing as VOD — cards/shelves read
        // cover/rating/genre/year/lastModified/backdrop/runtime; the
        // heavy text columns (plot/cast/director) and the trailer id
        // are detail-only and come back as NULL here. The detail
        // screen's full record arrives via `SeriesByIDRequest` and
        // its seasons fetch, unchanged.
        let sql = """
        SELECT series.seriesId, series.name, series.cover,
               NULL AS plot, NULL AS cast, NULL AS director,
               series.genre, series.releaseDate, series.rating, series.lastModified,
               series.rating5Based, series.backdropPath, NULL AS youtubeTrailer,
               series.episodeRunTime, series.categoryId, series.sortIndex,
               series.seasonsLoaded, series.playlistId,
               COALESCE(category.name, ?) AS categoryName
        FROM series
        LEFT JOIN category ON series.categoryId = category.id
                     AND series.playlistId = category.playlistId
                     AND category.type = 'series'
        WHERE series.playlistId = ?
        ORDER BY series.sortIndex
        """
        let items = try SeriesWithCategory.fetchAll(db, sql: sql, arguments: [L("content.uncategorized"), playlistId])
        return SeriesData(items: items, byCategory: Dictionary(grouping: items) { $0.series.categoryId ?? "" })
    }

    /// Merges buckets that are not among the known category ids (nil or orphaned) under the synthetic
    /// "Uncategorized" key.
    /// Build 63 (item 14, S2): `nonisolated` — the merge walks the
    /// full per-type arrays and now runs inside a detached task at
    /// the reload call sites instead of on the main actor.
    nonisolated private static func mergeUncategorized<T>(
        _ byCategory: [String: [T]], validIds: Set<String>
    ) -> [String: [T]] {
        var result: [String: [T]] = [:]
        for (key, items) in byCategory {
            let target = (key.isEmpty || !validIds.contains(key)) ? uncategorizedCategoryId : key
            result[target, default: []].append(contentsOf: items)
        }
        return result
    }

    /// If the synthetic "Uncategorized" bucket is non-empty, it appends a visible category to the end of the category list;
    /// if empty, it returns the list as-is.
    /// Build 63 (item 14, S2): `nonisolated`, same reason as
    /// `mergeUncategorized` above.
    nonisolated private static func appendingUncategorized(
        _ categories: [DBCategory],
        byCategory: [String: [some Any]],
        type: String,
        playlistId: UUID
    ) -> [DBCategory] {
        guard let orphans = byCategory[uncategorizedCategoryId], !orphans.isEmpty else { return categories }
        var result = categories
        result.append(DBCategory(
            id: uncategorizedCategoryId,
            name: L("content.uncategorized"),
            parentId: nil,
            type: type,
            sortIndex: (categories.map(\.sortIndex).max() ?? -1) + 1,
            playlistId: playlistId
        ))
        return result
    }

    // MARK: - Network sync (Xtream → SQLite)

    /// Settings screen: full refresh with a staged progress message.
    /// Local content is NOT DELETED until all network requests complete successfully: deletion and rewriting
    /// are done in a single transaction so a panel/network error does not empty the working library.
    func syncFromNetworkReplacingLocal(playlist: Playlist, progress: @escaping (String) -> Void) async throws {
        let client = XtreamAPIClient(playlist: playlist)
        let pid = playlist.id

        // Six endpoints are independent — fetching them in parallel seriously shortens the refresh time.
        progress(L("phase.fetch_categories"))
        async let liveCatsTask = client.getLiveCategories()
        async let vodCatsTask = client.getVODCategories()
        async let seriesCatsTask = client.getSeriesCategories()
        async let liveStreamsTask = client.getLiveStreams()
        async let vodsTask = client.getVODStreams()
        async let seriesTask = client.getSeries()
        let (liveCats, vodCats, seriesCats, liveStreamsAPI, vods, series) = try await (
            liveCatsTask, vodCatsTask, seriesCatsTask, liveStreamsTask, vodsTask, seriesTask
        )

        let filterAdult = playlist.filterAdultContent

        // Round 14 (B10): cheap fingerprint skip. When the remote
        // catalog's shape (row counts per type + first/last stream
        // ids, after the same adult filtering the rewrite applies)
        // matches the local tables exactly, the delete-then-insert
        // rewrite would reproduce the same catalog — skip it. This
        // also preserves locally enriched VOD metadata that a rewrite
        // would reset. A mismatch (including duplicate-id panels,
        // whose local count legitimately differs) always rewrites.
        let remoteFingerprint = Self.remoteCatalogFingerprint(
            liveCats: liveCats, vodCats: vodCats, seriesCats: seriesCats,
            liveStreams: liveStreamsAPI, vods: vods, series: series,
            filterAdult: filterAdult
        )
        let localFingerprint = try? await AppDatabase.shared.read { db in
            try Self.localCatalogFingerprint(playlistId: pid, db: db)
        }
        if let localFingerprint, localFingerprint == remoteFingerprint {
            return
        }

        progress(L("phase.save_db"))
        try await AppDatabase.shared.write { db in
            // Delete-then-insert inside one transaction: rolls back together on any error.
            try Self.replaceLiveCatalog(db: db, pid: pid, categories: liveCats, streams: liveStreamsAPI, filterAdult: filterAdult)
            try Self.replaceVODCatalog(db: db, pid: pid, categories: vodCats, streams: vods, filterAdult: filterAdult)
            try Self.replaceSeriesCatalog(db: db, pid: pid, categories: seriesCats, series: series, filterAdult: filterAdult)
        }
    }

    // MARK: - Round 14 (B10) catalog fingerprint

    /// Row counts per content type (+ category counts) and the
    /// first/last stream ids in catalog order. Two catalogs with the
    /// same fingerprint are treated as identical for refresh purposes.
    private struct CatalogFingerprint: Equatable {
        var liveCount: Int
        var liveFirstId: Int?
        var liveLastId: Int?
        var vodCount: Int
        var vodFirstId: Int?
        var vodLastId: Int?
        var seriesCount: Int
        var seriesFirstId: Int?
        var seriesLastId: Int?
        var liveCategoryCount: Int
        var vodCategoryCount: Int
        var seriesCategoryCount: Int
    }

    /// Remote fingerprint: applies the SAME adult filtering (and the
    /// same category-name filtering) as the `replace*Catalog` rewrite,
    /// so the comparison is against what the rewrite would store.
    private static func remoteCatalogFingerprint(
        liveCats: [XtreamCategory], vodCats: [XtreamCategory], seriesCats: [XtreamCategory],
        liveStreams: [XtreamLiveStream], vods: [XtreamVODStream], series: [XtreamSeries],
        filterAdult: Bool
    ) -> CatalogFingerprint {
        let liveAdultIds = filterAdult ? AdultContentFilter.adultCategoryIds(from: liveCats) : []
        let vodAdultIds = filterAdult ? AdultContentFilter.adultCategoryIds(from: vodCats) : []
        let seriesAdultIds = filterAdult ? AdultContentFilter.adultCategoryIds(from: seriesCats) : []
        let liveKept = liveStreams.filter { !(filterAdult && AdultContentFilter.isAdultLiveStream($0, adultCategoryIds: liveAdultIds)) }
        let vodKept = vods.filter { !(filterAdult && AdultContentFilter.isAdultVODStream($0, adultCategoryIds: vodAdultIds)) }
        let seriesKept = series.filter { !(filterAdult && ($0.categoryId.map { seriesAdultIds.contains($0) } ?? false)) }
        func categoryCount(_ cats: [XtreamCategory]) -> Int {
            guard filterAdult else { return cats.count }
            return cats.filter { !(($0.categoryName.map { AdultContentFilter.isAdultCategoryName($0) } ?? false)) }.count
        }
        return CatalogFingerprint(
            liveCount: liveKept.count, liveFirstId: liveKept.first?.id, liveLastId: liveKept.last?.id,
            vodCount: vodKept.count, vodFirstId: vodKept.first?.id, vodLastId: vodKept.last?.id,
            seriesCount: seriesKept.count, seriesFirstId: seriesKept.first?.id, seriesLastId: seriesKept.last?.id,
            liveCategoryCount: categoryCount(liveCats),
            vodCategoryCount: categoryCount(vodCats),
            seriesCategoryCount: categoryCount(seriesCats)
        )
    }

    /// Local fingerprint: counts + boundary ids in stored catalog
    /// order (`sortIndex` preserves the panel's original ordering).
    nonisolated private static func localCatalogFingerprint(playlistId: UUID, db: Database) throws -> CatalogFingerprint {
        func boundaryIds(table: String, idColumn: String) throws -> (count: Int, first: Int?, last: Int?) {
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE playlistId = ?", arguments: [playlistId]) ?? 0
            guard count > 0 else { return (0, nil, nil) }
            let first = try Int.fetchOne(db, sql: "SELECT \(idColumn) FROM \(table) WHERE playlistId = ? ORDER BY sortIndex ASC LIMIT 1", arguments: [playlistId])
            let last = try Int.fetchOne(db, sql: "SELECT \(idColumn) FROM \(table) WHERE playlistId = ? ORDER BY sortIndex DESC LIMIT 1", arguments: [playlistId])
            return (count, first, last)
        }
        func categoryCount(type: String) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM category WHERE playlistId = ? AND type = ?", arguments: [playlistId, type]) ?? 0
        }
        let live = try boundaryIds(table: "liveStream", idColumn: "streamId")
        let vod = try boundaryIds(table: "vodStream", idColumn: "streamId")
        let series = try boundaryIds(table: "series", idColumn: "seriesId")
        return CatalogFingerprint(
            liveCount: live.count, liveFirstId: live.first, liveLastId: live.last,
            vodCount: vod.count, vodFirstId: vod.first, vodLastId: vod.last,
            seriesCount: series.count, seriesFirstId: series.first, seriesLastId: series.last,
            liveCategoryCount: try categoryCount(type: "live"),
            vodCategoryCount: try categoryCount(type: "vod"),
            seriesCategoryCount: try categoryCount(type: "series")
        )
    }

    /// Scoped sync: refetches and rewrites a single content type; the other types'
    /// rows are left untouched. Same atomic delete-then-insert guarantee per type.
    func syncFromNetworkReplacingLocal(
        playlist: Playlist, only type: CatalogContentType, progress: @escaping (String) -> Void
    ) async throws {
        let client = XtreamAPIClient(playlist: playlist)
        let pid = playlist.id
        let filterAdult = playlist.filterAdultContent

        progress(L("phase.fetch_categories"))
        switch type {
        case .live:
            async let catsTask = client.getLiveCategories()
            async let streamsTask = client.getLiveStreams()
            let (cats, streams) = try await (catsTask, streamsTask)
            progress(L("phase.save_db"))
            try await AppDatabase.shared.write { db in
                try Self.replaceLiveCatalog(db: db, pid: pid, categories: cats, streams: streams, filterAdult: filterAdult)
            }
        case .vod:
            async let catsTask = client.getVODCategories()
            async let streamsTask = client.getVODStreams()
            let (cats, streams) = try await (catsTask, streamsTask)
            progress(L("phase.save_db"))
            try await AppDatabase.shared.write { db in
                try Self.replaceVODCatalog(db: db, pid: pid, categories: cats, streams: streams, filterAdult: filterAdult)
            }
        case .series:
            async let catsTask = client.getSeriesCategories()
            async let seriesTask = client.getSeries()
            let (cats, items) = try await (catsTask, seriesTask)
            progress(L("phase.save_db"))
            try await AppDatabase.shared.write { db in
                try Self.replaceSeriesCatalog(db: db, pid: pid, categories: cats, series: items, filterAdult: filterAdult)
            }
        }
    }

    // MARK: - DB rewrite helpers (shared by full and scoped sync)

    /// Round 12 (point 3): chunked multi-row INSERT, replacing the
    /// old one-`save(db)`-per-row loops. On the owner's playlist
    /// (~103k rows) the per-row writes meant ~103k prepared
    /// statements inside the sync transaction — the dominant cost
    /// of every refresh, and the reason Home's spinner outlived the
    /// data. 400-row chunks keep each statement far under SQLite's
    /// bind limit (400 × 21 columns = 8,400 ≤ 32,766) while cutting
    /// the statement count ~400×. Semantics are preserved exactly:
    /// the same rows, the same values the DB records would have
    /// written (metadata columns stay at their DB defaults — nil /
    /// false — precisely like a fresh record), the same adult
    /// filtering, and the same ORIGINAL enumerated sortIndex
    /// (skipped rows still consume their index). `INSERT OR
    /// REPLACE` mirrors `save()`'s last-wins outcome if a panel
    /// payload repeats an id.
    private static func bulkInsert(
        db: Database, table: String, columns: [String], rows: [[DatabaseValueConvertible]]
    ) throws {
        guard !rows.isEmpty else { return }
        let chunkSize = 400
        let columnList = columns.joined(separator: ", ")
        let oneRow = "(" + columns.map { _ in "?" }.joined(separator: ", ") + ")"
        var start = 0
        while start < rows.count {
            let end = min(start + chunkSize, rows.count)
            let chunk = rows[start..<end]
            let sql = "INSERT OR REPLACE INTO \(table) (\(columnList)) VALUES "
                + chunk.map { _ in oneRow }.joined(separator: ", ")
            var args: [DatabaseValueConvertible] = []
            args.reserveCapacity(chunk.count * columns.count)
            for row in chunk { args.append(contentsOf: row) }
            try db.execute(sql: sql, arguments: StatementArguments(args))
            start = end
        }
    }

    /// nil → SQL NULL for the flat argument arrays (DatabaseValue
    /// is itself DatabaseValueConvertible — the same pattern
    /// EPGStore uses to build dynamic arguments).
    private static func opt(_ value: String?) -> DatabaseValueConvertible {
        value.map { $0 as DatabaseValueConvertible } ?? DatabaseValue.null
    }

    private static func opt(_ value: Double?) -> DatabaseValueConvertible {
        value.map { $0 as DatabaseValueConvertible } ?? DatabaseValue.null
    }

    private static func opt(_ value: Int?) -> DatabaseValueConvertible {
        value.map { $0 as DatabaseValueConvertible } ?? DatabaseValue.null
    }

    private static func categoryRows(
        categories: [XtreamCategory], type: String, pid: UUID, filterAdult: Bool
    ) -> [[DatabaseValueConvertible]] {
        var rows: [[DatabaseValueConvertible]] = []
        for (index, cat) in categories.enumerated() {
            if filterAdult, let name = cat.categoryName, AdultContentFilter.isAdultCategoryName(name) { continue }
            rows.append([cat.id, cat.categoryName ?? L("content.unnamed"), opt(cat.parentId), type, index, pid])
        }
        return rows
    }

    private static let categoryColumns = ["id", "name", "parentId", "type", "sortIndex", "playlistId"]

    private static func replaceLiveCatalog(
        db: Database, pid: UUID, categories: [XtreamCategory], streams: [XtreamLiveStream], filterAdult: Bool
    ) throws {
        let adultCatIds = filterAdult ? AdultContentFilter.adultCategoryIds(from: categories) : []
        try db.execute(sql: "DELETE FROM category WHERE playlistId = ? AND type = 'live'", arguments: [pid])
        try db.execute(sql: "DELETE FROM liveStream WHERE playlistId = ?", arguments: [pid])
        try bulkInsert(db: db, table: "category", columns: categoryColumns,
                       rows: categoryRows(categories: categories, type: "live", pid: pid, filterAdult: filterAdult))
        var rows: [[DatabaseValueConvertible]] = []
        rows.reserveCapacity(streams.count)
        for (index, stream) in streams.enumerated() {
            if filterAdult, AdultContentFilter.isAdultLiveStream(stream, adultCategoryIds: adultCatIds) { continue }
            rows.append([
                stream.id, stream.name ?? L("content.unnamed"), opt(stream.streamIcon),
                opt(stream.epgChannelId), opt(stream.categoryId), index, pid,
                stream.tvArchive ?? 0, stream.tvArchiveDuration ?? 0
            ])
        }
        try bulkInsert(db: db, table: "liveStream",
                       columns: ["streamId", "name", "streamIcon", "epgChannelId", "categoryId", "sortIndex", "playlistId", "tvArchive", "tvArchiveDuration"],
                       rows: rows)
    }

    private static func replaceVODCatalog(
        db: Database, pid: UUID, categories: [XtreamCategory], streams: [XtreamVODStream], filterAdult: Bool
    ) throws {
        let adultCatIds = filterAdult ? AdultContentFilter.adultCategoryIds(from: categories) : []
        try db.execute(sql: "DELETE FROM category WHERE playlistId = ? AND type = 'vod'", arguments: [pid])
        try db.execute(sql: "DELETE FROM vodStream WHERE playlistId = ?", arguments: [pid])
        try bulkInsert(db: db, table: "category", columns: categoryColumns,
                       rows: categoryRows(categories: categories, type: "vod", pid: pid, filterAdult: filterAdult))
        var rows: [[DatabaseValueConvertible]] = []
        rows.reserveCapacity(streams.count)
        for (index, stream) in streams.enumerated() {
            if filterAdult, AdultContentFilter.isAdultVODStream(stream, adultCategoryIds: adultCatIds) { continue }
            // The metadata columns (director … kinopoiskURL) are the
            // fresh-record defaults — NULL — exactly what the old
            // per-row save() wrote; metadataLoaded = false likewise.
            rows.append([
                stream.id, stream.name ?? L("content.unnamed"), opt(stream.streamIcon),
                opt(stream.categoryId), opt(stream.rating), opt(stream.containerExtension),
                DatabaseValue.null, DatabaseValue.null, DatabaseValue.null, DatabaseValue.null,
                DatabaseValue.null, DatabaseValue.null, DatabaseValue.null, DatabaseValue.null,
                DatabaseValue.null, DatabaseValue.null, DatabaseValue.null,
                false, opt(stream.added), index, pid
            ])
        }
        try bulkInsert(db: db, table: "vodStream",
                       columns: ["streamId", "name", "streamIcon", "categoryId", "rating", "containerExtension",
                                 "director", "cast", "plot", "genre", "releaseDate", "rating5Based", "backdropPath",
                                 "youtubeTrailer", "duration", "tmdbId", "kinopoiskURL", "metadataLoaded",
                                 "added", "sortIndex", "playlistId"],
                       rows: rows)
    }

    private static func replaceSeriesCatalog(
        db: Database, pid: UUID, categories: [XtreamCategory], series: [XtreamSeries], filterAdult: Bool
    ) throws {
        let adultCatIds = filterAdult ? AdultContentFilter.adultCategoryIds(from: categories) : []
        try db.execute(sql: "DELETE FROM category WHERE playlistId = ? AND type = 'series'", arguments: [pid])
        try db.execute(sql: "DELETE FROM series WHERE playlistId = ?", arguments: [pid])
        try bulkInsert(db: db, table: "category", columns: categoryColumns,
                       rows: categoryRows(categories: categories, type: "series", pid: pid, filterAdult: filterAdult))
        var rows: [[DatabaseValueConvertible]] = []
        rows.reserveCapacity(series.count)
        for (index, s) in series.enumerated() {
            if filterAdult, let cid = s.categoryId, adultCatIds.contains(cid) { continue }
            // rating5Based / backdropPath / episodeRunTime are the
            // fresh-record defaults (NULL); seasonsLoaded = false —
            // identical to the old per-row save().
            rows.append([
                s.id, s.name ?? L("content.unnamed"), opt(s.cover), opt(s.plot), opt(s.cast),
                opt(s.director), opt(s.genre), opt(s.releaseDate), opt(s.rating), opt(s.lastModified),
                DatabaseValue.null, DatabaseValue.null, opt(s.youtubeTrailer), DatabaseValue.null,
                opt(s.categoryId), index, false, pid
            ])
        }
        try bulkInsert(db: db, table: "series",
                       columns: ["seriesId", "name", "cover", "plot", "cast", "director", "genre", "releaseDate",
                                 "rating", "lastModified", "rating5Based", "backdropPath", "youtubeTrailer",
                                 "episodeRunTime", "categoryId", "sortIndex", "seasonsLoaded", "playlistId"],
                       rows: rows)
    }
}
