import Foundation
import Combine

/// Build 61 (B8, C10): pinned live channels, per playlist.
///
/// Persistence mirrors `HiddenCategoryStore` / `WatchlistStore`:
/// UserDefaults arrays keyed by playlist, with a `@Published version`
/// bump on every mutation so SwiftUI surfaces refresh. Xtream pins are
/// streamIds (Int); M3U pins are the channel row ids (String) — the two
/// catalogs have different identity types, so they get separate keys,
/// exactly like the two favorites tables (DBFavorite / DBM3UFavorite).
///
/// Ordering (SPEC §4.5 O7): pinned → favorites → user's custom order →
/// alphabetical fallback. `ChannelOrdering` below is the ONE place that
/// tiering is applied to a live list.
@MainActor
final class PinnedChannelStore: ObservableObject {
    static let shared = PinnedChannelStore()

    @Published private(set) var version: Int = 0

    private init() {}

    private static func xtreamKey(playlistId: UUID) -> String {
        "pinned.live.\(playlistId.uuidString)"
    }

    private static func m3uKey(playlistId: UUID) -> String {
        "pinned.m3u.\(playlistId.uuidString)"
    }

    // MARK: - Xtream

    func pinnedIds(playlistId: UUID) -> Set<Int> {
        let arr = UserDefaults.standard.array(forKey: Self.xtreamKey(playlistId: playlistId)) as? [Int] ?? []
        return Set(arr)
    }

    func isPinned(playlistId: UUID, streamId: Int) -> Bool {
        pinnedIds(playlistId: playlistId).contains(streamId)
    }

    func setPinned(_ pinned: Bool, playlistId: UUID, streamId: Int) {
        var current = pinnedIds(playlistId: playlistId)
        let changed = pinned ? current.insert(streamId).inserted : (current.remove(streamId) != nil)
        guard changed else { return }
        UserDefaults.standard.set(Array(current), forKey: Self.xtreamKey(playlistId: playlistId))
        version &+= 1
    }

    func toggle(playlistId: UUID, streamId: Int) {
        setPinned(!isPinned(playlistId: playlistId, streamId: streamId), playlistId: playlistId, streamId: streamId)
    }

    // MARK: - M3U

    func pinnedM3UIds(playlistId: UUID) -> Set<String> {
        Self.pinnedM3UIds(playlistId: playlistId)
    }

    /// Non-isolated read for off-main list computations.
    nonisolated static func pinnedM3UIds(playlistId: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: m3uKey(playlistId: playlistId)) ?? [])
    }

    func isPinnedM3U(playlistId: UUID, channelId: String) -> Bool {
        pinnedM3UIds(playlistId: playlistId).contains(channelId)
    }

    func setPinnedM3U(_ pinned: Bool, playlistId: UUID, channelId: String) {
        var current = pinnedM3UIds(playlistId: playlistId)
        let changed = pinned ? current.insert(channelId).inserted : (current.remove(channelId) != nil)
        guard changed else { return }
        UserDefaults.standard.set(Array(current), forKey: Self.m3uKey(playlistId: playlistId))
        version &+= 1
    }

    func toggleM3U(playlistId: UUID, channelId: String) {
        setPinnedM3U(!isPinnedM3U(playlistId: playlistId, channelId: channelId), playlistId: playlistId, channelId: channelId)
    }

    // MARK: - Cleanup

    func removeAll(playlistId: UUID) {
        var changed = false
        for key in [Self.xtreamKey(playlistId: playlistId), Self.m3uKey(playlistId: playlistId)] {
            if UserDefaults.standard.object(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
                changed = true
            }
        }
        if changed { version &+= 1 }
    }
}

/// Build 61 (B8, C10 / O7): the in-category live ordering tiers.
///
/// Applied ONLY when the view's sort is the default (provider/custom)
/// order — an explicit user sort (name etc.) replaces tier 3 per O7's
/// Q12 note, and tiers 1–2 (pinned, favorites) still hold in front of
/// it. The sort is stable: within a tier the incoming order is kept.
nonisolated enum ChannelOrdering {
    static func pinnedFavoritesFirst<T>(
        _ items: [T],
        pinned: Set<Int>,
        favorites: Set<Int>,
        streamId: (T) -> Int
    ) -> [T] {
        func tier(_ item: T) -> Int {
            let id = streamId(item)
            if pinned.contains(id) { return 0 }
            if favorites.contains(id) { return 1 }
            return 2
        }
        return items.enumerated()
            .sorted { a, b in
                let ta = tier(a.element), tb = tier(b.element)
                if ta != tb { return ta < tb }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// M3U variant: String channel ids, pins only (M3U favorites
    /// live in their own store/surface).
    static func pinnedFirstM3U(
        _ items: [DBM3UChannel],
        pinned: Set<String>
    ) -> [DBM3UChannel] {
        items.enumerated()
            .sorted { a, b in
                let pa = pinned.contains(a.element.id) ? 0 : 1
                let pb = pinned.contains(b.element.id) ? 0 : 1
                if pa != pb { return pa < pb }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}
