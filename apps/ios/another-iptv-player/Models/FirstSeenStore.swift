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

    // MARK: - Raw storage

    private func seenMap(playlistId: UUID) -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: Self.seenKey(playlistId: playlistId)) as? [String: Double] ?? [:]
    }

    private func openedSet(playlistId: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.openedKey(playlistId: playlistId)) ?? [])
    }

    func hasBaseline(playlistId: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: Self.baselineKey(playlistId: playlistId))
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
        var map = seenMap(playlistId: playlistId)
        guard hasBaseline(playlistId: playlistId) else {
            // Baseline: stamp everything with the backdated sentinel.
            for key in itemKeys where map[key] == nil { map[key] = 0 }
            UserDefaults.standard.set(map, forKey: Self.seenKey(playlistId: playlistId))
            UserDefaults.standard.set(true, forKey: Self.baselineKey(playlistId: playlistId))
            version &+= 1
            return [:]
        }
        var counts: [String: Int] = [:]
        var changed = false
        for key in itemKeys where map[key] == nil {
            map[key] = now.timeIntervalSince1970
            changed = true
            let type = key.split(separator: ":").first.map(String.init) ?? "live"
            counts[type, default: 0] += 1
        }
        if changed {
            UserDefaults.standard.set(map, forKey: Self.seenKey(playlistId: playlistId))
            addPending(playlistId: playlistId, counts: counts)
            version &+= 1
        }
        return counts
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
        guard let stamp = seenMap(playlistId: playlistId)[itemKey], stamp > 0 else { return false }
        if openedSet(playlistId: playlistId).contains(itemKey) { return false }
        return now.timeIntervalSince1970 - stamp < Self.badgeWindow
    }

    func isNewLive(playlistId: UUID, streamId: Int) -> Bool { isNew(playlistId: playlistId, itemKey: "live:\(streamId)") }
    func isNewVOD(playlistId: UUID, streamId: Int) -> Bool { isNew(playlistId: playlistId, itemKey: "vod:\(streamId)") }

    /// R5 rollup: the series badges when it is itself new or any of
    /// its recorded episodes is new.
    func isNewSeries(playlistId: UUID, seriesId: Int) -> Bool {
        if isNew(playlistId: playlistId, itemKey: "series:\(seriesId)") { return true }
        let prefix = "episode:\(seriesId):"
        let map = seenMap(playlistId: playlistId)
        let opened = openedSet(playlistId: playlistId)
        let now = Date().timeIntervalSince1970
        for (key, stamp) in map where key.hasPrefix(prefix) {
            if stamp > 0, !opened.contains(key), now - stamp < Self.badgeWindow { return true }
        }
        return false
    }

    /// All currently-badged item keys for a playlist (Recently Added
    /// screen + Home row source), newest first.
    func newItemKeys(playlistId: UUID, now: Date = Date()) -> [(key: String, firstSeen: Date)] {
        let map = seenMap(playlistId: playlistId)
        let opened = openedSet(playlistId: playlistId)
        let cutoff = now.timeIntervalSince1970 - Self.badgeWindow
        var result: [(String, Date)] = []
        for (key, stamp) in map where stamp > cutoff && !opened.contains(key) {
            result.append((key, Date(timeIntervalSince1970: stamp)))
        }
        return result.sorted { $0.1 > $1.1 }
    }

    /// Opening an item clears its badge (R2). For a series, opening
    /// also clears its episodes' badges (the rollup source).
    func markOpened(playlistId: UUID, itemKey: String) {
        var opened = openedSet(playlistId: playlistId)
        opened.insert(itemKey)
        if itemKey.hasPrefix("series:") {
            let seriesId = itemKey.dropFirst("series:".count)
            let prefix = "episode:\(seriesId):"
            for key in seenMap(playlistId: playlistId).keys where key.hasPrefix(prefix) {
                opened.insert(key)
            }
        }
        UserDefaults.standard.set(Array(opened), forKey: Self.openedKey(playlistId: playlistId))
        version &+= 1
    }

    // MARK: - R4 pending what's-new counts

    /// Accumulated new-item counts not yet shown in the Home banner:
    /// `[type: count]`. Shown once per refresh batch (R4): the banner
    /// calls `clearPending` when it is dismissed or tapped.
    func pendingCounts(playlistId: UUID) -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: Self.pendingKey(playlistId: playlistId)) as? [String: Int] ?? [:]
    }

    private func addPending(playlistId: UUID, counts: [String: Int]) {
        guard !counts.isEmpty else { return }
        var pending = pendingCounts(playlistId: playlistId)
        for (type, count) in counts { pending[type, default: 0] += count }
        UserDefaults.standard.set(pending, forKey: Self.pendingKey(playlistId: playlistId))
    }

    func clearPending(playlistId: UUID) {
        UserDefaults.standard.removeObject(forKey: Self.pendingKey(playlistId: playlistId))
        version &+= 1
    }

    func removeAll(playlistId: UUID) {
        UserDefaults.standard.removeObject(forKey: Self.seenKey(playlistId: playlistId))
        UserDefaults.standard.removeObject(forKey: Self.openedKey(playlistId: playlistId))
        UserDefaults.standard.removeObject(forKey: Self.baselineKey(playlistId: playlistId))
        UserDefaults.standard.removeObject(forKey: Self.pendingKey(playlistId: playlistId))
        version &+= 1
    }
}
