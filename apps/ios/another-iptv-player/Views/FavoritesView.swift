import SwiftUI
import GRDB
import GRDBQuery

/// The app's ONE favorites surface (Xtream playlists).
///
/// Round 10 redesign (owner, build 46): the old header stacked a
/// segmented picker on an ultra-thin-material band, and its system
/// `.searchable` field hit the same double-mount glitch that broke
/// the Search page — the field now is the shared in-view
/// `CatalogSearchField`, the type switch is the shared pill style,
/// and each type gets a designed empty state. All data plumbing
/// (queries, filtering, the favorites play queue) is unchanged.
struct FavoritesView: View {
    let playlist: Playlist

    /// Build 65 (Favorites style 2 'Shelves by Type'): the type
    /// is no longer a switch — all three shelves render in one
    /// scroll. The caller's `initialType` now only decides which
    /// shelf comes FIRST (deep links from a section land on
    /// their shelf).
    @State private var selectedType: String
    @State private var searchText = ""
    @Environment(\.posterMetrics) private var posterMetrics
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    @Query<FavoriteLiveRequest> private var favoriteLive: [LiveStreamWithCategory]
    @Query<FavoriteVODRequest> private var favoriteVODs: [VODWithCategory]
    @Query<FavoriteSeriesRequest> private var favoriteSeries: [SeriesWithCategory]
    @Query<WatchProgressMapRequest> private var vodProgressMap: [String: Double]
    @Query<WatchProgressMapRequest> private var seriesProgressMap: [String: Double]

    init(playlist: Playlist, initialType: String = "vod") {
        self.playlist = playlist
        self._selectedType = State(initialValue: initialType)
        _favoriteLive = Query(FavoriteLiveRequest(playlistId: playlist.id), in: \.appDatabase)
        _favoriteVODs = Query(FavoriteVODRequest(playlistId: playlist.id), in: \.appDatabase)
        _favoriteSeries = Query(FavoriteSeriesRequest(playlistId: playlist.id), in: \.appDatabase)
        _vodProgressMap = Query(WatchProgressMapRequest(playlistId: playlist.id, type: "vod"), in: \.appDatabase)
        _seriesProgressMap = Query(WatchProgressMapRequest(playlistId: playlist.id, type: "series"), in: \.appDatabase)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Round 10 header: the shared search field + type pills,
            // one tidy block under the (large) navigation title.
            VStack(spacing: 12) {
                CatalogSearchField(text: $searchText, placeholder: L("favorites.search_placeholder"))

                // Build 61 (B8, J1): custom favorite groups live in
                // the Library alongside Favorites + Watch Later.
                NavigationLink {
                    FavoriteGroupsView(playlist: playlist)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.subheadline.weight(.semibold))
                        Text(L("groups.title"))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)

            shelvesScroll

            // Build 61 (B8, R6): favorites whose catalog entry has
            // vanished stay listed here, marked unavailable — user
            // data is never silently deleted.
            if !unavailableFavorites.isEmpty {
                unavailableSection
            }
        }
        .navigationTitle(L("favorites.title"))
        .navigationBarTitleDisplayMode(.large)
        .cinematicBackground()
        .task { await loadRawFavorites() }
        .onChange(of: favoriteLive.count) { _, _ in Task { await loadRawFavorites() } }
        .onChange(of: favoriteVODs.count) { _, _ in Task { await loadRawFavorites() } }
        .onChange(of: favoriteSeries.count) { _, _ in Task { await loadRawFavorites() } }
    }

    // MARK: - Build 61 (B8, R6): unavailable favorites

    @State private var rawFavorites: [DBFavorite] = []
    @ObservedObject private var snapshotStore = FavoriteSnapshotStore.shared

    private func loadRawFavorites() async {
        let pid = playlist.id
        let rows = try? await AppDatabase.shared.read { db in
            try DBFavorite.filter(Column("playlistId") == pid).fetchAll(db)
        }
        rawFavorites = rows ?? []
    }

    private var unavailableFavorites: [DBFavorite] {
        // Build 65: with shelves, unavailable favorites from ALL
        // types list together (was: only the selected type's).
        let liveIds = Set(favoriteLive.map(\.stream.streamId))
        let vodIds = Set(favoriteVODs.map(\.stream.streamId))
        let seriesIds = Set(favoriteSeries.map(\.series.seriesId))
        return rawFavorites.filter { favorite in
            switch favorite.type {
            case "live": return !liveIds.contains(favorite.streamId)
            case "vod": return !vodIds.contains(favorite.streamId)
            case "series": return !seriesIds.contains(favorite.streamId)
            default: return false
            }
        }
    }

    private var unavailableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("groups.unavailable"))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
            ForEach(unavailableFavorites, id: \.streamId) { favorite in
                let snap = snapshotStore.snapshot(playlistId: playlist.id, type: favorite.type, streamId: favorite.streamId)
                HStack(spacing: 12) {
                    CachedImage(
                        url: snap?.imageURL.flatMap { ArtworkURL.url(from: $0) },
                        width: 44, height: 44,
                        cornerRadius: AppTheme.smallCornerRadius,
                        iconName: "exclamationmark.triangle"
                    )
                    Text(snap?.title ?? L("groups.unavailable"))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button(role: .destructive) {
                        removeFavorite(streamId: favorite.streamId, type: favorite.type)
                        FavoriteSnapshotStore.shared.remove(playlistId: playlist.id, type: favorite.type, streamId: favorite.streamId)
                        rawFavorites.removeAll { $0.streamId == favorite.streamId && $0.type == favorite.type }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Search filtering (because the favorites lists are small, filtering per render is enough)

    private var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    private var displayedLive: [LiveStreamWithCategory] {
        guard !trimmedQuery.isEmpty else { return favoriteLive }
        return favoriteLive.filter { CatalogTextSearch.matches(search: trimmedQuery, text: $0.stream.name) }
    }

    private var displayedVODs: [VODWithCategory] {
        guard !trimmedQuery.isEmpty else { return favoriteVODs }
        return favoriteVODs.filter { CatalogTextSearch.matches(search: trimmedQuery, text: $0.stream.name) }
    }

    private var displayedSeries: [SeriesWithCategory] {
        guard !trimmedQuery.isEmpty else { return favoriteSeries }
        return favoriteSeries.filter { CatalogTextSearch.matches(search: trimmedQuery, text: $0.series.name) }
    }

    /// C1 (Round 15): unfavorite directly from this grid — same
    /// DBFavorite rows the detail screens toggle.
    private func removeFavorite(streamId: Int, type: String) {
        let pid = playlist.id
        Task {
            try? await AppDatabase.shared.write { db in
                try DBFavorite
                    .filter(Column("streamId") == streamId && Column("playlistId") == pid && Column("type") == type)
                    .deleteAll(db)
            }
        }
    }

    private func presentFavoriteLive(stream: DBLiveStream, history: DBWatchHistory?) {
        // Like all other live entry points, LivePlayerShell: so prev/next channel and the side panel work
        // between favorites (a bare PlayerView was losing these).
        let queue = displayedLive.map(\.stream)
        let sections = [LiveChannelCategorySection(
            id: "favorites",
            title: L("favorites.title"),
            streams: queue
        )]
        playerOverlay.present(playlistId: playlist.id) {
            LivePlayerShell(
                playlist: playlist,
                queue: queue,
                sections: sections,
                initialStream: stream,
                initialHistory: history,
                subtitle: nil
            )
        }
    }

    // MARK: - Build 65: Shelves by Type

    /// Shelf order: the caller's type first, then Live · Movies
    /// · Series.
    private var shelfOrder: [String] {
        let base = ["live", "vod", "series"]
        guard base.contains(selectedType) else { return base }
        return [selectedType] + base.filter { $0 != selectedType }
    }

    private var hasAnyDisplayed: Bool {
        !displayedLive.isEmpty || !displayedVODs.isEmpty || !displayedSeries.isEmpty
    }

    @ViewBuilder
    private var shelvesScroll: some View {
        if !hasAnyDisplayed {
            emptyState(
                icon: "star.slash",
                message: trimmedQuery.isEmpty ? L("favorites.empty.all") : L("list.no_result")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(shelfOrder, id: \.self) { type in
                        switch type {
                        case "live":
                            if !displayedLive.isEmpty { liveShelf }
                        case "vod":
                            if !displayedVODs.isEmpty { vodShelf }
                        default:
                            if !displayedSeries.isEmpty { seriesShelf }
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.bottom, 18)
            }
        }
    }

    private func shelfHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(AppTheme.accent)
                .frame(width: 3, height: 18)
            Text(title)
                .font(AppTheme.fontSectionTitle)
            Text("\(count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    /// Favorite Channels shelf: logo ROWS (build 80: the EPG
    /// now/next line went with the TV Guide removal).
    private var liveShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            shelfHeader(L("favorites.shelf.channels"), count: displayedLive.count)
            VStack(spacing: 8) {
                ForEach(displayedLive) { item in
                    Button {
                        presentFavoriteLive(stream: item.stream, history: nil)
                    } label: {
                        HStack(spacing: 12) {
                            CachedImage(
                                url: item.stream.streamIcon.flatMap { ArtworkURL.url(from: $0) },
                                width: 52, height: 38,
                                cornerRadius: 8,
                                contentMode: .fit,
                                iconName: "tv"
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.stream.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundStyle(AppTheme.accent)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                                .fill(AppTheme.elevated)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            removeFavorite(streamId: item.stream.streamId, type: "live")
                        } label: {
                            Label(L("favorites.remove"), systemImage: "star.slash")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .sectionAppear()
    }

    /// Favorite Movies shelf: a poster rail (same cards, menus
    /// and detail navigation the grid used).
    private var vodShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            shelfHeader(L("favorites.shelf.movies"), count: displayedVODs.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(displayedVODs) { item in
                        NavigationLink(destination: MovieDetailView(playlist: playlist, movie: item.stream, queue: displayedVODs.map(\.stream))) {
                            VODStreamCard(
                                playlistId: playlist.id,
                                stream: item.stream,
                                categoryName: item.categoryName,
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                imageLoadProfile: ImageLoadProfile.shelf,
                                watchProgress: vodProgressMap[String(item.stream.streamId)]
                            )
                        }
                        .contextMenu {
                            // Build 61 (B8, C2/J1): Watch Later +
                            // groups ride the same menu.
                            VODCardMenuItems(playlist: playlist, movie: item.stream)
                            Button(role: .destructive) {
                                removeFavorite(streamId: item.stream.streamId, type: "vod")
                            } label: {
                                Label(L("favorites.remove"), systemImage: "star.slash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
            .shelfEdgeFade()
        }
        .sectionAppear()
    }

    /// Favorite Series shelf: a poster rail, same treatment.
    private var seriesShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            shelfHeader(L("favorites.shelf.series"), count: displayedSeries.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(displayedSeries) { item in
                        NavigationLink(destination: SeriesDetailView(playlist: playlist, series: item.series)) {
                            SeriesCard(
                                playlistId: playlist.id,
                                stream: item.series,
                                categoryName: item.categoryName,
                                posterWidth: posterMetrics.shelfPosterWidth,
                                posterHeight: posterMetrics.shelfPosterHeight,
                                imageLoadProfile: ImageLoadProfile.shelf,
                                watchProgress: seriesProgressMap[String(item.series.seriesId)]
                            )
                        }
                        .contextMenu {
                            // Build 61 (B8, C2/J1): Watch Later +
                            // groups ride the same menu.
                            SeriesCardMenuItems(playlist: playlist, series: item.series)
                            Button(role: .destructive) {
                                removeFavorite(streamId: item.series.seriesId, type: "series")
                            } label: {
                                Label(L("favorites.remove"), systemImage: "star.slash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
            .shelfEdgeFade()
        }
        .sectionAppear()
    }

    /// Round 10: the designed empty state — the type's glyph in an
    /// elevated circle over the (existing) honest message; shown
    /// both with no favorites at all and when the search matches
    /// none.
    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 76, height: 76)
                .background(Circle().fill(AppTheme.elevated))
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
