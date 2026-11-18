import SwiftUI
import GRDBQuery

/// Build 61 (B8, C9): "Recent Channels" Home row COMPONENT.
///
/// Data API: the playlist's LIVE watch history, most-recent-first
/// (`RecentWatchHistoryRequest`, type "live"), deduped by channel —
/// history holds one row per channel for live, so the request order
/// IS the recency order. Channels that no longer exist in the loaded
/// catalog are skipped (a recent-channels row is a playback shortcut,
/// not a user list — R6's keep-and-mark rule applies to favorites /
/// watch-later / groups, not here).
///
/// Playback is handed to the parent via `onPlay` with the resolved
/// catalog stream; the parent presents it through its existing live
/// path. Home assembly is B7's wave-3 job.
struct RecentChannelsRow: View {
    let playlist: Playlist
    var onPlay: (DBLiveStream) -> Void

    @Query<RecentWatchHistoryRequest> private var historyItems: [DBWatchHistory]
    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @Environment(\.posterMetrics) private var posterMetrics

    init(playlist: Playlist, onPlay: @escaping (DBLiveStream) -> Void) {
        self.playlist = playlist
        self.onPlay = onPlay
        _historyItems = Query(
            RecentWatchHistoryRequest(playlistId: playlist.id, limit: 30, type: "live"),
            in: \.appDatabase
        )
    }

    private var displayStreams: [DBLiveStream] {
        var seen = Set<Int>()
        var result: [DBLiveStream] = []
        for item in historyItems {
            guard let streamId = Int(item.streamId), seen.insert(streamId).inserted else { continue }
            guard let match = contentStore.liveStreams.first(where: { $0.stream.streamId == streamId })?.stream
            else { continue }
            result.append(match)
            if result.count >= 15 { break }
        }
        return result
    }

    var body: some View {
        if !displayStreams.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CinematicSectionHeader(title: L("channels.recent.title")) {
                    WatchHistoryListView(playlist: playlist, typeFilter: "live") { item in
                        if let streamId = Int(item.streamId),
                           let match = contentStore.liveStreams.first(where: { $0.stream.streamId == streamId })?.stream {
                            onPlay(match)
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(displayStreams) { stream in
                            LiveStreamCard(
                                playlistId: playlist.id,
                                stream: stream,
                                width: posterMetrics.liveShelfLabelWidth,
                                iconSize: posterMetrics.liveShelfIcon,
                                imageLoadProfile: .shelf
                            ) { selected, _ in
                                onPlay(selected)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 6)
        }
    }
}
