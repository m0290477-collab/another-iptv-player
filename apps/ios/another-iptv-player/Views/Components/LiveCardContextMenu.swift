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
/// State (favorite / watch-history presence) is resolved when the
/// card appears (`.task` + `.onAppear`, so returning from the player
/// refreshes the facts) — one small DB read per visible card, the same
/// cost class as the existing per-card favorite lookups — never inside
/// `body` or the menu builder, which only read the resolved values.
/// The actions themselves re-resolve their fact fresh at tap time, so
/// a stale cached value can never make a tap throw or silently no-op.
struct LiveCardContextMenu: ViewModifier {
    let playlist: Playlist
    let stream: DBLiveStream
    let categoryId: String?
    let categoryName: String?

    @State private var isFavorite = false
    @State private var historyRowId: String?

    // MARK: - B2 (build 61) state: recording service + reorder sheet
    @ObservedObject private var recorder = LiveRecordingService.shared
    @State private var showReorderChannels = false

    func body(content: Content) -> some View {
        content
            .task(id: "\(playlist.id.uuidString)-\(stream.streamId)") {
                await resolveState()
            }
            .onAppear {
                // Re-resolve on every appearance: the card may have
                // stayed mounted while the favorite/history facts
                // changed elsewhere (e.g. inside the player).
                Task { await resolveState() }
            }
            // B2 (build 61, item 12): the channel reorder sheet for
            // this card's category.
            .sheet(isPresented: $showReorderChannels) {
                if let categoryId {
                    ReorderChannelsView(
                        playlist: playlist,
                        categoryId: categoryId,
                        categoryName: categoryName
                    )
                }
            }
            .contextMenu {
                Button {
                    toggleFavorite()
                } label: {
                    Label(isFavorite ? L("favorites.remove") : L("favorites.add"),
                          systemImage: isFavorite ? "star.slash" : "star")
                }

                if let categoryId, let categoryName, categoryId != "all", !categoryId.isEmpty {
                    Button {
                        HiddenCategoryStore.shared.setHidden(
                            true, playlistId: playlist.id, type: "live", categoryId: categoryId
                        )
                    } label: {
                        Label(L("live.card.hide_category", categoryName), systemImage: "eye.slash")
                    }
                }

                if historyRowId != nil {
                    Button(role: .destructive) {
                        removeFromContinueWatching()
                    } label: {
                        Label(L("continue_watching.remove"), systemImage: "xmark.circle")
                    }
                }

                // ────────────────────────────────────────────────
                // B2 (build 61) — recording / external player /
                // channel reorder. Delimited section: B8's menu
                // items live above; keep these additive.
                //
                // NOTE on the header comment: the "no Download
                // item" rule stands for file downloads — what
                // follows is RECORDING (item 2's DVR), a real-time
                // capture into Downloads, not a file download.
                Divider()

                if let activeId = recorder.activeRecordingId(playlistId: playlist.id, streamId: stream.streamId) {
                    Button {
                        recorder.stop(id: activeId)
                    } label: {
                        Label(L("record.stop"), systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        Task { await recorder.start(playlist: playlist, stream: stream) }
                    } label: {
                        Label(L("record.start"), systemImage: "record.circle")
                    }
                }

                if let liveURL = PlaybackURLBuilder(playlist: playlist).liveURL(streamId: stream.streamId) {
                    ExternalPlayerMenuItems(streamURL: liveURL)
                }

                if let categoryId, categoryId != "all", !categoryId.isEmpty {
                    Button {
                        showReorderChannels = true
                    } label: {
                        Label(L("reorder.title"), systemImage: "arrow.up.arrow.down")
                    }
                }
                // ────────────────────────────────────────────────
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
    /// performs for the in-player star. The CURRENT favorite state is
    /// read fresh at tap time and the insert/delete follows THAT
    /// value: inserting when the row already exists would throw
    /// against the (streamId, playlistId, type) composite primary key
    /// and make the tap visibly do nothing, and deleting when it is
    /// already gone must stay a harmless no-op.
    private func toggleFavorite() {
        let streamId = stream.streamId
        let playlistId = playlist.id
        Task {
            let fresh = try? await AppDatabase.shared.read { db in
                try DBFavorite
                    .filter(Column("streamId") == streamId
                        && Column("playlistId") == playlistId
                        && Column("type") == "live")
                    .fetchCount(db) > 0
            }
            // If the fresh read itself failed, fall back to the cached
            // value rather than guessing the opposite.
            let currentValue = fresh ?? isFavorite
            let nextValue = !currentValue
            isFavorite = nextValue
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
                isFavorite = currentValue
            }
        }
    }

    /// The same deletion `ContinueWatchingRow` performs for its
    /// long-press Remove: delete the backing watch-history row. The
    /// row is resolved at tap time by stream identity — not by the
    /// cached row id — so a row created or removed since the card
    /// appeared is handled correctly, and an already-gone row is a
    /// harmless no-op.
    private func removeFromContinueWatching() {
        historyRowId = nil
        let streamId = stream.streamId
        let playlistId = playlist.id
        Task {
            try? await AppDatabase.shared.write { db in
                try DBWatchHistory
                    .filter(Column("streamId") == String(streamId)
                        && Column("playlistId") == playlistId
                        && Column("type") == "live")
                    .deleteAll(db)
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
