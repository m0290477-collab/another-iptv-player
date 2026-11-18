import CloudKit
import Foundation
import GRDB
import UIKit

/// B5 (build 61), Item 3 — iCloud sync.
///
/// Two mechanisms, both strictly opt-in-by-availability: if there is no
/// iCloud account, the container errors, or the entitlement is missing,
/// the service disables itself for the session and the app behaves
/// exactly as before (local GRDB + UserDefaults only). Nothing here
/// ever blocks the UI or throws to a caller.
///
/// 1. Favorites — CloudKit private database, one record per favorite:
///    - `SXFavorite`    for `DBFavorite`    (Xtream live/vod/series)
///    - `SXM3UFavorite` for `DBM3UFavorite` (M3U channels)
///    Record identity is the favorite's stable identity
///    (playlistId + type + streamId / playlistId + channelId).
///    Merge rule is last-writer-wins on the record's modification
///    date: the newer `createdAt` (for a live favorite) or the newer
///    tombstone wins. Deletions are propagated with a tombstone
///    record (`deleted = 1`) carrying the deletion time, so a device
///    that was offline still learns the favorite is gone instead of
///    resurrecting it. Sync runs on launch, on local favorite changes
///    (GRDB ValueObservation, debounced), and on foregrounding.
///    NOTE: favorites carry playlistId + catalog ids only — no server
///    URL, username or password ever leaves the device through here.
///    A synced favorite whose playlist does not exist on the receiving
///    device is stored in the DB (harmless, invisible) and becomes
///    visible if the same playlist (same UUID) is added there.
///
/// 2. Watch history — CloudKit private database (B15, W2a):
///    - `SXWatchHistory` for `DBWatchHistory`, one record per
///    history row, keyed by the row's stable id. Fields carry the
///    resume position (`lastTimeMs` / `durationMs`), the per-record
///    timestamp `lastWatchedAt`, and the quick-listing metadata —
///    NO server URL, username or password ever syncs (history rows
///    don't hold any).
///    Merge rule is last-writer-wins on a per-record `modifiedAt`
///    stamp (equal to `lastWatchedAt` for live rows; the deletion
///    time for tombstones). Deletions (clear-history, pruning)
///    propagate via tombstone records exactly like favorites.
///    This one sync covers THREE features, because all three read
///    the same table:
///      (a) watch progress / Continue rows (resume positions),
///      (b) C5 watched-episode marks — the AUTO mark derives from
///          history position (≥90%), and the MANUAL overrides are
///          UserDefaults string arrays whose prefixes
///          (`episodes.manually_watched.` /
///          `episodes.manually_unwatched.`) B8 already added to the
///          KVS whitelist below,
///      (c) Recent Channels — `RecentChannelsRow` is a query over
///          this same table (type "live"), so there is deliberately
///          NO second sync path for it.
///    Triggers mirror favorites: launch, foregrounding, and a GRDB
///    ValueObservation (count + max(lastWatchedAt) fingerprint, so
///    pure position updates — which change neither the row count
///    nor the row set — still schedule a sync).
///
/// 3. Settings — `NSUbiquitousKeyValueStore`, whitelist ONLY:
///    Fixed keys (verified against their `@AppStorage` / store
///    definitions in this codebase):
///      appearance:  app.accent_preset, app.selected_language,
///                   motion.intensity, settings.uiSounds,
///                   dashboard_selected_tab
///      player:      player.pipEnabled, player.continuePlayingInBackground,
///                   player.speedUpOnLongPress, player.autoPlayNextEpisode,
///                   player.showSkipIntro, player.skipIntroLengthSeconds,
///                   player.defaultSleepTimerMinutes, player.videoAspectMode,
///                   player.zappingEnabled, player.zappingDirection,
///                   player.nextEpisodeCardMode
///      downloads:   download.wifi_only, downloads.autoDownloadNextEpisode
///      alerts:      notifications.expiryAlertsEnabled,
///                   reminders.enabled, reminders.leadTimeMinutes
///      playback:    playback.audioDelaySeconds,
///                   playback.subtitleAppearance.v2,
///                   playback.trackPreferences.v1
///      sort:        live.sortOption, vod.sortOption, series.sortOption
///    Dynamic (per-playlist) keys, matched by prefix:
///      hidden_categories.*  (HiddenCategoryStore)
///      category_order.*     (CategoryOrderStore)
///      watchlist.vod.*      (WatchlistStore — §5 sync scope: watch later)
///    NEVER synced: gate.draft.* (playlist server URL + username),
///    pin.* (parental-PIN behaviour; the PIN itself is Keychain-only),
///    applock.* (B15 W1: the app-lock enable flag; its PIN hash is a
///    device-only Keychain item and never leaves the device),
///    playlist credentials (they live in the GRDB `playlist` table and
///    are not UserDefaults values at all), and any key not listed here.
final class ICloudSyncService: NSObject {
    static let shared = ICloudSyncService()

    private let container = CKContainer(identifier: "iCloud.com.irqus.superx")
    private var database: CKDatabase { container.privateCloudDatabase }

    private let queue = DispatchQueue(label: "com.irqus.superx.icloud-sync")
    private var started = false
    private var isAvailable = false
    private var favoritesSyncInFlight = false
    private var favoritesSyncPending = false

    private var favoriteObservation: AnyDatabaseCancellable?
    private var m3uFavoriteObservation: AnyDatabaseCancellable?
    private var favoritesDebounceItem: DispatchWorkItem?
    private var settingsDebounceItem: DispatchWorkItem?

    // B15 (W2a): watch-history sync state, mirroring favorites.
    private var historySyncInFlight = false
    private var historySyncPending = false
    private var historyObservation: AnyDatabaseCancellable?
    private var historyDebounceItem: DispatchWorkItem?

    private static let lastSyncKey = "icloud.favoritesLastSyncAt"
    private static let historyLastSyncKey = "icloud.historyLastSyncAt"

    private override init() { super.init() }

    // MARK: - Lifecycle

    /// Idempotent entry point (called once from the app root's first
    /// task). Everything degrades silently: any failure leaves the
    /// feature off for this session.
    func startIfNeeded() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            Task { await self.bootstrap() }
        }
    }

    private func bootstrap() async {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            Log.error("ICloudSync", "accountStatus failed — sync off: \(error.localizedDescription)")
            return
        }
        guard status == .available else {
            Log.info("ICloudSync", "iCloud account not available (status \(status.rawValue)) — sync off")
            return
        }
        queue.sync { isAvailable = true }

        startSettingsSync()
        startFavoriteObservations()
        await syncFavorites()
        // B15 (W2a): watch-history sync rides the same bootstrap.
        startHistoryObservation()
        await syncWatchHistory()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func appWillEnterForeground() {
        Task {
            await syncFavorites()
            await syncWatchHistory()
        }
    }

    private var syncEnabled: Bool {
        queue.sync { isAvailable }
    }

    // MARK: - Favorites (CloudKit)

    private func startFavoriteObservations() {
        // Same ValueObservation pattern as M3UFavoriteStore: any local
        // write to either favorites table schedules a debounced sync.
        let favoriteObservation = ValueObservation.tracking { db in
            try DBFavorite.fetchCount(db)
        }
        self.favoriteObservation = favoriteObservation.start(
            in: AppDatabase.shared.reader,
            onError: { _ in },
            onChange: { [weak self] _ in self?.scheduleFavoritesSync() }
        )
        let m3uObservation = ValueObservation.tracking { db in
            try DBM3UFavorite.fetchCount(db)
        }
        self.m3uFavoriteObservation = m3uObservation.start(
            in: AppDatabase.shared.reader,
            onError: { _ in },
            onChange: { [weak self] _ in self?.scheduleFavoritesSync() }
        )
    }

    private func scheduleFavoritesSync() {
        queue.async { [weak self] in
            guard let self else { return }
            self.favoritesDebounceItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                Task { await self?.syncFavorites() }
            }
            self.favoritesDebounceItem = item
            self.queue.asyncAfter(deadline: .now() + 2, execute: item)
        }
    }

    /// Full bidirectional merge of both favorites tables against the
    /// private database. Last-writer-wins by modification date.
    func syncFavorites() async {
        guard syncEnabled else { return }
        let shouldRun: Bool = queue.sync {
            if favoritesSyncInFlight {
                favoritesSyncPending = true
                return false
            }
            favoritesSyncInFlight = true
            return true
        }
        guard shouldRun else { return }
        defer {
            let rerun: Bool = queue.sync {
                favoritesSyncInFlight = false
                let pending = favoritesSyncPending
                favoritesSyncPending = false
                return pending
            }
            if rerun { Task { await syncFavorites() } }
        }

        do {
            try await syncFavoriteTable(
                recordType: Self.xtreamRecordType,
                local: try await AppDatabase.shared.read { db in
                    try DBFavorite.fetchAll(db).map { Self.snapshot(for: $0) }
                },
                applyRemote: { snapshots in
                    try await AppDatabase.shared.write { db in
                        for snapshot in snapshots {
                            if snapshot.isDeleted {
                                _ = try DBFavorite
                                    .filter(Column("streamId") == snapshot.streamId ?? -1)
                                    .filter(Column("playlistId") == snapshot.playlistId)
                                    .filter(Column("type") == snapshot.type ?? "")
                                    .deleteAll(db)
                            } else if let streamId = snapshot.streamId, let type = snapshot.type {
                                try DBFavorite(
                                    streamId: streamId,
                                    playlistId: snapshot.playlistId,
                                    type: type,
                                    createdAt: snapshot.modifiedAt
                                ).save(db)
                            }
                        }
                    }
                }
            )
            try await syncFavoriteTable(
                recordType: Self.m3uRecordType,
                local: try await AppDatabase.shared.read { db in
                    try DBM3UFavorite.fetchAll(db).map { Self.snapshot(for: $0) }
                },
                applyRemote: { snapshots in
                    try await AppDatabase.shared.write { db in
                        for snapshot in snapshots {
                            if snapshot.isDeleted {
                                _ = try DBM3UFavorite
                                    .filter(Column("channelId") == snapshot.channelId ?? "")
                                    .filter(Column("playlistId") == snapshot.playlistId)
                                    .deleteAll(db)
                            } else if let channelId = snapshot.channelId {
                                try DBM3UFavorite(
                                    channelId: channelId,
                                    playlistId: snapshot.playlistId,
                                    createdAt: snapshot.modifiedAt
                                ).save(db)
                            }
                        }
                    }
                }
            )
            UserDefaults.standard.set(Date(), forKey: Self.lastSyncKey)
        } catch {
            // Any CloudKit failure (network, quota, entitlement,
            // container) leaves local data untouched and sync off
            // until the next trigger.
            Log.error("ICloudSync", "favorites sync failed — local data untouched: \(error.localizedDescription)")
        }
    }

    /// One favorite row, flattened across both tables.
    struct FavoriteSnapshot {
        var recordName: String
        var playlistId: UUID
        var streamId: Int?
        var type: String?
        var channelId: String?
        /// For a live favorite: its createdAt. For a tombstone: the
        /// deletion time. This is the last-writer-wins clock.
        var modifiedAt: Date
        var isDeleted: Bool
    }

    private static let xtreamRecordType = "SXFavorite"
    private static let m3uRecordType = "SXM3UFavorite"

    private static func snapshot(for favorite: DBFavorite) -> FavoriteSnapshot {
        FavoriteSnapshot(
            recordName: "fav|\(favorite.playlistId.uuidString)|\(favorite.type)|\(favorite.streamId)",
            playlistId: favorite.playlistId,
            streamId: favorite.streamId,
            type: favorite.type,
            channelId: nil,
            modifiedAt: favorite.createdAt,
            isDeleted: false
        )
    }

    private static func snapshot(for favorite: DBM3UFavorite) -> FavoriteSnapshot {
        FavoriteSnapshot(
            recordName: "m3ufav|\(favorite.playlistId.uuidString)|\(sanitized(favorite.channelId))",
            playlistId: favorite.playlistId,
            streamId: nil,
            type: nil,
            channelId: favorite.channelId,
            modifiedAt: favorite.createdAt,
            isDeleted: false
        )
    }

    /// CKRecord IDs accept alphanumerics plus a small punctuation set;
    /// M3U channel ids are app-generated UUIDs in practice, but map
    /// anything unexpected to `_` rather than failing the record.
    private static func sanitized(_ raw: String) -> String {
        String(raw.map { ch in
            (ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == ".") ? ch : "_"
        })
    }

    private static func snapshot(for record: CKRecord) -> FavoriteSnapshot? {
        guard let playlistRaw = record["playlistId"] as? String,
              let playlistId = UUID(uuidString: playlistRaw),
              let modifiedAt = record["modifiedAt"] as? Date
        else { return nil }
        return FavoriteSnapshot(
            recordName: record.recordID.recordName,
            playlistId: playlistId,
            streamId: (record["streamId"] as? NSNumber).map { $0.intValue },
            type: record["type"] as? String,
            channelId: record["channelId"] as? String,
            modifiedAt: modifiedAt,
            isDeleted: ((record["deleted"] as? NSNumber)?.int64Value ?? 0) != 0
        )
    }

    /// Merges one favorites table. `local` is the current local state;
    /// `applyRemote` writes the winning remote changes locally.
    private func syncFavoriteTable(
        recordType: String,
        local: [FavoriteSnapshot],
        applyRemote: ([FavoriteSnapshot]) async throws -> Void
    ) async throws {
        let remoteRecords = try await fetchAllRecords(recordType: recordType)
        let remoteSnapshots = remoteRecords.compactMap(Self.snapshot(for:))
        let remoteByName = Dictionary(uniqueKeysWithValues: remoteSnapshots.map { ($0.recordName, $0) })
        let localByName = Dictionary(uniqueKeysWithValues: local.map { ($0.recordName, $0) })
        let lastSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date

        // 1) Remote wins → apply locally.
        var toApply: [FavoriteSnapshot] = []
        for remote in remoteSnapshots {
            if let localRow = localByName[remote.recordName] {
                if remote.modifiedAt > localRow.modifiedAt { toApply.append(remote) }
            } else if !remote.isDeleted {
                // Not present locally: either genuinely new from
                // another device, or deleted locally after the last
                // sync — the tombstone push in step 2 handles the
                // latter; only download when the remote change is
                // newer than our last sync (or we never synced).
                if let lastSync {
                    if remote.modifiedAt > lastSync { toApply.append(remote) }
                } else {
                    toApply.append(remote)
                }
            } else {
                // Tombstone for a row we don't have: nothing to do.
            }
        }
        if !toApply.isEmpty { try await applyRemote(toApply) }

        // 2) Local wins → push.
        var recordsToSave: [CKRecord] = []
        for localRow in local {
            if let remote = remoteByName[localRow.recordName] {
                if localRow.modifiedAt > remote.modifiedAt {
                    let record = remoteRecords.first { $0.recordID.recordName == localRow.recordName }
                        ?? CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: localRow.recordName))
                    Self.write(localRow, into: record)
                    recordsToSave.append(record)
                }
            } else {
                let record = CKRecord(
                    recordType: recordType,
                    recordID: CKRecord.ID(recordName: localRow.recordName)
                )
                Self.write(localRow, into: record)
                recordsToSave.append(record)
            }
        }
        // Local deletions: a live remote record whose row is gone
        // locally and which has not changed since our last sync was
        // deleted here → push a tombstone stamped now.
        if let lastSync {
            for remote in remoteSnapshots where !remote.isDeleted {
                guard localByName[remote.recordName] == nil,
                      remote.modifiedAt <= lastSync,
                      let record = remoteRecords.first(where: { $0.recordID.recordName == remote.recordName })
                else { continue }
                record["deleted"] = NSNumber(value: 1)
                record["modifiedAt"] = Date() as NSDate
                recordsToSave.append(record)
            }
        }
        if !recordsToSave.isEmpty {
            _ = try await database.modifyRecords(saving: recordsToSave, deleting: [])
        }
    }

    private static func write(_ snapshot: FavoriteSnapshot, into record: CKRecord) {
        record["playlistId"] = snapshot.playlistId.uuidString as NSString
        if let streamId = snapshot.streamId { record["streamId"] = Int64(streamId) as NSNumber }
        if let type = snapshot.type { record["type"] = type as NSString }
        if let channelId = snapshot.channelId { record["channelId"] = channelId as NSString }
        record["modifiedAt"] = snapshot.modifiedAt as NSDate
        record["deleted"] = NSNumber(value: snapshot.isDeleted ? 1 : 0)
    }

    private func fetchAllRecords(recordType: String) async throws -> [CKRecord] {
        var all: [CKRecord] = []
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        // A per-record failure skips that record; the sync as a whole
        // only aborts on a query-level error.
        var (matches, cursor) = try await database.records(
            matching: query,
            inZoneWith: nil,
            desiredKeys: nil,
            resultsLimit: 200
        )
        all.append(contentsOf: matches.compactMap { _, result in try? result.get() })
        while let currentCursor = cursor {
            (matches, cursor) = try await database.records(
                continuingMatchFrom: currentCursor,
                desiredKeys: nil,
                resultsLimit: 200
            )
            all.append(contentsOf: matches.compactMap { _, result in try? result.get() })
        }
        return all
    }

    // MARK: - Watch history (CloudKit) — B15, W2a

    private static let historyRecordType = "SXWatchHistory"

    /// One watch-history row, flattened for sync.
    struct HistorySnapshot {
        var recordName: String
        /// The row's stable id ("\(playlistId)_\(type)_\(streamId)").
        var id: String
        var playlistId: UUID
        var streamId: String
        var type: String
        var lastTimeMs: Int
        var durationMs: Int
        /// The row's own timestamp (data — drives Continue-row
        /// ordering on the receiving device).
        var lastWatchedAt: Date
        var seriesId: String?
        var title: String
        var secondaryTitle: String?
        var imageURL: String?
        var containerExtension: String?
        /// The last-writer-wins clock: `lastWatchedAt` for a live
        /// row, the deletion time for a tombstone.
        var modifiedAt: Date
        var isDeleted: Bool
    }

    private static func snapshot(for row: DBWatchHistory) -> HistorySnapshot {
        HistorySnapshot(
            recordName: "hist|\(sanitized(row.id))",
            id: row.id,
            playlistId: row.playlistId,
            streamId: row.streamId,
            type: row.type,
            lastTimeMs: row.lastTimeMs,
            durationMs: row.durationMs,
            lastWatchedAt: row.lastWatchedAt,
            seriesId: row.seriesId,
            title: row.title,
            secondaryTitle: row.secondaryTitle,
            imageURL: row.imageURL,
            containerExtension: row.containerExtension,
            modifiedAt: row.lastWatchedAt,
            isDeleted: false
        )
    }

    private static func snapshotFromHistoryRecord(_ record: CKRecord) -> HistorySnapshot? {
        guard let id = record["id"] as? String,
              let playlistRaw = record["playlistId"] as? String,
              let playlistId = UUID(uuidString: playlistRaw),
              let streamId = record["streamId"] as? String,
              let type = record["type"] as? String,
              let lastWatchedAt = record["lastWatchedAt"] as? Date,
              let modifiedAt = record["modifiedAt"] as? Date
        else { return nil }
        return HistorySnapshot(
            recordName: record.recordID.recordName,
            id: id,
            playlistId: playlistId,
            streamId: streamId,
            type: type,
            lastTimeMs: (record["lastTimeMs"] as? NSNumber)?.intValue ?? 0,
            durationMs: (record["durationMs"] as? NSNumber)?.intValue ?? 0,
            lastWatchedAt: lastWatchedAt,
            seriesId: record["seriesId"] as? String,
            title: (record["title"] as? String) ?? "",
            secondaryTitle: record["secondaryTitle"] as? String,
            imageURL: record["imageURL"] as? String,
            containerExtension: record["containerExtension"] as? String,
            modifiedAt: modifiedAt,
            isDeleted: ((record["deleted"] as? NSNumber)?.int64Value ?? 0) != 0
        )
    }

    private static func write(_ snapshot: HistorySnapshot, into record: CKRecord) {
        record["id"] = snapshot.id as NSString
        record["playlistId"] = snapshot.playlistId.uuidString as NSString
        record["streamId"] = snapshot.streamId as NSString
        record["type"] = snapshot.type as NSString
        record["lastTimeMs"] = Int64(snapshot.lastTimeMs) as NSNumber
        record["durationMs"] = Int64(snapshot.durationMs) as NSNumber
        record["lastWatchedAt"] = snapshot.lastWatchedAt as NSDate
        if let seriesId = snapshot.seriesId { record["seriesId"] = seriesId as NSString }
        record["title"] = snapshot.title as NSString
        if let secondaryTitle = snapshot.secondaryTitle { record["secondaryTitle"] = secondaryTitle as NSString }
        if let imageURL = snapshot.imageURL { record["imageURL"] = imageURL as NSString }
        if let containerExtension = snapshot.containerExtension { record["containerExtension"] = containerExtension as NSString }
        record["modifiedAt"] = snapshot.modifiedAt as NSDate
        record["deleted"] = NSNumber(value: snapshot.isDeleted ? 1 : 0)
    }

    private func startHistoryObservation() {
        // Fingerprint = row count + newest lastWatchedAt. A pure
        // resume-position update rewrites its row with
        // lastWatchedAt = now, which moves the max; inserts and
        // deletions move the count. Either change schedules a sync.
        let observation = ValueObservation.tracking { db -> String in
            try String.fetchOne(
                db,
                sql: "SELECT COUNT(*) || '|' || COALESCE(MAX(lastWatchedAt), '') FROM watchHistory"
            ) ?? ""
        }
        self.historyObservation = observation.start(
            in: AppDatabase.shared.reader,
            onError: { _ in },
            onChange: { [weak self] _ in self?.scheduleHistorySync() }
        )
    }

    private func scheduleHistorySync() {
        queue.async { [weak self] in
            guard let self else { return }
            self.historyDebounceItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                Task { await self?.syncWatchHistory() }
            }
            self.historyDebounceItem = item
            self.queue.asyncAfter(deadline: .now() + 2, execute: item)
        }
    }

    /// Full bidirectional merge of the watch-history table against
    /// the private database. Last-writer-wins per record on
    /// `modifiedAt`; deletions propagate as tombstones — the same
    /// discipline as the favorites merge above.
    func syncWatchHistory() async {
        guard syncEnabled else { return }
        let shouldRun: Bool = queue.sync {
            if historySyncInFlight {
                historySyncPending = true
                return false
            }
            historySyncInFlight = true
            return true
        }
        guard shouldRun else { return }
        defer {
            let rerun: Bool = queue.sync {
                historySyncInFlight = false
                let pending = historySyncPending
                historySyncPending = false
                return pending
            }
            if rerun { Task { await syncWatchHistory() } }
        }

        do {
            let local = try await AppDatabase.shared.read { db in
                try DBWatchHistory.fetchAll(db).map { Self.snapshot(for: $0) }
            }
            let remoteRecords = try await fetchAllRecords(recordType: Self.historyRecordType)
            let remoteSnapshots = remoteRecords.compactMap(Self.snapshotFromHistoryRecord(_:))
            let remoteByName = Dictionary(uniqueKeysWithValues: remoteSnapshots.map { ($0.recordName, $0) })
            let localByName = Dictionary(uniqueKeysWithValues: local.map { ($0.recordName, $0) })
            let lastSync = UserDefaults.standard.object(forKey: Self.historyLastSyncKey) as? Date

            // 1) Remote wins → apply locally.
            var toApply: [HistorySnapshot] = []
            for remote in remoteSnapshots {
                if let localRow = localByName[remote.recordName] {
                    if remote.modifiedAt > localRow.modifiedAt { toApply.append(remote) }
                } else if !remote.isDeleted {
                    if let lastSync {
                        if remote.modifiedAt > lastSync { toApply.append(remote) }
                    } else {
                        toApply.append(remote)
                    }
                }
            }
            if !toApply.isEmpty {
                try await AppDatabase.shared.write { db in
                    for snapshot in toApply {
                        if snapshot.isDeleted {
                            _ = try DBWatchHistory
                                .filter(Column("id") == snapshot.id)
                                .deleteAll(db)
                        } else {
                            try DBWatchHistory(
                                id: snapshot.id,
                                playlistId: snapshot.playlistId,
                                streamId: snapshot.streamId,
                                type: snapshot.type,
                                lastTimeMs: snapshot.lastTimeMs,
                                durationMs: snapshot.durationMs,
                                lastWatchedAt: snapshot.lastWatchedAt,
                                seriesId: snapshot.seriesId,
                                title: snapshot.title,
                                secondaryTitle: snapshot.secondaryTitle,
                                imageURL: snapshot.imageURL,
                                containerExtension: snapshot.containerExtension
                            ).save(db)
                        }
                    }
                }
            }

            // 2) Local wins → push.
            var recordsToSave: [CKRecord] = []
            for localRow in local {
                if let remote = remoteByName[localRow.recordName] {
                    if localRow.modifiedAt > remote.modifiedAt {
                        let record = remoteRecords.first { $0.recordID.recordName == localRow.recordName }
                            ?? CKRecord(recordType: Self.historyRecordType, recordID: CKRecord.ID(recordName: localRow.recordName))
                        Self.write(localRow, into: record)
                        recordsToSave.append(record)
                    }
                } else {
                    let record = CKRecord(
                        recordType: Self.historyRecordType,
                        recordID: CKRecord.ID(recordName: localRow.recordName)
                    )
                    Self.write(localRow, into: record)
                    recordsToSave.append(record)
                }
            }
            // Local deletions: a live remote record whose row is
            // gone locally and which has not changed since our last
            // sync was deleted here (clear-history / prune) → push
            // a tombstone stamped now.
            if let lastSync {
                for remote in remoteSnapshots where !remote.isDeleted {
                    guard localByName[remote.recordName] == nil,
                          remote.modifiedAt <= lastSync,
                          let record = remoteRecords.first(where: { $0.recordID.recordName == remote.recordName })
                    else { continue }
                    record["deleted"] = NSNumber(value: 1)
                    record["modifiedAt"] = Date() as NSDate
                    recordsToSave.append(record)
                }
            }
            if !recordsToSave.isEmpty {
                _ = try await database.modifyRecords(saving: recordsToSave, deleting: [])
            }
            UserDefaults.standard.set(Date(), forKey: Self.historyLastSyncKey)
        } catch {
            // Same contract as favorites: any CloudKit failure
            // leaves local data untouched and sync retries on the
            // next trigger.
            Log.error("ICloudSync", "watch-history sync failed — local data untouched: \(error.localizedDescription)")
        }
    }

    // MARK: - Settings (NSUbiquitousKeyValueStore)

    /// The fixed whitelist — see the type documentation for the full
    /// enumeration and the never-sync list.
    static let syncedSettingsKeys: [String] = [
        // Appearance
        "app.accent_preset", "app.selected_language",
        "motion.intensity", "settings.uiSounds",
        "dashboard_selected_tab",
        // Player preferences
        "player.pipEnabled", "player.continuePlayingInBackground",
        "player.speedUpOnLongPress", "player.autoPlayNextEpisode",
        "player.showSkipIntro", "player.skipIntroLengthSeconds",
        "player.defaultSleepTimerMinutes", "player.videoAspectMode",
        // Build 61 (FA, H1): the audio-only Settings default syncs
        // with the per-channel audioonly.* sets B8 already syncs.
        "player.audioOnlyDefault",
        "player.zappingEnabled", "player.zappingDirection",
        "player.nextEpisodeCardMode",
        // Downloads preferences
        "download.wifi_only", "downloads.autoDownloadNextEpisode",
        // Alerts
        "notifications.expiryAlertsEnabled",
        "reminders.enabled", "reminders.leadTimeMinutes",
        // Playback detail stores
        "playback.audioDelaySeconds", "playback.subtitleAppearance.v2",
        "playback.trackPreferences.v1",
        // Sort options
        "live.sortOption", "vod.sortOption", "series.sortOption",
    ]

    /// Per-playlist key prefixes that are safe to sync (ids and
    /// preference values only — no URLs, no credentials).
    static let syncedSettingsKeyPrefixes: [String] = [
        "hidden_categories.",
        "category_order.",
        "watchlist.vod.",
        // Build 61 (B8): series Watch Later (C2), favorite groups
        // (J1), pins (C10), per-channel hide (H2), audio-only choices
        // (H1) and first-seen bookkeeping (R1) — ids/preferences
        // only, no URLs or credentials, same rule as the prefixes
        // above.
        "watchlist.series.",
        "watchlist.snapshots.",
        "favgroups.",
        "pinned.live.",
        "pinned.m3u.",
        "hidden_channels.",
        "hidden_m3u_channels.",
        "audioonly.on.",
        "audioonly.off.",
        "firstseen.",
        "episodes.manually_watched.",
        "episodes.manually_unwatched.",
    ]

    private static func isSyncedSettingsKey(_ key: String) -> Bool {
        if syncedSettingsKeys.contains(key) { return true }
        return syncedSettingsKeyPrefixes.contains { key.hasPrefix($0) }
    }

    private func startSettingsSync() {
        let store = NSUbiquitousKeyValueStore.default
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvsDidChangeExternally(_:)),
            name: NSUbiquitousKeyValueStoreDidChangeExternallyNotification,
            object: store
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        // Cold start: remote values are the cross-device source of
        // truth, then any local-only whitelisted keys are pushed up.
        pullSettingsFromKVS()
        pushSettingsToKVS()
        _ = store.synchronize()
    }

    @objc private func kvsDidChangeExternally(_ notification: Notification) {
        guard let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
              reason == NSUbiquitousKeyValueStoreServerChange
                || reason == NSUbiquitousKeyValueStoreInitialSyncChange
        else { return }
        pullSettingsFromKVS()
    }

    @objc private func userDefaultsDidChange() {
        // Fires for every defaults write in the app; debounce and
        // push only whitelisted keys.
        queue.async { [weak self] in
            guard let self else { return }
            self.settingsDebounceItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.pushSettingsToKVS() }
            self.settingsDebounceItem = item
            self.queue.asyncAfter(deadline: .now() + 2, execute: item)
        }
    }

    private func pullSettingsFromKVS() {
        let store = NSUbiquitousKeyValueStore.default
        let defaults = UserDefaults.standard
        for (key, value) in store.dictionaryRepresentation where Self.isSyncedSettingsKey(key) {
            if let current = defaults.object(forKey: key),
               (current as? NSObject) == (value as? NSObject) { continue }
            defaults.set(value, forKey: key)
        }
    }

    private func pushSettingsToKVS() {
        guard syncEnabled else { return }
        let store = NSUbiquitousKeyValueStore.default
        let defaults = UserDefaults.standard
        var keys = Set(Self.syncedSettingsKeys)
        for key in defaults.dictionaryRepresentation().keys where Self.isSyncedSettingsKey(key) {
            keys.insert(key)
        }
        for key in keys {
            if let value = defaults.object(forKey: key) {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
        _ = store.synchronize()
    }
}
