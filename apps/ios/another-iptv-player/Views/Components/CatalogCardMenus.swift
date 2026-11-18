import SwiftUI

/// Build 61 (B8, C2/J1): the long-press menu items shared by movie
/// and series cards — Watch Later toggle + favorite-group
/// assignment, both backed by the SAME stores the detail pages use
/// (O6: same actions, no duplicate stores). Attached at the card
/// call sites of the Movies/Series browsing surfaces; the detail
/// pages carry the same actions as rows.
struct VODCardMenuItems: View {
    let playlist: Playlist
    let movie: DBVODStream

    @ObservedObject private var watchlistStore = WatchlistStore.shared

    var body: some View {
        let inWatchlist = watchlistStore.contains(playlistId: playlist.id, streamId: movie.streamId)
        Button {
            watchlistStore.toggleMovie(
                playlistId: playlist.id, streamId: movie.streamId,
                title: movie.name, imageURL: movie.streamIcon
            )
        } label: {
            Label(
                inWatchlist ? L("watchlater.remove") : L("watchlater.add"),
                systemImage: inWatchlist ? "bookmark.slash" : "bookmark"
            )
        }
        FavoriteGroupMenuItems(
            playlist: playlist,
            item: FavoriteGroupStore.Item(type: "vod", itemId: String(movie.streamId), title: movie.name, imageURL: movie.streamIcon),
            allowCreateLink: false
        )
    }
}

/// Series twin of `VODCardMenuItems`.
struct SeriesCardMenuItems: View {
    let playlist: Playlist
    let series: DBSeries

    @ObservedObject private var watchlistStore = WatchlistStore.shared

    var body: some View {
        let inWatchlist = watchlistStore.containsSeries(playlistId: playlist.id, seriesId: series.seriesId)
        Button {
            watchlistStore.toggleSeries(
                playlistId: playlist.id, seriesId: series.seriesId,
                title: series.name, imageURL: series.cover
            )
        } label: {
            Label(
                inWatchlist ? L("watchlater.remove") : L("watchlater.add"),
                systemImage: inWatchlist ? "bookmark.slash" : "bookmark"
            )
        }
        FavoriteGroupMenuItems(
            playlist: playlist,
            item: FavoriteGroupStore.Item(type: "series", itemId: String(series.seriesId), title: series.name, imageURL: series.cover),
            allowCreateLink: false
        )
    }
}
