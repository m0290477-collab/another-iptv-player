import SwiftUI
import GRDB
import GRDBQuery

/// Lists downloaded and downloading content. On completed items, tapping plays from the local file.
struct DownloadsView: View {
    let playlist: Playlist

    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @ObservedObject private var manager = DownloadManager.shared
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

    private var completedMovies: [DBDownloadedItem] {
        completed.filter { $0.type == "vod" }
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
            .map { (key, items) in
                let sorted = items.sorted { lhs, rhs in
                    let ls = lhs.seasonNumber ?? 0, rs = rhs.seasonNumber ?? 0
                    if ls != rs { return ls < rs }
                    return (lhs.episodeNumber ?? 0) < (rhs.episodeNumber ?? 0)
                }
                return (key, sorted)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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
                    // Round 14 (B3): total size + delete-watched.
                    Section {
                        HStack {
                            Text(L("download.storage_used"))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: totalDownloadsBytes, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        if !watchedDownloads.isEmpty {
                            Button(role: .destructive) {
                                showDeleteWatchedAlert = true
                            } label: {
                                Text(L("download.delete_watched"))
                            }
                        }
                    }

                    if !inProgress.isEmpty {
                        Section(L("download.status.downloading")) {
                            ForEach(inProgress) { item in
                                actionableRow(item)
                            }
                        }
                    }
                    if !queued.isEmpty {
                        Section(L("download.status.queued")) {
                            ForEach(queued) { item in
                                actionableRow(item)
                            }
                        }
                    }
                    if !failed.isEmpty {
                        Section(L("download.status.failed")) {
                            ForEach(failed) { item in
                                actionableRow(item)
                            }
                        }
                    }
                    if !completedMovies.isEmpty {
                        Section(L("dashboard.movies")) {
                            ForEach(completedMovies) { item in
                                actionableRow(item)
                            }
                        }
                    }

                    ForEach(completedEpisodeGroups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.episodes) { item in
                                actionableRow(item)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .cinematicScrollBackground()
            }
        }
        .navigationTitle(L("download.title"))
        .navigationBarTitleDisplayMode(.inline)
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
            isPresented: Binding(
                get: { missingFileItem != nil },
                set: { if !$0 { missingFileItem = nil } }
            ),
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
            isPresented: Binding(
                get: { cancelCandidate != nil },
                set: { if !$0 { cancelCandidate = nil } }
            ),
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

    /// Re-queues a record whose file is lost, with the same id (the same path as a failed retry).
    private func redownload(_ item: DBDownloadedItem) {
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

    /// Tek tap = birincil aksiyon (tekrar dene/oynat),
    /// trailing swipe = delete/cancel. This pattern is applied to all download statuses.
    @ViewBuilder
    private func actionableRow(_ item: DBDownloadedItem) -> some View {
        Button {
            performPrimaryAction(item)
        } label: {
            row(item)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            switch item.downloadStatus {
            case .downloading, .queued:
                Button(role: .destructive) {
                    manager.cancel(id: item.id)
                } label: {
                    Label(L("download.cancel"), systemImage: "xmark")
                }
            case .completed, .failed:
                Button(role: .destructive) {
                    Task { await manager.delete(id: item.id) }
                } label: {
                    Label(L("download.delete"), systemImage: "trash")
                }
            }
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

    @ViewBuilder
    private func row(_ item: DBDownloadedItem) -> some View {
        HStack(spacing: 12) {
            CachedImage(
                url: item.imageURL.flatMap { URL(string: $0) },
                width: 56, height: 56,
                iconName: item.type == "episode" ? "play.tv" : "film",
                loadProfile: .grid
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let sub = item.secondaryTitle, !sub.isEmpty {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                footer(for: item)
            }
            Spacer()
            primaryActionIcon(for: item)
        }
        .padding(.vertical, 2)
    }

    /// Visually signals the row's primary action (not tappable — the whole row is the button).
    @ViewBuilder
    private func primaryActionIcon(for item: DBDownloadedItem) -> some View {
        switch item.downloadStatus {
        case .downloading:
            ProgressView()
                .controlSize(.small)
        case .queued:
            Image(systemName: "clock")
                .font(.title2)
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.orange)
        case .completed:
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
        }
    }

    @ViewBuilder
    private func footer(for item: DBDownloadedItem) -> some View {
        switch item.downloadStatus {
        case .downloading:
            let p = manager.progress[item.id]
            let fraction = p?.fraction ?? 0
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text(L("download.downloading_format", Int(fraction * 100)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let p, p.totalBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: p.totalBytes, countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .queued:
            Text(L("download.status.queued"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .completed:
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.totalBytes), countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed:
            Text(item.errorMessage ?? L("common.unknown_error"))
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func play(_ item: DBDownloadedItem) {
        Task {
            guard let localURL = try? DownloadStorage.absoluteURL(forRelativePath: item.localPath),
                  FileManager.default.fileExists(atPath: localURL.path) else {
                // Silent swallowing: while the row looks "completed", nothing happening
                // feels frozen to the user. Offer an alert + a re-download path.
                await MainActor.run { missingFileItem = item }
                return
            }

            // If it is an episode it is stored in the DB as history.type "series"; if a movie, as "vod".
            let historyType = item.type == "episode" ? "series" : "vod"
            let existingHistory: DBWatchHistory? = try? await AppDatabase.shared.read { db in
                try DBWatchHistory
                    .filter(
                        Column("playlistId") == playlist.id
                        && Column("type") == historyType
                        && Column("streamId") == item.streamId
                    )
                    .fetchOne(db)
            }

            await MainActor.run {
                if item.type == "episode" {
                    // Belongs to a series — HistorySeriesPlayerShell handles both resume and the next/previous
                    // manages the transition to the episode (the ordering is the series' own episode order, not the download order).
                    let history = existingHistory ?? DBWatchHistory(
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
                    playerOverlay.present(skipDownloadCheck: true, playlistId: playlist.id) {
                        HistorySeriesPlayerShell(
                            playlist: playlist,
                            history: history,
                            url: localURL,
                            onNavigateToDetail: navigateToSeriesDetail
                        )
                    }
                } else {
                    // Movie — no prev/next, only local playback + resume.
                    playerOverlay.present(skipDownloadCheck: true, playlistId: playlist.id) {
                        PlayerView(
                            url: localURL,
                            title: item.title,
                            subtitle: item.secondaryTitle,
                            artworkURL: item.imageURL.flatMap { URL(string: $0) },
                            isLiveStream: false,
                            playlistId: playlist.id,
                            streamId: item.streamId,
                            type: "vod",
                            seriesId: item.seriesId,
                            resumeTimeMs: existingHistory?.lastTimeMs,
                            containerExtension: item.containerExtension,
                            onNavigateToDetail: navigateToMovieDetail
                        )
                    }
                }
            }
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
