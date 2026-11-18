import Foundation
import GRDB
import Combine
import Network
import os.log

private let downloadLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "Downloads")

/// In-memory representation of download progress — we don't write it to the DB because the UI changes frequently.
struct DownloadProgress: Equatable {
    let totalBytes: Int64
    let downloadedBytes: Int64
    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }
}

/// Serial queue: only 1 download runs at a time. The rest wait with the `.queued` DB status.
/// Sorted by `createdAt`; when one finishes, the next starts automatically. When the app is
/// reopened, half-finished downloads are taken back to the head of the queue and resumed one by one.
///
/// Uses `URLSessionConfiguration.background` for background downloads; even if the OS
/// terminates the app, iOS continues the download and, when it finishes, wakes the app and calls the delegate.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "app") + ".downloads"
    /// Fallback concurrency when the provider's real `max_connections`
    /// is unknown (M3U, or the verify probe failed). C10 (Round 15):
    /// the live limit is derived per playlist from the provider's own
    /// `max_connections` (see `concurrencyLimit(for:)`), capped at 3.
    static let fallbackConcurrentPerPlaylist = 1
    /// C10: hard cap for the provider-derived concurrency.
    static let maxConcurrentCap = 3
    /// How many times a failed download is automatically re-added to the end of the queue. Once exceeded, `.failed`.
    private static let maxAutoRetries = 3
    /// Safety margin to leave before the disk fills — for the system and other apps.
    private static let minFreeDiskMargin: Int64 = 200 * 1024 * 1024

    /// The progress of active downloads, for views to observe.
    @Published private(set) var progress: [String: DownloadProgress] = [:]
    /// A counter incremented after DB writes — the refresh trigger for views outside GRDBQuery.
    @Published private(set) var dbVersion: Int = 0
    /// B2 (build 61, T4): true while Wi-Fi-only is ON, the current
    /// path is cellular-only, and downloads are waiting — shown as a
    /// state banner in DownloadsView so the pause is visible, never
    /// a silent stall.
    @Published private(set) var isWaitingForWifi: Bool = false

    /// Bumps `dbVersion` for services that write download rows
    /// outside the manager (LiveRecordingService) so observing views
    /// refresh.
    func bumpDBVersion() { dbVersion &+= 1 }

    // MARK: - B2 (build 61, T4) storage cap

    /// The user's downloads storage cap in bytes. The picker in
    /// DownloadsView writes `download.storage_cap_gb` (2/5/10/20);
    /// unset = the largest option (20 GB), so the cap only ever
    /// blocks at a limit the UI displays.
    static var storageCapBytes: Int64 {
        let gb = UserDefaults.standard.integer(forKey: "download.storage_cap_gb")
        let effective = [2, 5, 10, 20].contains(gb) ? gb : 20
        return Int64(effective) * 1024 * 1024 * 1024
    }

    private var session: URLSession!
    /// URLSessionTask.taskIdentifier → downloadedItem.id map.
    private var taskToId: [Int: String] = [:]
    /// downloadedItem.id → URLSessionDownloadTask (for cancellation).
    private var idToTask: [String: URLSessionDownloadTask] = [:]
    /// downloadedItem.id → playlistId; for per-playlist slot counting.
    private var idToPlaylistId: [String: UUID] = [:]
    /// URLSessionTask.taskIdentifier → target relative path (so the delegate does not do a DB lookup).
    private var taskToRelativePath: [Int: String] = [:]
    /// An in-memory guard so a second call for the same id doesn't arrive while `enqueue` performs an async DB write.
    private var enqueueInFlight: Set<String> = []
    /// didWriteData fires many times for the same task; we write totalBytes to the DB only on the first real value.
    private var totalBytesPersistedFor: Set<Int> = []
    /// The last published percentage (taskIdentifier → 0…100). didWriteData fires dozens of times per second;
    /// writing to @Published progress every time re-renders all DownloadButtons and
    /// DownloadsView. Nothing is published unless the percentage changed.
    private var lastPublishedPercent: [Int: Int] = [:]
    /// In-memory retry counter for downloads that errored.
    private var autoRetryCountById: [String: Int] = [:]
    /// Downloads we cancelled because disk space ran out: in the delegate's cancelled
    /// branch they are marked permanently failed instead of being requeued.
    private var spaceFailedIds: Set<String> = []
    /// B2 (build 61, T4): downloads we cancelled because the known
    /// total size would exceed the user's storage cap: permanently
    /// failed with the cap notice in the cancelled branch, like
    /// `spaceFailedIds`.
    private var capFailedIds: Set<String> = []
    /// S1 (Round 14): downloads the server refused (HTTP error status or an HTML
    /// error page): permanently failed instead of requeued in the cancelled branch.
    private var serverRefusedIds: Set<String> = []
    /// Whether the HTTP response was inspected once per task (for the early cut in didWriteData).
    private var responseValidatedFor: Set<Int> = []
    /// So `pumpQueue` runs only once at a time — parallel calls set `pumpPending`.
    private var pumpInFlight = false
    /// If another pump was triggered while a pump is running, it loops once more before the current pump ends.
    private var pumpPending = false
    /// The background completion handler given by AppDelegate; fired when it calls `urlSessionDidFinishEvents`.
    var backgroundCompletionHandler: (() -> Void)?

    // MARK: C2-wifi-resume + C10 state
    /// C2-wifi-resume: live network-path monitor. The resume-data path
    /// (`downloadTask(withResumeData:)`) cannot carry
    /// `allowsCellularAccess`, so Wi-Fi-only must be enforced BEFORE a
    /// resume task is created: while the path is cellular-only, resume
    /// attempts are deferred (row stays queued, resume blob kept) and
    /// the queue is re-pumped when the path gains Wi-Fi.
    private let pathMonitor = NWPathMonitor()
    private var pathMonitorStarted = false
    /// Ids currently deferred by the Wi-Fi-only resume gate.
    private var wifiDeferredIds: Set<String> = []
    /// C10: provider `max_connections` per playlist, probed once per
    /// session from the real verify response; absent = fallback 1.
    private var providerMaxConnections: [UUID: Int] = [:]
    private var providerMaxConnectionsProbed: Set<UUID> = []

    override private init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        startPathMonitor()
        Task { await restoreOutstandingTasks() }
    }

    /// C2-wifi-resume + B2/T4: watches the network path. When a
    /// Wi-Fi path appears, deferred downloads are released into the
    /// queue pump. On every change the published Wi-Fi-waiting state
    /// is recomputed so DownloadsView can show WHY downloads are
    /// paused on cellular (Wi-Fi-only ON) instead of stalling
    /// silently.
    private func startPathMonitor() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let hasWifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if hasWifi, !self.wifiDeferredIds.isEmpty {
                    self.wifiDeferredIds.removeAll()
                    await self.pumpQueue()
                }
                await self.refreshWifiWaitingState()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "superx.downloads.path-monitor"))
    }

    /// B2 (build 61, T4): recomputes `isWaitingForWifi` from the
    /// live facts — Wi-Fi-only setting, cellular-only path, and
    /// something actually waiting (a deferred id or a queued /
    /// downloading row).
    private func refreshWifiWaitingState() async {
        guard Self.wifiOnly, isCellularOnlyPath else {
            if isWaitingForWifi { isWaitingForWifi = false }
            return
        }
        if !wifiDeferredIds.isEmpty {
            isWaitingForWifi = true
            return
        }
        let waitingCount: Int = (try? await AppDatabase.shared.read { db in
            try DBDownloadedItem
                .filter([DownloadStatus.queued.rawValue, DownloadStatus.downloading.rawValue].contains(Column("status")))
                .filter(Column("type") != "recording")
                .fetchCount(db)
        }) ?? 0
        isWaitingForWifi = waitingCount > 0
    }

    /// True when the current path is cellular WITHOUT Wi-Fi/Ethernet —
    /// the only state the Wi-Fi-only resume gate blocks on. Unknown /
    /// satisfied non-cellular paths are not blocked.
    private var isCellularOnlyPath: Bool {
        let path = pathMonitor.currentPath
        guard path.status == .satisfied else { return false }
        return path.usesInterfaceType(.cellular)
            && !path.usesInterfaceType(.wifi)
            && !path.usesInterfaceType(.wiredEthernet)
    }

    // MARK: - App lifecycle

    /// On app launch: if there is still a live task in the background session, match it; otherwise convert records
    /// left as "downloading" in the DB back to `.queued` (createdAt is preserved →
    /// the queue order is not lost). Then run the queue.
    private func restoreOutstandingTasks() async {
        let allDownloadingRows: [DBDownloadedItem] = (try? await AppDatabase.shared.read { db in
            try DBDownloadedItem
                .filter(Column("status") == DownloadStatus.downloading.rawValue)
                .fetchAll(db)
        }) ?? []

        // B2 (build 61, item 2): rows left "downloading" by a live
        // recording are NOT URLSession downloads — a recording cannot
        // survive an app kill and must never be re-queued as a file
        // download. Finalize them from what is actually on disk: a
        // partial file with content becomes a completed recording;
        // an empty/missing one is marked interrupted.
        let recordingRows = allDownloadingRows.filter { $0.type == "recording" }
        if !recordingRows.isEmpty {
            _ = try? await AppDatabase.shared.write { db in
                for var row in recordingRows {
                    var size: Int64 = 0
                    if let url = try? DownloadStorage.absoluteURL(forRelativePath: row.localPath),
                       let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                        size = (attrs[.size] as? Int64) ?? 0
                    }
                    if size > 0 {
                        row.status = DownloadStatus.completed.rawValue
                        row.totalBytes = Int(size)
                        row.downloadedBytes = Int(size)
                        row.completedAt = Date()
                        row.errorMessage = nil
                    } else {
                        row.status = DownloadStatus.failed.rawValue
                        row.errorMessage = L("record.interrupted")
                        DownloadStorage.removeFile(relativePath: row.localPath)
                    }
                    try row.update(db)
                }
            }
            dbVersion &+= 1
        }
        let downloadingRows = allDownloadingRows.filter { $0.type != "recording" }

        var matchedIds: Set<String> = []
        if !downloadingRows.isEmpty {
            let tasks = await session.allTasks
            for task in tasks {
                // C2 (Round 15): background-task restore matches by
                // URL + PLAYLIST, not URL alone — the same provider URL
                // can exist under two playlists. Tasks created by
                // `startTask` carry their download id in
                // `taskDescription`, and the id embeds the playlistId
                // (`vod.<playlistId>.…`), so an exact id match IS a
                // URL+playlist match; the URL is still verified against
                // the row. Legacy tasks without a description fall back
                // to URL-only matching (unchanged old behavior).
                guard let url = task.originalRequest?.url?.absoluteString,
                      let match = downloadingRows.first(where: { row in
                          if let describedId = task.taskDescription, !describedId.isEmpty {
                              return row.id == describedId && row.remoteURL == url
                          }
                          return row.remoteURL == url
                      }),
                      let downloadTask = task as? URLSessionDownloadTask else {
                    continue
                }
                taskToId[downloadTask.taskIdentifier] = match.id
                taskToRelativePath[downloadTask.taskIdentifier] = match.localPath
                idToTask[match.id] = downloadTask
                idToPlaylistId[match.id] = match.playlistId
                progress[match.id] = DownloadProgress(
                    totalBytes: Int64(match.totalBytes),
                    downloadedBytes: Int64(match.downloadedBytes)
                )
                matchedIds.insert(match.id)
            }
        }

        // After a force-kill / OS termination, iOS may have dropped the background task too.
        // The DB says "downloading" but there is no counterpart in the session → take it back into the queue so it continues in order.
        // createdAt is NOT CHANGED, so the user's original order is preserved.
        let orphans = downloadingRows.filter { !matchedIds.contains($0.id) }
        if !orphans.isEmpty {
            _ = try? await AppDatabase.shared.write { db in
                for orphan in orphans {
                    if var row = try DBDownloadedItem.filter(Column("id") == orphan.id).fetchOne(db) {
                        row.status = DownloadStatus.queued.rawValue
                        row.errorMessage = nil
                        // Keep byte counters when resume data exists — the restart will
                        // continue from the downloaded prefix, not from zero.
                        if !DownloadStorage.hasResumeData(forId: orphan.id) {
                            row.totalBytes = 0
                            row.downloadedBytes = 0
                        }
                        try row.update(db)
                    }
                }
            }
            for orphan in orphans {
                downloadLog.info("restore orphan id=\(orphan.id, privacy: .public) — DB downloading, task yok; kuyruğa geri alındı")
            }
            dbVersion &+= 1
        }

        await sweepOrphanedDownloadFiles()
        await verifyCompletedDownloads()
        await pumpQueue()
    }

    /// B2 (build 61, Q16): integrity verification of completed
    /// downloads, run once per launch. A completed row is checked
    /// against its file: the file must exist, be non-empty, not be
    /// an HTML error page, and not be SHORTER than the size recorded
    /// at completion (truncated). A file that fails is removed and
    /// its row is marked failed with a plain "damaged — removed"
    /// message, so the cleanup is USER-VISIBLE in DownloadsView and
    /// the item can be re-downloaded — never a silent deletion.
    /// A file LARGER than recorded is never deleted: the recorded
    /// size is healed to the real one (the file may be perfectly
    /// playable; only provably-broken files are removed).
    private func verifyCompletedDownloads() async {
        let rows: [DBDownloadedItem] = (try? await AppDatabase.shared.read { db in
            try DBDownloadedItem
                .filter(Column("status") == DownloadStatus.completed.rawValue)
                .fetchAll(db)
        }) ?? []
        guard !rows.isEmpty else { return }
        let fm = FileManager.default
        for row in rows {
            guard let url = try? DownloadStorage.absoluteURL(forRelativePath: row.localPath) else { continue }
            let exists = fm.fileExists(atPath: url.path)
            let size: Int64 = exists
                ? ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0)
                : 0
            let isCorrupt = !exists
                || size == 0
                || Self.fileLooksLikeHTMLPage(url)
                || (row.totalBytes > 0 && size < Int64(row.totalBytes))
            if isCorrupt {
                if exists { DownloadStorage.removeFile(relativePath: row.localPath) }
                downloadLog.error("integrity id=\(row.id, privacy: .public) — completed file corrupt/missing (exists=\(exists) size=\(size) expected=\(row.totalBytes)); removed, row marked failed")
                await markFailed(
                    id: row.id,
                    error: NSError(domain: "Download", code: -6,
                                   userInfo: [NSLocalizedDescriptionKey: L("download.error.corrupt_removed")])
                )
            } else if size > Int64(row.totalBytes) {
                _ = try? await AppDatabase.shared.write { db in
                    if var r = try DBDownloadedItem.filter(Column("id") == row.id).fetchOne(db) {
                        r.totalBytes = Int(size)
                        r.downloadedBytes = Int(size)
                        try r.update(db)
                    }
                }
            }
        }
    }

    /// C2 (Round 15) launch sweep: deletes media files under the
    /// Downloads root that have NO DB row (left behind by a delete that
    /// raced a completion, an old crash, or a removed playlist whose
    /// folder cleanup was skipped). Resume blobs (`.resume`) are not
    /// media files and are left alone; any file whose relative path
    /// matches a row — in ANY status — is kept.
    private func sweepOrphanedDownloadFiles() async {
        let knownPaths: Set<String> = Set(
            ((try? await AppDatabase.shared.read { db in
                try DBDownloadedItem.fetchAll(db)
            }) ?? []).map(\.localPath)
        )
        await Task.detached(priority: .background) {
            guard let root = try? DownloadStorage.rootDirectory() else { return }
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for case let fileURL as URL in enumerator {
                let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
                if !knownPaths.contains(relative) {
                    try? fm.removeItem(at: fileURL)
                    downloadLog.info("orphan-sweep removed \(relative, privacy: .public)")
                }
            }
        }.value
    }

    // MARK: - Public API

    /// Adds the download to the queue. If the queue is empty it starts immediately; otherwise it waits as `.queued`.
    /// If the same `id` is already downloading/queued, the call is ignored.
    func enqueue(
        id: String,
        playlistId: UUID,
        streamId: String,
        type: String,
        title: String,
        secondaryTitle: String?,
        imageURL: String?,
        remoteURL: URL,
        containerExtension: String?,
        seriesId: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil
    ) async {
        if idToTask[id] != nil || enqueueInFlight.contains(id) { return }
        enqueueInFlight.insert(id)
        defer { enqueueInFlight.remove(id) }
        autoRetryCountById.removeValue(forKey: id)

        // Round 17 (R17-4): same normalization as playback URLs —
        // an empty panel extension must not produce a "12345."
        // file path either.
        let ext = PlaybackURLBuilder.normalizedContainerExtension(containerExtension)
        let relPath = DownloadStorage.relativePath(playlistId: playlistId, type: type, streamId: streamId, ext: ext)

        do {
            _ = try DownloadStorage.ensureParentDirectory(for: relPath)
        } catch {
            await persistFailed(
                id: id, playlistId: playlistId, streamId: streamId, type: type,
                title: title, secondaryTitle: secondaryTitle, imageURL: imageURL,
                remoteURL: remoteURL.absoluteString, relPath: relPath,
                containerExtension: containerExtension, seriesId: seriesId,
                seasonNumber: seasonNumber, episodeNumber: episodeNumber,
                errorMessage: error.localizedDescription
            )
            return
        }

        // B2 (build 61, T4): storage-cap gate. When the downloads
        // already on disk reach the user's cap, the new download is
        // BLOCKED with a visible failed row carrying the cap notice
        // — never a silent no-op.
        if DownloadStorage.totalUsedBytes() >= Self.storageCapBytes {
            downloadLog.error("enqueue id=\(id, privacy: .public) — BLOCKED by storage cap (\(Self.storageCapBytes) bytes)")
            await persistFailed(
                id: id, playlistId: playlistId, streamId: streamId, type: type,
                title: title, secondaryTitle: secondaryTitle, imageURL: imageURL,
                remoteURL: remoteURL.absoluteString, relPath: relPath,
                containerExtension: containerExtension, seriesId: seriesId,
                seasonNumber: seasonNumber, episodeNumber: episodeNumber,
                errorMessage: L("downloadcap.blocked")
            )
            return
        }

        // Write every download as `.queued` first; the pump runs the queue right after.
        // That way slot assignment happens in one place (pumpQueue) and there is no race.
        do {
            try await AppDatabase.shared.write { db in
                let item = DBDownloadedItem(
                    id: id,
                    playlistId: playlistId,
                    streamId: streamId,
                    type: type,
                    title: title,
                    secondaryTitle: secondaryTitle,
                    imageURL: imageURL,
                    remoteURL: remoteURL.absoluteString,
                    localPath: relPath,
                    containerExtension: containerExtension,
                    totalBytes: 0,
                    downloadedBytes: 0,
                    status: DownloadStatus.queued.rawValue,
                    errorMessage: nil,
                    createdAt: Date(),
                    completedAt: nil,
                    seriesId: seriesId,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber
                )
                try item.save(db)
            }
        } catch {
            // Silent swallowing: the user tapped Download, the button stayed idle, no trace at all.
            // Write a failed row so it appears in DownloadsView and can be retried.
            downloadLog.error("enqueue id=\(id, privacy: .public) — DB insert failed: \(error.localizedDescription, privacy: .public)")
            await persistFailed(
                id: id, playlistId: playlistId, streamId: streamId, type: type,
                title: title, secondaryTitle: secondaryTitle, imageURL: imageURL,
                remoteURL: remoteURL.absoluteString, relPath: relPath,
                containerExtension: containerExtension, seriesId: seriesId,
                seasonNumber: seasonNumber, episodeNumber: episodeNumber,
                errorMessage: error.localizedDescription
            )
            return
        }
        dbVersion &+= 1
        downloadLog.info("enqueue id=\(id, privacy: .public) — kuyruğa alındı")
        await pumpQueue()
    }

    /// Cancels an in-progress or queued download; deletes the partial file and the DB row.
    /// If the active task was cancelled, the next one in the queue starts.
    func cancel(id: String) {
        let hadActiveTask = idToTask[id] != nil
        if let task = idToTask[id] {
            task.cancel()
            idToTask.removeValue(forKey: id)
            taskToId.removeValue(forKey: task.taskIdentifier)
        }
        idToPlaylistId.removeValue(forKey: id)
        progress.removeValue(forKey: id)
        autoRetryCountById.removeValue(forKey: id)
        DownloadStorage.removeResumeData(forId: id)
        Task { [id] in
            await self.deleteRow(id: id, removeFile: true)
            if hadActiveTask { await self.pumpQueue() }
        }
    }

    /// Deletes a completed/failed/queued record and its file.
    func delete(id: String) async {
        let hadActiveTask = idToTask[id] != nil
        if let task = idToTask[id] {
            task.cancel()
            idToTask.removeValue(forKey: id)
            taskToId.removeValue(forKey: task.taskIdentifier)
        }
        idToPlaylistId.removeValue(forKey: id)
        progress.removeValue(forKey: id)
        autoRetryCountById.removeValue(forKey: id)
        DownloadStorage.removeResumeData(forId: id)
        await deleteRow(id: id, removeFile: true)
        if hadActiveTask { await pumpQueue() }
    }

    /// Called when a playlist is deleted: cancels the related tasks and deletes the folder.
    func cleanupPlaylist(playlistId: UUID) {
        // B2 (build 61, item 2): stop + discard any active recording
        // of this playlist first — its file lives in the folder
        // removed below.
        LiveRecordingService.shared.cancelRecordings(playlistId: playlistId)
        // Active tasks: find them by playlist match from idToPlaylistId. While iterating `idToTask.keys`
        // the playlist map is more reliable than filtering by string parsing.
        let idsToCancel = idToPlaylistId.filter { $0.value == playlistId }.map(\.key)
        var hadAny = false
        for id in idsToCancel {
            if let task = idToTask[id] {
                task.cancel()
                taskToId.removeValue(forKey: task.taskIdentifier)
                hadAny = true
            }
            idToTask.removeValue(forKey: id)
            idToPlaylistId.removeValue(forKey: id)
            progress.removeValue(forKey: id)
            autoRetryCountById.removeValue(forKey: id)
        }
        DownloadStorage.removePlaylistDirectory(playlistId: playlistId)
        DownloadStorage.removeResumeData(playlistId: playlistId)
        dbVersion &+= 1
        if hadAny { Task { await pumpQueue() } }
    }

    /// The local file URL of a completed download (for playback).
    func localURL(forId id: String) async -> URL? {
        do {
            let row: DBDownloadedItem? = try await AppDatabase.shared.read { db in
                try DBDownloadedItem.filter(Column("id") == id).fetchOne(db)
            }
            guard let row, row.downloadStatus == .completed else { return nil }
            let url = try DownloadStorage.absoluteURL(forRelativePath: row.localPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        } catch {
            return nil
        }
    }

    /// Deletes all downloads belonging to one specific playlist only (in every status).
    /// Cancels the active tasks, removes the files from disk, deletes the DB rows.
    func deleteAll(playlistId: UUID) async {
        // B2 (build 61, item 2): cancel this playlist's active recordings first.
        LiveRecordingService.shared.cancelRecordings(playlistId: playlistId)
        // Aktif task'ler
        let activeIds = idToPlaylistId.filter { $0.value == playlistId }.map(\.key)
        var hadAny = false
        for id in activeIds {
            if let task = idToTask[id] {
                task.cancel()
                taskToId.removeValue(forKey: task.taskIdentifier)
                hadAny = true
            }
            idToTask.removeValue(forKey: id)
            idToPlaylistId.removeValue(forKey: id)
            progress.removeValue(forKey: id)
            autoRetryCountById.removeValue(forKey: id)
        }
        // The DB rows (those belonging to this playlist) and the files
        let rows: [DBDownloadedItem] = (try? await AppDatabase.shared.read { db in
            try DBDownloadedItem.filter(Column("playlistId") == playlistId).fetchAll(db)
        }) ?? []
        for row in rows {
            DownloadStorage.removeFile(relativePath: row.localPath)
        }
        // Remove the playlist folder entirely (subdir + any empty folders).
        DownloadStorage.removePlaylistDirectory(playlistId: playlistId)
        DownloadStorage.removeResumeData(playlistId: playlistId)
        _ = try? await AppDatabase.shared.write { db in
            try DBDownloadedItem.filter(Column("playlistId") == playlistId).deleteAll(db)
        }
        dbVersion &+= 1
        if hadAny { await pumpQueue() }
    }

    /// Deletes the downloads of all playlists (in every status).
    func deleteAll() async {
        // B2 (build 61, item 2): active recordings write into the
        // folders removed below — cancel them first.
        LiveRecordingService.shared.cancelAllRecordings()
        for (id, task) in idToTask {
            task.cancel()
            taskToId.removeValue(forKey: task.taskIdentifier)
            progress.removeValue(forKey: id)
        }
        idToTask.removeAll()
        idToPlaylistId.removeAll()
        autoRetryCountById.removeAll()

        let all: [DBDownloadedItem] = (try? await AppDatabase.shared.read { db in
            try DBDownloadedItem.fetchAll(db)
        }) ?? []
        for row in all {
            DownloadStorage.removeFile(relativePath: row.localPath)
        }
        _ = try? await AppDatabase.shared.write { db in
            try DBDownloadedItem.deleteAll(db)
        }
        DownloadStorage.removeAllResumeData()
        dbVersion &+= 1
    }

    // MARK: - ID helpers
    static func idFor(vod playlistId: UUID, streamId: Int) -> String {
        "vod.\(playlistId.uuidString).\(streamId)"
    }
    static func idFor(episode playlistId: UUID, episodeId: String) -> String {
        "episode.\(playlistId.uuidString).\(episodeId)"
    }
    /// We use the `m3u_` prefix so an M3U channel id doesn't get confused with a UUID.
    static func idFor(m3uChannel playlistId: UUID, channelId: String) -> String {
        "vod.\(playlistId.uuidString).m3u_\(channelId)"
    }

    // MARK: - Settings
    private static var wifiOnly: Bool {
        UserDefaults.standard.bool(forKey: "download.wifi_only")
    }

    // MARK: - S1 (Round 14) response validation

    /// Is it a provider refusal? On accounts whose subscription expired / that hit the connection limit,
    /// the panel often serves a small error page instead of the media, and it used to be saved as if it were
    /// it returns with 200 or 4xx; if the status code goes unchecked, that page is saved as
    /// the media file and the download was marked `.completed`.
    /// If there is an HTTP response: 2xx is required and the Content-Type must not be `text/html`.
    /// A non-HTTP response (local/mock) does not pass this check — the body-signature
    /// check (`fileLooksLikeHTMLPage`) covers it too.
    nonisolated static func responseLooksLikeServerRefusal(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        if !(200...299).contains(http.statusCode) { return true }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? http.mimeType ?? "")
            .lowercased()
        return contentType.contains("text/html")
    }

    /// Does the head of the downloaded body carry an HTML/XML error-page signature?
    /// Real media (MP4/MKV/TS) never starts with `<`.
    nonisolated static func fileLooksLikeHTMLPage(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512), !data.isEmpty else { return false }
        let head = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return head.hasPrefix("<!doctype") || head.hasPrefix("<html")
            || head.hasPrefix("<head") || head.hasPrefix("<?xml")
    }

    /// The reason for an S1 refusal shown to the user (appears as the error text
    /// of the failed row in DownloadsView).
    nonisolated static func serverRefusedError() -> NSError {
        NSError(
            domain: "Download", code: -5,
            userInfo: [NSLocalizedDescriptionKey: L("download.error.server_refused")]
        )
    }

    // MARK: - Queue pump

    /// The number of active (downloading) downloads for a playlist.
    private func activeDownloadCount(for playlistId: UUID) -> Int {
        idToPlaylistId.values.reduce(into: 0) { $0 += ($1 == playlistId ? 1 : 0) }
    }

    /// Whether there is an active download for the given playlist — for the player warning.
    func hasActiveDownload(playlistId: UUID) -> Bool {
        activeDownloadCount(for: playlistId) > 0
    }

    /// Processes the queue: for each playlist, pulls `.queued` rows into `.downloading` up to
    /// `maxConcurrentPerPlaylist` active tasks. Rows are looked at in ascending createdAt order —
    /// if the playlist has a slot, start it; otherwise skip and look at the next row.
    /// Only one pump runs at a time; overlapping calls are marked with `pumpPending`.
    private func pumpQueue() async {
        if pumpInFlight {
            pumpPending = true
            return
        }
        pumpInFlight = true
        defer { pumpInFlight = false }

        repeat {
            pumpPending = false

            let queuedRows: [DBDownloadedItem] = (try? await AppDatabase.shared.read { db in
                try DBDownloadedItem
                    .filter(Column("status") == DownloadStatus.queued.rawValue)
                    .order(Column("createdAt"))
                    .fetchAll(db)
            }) ?? []

            var remaining = queuedRows
            while !remaining.isEmpty {
                // Take the first row whose playlist has a free slot.
                guard let idx = remaining.firstIndex(where: { row in
                    activeDownloadCount(for: row.playlistId) < concurrencyLimit(for: row.playlistId)
                }) else { break }
                let next = remaining.remove(at: idx)

                // B2 (build 61, item 2): recording rows are owned by
                // LiveRecordingService and are never URLSession
                // downloads. One reaching the queue is an interrupted
                // leftover — fail it visibly instead of downloading
                // the live URL as a file.
                if next.type == "recording" {
                    await markFailed(
                        id: next.id,
                        error: NSError(domain: "Download", code: -7,
                                       userInfo: [NSLocalizedDescriptionKey: L("record.interrupted")])
                    )
                    continue
                }

                probeProviderMaxConnectionsIfNeeded(playlistId: next.playlistId)

                guard let url = URL(string: next.remoteURL) else {
                    downloadLog.error("pumpQueue id=\(next.id, privacy: .public) — URL bozuk, failed işaretleniyor")
                    await markFailed(
                        id: next.id,
                        error: NSError(domain: "Download", code: -3,
                                       userInfo: [NSLocalizedDescriptionKey: "Invalid download URL"])
                    )
                    continue
                }

                // If the size is known from a previous attempt, verify it will fit before starting.
                if next.totalBytes > 0 {
                    let remainingBytes = Int64(max(next.totalBytes - next.downloadedBytes, 0))
                    // B2 (build 61, T4): the same known size is also
                    // checked against the user's storage cap.
                    if DownloadStorage.totalUsedBytes() + remainingBytes > Self.storageCapBytes {
                        downloadLog.error("pumpQueue cap-block id=\(next.id, privacy: .public) needed=\(remainingBytes) cap=\(Self.storageCapBytes)")
                        await markFailed(
                            id: next.id,
                            error: NSError(domain: "Download", code: -8,
                                           userInfo: [NSLocalizedDescriptionKey: L("downloadcap.blocked")])
                        )
                        continue
                    }
                    if let available = DownloadStorage.availableCapacityBytes(),
                       available < remainingBytes + Self.minFreeDiskMargin {
                        downloadLog.error("pumpQueue no-space id=\(next.id, privacy: .public) needed=\(remainingBytes) available=\(available)")
                        await markFailed(
                            id: next.id,
                            error: NSError(domain: "Download", code: -4,
                                           userInfo: [NSLocalizedDescriptionKey: L("download.error.no_space")])
                        )
                        continue
                    }
                }

                _ = try? await AppDatabase.shared.write { db in
                    if var row = try DBDownloadedItem.filter(Column("id") == next.id).fetchOne(db) {
                        row.status = DownloadStatus.downloading.rawValue
                        try row.update(db)
                    }
                }
                startTask(id: next.id, playlistId: next.playlistId, remoteURL: url, relPath: next.localPath)
                dbVersion &+= 1
            }
        } while pumpPending
        await refreshWifiWaitingState()
    }

    /// C10 (Round 15): per-playlist concurrency from the provider's
    /// REAL `max_connections` (verify response, probed once per
    /// session, cached), clamped to 1…3; unknown (M3U / probe failure)
    /// falls back to 1 — never guessed upward.
    private func concurrencyLimit(for playlistId: UUID) -> Int {
        guard let maxConnections = providerMaxConnections[playlistId] else {
            return Self.fallbackConcurrentPerPlaylist
        }
        return min(max(maxConnections, 1), Self.maxConcurrentCap)
    }

    /// Probes `max_connections` for a playlist once per session.
    /// Fire-and-forget from the pump: the current pump keeps the
    /// fallback limit; the NEXT pump uses the probed value.
    private func probeProviderMaxConnectionsIfNeeded(playlistId: UUID) {
        guard !providerMaxConnectionsProbed.contains(playlistId) else { return }
        providerMaxConnectionsProbed.insert(playlistId)
        Task {
            guard let playlist = try? await AppDatabase.shared.read({ db in
                try Playlist.fetchOne(db, key: playlistId)
            }), playlist.kind == .xtream else { return }
            let client = XtreamAPIClient(playlist: playlist)
            guard let response = try? await client.verify(),
                  let raw = response.userInfo?.maxConnections,
                  let value = Int(raw.trimmingCharacters(in: .whitespaces)), value > 0
            else { return }
            providerMaxConnections[playlistId] = value
            await pumpQueue()
        }
    }

    /// The DB row is assumed to already exist. Sets up the URLSession task and writes the in-memory maps.
    /// If there is resume data from a previous attempt, it resumes where it left off; otherwise it starts from scratch.
    private func startTask(id: String, playlistId: UUID, remoteURL: URL, relPath: String) {
        downloadLog.info("start id=\(id, privacy: .public) playlist=\(playlistId.uuidString, privacy: .public) url=\(remoteURL.absoluteString, privacy: .public)")
        // B2 (build 61, T4): the Wi-Fi-only gate now covers EVERY
        // start, not only resumes (the C2 resume gate below remains
        // the reason it must happen BEFORE task creation:
        // `downloadTask(withResumeData:)` cannot carry
        // `allowsCellularAccess`). On a cellular-only path with
        // Wi-Fi-only ON, the download PAUSES: the row goes back to
        // `.queued`, any resume blob is kept, `isWaitingForWifi`
        // surfaces the state in DownloadsView, and the path
        // monitor's Wi-Fi callback re-pumps the queue.
        if Self.wifiOnly && isCellularOnlyPath {
            wifiDeferredIds.insert(id)
            downloadLog.info("start id=\(id, privacy: .public) — DEFERRED (Wi-Fi-only, cellular path)")
            Task {
                _ = try? await AppDatabase.shared.write { db in
                    if var row = try DBDownloadedItem.filter(Column("id") == id).fetchOne(db),
                       row.status == DownloadStatus.downloading.rawValue {
                        row.status = DownloadStatus.queued.rawValue
                        try row.update(db)
                    }
                }
                dbVersion &+= 1
                await self.refreshWifiWaitingState()
            }
            return
        }
        let task: URLSessionDownloadTask
        if let resumeData = DownloadStorage.loadResumeData(forId: id) {
            // Consume the blob up front: if this attempt fails again we either get
            // fresh resume data (persisted anew in didCompleteWithError) or the next
            // retry falls back to a clean full download.
            DownloadStorage.removeResumeData(forId: id)
            downloadLog.info("start id=\(id, privacy: .public) — resuming with \(resumeData.count) bytes of resume data")
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: remoteURL)
            request.allowsCellularAccess = !Self.wifiOnly
            task = session.downloadTask(with: request)
        }
        // C2: the id (which embeds the playlistId) rides the task so a
        // post-relaunch restore can match URL + playlist, not URL alone.
        task.taskDescription = id
        taskToId[task.taskIdentifier] = id
        taskToRelativePath[task.taskIdentifier] = relPath
        idToTask[id] = task
        idToPlaylistId[id] = playlistId
        if progress[id] == nil {
            progress[id] = DownloadProgress(totalBytes: 0, downloadedBytes: 0)
        }
        task.resume()
    }

    // MARK: - DB helpers

    private func deleteRow(id: String, removeFile: Bool) async {
        do {
            let existing: DBDownloadedItem? = try await AppDatabase.shared.read { db in
                try DBDownloadedItem.filter(Column("id") == id).fetchOne(db)
            }
            if removeFile, let relPath = existing?.localPath {
                DownloadStorage.removeFile(relativePath: relPath)
            }
            _ = try await AppDatabase.shared.write { db in
                try DBDownloadedItem.filter(Column("id") == id).deleteAll(db)
            }
            dbVersion &+= 1
        } catch {
            // ignore
        }
    }

    private func persistFailed(
        id: String,
        playlistId: UUID,
        streamId: String,
        type: String,
        title: String,
        secondaryTitle: String?,
        imageURL: String?,
        remoteURL: String,
        relPath: String,
        containerExtension: String?,
        seriesId: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        errorMessage: String
    ) async {
        _ = try? await AppDatabase.shared.write { db in
            let item = DBDownloadedItem(
                id: id,
                playlistId: playlistId,
                streamId: streamId,
                type: type,
                title: title,
                secondaryTitle: secondaryTitle,
                imageURL: imageURL,
                remoteURL: remoteURL,
                localPath: relPath,
                containerExtension: containerExtension,
                totalBytes: 0,
                downloadedBytes: 0,
                status: DownloadStatus.failed.rawValue,
                errorMessage: errorMessage,
                createdAt: Date(),
                completedAt: nil,
                seriesId: seriesId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber
            )
            try item.save(db)
        }
        dbVersion &+= 1
    }
}

// MARK: - URLSessionDownloadDelegate
// Because the delegate queue is configured as the main queue, we can access main-actor state directly.

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        MainActor.assumeIsolated {
            let taskId = downloadTask.taskIdentifier
            guard let id = self.taskToId[taskId] else { return }
            // S1 (Round 14): inspect as soon as the response header is known —
            // cut a server refusal (expired subscription / connection limit) before the whole error
            // page downloads; the cancelled branch marks this id permanently failed
            // instead of requeueing it.
            if !self.responseValidatedFor.contains(taskId) {
                self.responseValidatedFor.insert(taskId)
                if Self.responseLooksLikeServerRefusal(downloadTask.response) {
                    downloadLog.error("server-refused id=\(id, privacy: .public) status=\((downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                    self.serverRefusedIds.insert(id)
                    downloadTask.cancel()
                    return
                }
            }
            let newProgress = DownloadProgress(
                totalBytes: max(0, totalBytesExpectedToWrite),
                downloadedBytes: max(0, totalBytesWritten)
            )
            let percent = Int(newProgress.fraction * 100)
            let totalJustBecameKnown = totalBytesExpectedToWrite > 0
                && !self.totalBytesPersistedFor.contains(taskId)
            if self.lastPublishedPercent[taskId] != percent || totalJustBecameKnown {
                self.lastPublishedPercent[taskId] = percent
                self.progress[id] = newProgress
            }
            // As soon as Content-Length is known, cut a file that won't fit: downloading a 6 GB movie into 2 GB of free space
            // used to end hours later with a disk-full error (and 3 retries).
            if totalJustBecameKnown {
                let remaining = totalBytesExpectedToWrite - totalBytesWritten
                // B2 (build 61, T4): same early cut for the user's
                // storage cap — a fresh download whose real size is
                // only known now must not run past the cap.
                if DownloadStorage.totalUsedBytes() + remaining > Self.storageCapBytes {
                    downloadLog.error("cap-block id=\(id, privacy: .public) needed=\(remaining) cap=\(Self.storageCapBytes)")
                    self.capFailedIds.insert(id)
                    downloadTask.cancel()
                    return
                }
                if let available = DownloadStorage.availableCapacityBytes(),
                   available < remaining + Self.minFreeDiskMargin {
                    downloadLog.error("no-space id=\(id, privacy: .public) needed=\(remaining) available=\(available)")
                    self.spaceFailedIds.insert(id)
                    downloadTask.cancel()
                    return
                }
            }
            if totalBytesExpectedToWrite > 0,
               !self.totalBytesPersistedFor.contains(taskId) {
                self.totalBytesPersistedFor.insert(taskId)
                let total = totalBytesExpectedToWrite
                Task {
                    _ = try? await AppDatabase.shared.write { db in
                        if var row = try DBDownloadedItem.filter(Column("id") == id).fetchOne(db) {
                            row.totalBytes = Int(total)
                            try row.update(db)
                        }
                    }
                }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The file is deleted when this delegate method returns; we MUST move it SYNCHRONOUSLY.
        let (id, relPath) = MainActor.assumeIsolated { () -> (String?, String?) in
            let taskId = downloadTask.taskIdentifier
            return (self.taskToId[taskId], self.taskToRelativePath[taskId])
        }
        guard let id, let relPath else { return }

        // S1 (Round 14): verify the response BEFORE counting it as COMPLETED.
        // If the HTTP status is not 2xx or the body is an HTML error page
        // (including the 200 + HTML case that escaped the header check), the file is NOT
        // MOVED to the destination; the download is marked failed with a reason the user can understand
        // it is marked failed. Tasks arriving via resume also pass through the same
        // delegate path, so this check covers them too.
        if Self.responseLooksLikeServerRefusal(downloadTask.response)
            || Self.fileLooksLikeHTMLPage(location) {
            downloadLog.error("server-refused-finish id=\(id, privacy: .public) status=\((downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
            MainActor.assumeIsolated {
                DownloadStorage.removeResumeData(forId: id)
                _ = Task { await self.markFailed(id: id, error: Self.serverRefusedError()) }
            }
            return
        }

        let fm = FileManager.default
        let sourceSize: Int64 = {
            guard let attrs = try? fm.attributesOfItem(atPath: location.path) else { return 0 }
            return (attrs[.size] as? Int64) ?? 0
        }()
        guard sourceSize > 0 else {
            MainActor.assumeIsolated {
                _ = Task { await self.markFailed(
                    id: id,
                    error: NSError(domain: "Download", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "Empty download payload"])
                ) }
            }
            return
        }

        do {
            let destination = try DownloadStorage.ensureParentDirectory(for: relPath)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
        } catch {
            MainActor.assumeIsolated {
                _ = Task { await self.markFailed(id: id, error: error) }
            }
            return
        }

        MainActor.assumeIsolated {
            _ = Task { await self.markCompleted(id: id, fallbackSize: sourceSize, relPath: relPath) }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        MainActor.assumeIsolated {
            let taskId = task.taskIdentifier
            self.totalBytesPersistedFor.remove(taskId)
            self.responseValidatedFor.remove(taskId)
            self.lastPublishedPercent.removeValue(forKey: taskId)
            // Clean BEFORE the guard: the cancel/delete paths may already have removed taskToId;
            // otherwise every cancelled download leaks a path entry.
            self.taskToRelativePath.removeValue(forKey: taskId)
            let resumeData = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            guard let id = self.taskToId[taskId] else {
                // No in-memory mapping — typically a delegate event delivered right after a
                // relaunch (force-quit cancels background tasks and hands us their resume
                // data here, before restoreOutstandingTasks could match anything). Re-attach
                // the resume data to the matching DB row so the download continues from
                // where it stopped instead of restarting at byte 0.
                if let resumeData,
                   let url = task.originalRequest?.url?.absoluteString ?? task.currentRequest?.url?.absoluteString {
                    // C2: a taskDescription carries the download id
                    // (URL + playlist identity); use it when present.
                    let describedId = task.taskDescription
                    Task { await self.adoptOrphanResumeData(resumeData, remoteURL: url, describedId: describedId) }
                }
                return
            }
            self.taskToId.removeValue(forKey: taskId)
            self.idToTask.removeValue(forKey: id)
            self.idToPlaylistId.removeValue(forKey: id)

            if let error = error {
                let ns = error as NSError
                // User cancellation removes the id mappings before calling task.cancel(),
                // so reaching here with a known id means the SYSTEM cancelled the task
                // (session invalidation, OS reclaim). Keep the resume data and requeue;
                // for a genuine user cancel there is nothing to do (row already deleted).
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                    // S1 (Round 14): a task we cut because of a server refusal:
                    // the retry/red queue is meaningless — permanently failed.
                    if self.serverRefusedIds.remove(id) != nil {
                        DownloadStorage.removeResumeData(forId: id)
                        self.autoRetryCountById.removeValue(forKey: id)
                        Task {
                            await self.markFailed(id: id, error: Self.serverRefusedError())
                            await self.pumpQueue()
                        }
                        return
                    }
                    // B2 (build 61, T4): a task we cut because it
                    // would exceed the storage cap: do not requeue.
                    if self.capFailedIds.remove(id) != nil {
                        DownloadStorage.removeResumeData(forId: id)
                        self.autoRetryCountById.removeValue(forKey: id)
                        Task {
                            await self.markFailed(id: id, error: NSError(
                                domain: "Download", code: -8,
                                userInfo: [NSLocalizedDescriptionKey: L("downloadcap.blocked")]
                            ))
                            await self.pumpQueue()
                        }
                        return
                    }
                    // A task we cut because disk space ran out: do not requeue.
                    if self.spaceFailedIds.remove(id) != nil {
                        DownloadStorage.removeResumeData(forId: id)
                        self.autoRetryCountById.removeValue(forKey: id)
                        Task {
                            await self.markFailed(id: id, error: NSError(
                                domain: "Download", code: -4,
                                userInfo: [NSLocalizedDescriptionKey: L("download.error.no_space")]
                            ))
                            await self.pumpQueue()
                        }
                        return
                    }
                    if let resumeData {
                        DownloadStorage.saveResumeData(resumeData, forId: id)
                        downloadLog.info("system-cancel id=\(id, privacy: .public) — resume data saklandı, kuyruğa geri alındı")
                        Task {
                            await self.requeueAfterError(id: id, errorMessage: error.localizedDescription, preserveProgress: true)
                            await self.pumpQueue()
                        }
                    }
                    return
                }
                // A disk-full error is not fixed by retrying — trying to download from scratch 3 times
                // means gigabytes of wasted traffic. Mark it failed directly.
                let isDiskFull = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
                    || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
                if isDiskFull {
                    self.autoRetryCountById.removeValue(forKey: id)
                    if let resumeData {
                        DownloadStorage.saveResumeData(resumeData, forId: id)
                    }
                    Task {
                        await self.markFailed(id: id, error: NSError(
                            domain: "Download", code: -4,
                            userInfo: [NSLocalizedDescriptionKey: L("download.error.no_space")]
                        ))
                        await self.pumpQueue()
                    }
                    return
                }
                // Persist resume data so the retry (or a later manual retry) resumes
                // from the downloaded prefix instead of restarting the whole file.
                if let resumeData {
                    DownloadStorage.saveResumeData(resumeData, forId: id)
                }
                let attempts = (self.autoRetryCountById[id] ?? 0) + 1
                self.autoRetryCountById[id] = attempts
                if attempts <= Self.maxAutoRetries {
                    downloadLog.info("retry id=\(id, privacy: .public) attempt=\(attempts) resume=\(resumeData != nil) — kuyruğun sonuna eklendi: \(error.localizedDescription, privacy: .public)")
                    Task {
                        await self.requeueAfterError(id: id, errorMessage: error.localizedDescription, preserveProgress: resumeData != nil)
                        await self.pumpQueue()
                    }
                } else {
                    self.autoRetryCountById.removeValue(forKey: id)
                    Task {
                        await self.markFailed(id: id, error: error)
                        await self.pumpQueue()
                    }
                }
            } else {
                // Successful completion: markCompleted was called in didFinishDownloadingTo.
                self.autoRetryCountById.removeValue(forKey: id)
                Task { await self.pumpQueue() }
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }

    /// Puts a failed download back at the end of the queue. `createdAt` is updated so
    /// the other waiting downloads are not blocked.
    /// `preserveProgress`: true if resume data was kept — the byte counters are preserved so
    /// the UI correctly shows the "will resume where it left off" state.
    private func requeueAfterError(id: String, errorMessage: String, preserveProgress: Bool = false) async {
        _ = try? await AppDatabase.shared.write { db in
            if var row = try DBDownloadedItem.filter(Column("id") == id).fetchOne(db) {
                row.status = DownloadStatus.queued.rawValue
                row.errorMessage = errorMessage
                if !preserveProgress {
                    row.totalBytes = 0
                    row.downloadedBytes = 0
                }
                row.createdAt = Date()
                try row.update(db)
            }
        }
        progress.removeValue(forKey: id)
        dbVersion &+= 1
    }

    /// Links the resume data in a delegate error that arrived unmatched after relaunch, via the URL,
    /// to the DB row and takes the row back into the queue. Best-effort: if there is no match, it drops silently.
    private func adoptOrphanResumeData(_ data: Data, remoteURL: String, describedId: String? = nil) async {
        // C2 (Round 15): match by id (= URL + playlist) when the task
        // carried one; URL-only matching could attach resume data to
        // another playlist's identical URL.
        let row: DBDownloadedItem? = try? await AppDatabase.shared.read { db in
            if let describedId, !describedId.isEmpty {
                return try DBDownloadedItem
                    .filter(Column("id") == describedId && Column("remoteURL") == remoteURL)
                    .filter([DownloadStatus.downloading.rawValue, DownloadStatus.queued.rawValue].contains(Column("status")))
                    .fetchOne(db)
            }
            return try DBDownloadedItem
                .filter(Column("remoteURL") == remoteURL)
                .filter([DownloadStatus.downloading.rawValue, DownloadStatus.queued.rawValue].contains(Column("status")))
                .fetchOne(db)
        }
        guard let row else { return }
        // Skip if an in-memory task is already re-downloading this item.
        guard idToTask[row.id] == nil else { return }
        DownloadStorage.saveResumeData(data, forId: row.id)
        downloadLog.info("adopt-resume id=\(row.id, privacy: .public) — relaunch sonrası resume data kurtarıldı")
        if row.downloadStatus == .downloading {
            await requeueAfterError(id: row.id, errorMessage: "Interrupted", preserveProgress: true)
        }
        await pumpQueue()
    }

    private func markCompleted(id: String, fallbackSize: Int64 = 0, relPath: String? = nil) async {
        let now = Date()
        let row: DBDownloadedItem? = try? await AppDatabase.shared.read { db in
            try DBDownloadedItem.filter(Column("id") == id).fetchOne(db)
        }
        guard let row else {
            // C2 (Round 15) delete-vs-complete race: the user deleted
            // this download while the task was finishing — the file was
            // already moved into place by didFinishDownloadingTo, but
            // its row is gone, so the file is an orphan. Delete it
            // instead of leaving unowned bytes on disk (the launch
            // sweep is only the backstop).
            if let relPath {
                DownloadStorage.removeFile(relativePath: relPath)
                downloadLog.info("complete-after-delete id=\(id, privacy: .public) — row gone, file removed")
            }
            progress.removeValue(forKey: id)
            return
        }
        let actualSize: Int64 = {
            guard let url = try? DownloadStorage.absoluteURL(forRelativePath: row.localPath),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return 0
            }
            return (attrs[.size] as? Int64) ?? 0
        }()
        let finalSize = max(actualSize, fallbackSize)
        if finalSize == 0 {
            await markFailed(
                id: id,
                error: NSError(domain: "Download", code: -2,
                               userInfo: [NSLocalizedDescriptionKey: "Downloaded file missing or empty"])
            )
            return
        }
        _ = try? await AppDatabase.shared.write { db in
            if var r = try DBDownloadedItem.filter(Column("id") == id).fetchOne(db) {
                r.status = DownloadStatus.completed.rawValue
                r.completedAt = now
                r.totalBytes = Int(finalSize)
                r.downloadedBytes = Int(finalSize)
                r.errorMessage = nil
                try r.update(db)
            }
        }
        DownloadStorage.removeResumeData(forId: id)
        progress.removeValue(forKey: id)
        dbVersion &+= 1
        // C12 (Round 15): completion signal for in-app banners in
        // other sections (Home observes it; the Downloads section's
        // own ring->checkmark morph lives in its own UI).
        NotificationCenter.default.post(name: Notification.Name("superx.downloadCompleted"), object: id)
        // B3 (Round 14): if "auto-download the next episode" is on, queue the next one.
        await enqueueNextEpisodeIfEnabled(completedRow: row)
    }

    /// B3 (Round 14): When an EPISODE download finishes successfully and
    /// the `downloads.autoDownloadNextEpisode` setting is on (the Settings
    /// toggle is bound via `@AppStorage` to exactly this key), it queues the next episode
    /// of the same series. The order is the `SeriesPlaybackOrdering` order the player
    /// uses for prev/next. If there is no next episode, or it is already
    /// If there is no next episode, or it is already downloaded/queued/downloading,
    /// nothing is done. A failed episode row (failed) can be
    /// re-queued — `enqueue` overwrites it as `.queued`.
    private func enqueueNextEpisodeIfEnabled(completedRow row: DBDownloadedItem) async {
        guard row.type == "episode",
              UserDefaults.standard.bool(forKey: "downloads.autoDownloadNextEpisode"),
              let seriesIdString = row.seriesId,
              let seriesId = Int(seriesIdString)
        else { return }

        struct NextEpisodePayload {
            let episode: DBEpisode
            let playlist: Playlist
            let seriesName: String?
            let seriesCover: String?
            let existingStatus: DownloadStatus?
        }

        let payload: NextEpisodePayload? = try? await AppDatabase.shared.read { db in
            let ordered = try SeriesPlaybackOrdering.orderedEpisodes(
                seriesId: seriesId, playlistId: row.playlistId, db: db
            )
            guard let index = SeriesPlaybackOrdering.index(playbackStreamId: row.streamId, in: ordered),
                  index + 1 < ordered.count else { return nil }
            let next = ordered[index + 1]
            guard let playlist = try Playlist.fetchOne(db, key: row.playlistId) else { return nil }
            let series = try DBSeries
                .filter(Column("seriesId") == seriesId && Column("playlistId") == row.playlistId)
                .fetchOne(db)
            let nextDownloadId = DownloadManager.idFor(
                episode: row.playlistId, episodeId: next.episodeId ?? next.id
            )
            let existing = try DBDownloadedItem
                .filter(Column("id") == nextDownloadId)
                .fetchOne(db)
            return NextEpisodePayload(
                episode: next,
                playlist: playlist,
                seriesName: series?.name,
                seriesCover: series?.cover,
                existingStatus: existing?.downloadStatus
            )
        }
        guard let payload else { return }
        if let status = payload.existingStatus,
           status == .completed || status == .queued || status == .downloading {
            return
        }

        let next = payload.episode
        let nextEpisodeId = next.episodeId ?? next.id
        guard let remoteURL = PlaybackURLBuilder(playlist: payload.playlist).seriesURL(
            streamId: nextEpisodeId, containerExtension: next.containerExtension
        ) else { return }

        downloadLog.info("auto-next id=\(row.id, privacy: .public) → sıradaki bölüm kuyruğa alınıyor: \(nextEpisodeId, privacy: .public)")
        await enqueue(
            id: DownloadManager.idFor(episode: row.playlistId, episodeId: nextEpisodeId),
            playlistId: row.playlistId,
            streamId: nextEpisodeId,
            type: "episode",
            title: next.title ?? payload.seriesName ?? row.secondaryTitle ?? row.title,
            secondaryTitle: payload.seriesName ?? row.secondaryTitle,
            imageURL: next.cover ?? payload.seriesCover,
            remoteURL: remoteURL,
            containerExtension: next.containerExtension,
            seriesId: row.seriesId,
            seasonNumber: next.seasonId.split(separator: "_").last.flatMap { Int($0) },
            episodeNumber: next.episodeNum
        )
    }

    private func markFailed(id: String, error: Error) async {
        _ = try? await AppDatabase.shared.write { db in
            if var row = try DBDownloadedItem.filter(Column("id") == id).fetchOne(db) {
                row.status = DownloadStatus.failed.rawValue
                row.errorMessage = error.localizedDescription
                try row.update(db)
            }
        }
        progress.removeValue(forKey: id)
        dbVersion &+= 1
    }
}
