import SwiftUI
import GRDB
import GRDBQuery

/// Build 61 (B8, C7): "Continue Series" Home row COMPONENT.
///
/// Data API: the row is fed by the SAME watch-history store as
/// Continue Watching (`RecentWatchHistoryRequest`, type "series").
/// One card per series (its latest episode record); the card's target
/// is the NEXT episode in chain order when the latest episode is
/// finished (≥98%), otherwise the in-progress episode itself at its
/// saved position. Next-episode resolution uses the existing
/// `SeriesPlaybackOrdering.navigationContext` — no new ordering logic.
///
/// Playback is NOT presented here: `onPlay` hands the parent the
/// history item to resume/advance from, and the parent routes it
/// through its existing history-playback path (exactly the
/// `ContinueWatchingRow` contract). Home assembly is B7's wave-3 job.
struct ContinueSeriesRow: View {
    let playlist: Playlist
    var onPlay: (DBWatchHistory) -> Void

    @Query<RecentWatchHistoryRequest> private var historyItems: [DBWatchHistory]
    @ObservedObject private var contentStore = PlaylistContentStore.shared
    /// seriesId → next episode label ("S02 E05"), resolved off the
    /// history change, never per body pass.
    @State private var nextLabels: [String: String] = [:]

    init(playlist: Playlist, onPlay: @escaping (DBWatchHistory) -> Void) {
        self.playlist = playlist
        self.onPlay = onPlay
        _historyItems = Query(
            RecentWatchHistoryRequest(playlistId: playlist.id, limit: 30, type: "series"),
            in: \.appDatabase
        )
    }

    /// One entry per series: the latest episode record, kept only
    /// when the series is genuinely continuable — in progress, or
    /// finished with a next episode available.
    private var displayItems: [DBWatchHistory] {
        var seen = Set<String>()
        var result: [DBWatchHistory] = []
        for item in historyItems {
            guard let seriesId = item.seriesId, !seriesId.isEmpty else { continue }
            guard seen.insert(seriesId).inserted else { continue }
            let finished = item.durationMs > 0
                && Double(item.lastTimeMs) / Double(item.durationMs) >= 0.98
            if finished && nextLabels[seriesId] == nil { continue }
            result.append(item)
            if result.count >= 10 { break }
        }
        return result
    }

    var body: some View {
        if !displayItems.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                CinematicSectionHeader(title: L("series.continue.title")) {
                    WatchHistoryListView(playlist: playlist, typeFilter: "series") { item in
                        onPlay(item)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(displayItems) { item in
                            HistoryCard(
                                item: item,
                                backdropURL: seriesBackdrop(for: item),
                                metaText: nextLabels[item.seriesId ?? ""].map { L("series.continue.next_format", $0) }
                            )
                            .onTapGesture { onPlay(item) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .padding(.vertical, 12)
            .task(id: historyItems.map(\.id).joined()) { await resolveNextLabels() }
        }
    }

    private func seriesBackdrop(for item: DBWatchHistory) -> URL? {
        guard let seriesId = item.seriesId,
              let record = contentStore.seriesItems.first(where: { "\($0.series.seriesId)" == seriesId })?.series,
              let raw = record.backdropPath?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        return ArtworkURL.url(from: raw)
    }

    /// For each series whose latest episode is finished, resolve the
    /// chain successor once; series still in progress need no label
    /// (their card resumes the current episode).
    private func resolveNextLabels() async {
        var seen = Set<String>()
        var targets: [(seriesId: String, streamId: String)] = []
        for item in historyItems {
            guard let seriesId = item.seriesId, !seriesId.isEmpty, seen.insert(seriesId).inserted else { continue }
            let finished = item.durationMs > 0
                && Double(item.lastTimeMs) / Double(item.durationMs) >= 0.98
            if finished { targets.append((seriesId, item.streamId)) }
        }
        guard !targets.isEmpty else { nextLabels = [:]; return }
        let pid = playlist.id
        let resolved = await Task.detached(priority: .utility) { () -> [String: String] in
            var labels: [String: String] = [:]
            for target in targets {
                let ctx = try? await AppDatabase.shared.read { db in
                    try SeriesPlaybackOrdering.navigationContext(
                        playlistId: pid,
                        playbackStreamId: target.streamId,
                        seriesIdHint: target.seriesId,
                        db: db
                    )
                }
                if let ctx, let next = ctx.next {
                    let season = ctx.nextSeasonNumber ?? next.seasonId.split(separator: "_").last.flatMap { Int($0) }
                    let episode = ctx.nextEpisodeNumber ?? next.episodeNum
                    if let season, let episode {
                        labels[target.seriesId] = String(format: "S%02d E%02d", season, episode)
                    } else if let episode {
                        labels[target.seriesId] = String(format: "E%02d", episode)
                    }
                }
            }
            return labels
        }.value
        guard !Task.isCancelled else { return }
        nextLabels = resolved
    }
}
