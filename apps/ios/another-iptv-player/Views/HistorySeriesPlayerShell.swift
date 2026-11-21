import GRDB
import SwiftUI

/// The series player opened from "Where you left off" / history; moves to the prev/next episode within the same series.
struct HistorySeriesPlayerShell: View {
    let playlist: Playlist
    private let initialHistory: DBWatchHistory
    private let initialURL: URL

    @State private var session: SeriesPlaybackSession
    @State private var neighborPrev: DBEpisode?
    @State private var neighborNext: DBEpisode?
    /// Build 66 (W4, item 5b): a series-info fetch failure is no
    /// longer swallowed — it surfaces in an alert with a Retry
    /// action (the same errorMessage pattern Series Detail uses).
    /// Playback of the current episode is unaffected; only the
    /// episode-chain fetch failed.
    @State private var episodeLoadError: String?
    @Environment(\.playerOverlayPresentationID) private var overlayPresentationID
    
    var onNavigateToDetail: ((String, String) -> Void)? = nil

    init(playlist: Playlist, history: DBWatchHistory, url: URL, onNavigateToDetail: ((String, String) -> Void)? = nil) {
        self.playlist = playlist
        self.initialHistory = history
        self.initialURL = url
        _session = State(initialValue: SeriesPlaybackSession(history: history, url: url))
        self.onNavigateToDetail = onNavigateToDetail
    }

    var body: some View {
        PlayerView(
            url: session.url,
            title: session.title,
            subtitle: session.subtitle,
            artworkURL: session.artworkURL,
            isLiveStream: false,
            playlistId: playlist.id,
            streamId: session.streamId,
            type: "series",
            seriesId: session.seriesId,
            resumeTimeMs: session.resumeTimeMs,
            containerExtension: session.containerExtension,
            // Build 61 (B10, G2): playlist User-Agent to the engine load path.
            userAgent: playlist.playbackUserAgent(channelUserAgent: nil),
            // Build 61 (FA, F-2/G2): custom headers alongside the UA.
            customHeaders: playlist.customHeaders,
            canGoToPreviousEpisode: neighborPrev != nil,
            canGoToNextEpisode: neighborNext != nil,
            onPreviousEpisode: { jumpTo(neighborPrev) },
            onNextEpisode: { jumpTo(neighborNext) },
            onNavigateToDetail: onNavigateToDetail
        )
        .task(id: session.streamId) {
            await refreshNeighbors()
        }
        // Build 66 (W4, item 5b): visible failure + Retry for the
        // episode fetch (mirrors Series Detail's errorMessage flow).
        .alert(L("common.error"), isPresented: Binding(
            get: { episodeLoadError != nil },
            set: { if !$0 { episodeLoadError = nil } }
        )) {
            Button(L("common.try_again")) {
                episodeLoadError = nil
                if let seriesIdStr = session.seriesId, let sid = Int(seriesIdStr) {
                    Task {
                        await loadEpisodesFromAPI(seriesId: sid)
                        await refreshNeighbors()
                    }
                }
            }
            Button(L("common.ok"), role: .cancel) { episodeLoadError = nil }
        } message: {
            Text(episodeLoadError ?? "")
        }
        .onChange(of: overlayPresentationID) { _, _ in
            applyInitialSelectionIfNeeded()
        }
    }

    private func applyInitialSelectionIfNeeded() {
        let target = SeriesPlaybackSession(history: initialHistory, url: initialURL)
        guard session != target else { return }
        neighborPrev = nil
        neighborNext = nil
        session = target
    }

    private func refreshNeighbors() async {
        guard let seriesIdStr = session.seriesId, let seriesId = Int(seriesIdStr) else {
            await MainActor.run {
                neighborPrev = nil; neighborNext = nil
            }
            return
        }

        // It may have been cascade-deleted after sync; if seasonsLoaded = false, fetch it from the API
        let episodesMissing = (try? await AppDatabase.shared.read { db in
            try DBSeries
                .filter(Column("seriesId") == seriesId && Column("playlistId") == playlist.id)
                .fetchOne(db)
                .map { !$0.seasonsLoaded } ?? true
        }) ?? true

        if episodesMissing {
            await loadEpisodesFromAPI(seriesId: seriesId)
        }

        let ctx = try? await AppDatabase.shared.read { db in
            try SeriesPlaybackOrdering.navigationContext(
                playlistId: playlist.id,
                playbackStreamId: session.streamId,
                seriesIdHint: seriesIdStr,
                db: db
            )
        }
        await MainActor.run {
            neighborPrev = ctx?.previous
            neighborNext = ctx?.next
        }
    }

    private func loadEpisodesFromAPI(seriesId: Int) async {
        let client = XtreamAPIClient(playlist: playlist)
        // Build 66 (W4, item 5b): was `guard let info = try? … else
        // { return }` — a fetch failure silently left prev/next
        // episode navigation dead. Now logged + surfaced with Retry
        // (see the alert in `body`).
        let info: XtreamSeriesInfoResponse
        do {
            info = try await client.getSeriesInfo(seriesId: seriesId)
        } catch {
            Log.error("HistorySeriesPlayerShell", "Series info fetch failed: \(error.localizedDescription)")
            await MainActor.run { episodeLoadError = error.localizedDescription }
            return
        }

        let episodesBySeason = info.episodesBySeasonNumber

        try? await AppDatabase.shared.write { db in
            // Round 15 (C8): ghost-episode cleanup, same rule as the
            // detail screen's fetch — fetched set first, then delete
            // this series' stored episodes absent from it.
            var fetchedEpisodeIds = Set<String>()
            for (seasonNum, apiSeason) in info.resolvedSeasons {
                let seasonId = DBSeason.scopedId(playlistId: playlist.id, seriesId: seriesId, seasonNumber: seasonNum)
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
                    seriesId: seriesId,
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

            let storedSeasonIds = try DBSeason
                .filter(Column("seriesId") == seriesId && Column("playlistId") == playlist.id)
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

            // So it isn't fetched again on the next open
            if var s = try DBSeries
                .filter(Column("seriesId") == seriesId && Column("playlistId") == playlist.id)
                .fetchOne(db) {
                s.seasonsLoaded = true
                try s.save(db)
            }
        }
    }

    private func jumpTo(_ episode: DBEpisode?) {
        guard let ep = episode else { return }
        let targetSid = ep.episodeId ?? ep.id
        // Swallow a jump to the same episode (fast double tap / stale button) and immediately reset the neighbors:
        // until the refreshNeighbors network round finished, the old episode's neighbors
        // stayed valid on the buttons/in Control Center.
        guard targetSid != session.streamId else { return }
        neighborPrev = nil
        neighborNext = nil
        Task {
            let sid = targetSid
            // If the episode is downloaded, play it from the local file; otherwise use the remote URL.
            let localURL = await DownloadManager.shared.localURL(
                forId: DownloadManager.idFor(episode: playlist.id, episodeId: sid)
            )
            let url: URL
            if let localURL {
                url = localURL
            } else {
                let builder = PlaybackURLBuilder(playlist: playlist)
                guard let remoteURL = builder.seriesURL(streamId: sid, containerExtension: ep.containerExtension) else { return }
                url = remoteURL
            }
            let hist: DBWatchHistory? = try? await AppDatabase.shared.read { db in
                try DBWatchHistory
                    .filter(
                        Column("streamId") == sid && Column("playlistId") == playlist.id && Column("type") == "series"
                    )
                    .fetchOne(db)
            }
            let seriesIdStr = session.seriesId
            let seriesTitle = session.subtitle
            await MainActor.run {
                session = SeriesPlaybackSession(
                    episode: ep,
                    url: url,
                    seriesId: seriesIdStr,
                    seriesTitle: seriesTitle,
                    resumeHistory: hist
                )
            }
        }
    }
}

private struct SeriesPlaybackSession: Equatable {
    var url: URL
    var streamId: String
    var title: String
    var subtitle: String?
    var artworkURL: URL?
    var resumeTimeMs: Int?
    var containerExtension: String?
    var seriesId: String?

    init(history: DBWatchHistory, url: URL) {
        self.url = url
        streamId = history.streamId
        title = history.title
        subtitle = history.secondaryTitle
        artworkURL = history.imageURL.flatMap { ArtworkURL.url(from: $0) }
        resumeTimeMs = history.lastTimeMs
        containerExtension = history.containerExtension
        seriesId = history.seriesId
    }

    init(episode: DBEpisode, url: URL, seriesId: String?, seriesTitle: String?, resumeHistory: DBWatchHistory?) {
        self.url = url
        streamId = episode.episodeId ?? episode.id
        title = {
            let num = episode.episodeNum.map { "\($0). " } ?? ""
            let raw = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let t = raw.isEmpty ? L("detail.episode_fallback") : raw
            return num + t
        }()
        subtitle = seriesTitle
        artworkURL = episode.cover.flatMap { ArtworkURL.url(from: $0) }
        resumeTimeMs = resumeHistory?.lastTimeMs
        containerExtension = episode.containerExtension
        self.seriesId = seriesId
    }
}
