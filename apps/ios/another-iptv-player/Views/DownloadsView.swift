import SwiftUI
import GRDB
import GRDBQuery

/// Lists downloaded and downloading content. On completed items, tapping plays from the local file.
struct DownloadsView: View {
    let playlist: Playlist

    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @ObservedObject private var manager = DownloadManager.shared
    /// B2 (build 61, item 2): live recordings live in this list as
    /// `type == "recording"` rows; the service drives their elapsed
    /// time / size and stop+cancel.
    @ObservedObject private var recorder = LiveRecordingService.shared
    /// B2 (build 61, T4): the downloads storage cap (GB) enforced by
    /// `DownloadManager.storageCapBytes`.
    @AppStorage("download.storage_cap_gb") private var storageCapGB: Int = 20
    @Query<AllDownloadsRequest> private var items: [DBDownloadedItem]
    @State private var searchText: String = ""
    @State private var debouncedQuery: String = ""
    @State private var isSearchActive: Bool = false
    @State private var debounceTask: Task<Void, Never>?
    @State private var pendingMovieDetail: DBVODStream?
    @State private var pendingSeriesDetail: DBSeries?
    /// A record that looks "Completed" but whose file is not on disk (the typical case after a device restore
    /// — the Downloads folder is not included in the backup). Re-downloading is offered with an alert.
    @State private var missingFileItem: DBDownloadedItem?
    /// Round 8 (F-3): tapping a downloading/queued row used to hit a
    /// dead `break` — the row looked tappable and did nothing. The tap
    /// now offers the one real management action for an active
    /// download, cancel, behind this confirmation.
    @State private var cancelCandidate: DBDownloadedItem?
    /// Round 14 (B3): "type_streamId" keys of watch-history rows the
    /// user has FINISHED (≥98% — the app's one finished threshold),
    /// loaded from the DB; drives "Delete watched downloads".
    @State private var finishedHistoryKeys: Set<String> = []
    @State private var showDeleteWatchedAlert = false
    /// Build 61 fixer (X7, download half): the completed-set diff
    /// that drives the drawn-check moment. `knownCompletedIDs` is
    /// seeded from the rows already completed when this view appears
    /// (those never animate); a download that TRANSITIONS to
    /// completed while the view is open lands in `justCompletedIDs`,
    /// shows B7's shared `AnimatedCheckView` in place of the play
    /// icon for a beat, and fires the same light success haptic as
    /// the playlist-add half. Driven by the @Query items diff —
    /// event-based, no polling.
    @State private var knownCompletedIDs: Set<String> = []
    @State private var completedSeeded = false
    @State private var justCompletedIDs: Set<String> = []

    init(playlist: Playlist) {
        self.playlist = playlist
        _items = Query(AllDownloadsRequest(playlistId: playlist.id), in: \.appDatabase)
    }

    private var filteredItems: [DBDownloadedItem] {
        let q = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { item in
            CatalogTextSearch.matches(search: q, text: item.title)
                || CatalogTextSearch.matches(search: q, text: item.secondaryTitle ?? "")
        }
    }

    private var inProgress: [DBDownloadedItem] { filteredItems.filter { $0.downloadStatus == .downloading } }
    /// The queue is shown in ascending `createdAt` order — the next (oldest) is at the top.
    /// `AllDownloadsRequest` returns desc by default; here we deliberately reverse it.
    private var queued: [DBDownloadedItem] {
        filteredItems
            .filter { $0.downloadStatus == .queued }
            .sorted { $0.createdAt < $1.createdAt }
    }
    private var completed: [DBDownloadedItem] { filteredItems.filter { $0.downloadStatus == .completed } }
    private var failed: [DBDownloadedItem] { filteredItems.filter { $0.downloadStatus == .failed } }

    /// Build 61 fix round 2: the completed rows' ids as a
    /// standalone, explicitly-typed expression. Inline in the
    /// body chain (the X7 `.onAppear` seed and the `.onChange`
    /// diff below) this filter+map chain timed out the type
    /// checker; as its own property it is trivially checkable
    /// and both call sites observe the identical value.
    private var completedItemIDs: [String] {
        items
            .filter { (item: DBDownloadedItem) in item.downloadStatus == .completed }
            .map(\.id)
    }

    private var completedMovies: [DBDownloadedItem] {
        completed.filter { $0.type == "vod" }
    }

    /// B2 (build 61, item 2): finished live recordings.
    private var completedRecordings: [DBDownloadedItem] {
        completed.filter { $0.type == "recording" }
    }

    /// Round 14 (B3): total size of everything in this playlist's
    /// downloads — completed items at their full size, in-progress
    /// ones at the bytes actually on disk so far.
    private var totalDownloadsBytes: Int64 {
        items.reduce(Int64(0)) { sum, item in
            sum + (item.downloadStatus == .completed ? Int64(item.totalBytes) : Int64(item.downloadedBytes))
        }
    }

    /// Round 14 (B3): completed downloads whose watch-history row is
    /// finished (≥98%). History type is "vod" for movies and
    /// "series" for episodes (the same mapping `play(_:)` uses).
    private var watchedDownloads: [DBDownloadedItem] {
        completed.filter { item in
            let historyType = item.type == "episode" ? "series" : "vod"
            return finishedHistoryKeys.contains("\(historyType)_\(item.streamId)")
        }
    }

    /// Groups completed episodes by series. The key is the seriesId + secondaryTitle pair,
    /// so that when seriesId is nil we can group by name.
    private var completedEpisodeGroups: [(title: String, episodes: [DBDownloadedItem])] {
        let episodes = completed.filter { $0.type == "episode" }
        let grouped = Dictionary(grouping: episodes) { $0.secondaryTitle ?? $0.seriesId ?? "-" }
        return grouped
            .map { (key: String, items: [DBDownloadedItem]) in
                let sorted = items.sorted { lhs, rhs in
                    let ls = lhs.seasonNumber ?? 0, rs = rhs.seasonNumber ?? 0
                    if ls != rs { return ls < rs }
                    return (lhs.episodeNumber ?? 0) < (rhs.episodeNumber ?? 0)
                }
                return (key, sorted)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Build 61 fix round 2: the two item-driven alert
    /// presentations as standalone, explicitly-typed bindings.
    /// Inline `Binding(get:set:)` constructions inside the body
    /// modifier chain are solver-heavy; the presentation logic
    /// (presented iff the item is non-nil, dismissal clears it)
    /// is unchanged.
    private var missingFileAlertBinding: Binding<Bool> {
        Binding(
            get: { missingFileItem != nil },
            set: { if !$0 { missingFileItem = nil } }
        )
    }

    private var cancelAlertBinding: Binding<Bool> {
        Binding(
            get: { cancelCandidate != nil },
            set: { if !$0 { cancelCandidate = nil } }
        )
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    L("download.empty.title"),
                    systemImage: "arrow.down.circle",
                    description: Text(L("download.empty.message"))
                )
            } else if filteredItems.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    // Build 65 (Storage Dashboard): ring header
                    // with the real on-disk total, cap and free
                    // space — above the existing management
                    // sections, which are unchanged.
                    DownloadsDashboardSection(
                        usedBytes: StorageService.downloadsSizeBytes(),
                        capGB: storageCapGB,
                        freeBytes: DownloadStorage.availableCapacityBytes(),
                        itemCount: items.count
                    )
                    DownloadsHeaderSections(
                        manager: manager,
                        storageCapGB: $storageCapGB,
                        totalDownloadsBytes: totalDownloadsBytes,
                        watchedDownloads: watchedDownloads,
                        showDeleteWatchedAlert: $showDeleteWatchedAlert,
                        inProgress: inProgress,
                        queued: queued
                    )
                    DownloadsTransferSections(
                        inProgress: inProgress,
                        queued: queued,
                        failed: failed,
                        manager: manager,
                        recorder: recorder,
                        justCompletedIDs: justCompletedIDs,
                        onPrimaryAction: performPrimaryAction
                    )
                    DownloadsCompletedSections(
                        completedMovies: completedMovies,
                        completedRecordings: completedRecordings,
                        completedEpisodeGroups: completedEpisodeGroups,
                        manager: manager,
                        justCompletedIDs: justCompletedIDs,
                        onPrimaryAction: performPrimaryAction
                    )
                }
                .listStyle(.insetGrouped)
                .cinematicScrollBackground()
            }
        }
        .navigationTitle(L("download.title"))
        .navigationBarTitleDisplayMode(.inline)
        // Z9: Edit mode enables the queued section's drag handles.
        // Only offered when there is a queue worth reordering.
        .toolbar {
            if queued.count > 1 {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
            }
        }
        .searchable(text: $searchText, isPresented: $isSearchActive, prompt: L("download.search_placeholder"))
        .onChange(of: searchText) { _, new in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { debouncedQuery = new }
            }
        }
        .onChange(of: isSearchActive) { _, active in
            if !active { searchText = ""; debouncedQuery = "" }
        }
        .navigationDestination(item: $pendingMovieDetail) { movie in
            MovieDetailView(playlist: playlist, movie: movie)
        }
        .navigationDestination(item: $pendingSeriesDetail) { series in
            SeriesDetailView(playlist: playlist, series: series)
        }
        .alert(
            L("download.missing_file.title"),
            isPresented: missingFileAlertBinding,
            presenting: missingFileItem
        ) { item in
            Button(L("download.retry")) {
                redownload(item)
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(L("download.missing_file.message"))
        }
        .alert(
            L("download.cancel.title"),
            isPresented: cancelAlertBinding,
            presenting: cancelCandidate
        ) { item in
            Button(L("download.cancel"), role: .destructive) {
                manager.cancel(id: item.id)
            }
            Button(L("download.keep"), role: .cancel) {}
        } message: { _ in
            Text(L("download.cancel.message"))
        }
        .alert(L("download.delete_watched"), isPresented: $showDeleteWatchedAlert) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("common.confirm_delete_yes"), role: .destructive) {
                Task {
                    for item in watchedDownloads {
                        await manager.delete(id: item.id)
                    }
                }
            }
        } message: {
            Text(L("download.delete_watched.message"))
        }
        .task {
            await loadFinishedHistory()
        }
        // Round 15 (C12): the download-complete UI sound for this
        // surface — fires when the completed count grows.
        .onChange(of: completed.count) { oldCount, newCount in
            if newCount > oldCount {
                AppSound.play(.downloadComplete)
            }
        }
        // Build 61 fixer (X7, download half): seed the completed set
        // on first appearance, then diff it — only NEW completions
        // (transitions observed while this view is open) get the
        // drawn check + haptic; rows already completed at open never
        // animate.
        .onAppear {
            guard !completedSeeded else { return }
            completedSeeded = true
            knownCompletedIDs = Set(completedItemIDs)
        }
        // The diff runs over the UNFILTERED completed set, so a
        // search-filter change can never masquerade as a completion.
        .onChange(of: completedItemIDs) { _, newIDs in
            guard completedSeeded else { return }
            let newSet = Set(newIDs)
            let fresh = newSet.subtracting(knownCompletedIDs)
            knownCompletedIDs = newSet
            guard !fresh.isEmpty else { return }
            justCompletedIDs.formUnion(fresh)
            Haptics.success()
            Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                justCompletedIDs.subtract(fresh)
            }
        }
        .onChange(of: manager.dbVersion) { _, _ in
            Task { await loadFinishedHistory() }
        }
    }

    /// Loads the finished (≥98%) watch-history keys for this
    /// playlist — the data "Delete watched downloads" matches on.
    private func loadFinishedHistory() async {
        let pid = playlist.id
        let keys: Set<String> = (try? await AppDatabase.shared.read { db in
            let rows = try DBWatchHistory
                .filter(Column("playlistId") == pid)
                .fetchAll(db)
            var finished: Set<String> = []
            for row in rows where row.durationMs > 0 && row.lastTimeMs * 100 >= row.durationMs * 98 {
                finished.insert("\(row.type)_\(row.streamId)")
            }
            return finished
        }) ?? []
        await MainActor.run { finishedHistoryKeys = keys }
    }

    /// B2: retry for a recording row — deletes the failed row and
    /// starts a fresh recording of the same channel (looked up in
    /// the live catalog; if the channel is gone, nothing happens).
    private func restartRecording(_ item: DBDownloadedItem) {
        guard let streamId = Int(item.streamId) else { return }
        let pid = playlist.id
        Task {
            let stream: DBLiveStream? = try? await AppDatabase.shared.read { db in
                try DBLiveStream
                    .filter(Column("streamId") == streamId && Column("playlistId") == pid)
                    .fetchOne(db)
            }
            guard let stream else { return }
            await manager.delete(id: item.id)
            await recorder.start(playlist: playlist, stream: stream)
        }
    }

    /// Re-queues a record whose file is lost, with the same id (the same path as a failed retry).
    private func redownload(_ item: DBDownloadedItem) {
        // B2: a recording has no file to re-download — retry means
        // recording the channel again.
        if item.type == "recording" {
            restartRecording(item)
            return
        }
        guard let url = URL(string: item.remoteURL) else { return }
        Task {
            await manager.enqueue(
                id: item.id,
                playlistId: item.playlistId,
                streamId: item.streamId,
                type: item.type,
                title: item.title,
                secondaryTitle: item.secondaryTitle,
                imageURL: item.imageURL,
                remoteURL: url,
                containerExtension: item.containerExtension,
                seriesId: item.seriesId,
                seasonNumber: item.seasonNumber,
                episodeNumber: item.episodeNumber
            )
        }
    }

    private func performPrimaryAction(_ item: DBDownloadedItem) {
        switch item.downloadStatus {
        case .downloading, .queued:
            // Round 8 (F-3): was a dead `break`. The manager has no
            // pause/resume, so the tap's real action is cancel —
            // confirmed via the alert above (same manager call the
            // swipe action and context menu already used).
            cancelCandidate = item
        case .failed:
            // B2: a failed RECORDING retries by starting a fresh
            // recording of the channel — never by enqueueing the
            // live URL as a file download.
            if item.type == "recording" {
                restartRecording(item)
                return
            }
            // Retry: just re-enqueue with the same id. The manager already overwrites the failed row.
            guard let url = URL(string: item.remoteURL) else { return }
            Task {
                await manager.enqueue(
                    id: item.id,
                    playlistId: item.playlistId,
                    streamId: item.streamId,
                    type: item.type,
                    title: item.title,
                    secondaryTitle: item.secondaryTitle,
                    imageURL: item.imageURL,
                    remoteURL: url,
                    containerExtension: item.containerExtension,
                    seriesId: item.seriesId,
                    seasonNumber: item.seasonNumber,
                    episodeNumber: item.episodeNumber
                )
            }
        case .completed:
            play(item)
        }
    }

    private func play(_ item: DBDownloadedItem) {
        // Explicit type: the bare `Task {` here is ambiguous against
        // `Task.init(name:priority:operation:)` in the current SDK.
        let _: Task<Void, Never> = Task {
            guard let localURL = try? DownloadStorage.absoluteURL(forRelativePath: item.localPath),
                  FileManager.default.fileExists(atPath: localURL.path) else {
                // Silent swallowing: while the row looks "completed", nothing happening
                // feels frozen to the user. Offer an alert + a re-download path.
                await MainActor.run { missingFileItem = item }
                return
            }

            // If it is an episode it is stored in the DB as history.type "series"; if a movie, as "vod".
            // A recording plays through the same file-playback path as a movie (type "vod").
            let historyType = item.type == "episode" ? "series" : "vod"
            let existingHistory = await fetchWatchHistory(for: item, historyType: historyType)

            await MainActor.run {
                if item.type == "episode" {
                    presentEpisodePlayback(item: item, localURL: localURL, existingHistory: existingHistory)
                } else {
                    presentMoviePlayback(item: item, localURL: localURL, existingHistory: existingHistory)
                }
            }
        }
    }

    /// Build 61 fix round 2: the watch-history lookup as its own
    /// explicitly-typed step. Inside the `play(_:)` Task closure,
    /// this GRDB filter chain plus the two player presentations
    /// overloaded the type checker ("failed to produce diagnostic
    /// for expression" at the `Task {`). Each step is now its own
    /// declaration and trivially checkable; the query, the values
    /// it binds and the constructed views are unchanged.
    private func fetchWatchHistory(for item: DBDownloadedItem, historyType: String) async -> DBWatchHistory? {
        let playlistId = playlist.id
        let streamId = item.streamId
        let history: DBWatchHistory? = try? await AppDatabase.shared.read { db in
            try DBWatchHistory
                .filter(
                    Column("playlistId") == playlistId
                    && Column("type") == historyType
                    && Column("streamId") == streamId
                )
                .fetchOne(db)
        }
        return history
    }

    /// Build 61 fix round 3: the presentation itself now lives in
    /// DownloadsPlayback.swift (DownloadsEpisodePresentation).
    private func presentEpisodePlayback(item: DBDownloadedItem, localURL: URL, existingHistory: DBWatchHistory?) {
        playerOverlay.present(skipDownloadCheck: true, playlistId: playlist.id) {
            DownloadsEpisodePresentation(
                playlist: playlist,
                item: item,
                localURL: localURL,
                existingHistory: existingHistory,
                onNavigateToDetail: navigateToSeriesDetail
            )
        }
    }

    /// Build 61 fix round 3: the presentation itself now lives in
    /// DownloadsPlayback.swift (DownloadsMoviePresentation).
    private func presentMoviePlayback(item: DBDownloadedItem, localURL: URL, existingHistory: DBWatchHistory?) {
        playerOverlay.present(skipDownloadCheck: true, playlistId: playlist.id) {
            DownloadsMoviePresentation(
                playlist: playlist,
                item: item,
                localURL: localURL,
                existingHistory: existingHistory,
                onNavigateToDetail: navigateToMovieDetail
            )
        }
    }

    /// When the title is tapped in the player, go to the movie detail.
    private func navigateToMovieDetail(type: String, id: String) {
        guard type == "vod", let vId = Int(id) else { return }
        Task {
            guard let movie = try? await AppDatabase.shared.read({ db in
                try DBVODStream
                    .filter(Column("streamId") == vId && Column("playlistId") == playlist.id)
                    .fetchOne(db)
            }) else { return }
            await MainActor.run {
                playerOverlay.dismiss()
                pendingMovieDetail = movie
            }
        }
    }

    /// When the title is tapped in the player, go to the series detail.
    private func navigateToSeriesDetail(type: String, id: String) {
        guard let sId = Int(id) else { return }
        Task {
            guard let series = try? await AppDatabase.shared.read({ db in
                try DBSeries
                    .filter(Column("seriesId") == sId && Column("playlistId") == playlist.id)
                    .fetchOne(db)
            }) else { return }
            await MainActor.run {
                playerOverlay.dismiss()
                pendingSeriesDetail = series
            }
        }
    }
}
