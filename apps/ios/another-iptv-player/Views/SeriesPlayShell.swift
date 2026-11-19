import GRDB
import SwiftUI

/// Round 8 (F-2): direct-play shell behind the Home featured carousel's
/// series Play button. The button used to open Series Detail — the same
/// destination as the Details button next to it. This shell runs the
/// REAL episode pipeline instead, with the same rules the detail
/// screen applies:
///
/// 1. Episodes are loaded first when the catalog hasn't fetched them
///    yet (same Xtream series-info fetch + DB save the detail screen
///    and HistorySeriesPlayerShell perform).
/// 2. The target episode is the viewer's actual next step: resume the
///    in-progress episode when the latest series history is mid-watch
///    (>5 s in, <98% through — the detail screen's own resume rule),
///    otherwise the NEXT episode after the last watched one, otherwise
///    the first episode of the first season.
/// 3. Playback itself is the stock PlayerView with working episode
///    prev/next (SeriesPlaybackOrdering), local-download playback when
///    the episode is on disk, and per-episode resume — no parallel
///    player machinery.
struct SeriesPlayShell: View {
    let playlist: Playlist
    let series: DBSeries
    /// Player title-tap target: the caller (Home) dismisses the overlay
    /// and pushes this series' detail screen.
    var onNavigateToDetail: ((DBSeries) -> Void)? = nil

    @State private var session: EpisodePlaySession?
    @State private var neighborPrev: DBEpisode?
    @State private var neighborNext: DBEpisode?
    @State private var loadFailed = false
    /// Build 66 (W4, item 5b): a series-info fetch failure is no
    /// longer swallowed — it surfaces here with a Retry action (the
    /// same errorMessage pattern Series Detail uses).
    @State private var loadErrorMessage: String?
    @Environment(\.playerOverlayDismiss) private var overlayDismiss
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session {
                PlayerView(
                    url: session.url,
                    title: session.title,
                    subtitle: session.subtitle,
                    artworkURL: session.artworkURL,
                    isLiveStream: false,
                    playlistId: playlist.id,
                    streamId: session.streamId,
                    type: "series",
                    seriesId: String(series.seriesId),
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
                    onNavigateToDetail: onNavigateToDetail == nil ? nil : { _, _ in onNavigateToDetail?(series) }
                )
            } else if let loadErrorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(loadErrorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L("common.try_again")) {
                        Task { await prepare() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    Button(L("common.close")) {
                        if let overlayDismiss { overlayDismiss() } else { dismiss() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(24)
            } else if loadFailed {
                VStack(spacing: 16) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(L("series.no_seasons_info"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L("common.close")) {
                        if let overlayDismiss { overlayDismiss() } else { dismiss() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(24)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.3)
            }
        }
        .task(id: series.seriesId) { await prepare() }
        .task(id: session?.streamId) { await refreshNeighbors() }
    }

    // MARK: - Target selection

    private func prepare() async {
        session = nil
        neighborPrev = nil
        neighborNext = nil
        loadFailed = false
        loadErrorMessage = nil

        // 1. Episodes must exist locally; fetch them exactly like the
        // detail screen does when `seasonsLoaded` is false.
        let seasonsLoaded = (try? await AppDatabase.shared.read { db in
            try DBSeries
                .filter(Column("seriesId") == series.seriesId && Column("playlistId") == playlist.id)
                .fetchOne(db)
                .map { $0.seasonsLoaded } ?? false
        }) ?? false
        if !seasonsLoaded {
            await loadEpisodesFromAPI()
        }

        // 2. Latest series history decides resume vs next unwatched.
        let history = try? await AppDatabase.shared.read { db in
            try DBWatchHistory
                .filter(
                    Column("seriesId") == String(series.seriesId)
                        && Column("playlistId") == playlist.id
                        && Column("type") == "series"
                )
                .order(Column("lastWatchedAt").desc)
                .fetchOne(db)
        }

        var target: (episode: DBEpisode, resume: DBWatchHistory?)?
        if let history {
            let watched = try? await AppDatabase.shared.read { db in
                try DBEpisode
                    .filter(Column("episodeId") == history.streamId || Column("id") == history.streamId)
                    .fetchOne(db)
            }
            if let watched {
                let midWatch = history.lastTimeMs > 5000
                    && (history.durationMs <= 0
                        || Double(history.lastTimeMs) / Double(history.durationMs) < 0.98)
                if midWatch {
                    target = (watched, history)
                } else {
                    // Finished (or barely started): the next unwatched
                    // episode, when the ordering knows one.
                    let next = try? await AppDatabase.shared.read { db in
                        try SeriesPlaybackOrdering.navigationContext(
                            playlistId: playlist.id,
                            playbackStreamId: history.streamId,
                            seriesIdHint: String(series.seriesId),
                            db: db
                        ).next
                    }
                    if let next {
                        target = (next, nil)
                    }
                }
            }
        }

        // 3. First episode in chain order (round 14, B8: season 0
        // is skipped whenever a season ≥ 1 exists — the same rule
        // the detail screen's playFirstEpisode applies, via the one
        // ordering implementation).
        if target == nil {
            target = try? await AppDatabase.shared.read { db in
                guard let first = try SeriesPlaybackOrdering.firstEpisode(
                    seriesId: series.seriesId,
                    playlistId: playlist.id,
                    db: db
                ) else { return nil }
                return (episode: first, resume: nil)
            }
        }

        guard let target else {
            loadFailed = true
            return
        }
        await startPlayback(episode: target.episode, resume: target.resume)
    }

    private func startPlayback(episode: DBEpisode, resume: DBWatchHistory?) async {
        let sid = episode.episodeId ?? episode.id
        // Build 63 (item 16 hardening, same fix as item 6a): the
        // BOUNDED variant — an unbounded local-file lookup must
        // never be able to stall episode playback before it starts.
        let localURL = await DownloadManager.shared.localURL(
            forId: DownloadManager.idFor(episode: playlist.id, episodeId: sid),
            timeout: 1.5
        )
        let url: URL
        if let localURL {
            url = localURL
        } else {
            let builder = PlaybackURLBuilder(playlist: playlist)
            guard let remoteURL = builder.seriesURL(streamId: sid, containerExtension: episode.containerExtension) else {
                loadFailed = true
                return
            }
            url = remoteURL
        }
        session = EpisodePlaySession(
            episode: episode,
            url: url,
            seriesName: series.name,
            seriesCover: series.cover,
            resumeTimeMs: resume?.lastTimeMs
        )
    }

    // MARK: - Prev / next (same pattern as HistorySeriesPlayerShell)

    private func refreshNeighbors() async {
        guard let session else {
            neighborPrev = nil
            neighborNext = nil
            return
        }
        let ctx = try? await AppDatabase.shared.read { db in
            try SeriesPlaybackOrdering.navigationContext(
                playlistId: playlist.id,
                playbackStreamId: session.streamId,
                seriesIdHint: String(series.seriesId),
                db: db
            )
        }
        neighborPrev = ctx?.previous
        neighborNext = ctx?.next
    }

    private func jumpTo(_ episode: DBEpisode?) {
        guard let episode else { return }
        let targetSid = episode.episodeId ?? episode.id
        guard targetSid != session?.streamId else { return }
        neighborPrev = nil
        neighborNext = nil
        Task {
            let hist: DBWatchHistory? = try? await AppDatabase.shared.read { db in
                try DBWatchHistory
                    .filter(
                        Column("streamId") == targetSid && Column("playlistId") == playlist.id && Column("type") == "series"
                    )
                    .fetchOne(db)
            }
            await startPlayback(episode: episode, resume: hist)
        }
    }

    // MARK: - Episode loading (the detail screen's fetch, verbatim pattern)

    private func loadEpisodesFromAPI() async {
        let client = XtreamAPIClient(playlist: playlist)
        // Build 66 (W4, item 5b): was `guard let info = try? … else
        // { return }` — a fetch failure silently left the shell on
        // its spinner/no-seasons path. Now logged + surfaced with
        // Retry (see the loadErrorMessage branch in `body`).
        let info: XtreamSeriesInfoResponse
        do {
            info = try await client.getSeriesInfo(seriesId: series.seriesId)
        } catch {
            Log.error("SeriesPlayShell", "Series info fetch failed: \(error.localizedDescription)")
            loadErrorMessage = error.localizedDescription
            return
        }

        let episodesBySeason = info.episodesBySeasonNumber

        try? await AppDatabase.shared.write { db in
            // Round 15 (C8): ghost-episode cleanup, same rule as the
            // detail screen's fetch — fetched set first, then delete
            // this series' stored episodes absent from it.
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
                        cover: ep.info?.movieImage ?? ep.info?.cover,
                        duration: ep.info?.duration,
                        rating: ep.info?.rating,
                        seasonId: seasonId
                    )
                    fetchedEpisodeIds.insert(dbEp.id)
                    try dbEp.save(db)
                }
            }

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

            if var s = try DBSeries
                .filter(Column("seriesId") == series.seriesId && Column("playlistId") == playlist.id)
                .fetchOne(db) {
                s.seasonsLoaded = true
                try s.save(db)
            }
        }
    }
}

private struct EpisodePlaySession: Equatable {
    var url: URL
    var streamId: String
    var title: String
    var subtitle: String?
    var artworkURL: URL?
    var resumeTimeMs: Int?
    var containerExtension: String?

    init(episode: DBEpisode, url: URL, seriesName: String, seriesCover: String?, resumeTimeMs: Int?) {
        self.url = url
        streamId = episode.episodeId ?? episode.id
        title = {
            let num = episode.episodeNum.map { "\($0). " } ?? ""
            let raw = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let t = raw.isEmpty ? L("detail.episode_fallback") : raw
            return num + t
        }()
        subtitle = seriesName
        artworkURL = (episode.cover ?? seriesCover).flatMap { URL(string: $0) }
        self.resumeTimeMs = resumeTimeMs
        containerExtension = episode.containerExtension
    }
}
