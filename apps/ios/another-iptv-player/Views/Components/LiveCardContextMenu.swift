import SwiftUI
import GRDB

/// F-32/F-76: long-press context menu for Xtream Live channel cards
/// (`LiveStreamCard`), attached at the card call sites. Mirrors the
/// M3U card menu's shape (`M3UChannelCard`): Favorite toggle, Hide
/// category, and Remove from Continue Watching — each shown only when
/// it applies to this card.
///
/// There is deliberately NO Download item: a live Xtream stream is a
/// broadcast, not a single file — the same gate the M3U side applies
/// (`M3UDownloadClassifier` marks live `.notDownloadable`, and every
/// `DownloadManager.enqueue` call site is movie/episode only). Adding
/// the row would be a fake action.
///
/// State (favorite / watch-history presence) is resolved ONCE when the
/// card appears — one small DB read per visible card, the same cost
/// class as the existing per-card favorite lookups — never inside
/// `body` or the menu builder, which only read the resolved values.
struct LiveCardContextMenu: ViewModifier {
    let playlist: Playlist
    let stream: DBLiveStream
    let categoryId: String?
    let categoryName: String?

    @State private var isFavorite = false
    @State private var historyRowId: String?

    func body(content: Content) -> some View {
        content
            .task(id: "\(playlist.id.uuidString)-\(stream.streamId)") {
                await resolveState()
            }
            .contextMenu {
                Button {
                    toggleFavorite()
                } label: {
                    Label(isFavorite ? L("favorites.remove") : L("favorites.add"),
                          systemImage: isFavorite ? "star.slash" : "star")
                }

                if let categoryId, let categoryName, categoryId != "all" {
                    Button {
                        HiddenCategoryStore.shared.setHidden(
                            true, playlistId: playlist.id, type: "live", categoryId: categoryId
                        )
                    } label: {
                        Label(L("live.card.hide_category", categoryName), systemImage: "eye.slash")
                    }
                }

                if let historyRowId {
                    Button(role: .destructive) {
                        removeFromContinueWatching(id: historyRowId)
                    } label: {
                        Label(L("continue_watching.remove"), systemImage: "xmark.circle")
                    }
                }
            }
    }

    /// One read for both menu facts: the DBFavorite row and the live
    /// watch-history row backing Continue Watching for this channel.
    private func resolveState() async {
        let streamId = stream.streamId
        let playlistId = playlist.id
        let result = try? await AppDatabase.shared.read { db -> (favorite: Bool, historyId: String?) in
            let favorite = try DBFavorite
                .filter(Column("streamId") == streamId
                    && Column("playlistId") == playlistId
                    && Column("type") == "live")
                .fetchCount(db) > 0
            let historyId = try DBWatchHistory
                .filter(Column("streamId") == String(streamId)
                    && Column("playlistId") == playlistId
                    && Column("type") == "live")
                .fetchOne(db)?.id
            return (favorite, historyId)
        }
        guard !Task.isCancelled else { return }
        isFavorite = result?.favorite ?? false
        historyRowId = result?.historyId
    }

    /// The same DBFavorite write `LivePlayerShell.toggleFavorite`
    /// performs for the in-player star.
    private func toggleFavorite() {
        let streamId = stream.streamId
        let playlistId = playlist.id
        let nextValue = !isFavorite
        isFavorite = nextValue
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    if nextValue {
                        try DBFavorite(
                            streamId: streamId, playlistId: playlistId, type: "live"
                        ).insert(db)
                    } else {
                        try DBFavorite
                            .filter(Column("streamId") == streamId
                                && Column("playlistId") == playlistId
                                && Column("type") == "live")
                            .deleteAll(db)
                    }
                }
            } catch {
                isFavorite = !nextValue
            }
        }
    }

    /// The same deletion `ContinueWatchingRow` performs for its
    /// long-press Remove: delete the backing watch-history row.
    private func removeFromContinueWatching(id: String) {
        historyRowId = nil
        Task {
            try? await AppDatabase.shared.write { db in
                try DBWatchHistory.filter(Column("id") == id).deleteAll(db)
            }
        }
    }
}

extension View {
    /// Attaches the F-32 Live channel card context menu. `categoryId` /
    /// `categoryName` drive the Hide-category item; pass nil where the
    /// card's category is unknown.
    func liveCardContextMenu(
        playlist: Playlist,
        stream: DBLiveStream,
        categoryId: String?,
        categoryName: String?
    ) -> some View {
        modifier(LiveCardContextMenu(
            playlist: playlist,
            stream: stream,
            categoryId: categoryId,
            categoryName: categoryName
        ))
    }
}
