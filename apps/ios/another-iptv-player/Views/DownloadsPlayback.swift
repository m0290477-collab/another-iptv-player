import SwiftUI

/// Build 61 fix round 3: the two player presentations from
/// DownloadsView's `play(_:)` as standalone structs. The movie
/// presentation's `playerOverlay.present { PlayerView(…15 args) }`
/// expression is the one the type checker failed to produce a
/// diagnostic for at DownloadsView.swift:806 in the third build;
/// as a struct body fed by explicit stored properties it is
/// trivially checkable. DownloadsView keeps the two
/// `present*Playback` wrappers that hand these to the overlay.

/// Build 61 fix round 2: the episode presentation, verbatim
/// from `play(_:)`'s former MainActor block (called on the
/// main actor from there, as before).
struct DownloadsEpisodePresentation: View {
    let playlist: Playlist
    let item: DBDownloadedItem
    let localURL: URL
    let existingHistory: DBWatchHistory?
    let onNavigateToDetail: (String, String) -> Void

    // Belongs to a series — HistorySeriesPlayerShell handles both resume and the next/previous
    // manages the transition to the episode (the ordering is the series' own episode order, not the download order).
    private var history: DBWatchHistory {
        existingHistory ?? DBWatchHistory(
            id: "\(playlist.id)_series_\(item.streamId)",
            playlistId: playlist.id,
            streamId: item.streamId,
            type: "series",
            lastTimeMs: 0,
            durationMs: 0,
            lastWatchedAt: Date(),
            seriesId: item.seriesId,
            title: item.title,
            secondaryTitle: item.secondaryTitle,
            imageURL: item.imageURL,
            containerExtension: item.containerExtension
        )
    }

    var body: some View {
        HistorySeriesPlayerShell(
            playlist: playlist,
            history: history,
            url: localURL,
            onNavigateToDetail: onNavigateToDetail
        )
    }
}

/// Build 61 fix round 2: the movie/recording presentation,
/// verbatim from `play(_:)`'s former MainActor block (called
/// on the main actor from there, as before).
struct DownloadsMoviePresentation: View {
    let playlist: Playlist
    let item: DBDownloadedItem
    let localURL: URL
    let existingHistory: DBWatchHistory?
    let onNavigateToDetail: (String, String) -> Void

    private var detailNavigation: ((String, String) -> Void)? {
        item.type == "recording" ? nil : onNavigateToDetail
    }

    // Movie — no prev/next, only local playback + resume.
    var body: some View {
        PlayerView(
            url: localURL,
            title: item.title,
            subtitle: item.secondaryTitle,
            artworkURL: item.imageURL.flatMap { ArtworkURL.url(from: $0) },
            isLiveStream: false,
            playlistId: playlist.id,
            streamId: item.streamId,
            type: "vod",
            seriesId: item.seriesId,
            resumeTimeMs: existingHistory?.lastTimeMs,
            containerExtension: item.containerExtension,
            onNavigateToDetail: detailNavigation
        )
    }
}
