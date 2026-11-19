import Foundation
import Combine

/// Build 61 (B8, R-pack): first-seen tracking for "new content".
///
/// R1: every catalog item (live channel, movie, series, series
/// EPISODE) records the timestamp it was first seen in a refresh, per
/// playlist. Storage is UserDefaults (no GRDB schema change — the
/// store pattern the app already uses for pins/hidden/watchlist):
/// one `[itemKey: epochSeconds]` dictionary per playlist plus an
/// "opened" set and a baseline flag.
///
/// BASELINE RULE (R1): the first recorded refresh for a playlist
/// establishes the baseline SILENTLY — every item in it is stamped
/// with a backdated sentinel (epoch 0) so it can never badge, and no
/// what's-new counts are produced. Items become "new" only from the
/// SECOND refresh onward.
///
/// Item keys: "live:<streamId>", "vod:<streamId>", "series:<id>",
/// "episode:<seriesId>:<episodeId>", "m3u:<channelId>".
///
/// R5: a series is "new" when the series itself is new OR any of its
/// episodes is new (episode keys carry the series id as a prefix, so
/// the rollup is a prefix scan over the series' own episode keys —
/// the per-series episode key set is tracked alongside).
///
/// Build 63 (item 14): PERFORMANCE REWRITE of the storage layer —
/// semantics unchanged. On build 62, tapping refresh froze the
/// whole app until the watchdog killed it: every refresh funnel
/// re-DESERIALIZED the entire `[String: Double]` map from
/// UserDefaults on the main thread, diffed, and SERIALIZED it back,
/// and every badge check (`isNew*`, called per rendered row)
/// deserialized the whole map AGAIN. On a ~37k-item catalog that
/// is a multi-second main-thread block per refresh, multiplied by
/// per-row reads. Now: each playlist's state is loaded ONCE into
/// memory (same UserDefaults keys and format — existing data is
/// read as-is, no migration), all reads/writes hit the in-memory
/// snapshot (badge checks are O(1)), and persistence is a debounced
/// snapshot write performed on a private background queue (deltas
/// are coalesced by the debounce; the on-disk format is identical).
@MainActor
final class FirstSeenStore: ObservableObject {
    static let shared = FirstSeenStore()

    @Published private(set) var version: Int = 0

    private init() {}

    /// R2: badges live for 7 days from first sight.
    static let badgeWindow: TimeInterval = 7 * 24 * 3600

    private static func seenKey(playlistId: UUID) -> String { "firstseen.map.\(playlistId.uuidString)" }
    private static func openedKey(playlistId: UUID) -> String { "firstseen.opened.\(playlistId.uuidString)" }
    private static func baselineKey(playlistId: UUID) -> String { "firstseen.baseline.\(playlistId.uuidString)" }
    private static func pendingKey(playlistId: UUID) -> String { "firstseen.pending.\(playlistId.uuidString)" }

    // MARK: - In-memory state (build 63, item 14)

    /// One playlist's first-seen state, loaded from UserDefaults
    /// exactly once per process. All public API reads/writes this
    /// snapshot; UserDefaults is only the persistence layer.
    private struct PlaylistState {
        var seen: [String: Double] = [:]
        var opened: Set<String> = []
        var pending: [String: Int] = [:]
        var hasBaseline = false
        /// Episode keys grouped by series id, built once when the
        /// state loads and maintained by `record` — the R5 series
        /// rollup (`isNewSeries`, the series branch of
        /// `markOpened`) reads ONLY the series' own episode keys
        /// instead of prefix-scanning the whole map per call.
        /// Semantics identical to the prefix scan: the key format
        /// "episode:<seriesId>:<episodeId>" parses the id up to the
        /// second colon, so series 12 can never see series 123's
        /// episodes.
        var episodeKeysBySeries: [Int: [String]] = [:]
        /// Bumped by `removeAll` so a persist snapshot scheduled
        /// before the removal can never resurrect deleted data.
        var generation = 0
    }

    /// The series id embedded in an "episode:<seriesId>:<episodeId>"
    /// key, or nil for any other key shape.
    private static func episodeSeriesId(fromKey key: String) -> Int? {
        guard key.hasPrefix("episode:") else { return nil }
        let rest = key.dropFirst("episode:".count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        return Int(rest[..<colon])
    }

    private static func buildEpisodeIndex(seen: [String: Double]) -> [Int: [String]] {
        var index: [Int: [String]] = [:]
        for key in seen.keys {
            if let seriesId = episodeSeriesId(fromKey: key) {
                index[seriesId, default: []].append(key)
            }
        }
        return index
    }

    private var states: [UUID: PlaylistState] = [:]
    private var persistTasks: [UUID: Task<Void, Never>] = [:]

    /// Serial queue that performs the actual UserDefaults writes
    /// (plist serialization of a ~37k-entry map is exactly the
    /// work that must never run on the main thread again).
    private static let persistenceQueue = DispatchQueue(label: "superx.firstseen.persistence")

    private func state(for playlistId: UUID) -> PlaylistState {
        if let cached = states[playlistId] { return cached }
        let defaults = UserDefaults.standard
        let seenMap = defaults.dictionary(forKey: Self.seenKey(playlistId: playlistId)) as? [String: Double] ?? [:]
        let loaded = PlaylistState(
            seen: seenMap,
            opened: Set(defaults.stringArray(forKey: Self.openedKey(playlistId: playlistId)) ?? []),
            pending: defaults.dictionary(forKey: Self.pendingKey(playlistId: playlistId)) as? [String: Int] ?? [:],
            hasBaseline: defaults.bool(forKey: Self.baselineKey(playlistId: playlistId)),
            episodeKeysBySeries: Self.buildEpisodeIndex(seen: seenMap)
        )
        states[playlistId] = loaded
        return loaded
    }

    private func updateState(for playlistId: UUID, _ mutate: (inout PlaylistState) -> Void) {
        var current = state(for: playlistId)
        mutate(&current)
        states[playlistId] = current
    }

    /// Debounced persistence: mutations within the window coalesce
    /// into ONE snapshot write. The snapshot is taken from memory
    /// when the debounce fires (so it always carries the latest
    /// state), then serialized + stored off the main thread.
    private func schedulePersist(playlistId: UUID) {
        persistTasks[playlistId]?.cancel()
        let generation = state(for: playlistId).generation
        persistTasks[playlistId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.state(for: playlistId)
            guard snapshot.generation == generation else { return }
            let seen = snapshot.seen
            let opened = Array(snapshot.opened)
            let pending = snapshot.pending
            let hasBaseline = snapshot.hasBaseline
            Self.persistenceQueue.async {
                let defaults = UserDefaults.standard
                defaults.set(seen, forKey: Self.seenKey(playlistId: playlistId))
                defaults.set(opened, forKey: Self.openedKey(playlistId: playlistId))
                defaults.set(pending, forKey: Self.pendingKey(playlistId: playlistId))
                defaults.set(hasBaseline, forKey: Self.baselineKey(playlistId: playlistId))
            }
        }
    }

    // MARK: - Raw storage

    func hasBaseline(playlistId: UUID) -> Bool {
        state(for: playlistId).hasBaseline
    }

    // MARK: - R1 recording

    /// Records one refresh batch for a playlist. Returns the counts of
    /// genuinely new items per type (empty on the baseline batch).
    /// Episode items roll up: a batch with new episodes also counts
    /// their series once under "series" ONLY for the what's-new
    /// summary when the series itself is not new — the caller-facing
    /// counts here keep episodes under "episode" and the banner copy
    /// presents live/vod/series counts; episode-only batches surface
    /// through the series badge (R5) and the Recently Added screen.
    @discardableResult
    func record(playlistId: UUID, itemKeys: [String], now: Date = Date()) -> [String: Int] {
        var result: [String: Int] = [:]
        var didChange = false
        updateState(for: playlistId) { state in
            guard state.hasBaseline else {
                // Baseline: stamp everything with the backdated sentinel.
                for key in itemKeys where state.seen[key] == nil {
                    state.seen[key] = 0
                    if let seriesId = Self.episodeSeriesId(fromKey: key) {
                        state.episodeKeysBySeries[seriesId, default: []].append(key)
                    }
                }
                state.hasBaseline = true
                didChange = true
                return
            }
            var counts: [String: Int] = [:]
            for key in itemKeys where state.seen[key] == nil {
                state.seen[key] = now.timeIntervalSince1970
                if let seriesId = Self.episodeSeriesId(fromKey: key) {
                    state.episodeKeysBySeries[seriesId, default: []].append(key)
                }
                didChange = true
                let type = key.split(separator: ":").first.map(String.init) ?? "live"
                counts[type, default: 0] += 1
            }
            if didChange {
                for (type, count) in counts { state.pending[type, default: 0] += count }
            }
            result = counts
        }
        if didChange {
            schedulePersist(playlistId: playlistId)
            version &+= 1
        }
        return result
    }

    /// Convenience for the content-store hook: builds the key list
    /// from the loaded Xtream catalog arrays.
    @discardableResult
    func recordCatalog(playlistId: UUID, liveIds: [Int], vodIds: [Int], seriesIds: [Int], now: Date = Date()) -> [String: Int] {
        var keys: [String] = []
        keys.reserveCapacity(liveIds.count + vodIds.count + seriesIds.count)
        keys += liveIds.map { "live:\($0)" }
        keys += vodIds.map { "vod:\($0)" }
        keys += seriesIds.map { "series:\($0)" }
        return record(playlistId: playlistId, itemKeys: keys, now: now)
    }

    // MARK: - R2 badge state

    /// True when the item was first seen within the badge window and
    /// has not been opened yet. Baseline items (stamp 0) never badge.
    func isNew(playlistId: UUID, itemKey: String, now: Date = Date()) -> Bool {
        let state = state(for: playlistId)
        guard let stamp = state.seen[itemKey], stamp > 0 else { return false }
        if state.opened.contains(itemKey) { return false }
        return now.timeIntervalSince1970 - stamp < Self.badgeWindow
    }

    func isNewLive(playlistId: UUID, streamId: Int) -> Bool { isNew(playlistId: playlistId, itemKey: "live:\(streamId)") }
    func isNewVOD(playlistId: UUID, streamId: Int) -> Bool { isNew(playlistId: playlistId, itemKey: "vod:\(streamId)") }

    /// R5 rollup: the series badges when it is itself new or any of
    /// its recorded episodes is new.
    func isNewSeries(playlistId: UUID, seriesId: Int) -> Bool {
        if isNew(playlistId: playlistId, itemKey: "series:\(seriesId)") { return true }
        let state = state(for: playlistId)
        let now = Date().timeIntervalSince1970
        for key in state.episodeKeysBySeries[seriesId] ?? [] {
            guard let stamp = state.seen[key] else { continue }
            if stamp > 0, !state.opened.contains(key), now - stamp < Self.badgeWindow { return true }
        }
        return false
    }

    /// All currently-badged item keys for a playlist (Recently Added
    /// screen + Home row source), newest first.
    func newItemKeys(playlistId: UUID, now: Date = Date()) -> [(key: String, firstSeen: Date)] {
        let state = state(for: playlistId)
        let cutoff = now.timeIntervalSince1970 - Self.badgeWindow
        var result: [(String, Date)] = []
        for (key, stamp) in state.seen where stamp > cutoff && !state.opened.contains(key) {
            result.append((key, Date(timeIntervalSince1970: stamp)))
        }
        return result.sorted { $0.1 > $1.1 }
    }

    /// Opening an item clears its badge (R2). For a series, opening
    /// also clears its episodes' badges (the rollup source).
    func markOpened(playlistId: UUID, itemKey: String) {
        updateState(for: playlistId) { state in
            state.opened.insert(itemKey)
            if itemKey.hasPrefix("series:"),
               let seriesId = Int(itemKey.dropFirst("series:".count)) {
                for key in state.episodeKeysBySeries[seriesId] ?? [] {
                    state.opened.insert(key)
                }
            }
        }
        schedulePersist(playlistId: playlistId)
        version &+= 1
    }

    // MARK: - R4 pending what's-new counts

    /// Accumulated new-item counts not yet shown in the Home banner:
    /// `[type: count]`. Shown once per refresh batch (R4): the banner
    /// calls `clearPending` when it is dismissed or tapped.
    func pendingCounts(playlistId: UUID) -> [String: Int] {
        state(for: playlistId).pending
    }

    func clearPending(playlistId: UUID) {
        updateState(for: playlistId) { $0.pending = [:] }
        schedulePersist(playlistId: playlistId)
        version &+= 1
    }

    func removeAll(playlistId: UUID) {
        persistTasks[playlistId]?.cancel()
        persistTasks[playlistId] = nil
        updateState(for: playlistId) { state in
            state.seen = [:]
            state.opened = []
            state.pending = [:]
            state.hasBaseline = false
            state.episodeKeysBySeries = [:]
            state.generation &+= 1
        }
        // Removal rides the SAME serial persistence queue, so it
        // executes after any snapshot write already enqueued and
        // can never be overwritten by one.
        Self.persistenceQueue.async {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: Self.seenKey(playlistId: playlistId))
            defaults.removeObject(forKey: Self.openedKey(playlistId: playlistId))
            defaults.removeObject(forKey: Self.baselineKey(playlistId: playlistId))
            defaults.removeObject(forKey: Self.pendingKey(playlistId: playlistId))
        }
        version &+= 1
    }
}
