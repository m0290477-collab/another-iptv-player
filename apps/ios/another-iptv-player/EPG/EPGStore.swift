import Foundation
import Combine
import GRDB
import UIKit

enum EPGRefreshState: Equatable {
    case idle
    case refreshing(EPGRefreshPhase?)
    case failed(String)

    var isRefreshing: Bool {
        if case .refreshing = self { return true }
        return false
    }
}

/// Lightweight record used by the timeline grid. Long descriptions and artwork
/// are fetched only when the user opens a programme, keeping the day view's peak
/// memory proportional to titles rather than the full XMLTV payload.
nonisolated struct EPGGuideProgrammeRecord: FetchableRecord, Decodable, Sendable {
    let channelKey: String
    let startTs: Int64
    let stopTs: Int64
    let title: String

    var programme: EPGProgramme {
        EPGProgramme(
            channelKey: channelKey,
            title: title,
            start: Date(timeIntervalSince1970: TimeInterval(startTs)),
            stop: Date(timeIntervalSince1970: TimeInterval(stopTs))
        )
    }
}

/// Central EPG store. Owns a single in-memory now/next index (published once per
/// minute as an `EPGSnapshot`) plus per-playlist refresh orchestration. One store,
/// one active playlist at a time — the snapshot dictionary carries no playlist
/// dimension and is rebuilt whenever the active playlist changes.
@MainActor
final class EPGStore: ObservableObject {
    static let shared: EPGStore = {
        let store = EPGStore()
        store.registerLifecycleObservers()
        return store
    }()

    /// Now/next for the active playlist. `nil` = EPG not configured/loaded.
    @Published private(set) var snapshot: EPGSnapshot?
    @Published private(set) var refreshState: [UUID: EPGRefreshState] = [:]
    @Published private(set) var lastSuccess: [UUID: Date] = [:]
    /// `now` used for progress/highlight math; bumped by the tick.
    @Published private(set) var nowDate: Date = Date()

    private var activePlaylistId: UUID?
    private var resolution: [String: String] = [:]   // aliasKey → stored channelKey
    private var configured = false                    // active playlist has a successful epgSource
    private var version = 0

    /// C10 (Round 15): fingerprint of the last published now/next
    /// snapshot. The 60 s tick re-queries every minute, but a new
    /// snapshot is published ONLY when the now/next assignment actually
    /// changed — previously every tick bumped `version` and republished,
    /// re-rendering every EPG-reading card once a minute for nothing.
    private var lastSnapshotFingerprint: Int?
    private var tickTask: Task<Void, Never>?
    private var activeRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Round 14 (B10): when the store was created, and whether the
    /// first-launch settle window has already been honored. The
    /// dashboards call `refreshIfStale` from their root `.task`, i.e.
    /// during the very first render — starting a full XMLTV download
    /// + parse there competes with that render on a cold launch.
    private let createdAt = Date()
    private var didHonorFirstLaunchSettle = false
    /// How long after store creation the first stale-refresh waits
    /// before touching the network (only while no snapshot exists).
    private static let firstLaunchSettleDelay: TimeInterval = 2.5

    private init() {}

    /// Called by the `shared` factory right after `init` returns. The notification
    /// closures capture `self`, which inside `init` is still a mutable variable —
    /// a Swift 6 concurrency error for `@Sendable` closures.
    private func registerLifecycleObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopTimer() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.startTimerIfActive() }
        })
    }

    // MARK: - Active playlist lifecycle

    func setActivePlaylist(_ playlist: Playlist?) {
        guard activePlaylistId != playlist?.id else { return }
        activePlaylistId = playlist?.id
        resolution = [:]
        configured = false
        snapshot = nil
        guard let playlist else { stopTimer(); return }
        Task { await self.reload(playlist: playlist) }
    }

    /// Rebuilds the resolution map + snapshot and (re)starts the minute timer.
    func reload(playlist: Playlist) async {
        guard playlist.id == activePlaylistId else { return }
        await loadSourceStatus(playlist: playlist)
        await rebuildResolution(playlist: playlist)
        await tick()
        startTimerIfActive()
    }

    private func loadSourceStatus(playlist: Playlist) async {
        let src = try? await AppDatabase.shared.read { db in
            try DBEPGSource.fetchOne(db, key: playlist.id)
        }
        if let success = (src ?? nil)?.lastSuccessAt {
            configured = true
            lastSuccess[playlist.id] = success
        } else {
            configured = ((src ?? nil) != nil)
        }
    }

    // MARK: - Timer

    /// Round 15 (C10): the player stamps this UserDefaults key
    /// with the current time while fullscreen playback is active
    /// (refreshed on a heartbeat, so a crashed/killed app can't
    /// leave it set). While it is fresh, the minute tick below is
    /// lengthened to 5 minutes: rebuilding the now/next index
    /// every 60 s competes with fullscreen video decode, and a
    /// programme boundary crossed mid-playback is not worth that
    /// cost — the index is rebuilt on the normal cadence as soon
    /// as playback ends or shrinks to the mini player.
    nonisolated static let fullscreenPlaybackStampKey = "epg.fullscreenPlaybackActiveAt"
    private static let fullscreenTickInterval: TimeInterval = 300
    private static let fullscreenStampFreshness: TimeInterval = 90

    private static var isFullscreenPlaybackActive: Bool {
        let stamp = UserDefaults.standard.double(forKey: fullscreenPlaybackStampKey)
        guard stamp > 0 else { return false }
        return Date().timeIntervalSince1970 - stamp < fullscreenStampFreshness
    }

    private func startTimerIfActive() {
        guard activePlaylistId != nil, tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                let nextBoundary = (now.timeIntervalSince1970 / 60.0).rounded(.down) * 60 + 60
                var delay = max(1, nextBoundary - now.timeIntervalSince1970)
                // Round 15 (C10): lengthen (never fully pause, so
                // a stale stamp still recovers) during fullscreen
                // playback — see `fullscreenPlaybackStampKey`.
                if Self.isFullscreenPlaybackActive {
                    delay = max(delay, Self.fullscreenTickInterval)
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.tick()
            }
        }
    }

    private func stopTimer() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Now/next index

    func tick() async {
        nowDate = Date()
        guard let pid = activePlaylistId else { snapshot = nil; return }
        // F1 (B13): the now/next index is built against the
        // offset-shifted "now" (`EPGOffsetStore.lookupNow`), so the
        // snapshot's current programme is the one the user SEES as
        // current under the F1 EPG time offset — the same offset
        // `EPGTimeFormat` applies to every displayed time.
        let now = Int64(EPGOffsetStore.lookupNow().timeIntervalSince1970)

        // C10 (Round 15): the tick query is narrowed to NOW/NEXT per
        // channel only. The old query fetched EVERY programme starting
        // within the 12 h lookahead for every channel (thousands of
        // rows on a big guide) just to pick the first current and the
        // first future row per channel. Two arms: (1) the programme on
        // air now, (2) the single earliest future programme per channel
        // via a correlated MIN(startTs).
        let rows: [DBEPGProgramme]
        do {
            rows = try await AppDatabase.shared.read { db in
                try DBEPGProgramme.fetchAll(db, sql: """
                    SELECT * FROM epgProgramme
                    WHERE playlistId = ? AND startTs <= ? AND stopTs > ?
                    UNION ALL
                    SELECT * FROM epgProgramme AS p
                    WHERE p.playlistId = ? AND p.startTs > ?
                      AND p.startTs = (
                          SELECT MIN(q.startTs) FROM epgProgramme AS q
                          WHERE q.playlistId = p.playlistId
                            AND q.channelKey = p.channelKey
                            AND q.startTs > ?
                      )
                    ORDER BY channelKey, startTs
                    """, arguments: [pid, now, now, pid, now, now])
            }
        } catch {
            return
        }
        guard pid == activePlaylistId else { return }

        var byStored: [String: EPGNowNext] = [:]
        for row in rows {
            let prog = EPGProgramme(from: row)
            var entry = byStored[row.channelKey] ?? EPGNowNext()
            if prog.isCurrent(at: EPGOffsetStore.lookupNow()) {
                if entry.now == nil { entry.now = prog }
            } else if prog.start.timeIntervalSince1970 > Double(now) {
                if entry.next == nil { entry.next = prog }
            }
            byStored[row.channelKey] = entry
        }

        // Fold in alias entries so lookups by a channel's own id/name resolve to
        // the stored (possibly display-name-matched) key.
        var dict = byStored
        for (alias, stored) in resolution where dict[alias] == nil {
            if let nn = byStored[stored] { dict[alias] = nn }
        }

        if dict.isEmpty && !configured {
            if snapshot != nil { snapshot = nil }
            lastSnapshotFingerprint = nil
            return
        }
        // C10 (Round 15): publish ONLY on change. The fingerprint
        // covers exactly what a snapshot consumer can see — per channel,
        // the now/next programmes' start/stop/title. `nowDate` above
        // still advances every tick, so time-driven UI (progress bars)
        // keeps its clock without a whole-snapshot republish.
        var hasher = Hasher()
        for key in dict.keys.sorted() {
            hasher.combine(key)
            if let entry = dict[key] {
                hasher.combine(entry.now?.start)
                hasher.combine(entry.now?.stop)
                hasher.combine(entry.now?.title)
                hasher.combine(entry.next?.start)
                hasher.combine(entry.next?.title)
            }
        }
        let fingerprint = hasher.finalize()
        guard fingerprint != lastSnapshotFingerprint else { return }
        lastSnapshotFingerprint = fingerprint
        version += 1
        snapshot = EPGSnapshot(version: version, byChannelKey: dict)
    }

    func nowNext(channelKey: String?) -> EPGNowNext? { snapshot?[channelKey] }

    // MARK: - Resolution

    func rebuildResolution(playlist: Playlist) async {
        let map = try? await AppDatabase.shared.read { db -> [String: String] in
            let channels = try DBEPGChannel.fetchAll(db, sql: "SELECT * FROM epgChannel WHERE playlistId = ?", arguments: [playlist.id])
            var storedKeys = Set<String>()
            var nameToStored: [String: String] = [:]
            for c in channels {
                storedKeys.insert(c.channelKey)
                if let dn = c.displayName?.lowercased(), !dn.isEmpty, nameToStored[dn] == nil {
                    nameToStored[dn] = c.channelKey
                }
            }
            let progKeys = try String.fetchAll(db, sql: "SELECT DISTINCT channelKey FROM epgProgramme WHERE playlistId = ?", arguments: [playlist.id])
            storedKeys.formUnion(progKeys)

            var map: [String: String] = [:]
            if playlist.kind == .xtream {
                let rows = try DBLiveStream.fetchAll(db, sql: "SELECT * FROM liveStream WHERE playlistId = ?", arguments: [playlist.id])
                for r in rows {
                    Self.resolveAlias(idKey: EPGConstants.normalizeChannelKey(r.epgChannelId),
                                      nameKey: EPGConstants.normalizeChannelKey(r.name),
                                      storedKeys: storedKeys, nameToStored: nameToStored, into: &map)
                }
            } else {
                let rows = try DBM3UChannel.fetchAll(db, sql: "SELECT * FROM m3uChannel WHERE playlistId = ?", arguments: [playlist.id])
                for r in rows {
                    Self.resolveAlias(idKey: EPGConstants.normalizeChannelKey(r.tvgId),
                                      nameKey: EPGConstants.normalizeChannelKey(r.tvgName ?? r.name),
                                      storedKeys: storedKeys, nameToStored: nameToStored, into: &map)
                }
            }
            return map
        }
        guard playlist.id == activePlaylistId else { return }
        resolution = map ?? [:]
    }

    private nonisolated static func resolveAlias(idKey: String?, nameKey: String?,
                                                 storedKeys: Set<String>, nameToStored: [String: String],
                                                 into map: inout [String: String]) {
        var stored: String?
        if let idKey, storedKeys.contains(idKey) { stored = idKey }
        else if let nameKey, let s = nameToStored[nameKey] { stored = s }
        guard let stored else { return }
        if let idKey { map[idKey] = stored }
        if let nameKey, map[nameKey] == nil { map[nameKey] = stored }
    }

    /// Resolves a channel's own id/name to the stored key its programmes live under.
    func storedKey(idKey: String?, nameKey: String?) -> String? {
        if let idKey, let s = resolution[idKey] { return s }
        if let nameKey, let s = resolution[nameKey] { return s }
        if let idKey { return idKey }   // direct fallback
        return nil
    }

    // MARK: - Queries

    func programmes(playlistId: UUID, channelKey: String, from: Date, to: Date) async throws -> [EPGProgramme] {
        let f = Int64(from.timeIntervalSince1970)
        let t = Int64(to.timeIntervalSince1970)
        return try await AppDatabase.shared.read { db in
            let rows = try DBEPGProgramme.fetchAll(db, sql: """
                SELECT * FROM epgProgramme
                WHERE playlistId = ? AND channelKey = ? AND stopTs > ? AND startTs < ?
                ORDER BY startTs
                """, arguments: [playlistId, channelKey, f, t])
            // Keep record conversion on GRDB's reader queue. This method belongs to
            // the main-actor store, so doing it after `await` blocks UI rendering.
            return rows.map(EPGProgramme.init(from:))
        }
    }

    /// All programmes for a playlist within a window, grouped by channelKey. Used by
    /// the guide grid — avoids a giant `channelKey IN (…)` clause (SQLite variable
    /// limit / slow) for playlists with thousands of channels.
    func programmes(playlistId: UUID, from: Date, to: Date) async throws -> [String: [EPGProgramme]] {
        let f = Int64(from.timeIntervalSince1970)
        let t = Int64(to.timeIntervalSince1970)
        return try await AppDatabase.shared.read { db in
            let rows = try EPGGuideProgrammeRecord.fetchAll(db, sql: """
                SELECT channelKey, startTs, stopTs, title FROM epgProgramme
                WHERE playlistId = ? AND stopTs > ? AND startTs < ?
                """, arguments: [playlistId, f, t])
            // The guide sorts each channel while building its layout. A global
            // ORDER BY forced SQLite to create a large temporary B-tree first.
            return Self.groupGuideProgrammes(rows)
        }
    }

    /// Loads the fields omitted from the grid query just before presenting the
    /// programme detail sheet. The composite primary key makes this an O(log n)
    /// point lookup.
    func programmeDetails(playlistId: UUID, channelKey: String, start: Date) async throws -> EPGProgramme? {
        let startTs = Int64(start.timeIntervalSince1970)
        return try await AppDatabase.shared.read { db in
            try DBEPGProgramme.fetchOne(db, sql: """
                SELECT * FROM epgProgramme
                WHERE playlistId = ? AND channelKey = ? AND startTs = ?
                """, arguments: [playlistId, channelKey, startTs])
                .map(EPGProgramme.init(from:))
        }
    }

    func programmes(playlistId: UUID, channelKeys: [String], from: Date, to: Date) async throws -> [String: [EPGProgramme]] {
        guard !channelKeys.isEmpty else { return [:] }
        let f = Int64(from.timeIntervalSince1970)
        let t = Int64(to.timeIntervalSince1970)
        let placeholders = databaseQuestionMarks(count: channelKeys.count)
        var args: [DatabaseValueConvertible] = [playlistId]
        args.append(contentsOf: channelKeys)
        args.append(f); args.append(t)
        return try await AppDatabase.shared.read { db in
            let rows = try DBEPGProgramme.fetchAll(db, sql: """
                SELECT * FROM epgProgramme
                WHERE playlistId = ? AND channelKey IN (\(placeholders)) AND stopTs > ? AND startTs < ?
                ORDER BY channelKey, startTs
                """, arguments: StatementArguments(args))
            return Self.groupProgrammes(rows)
        }
    }

    /// Runs inside the database reader closure for guide queries, away from the
    /// main actor. Kept internal so large synthetic datasets can regression-test it.
    nonisolated static func groupProgrammes(_ rows: [DBEPGProgramme]) -> [String: [EPGProgramme]] {
        var result: [String: [EPGProgramme]] = [:]
        result.reserveCapacity(min(rows.count, 4_096))
        for row in rows {
            result[row.channelKey, default: []].append(EPGProgramme(from: row))
        }
        return result
    }

    nonisolated static func groupGuideProgrammes(_ rows: [EPGGuideProgrammeRecord]) -> [String: [EPGProgramme]] {
        var result: [String: [EPGProgramme]] = [:]
        result.reserveCapacity(min(rows.count, 4_096))
        for row in rows {
            result[row.channelKey, default: []].append(row.programme)
        }
        return result
    }

    /// Catch-up detail: past programmes for a channel, clamped to its archive
    /// window. Falls back to `get_simple_data_table` when the stored (XMLTV) guide
    /// has no past coverage but the channel advertises an archive.
    func archiveProgrammes(playlist: Playlist, stream: DBLiveStream) async throws -> [EPGProgramme] {
        let idKey = EPGConstants.normalizeChannelKey(stream.epgChannelId)
        let nameKey = EPGConstants.normalizeChannelKey(stream.name)
        let key = storedKey(idKey: idKey, nameKey: nameKey) ?? "#stream:\(stream.streamId)"

        let now = Date()
        let days = min(max(stream.tvArchiveDuration, EPGConstants.minCatchupPastDays), EPGConstants.maxCatchupPastDays)
        let from = now.addingTimeInterval(-Double(days) * 86_400)

        var rows = try await programmes(playlistId: playlist.id, channelKey: key, from: from, to: now)
        let hasPast = rows.contains { $0.start < now }
        if !hasPast, stream.tvArchive == 1, playlist.kind == .xtream {
            await fetchSimpleDataTable(playlist: playlist, stream: stream, channelKey: key)
            rows = try await programmes(playlistId: playlist.id, channelKey: key, from: from, to: now)
        }
        return rows.filter { $0.start < now }
    }

    // MARK: - JSON fallback (player now/next + catch-up detail)

    /// Ensures the currently-playing channel has now/next when the XMLTV guide is
    /// missing it — pulls `get_short_epg` and stores it.
    func ensureShortEPG(playlist: Playlist, stream: DBLiveStream) async {
        guard playlist.kind == .xtream else { return }
        let idKey = EPGConstants.normalizeChannelKey(stream.epgChannelId)
        let nameKey = EPGConstants.normalizeChannelKey(stream.name)
        let key = storedKey(idKey: idKey, nameKey: nameKey) ?? idKey ?? "#stream:\(stream.streamId)"
        if let existing = snapshot?[key], existing.now != nil { return }
        guard let response = try? await XtreamAPIClient(playlist: playlist).getShortEPG(streamId: stream.streamId) else { return }
        await storeListings(response.epgListings, playlistId: playlist.id, fallbackKey: key)
        await tick()
    }

    private func fetchSimpleDataTable(playlist: Playlist, stream: DBLiveStream, channelKey: String) async {
        guard let response = try? await XtreamAPIClient(playlist: playlist).getSimpleDataTable(streamId: stream.streamId) else { return }
        await storeListings(response.epgListings, playlistId: playlist.id, fallbackKey: channelKey)
    }

    private func storeListings(_ listings: [XtreamEPGListing], playlistId: UUID, fallbackKey: String) async {
        let rows: [DBEPGProgramme] = listings.compactMap { listing in
            guard let start = listing.startTimestamp, let stop = listing.stopTimestamp, stop > start else { return nil }
            let key = EPGConstants.normalizeChannelKey(listing.channelId) ?? fallbackKey
            return DBEPGProgramme(
                playlistId: playlistId, channelKey: key,
                startTs: Int64(start), stopTs: Int64(stop),
                title: listing.decodedTitle ?? "",
                subtitle: nil, desc: listing.decodedDescription,
                category: nil, iconURL: nil, episodeNum: nil
            )
        }
        guard !rows.isEmpty else { return }
        try? await AppDatabase.shared.write { db in
            for r in rows { try r.insert(db) }
        }
    }

    // MARK: - Refresh orchestration

    func refreshIfStale(playlist: Playlist) async {
        guard playlist.epgEnabled else { return }
        let src = try? await AppDatabase.shared.read { db in try DBEPGSource.fetchOne(db, key: playlist.id) }
        if let src = src ?? nil {
            if let last = src.lastSuccessAt, Date().timeIntervalSince(last) < EPGConstants.refreshTTL { return }
            if let attempt = src.fetchedAt, src.lastSuccessAt == nil,
               Date().timeIntervalSince(attempt) < EPGConstants.retryCooldown { return }
        }
        // M3U with no configured source → nothing to do.
        if playlist.kind == .m3u, playlist.effectiveEPGURL == nil { return }
        // Round 14 (B10): defer the network refresh until the first
        // render settles on a cold launch (see `createdAt`). Only the
        // stale path pays this — `forceRefresh` stays immediate.
        await waitForFirstLaunchSettleIfNeeded()
        guard !Task.isCancelled else { return }
        await runRefresh(playlist: playlist)
    }

    /// Sleeps out the remainder of the settle window exactly once
    /// per store lifetime, and only while no snapshot has been
    /// published yet (a warm store with data on screen never waits).
    private func waitForFirstLaunchSettleIfNeeded() async {
        guard !didHonorFirstLaunchSettle else { return }
        didHonorFirstLaunchSettle = true
        guard snapshot == nil else { return }
        let remaining = Self.firstLaunchSettleDelay - Date().timeIntervalSince(createdAt)
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    func forceRefresh(playlist: Playlist) async {
        await runRefresh(playlist: playlist)
    }

    private func runRefresh(playlist: Playlist) async {
        // Dedup concurrent refreshes for the same playlist.
        if let existing = activeRefreshTasks[playlist.id] {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await self.performRefresh(playlist: playlist)
        }
        activeRefreshTasks[playlist.id] = task
        await task.value
        activeRefreshTasks[playlist.id] = nil
    }

    private func performRefresh(playlist: Playlist) async {
        refreshState[playlist.id] = .refreshing(nil)
        let coordinator = EPGRefreshCoordinator()
        do {
            _ = try await coordinator.refresh(playlist: playlist) { [weak self] phase in
                self?.refreshState[playlist.id] = .refreshing(phase)
            }
            refreshState[playlist.id] = .idle
            lastSuccess[playlist.id] = Date()
            if playlist.id == activePlaylistId {
                configured = true
                await rebuildResolution(playlist: playlist)
                await tick()
            }
        } catch is CancellationError {
            refreshState[playlist.id] = .idle
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            refreshState[playlist.id] = .failed(message)
        }
    }

    // MARK: - Helpers

    private func databaseQuestionMarks(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}
