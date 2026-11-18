import Foundation
import Combine

/// Build 61 (B8, H2): per-CHANNEL hide, the channel-level sibling of
/// `HiddenCategoryStore` (which hides whole categories and is untouched).
/// Same store family and pattern: UserDefaults arrays per playlist, a
/// `@Published version` bump on every mutation. Hidden channels are
/// filtered out of the live lists; the hide is reversible from the same
/// menus that set it (the menu item becomes Unhide while hidden items
/// are shown via the category's "show hidden" path in settings is out of
/// scope — unhide happens from Favorites/search surfaces that still
/// resolve the channel, and from this store's `removeAll` on playlist
/// deletion).
@MainActor
final class HiddenChannelStore: ObservableObject {
    static let shared = HiddenChannelStore()

    @Published private(set) var version: Int = 0

    private init() {}

    private static func xtreamKey(playlistId: UUID) -> String {
        "hidden_channels.\(playlistId.uuidString)"
    }

    private static func m3uKey(playlistId: UUID) -> String {
        "hidden_m3u_channels.\(playlistId.uuidString)"
    }

    // MARK: - Xtream

    func hiddenIds(playlistId: UUID) -> Set<Int> {
        Set(UserDefaults.standard.array(forKey: Self.xtreamKey(playlistId: playlistId)) as? [Int] ?? [])
    }

    func isHidden(playlistId: UUID, streamId: Int) -> Bool {
        hiddenIds(playlistId: playlistId).contains(streamId)
    }

    func setHidden(_ hidden: Bool, playlistId: UUID, streamId: Int) {
        var current = hiddenIds(playlistId: playlistId)
        let changed = hidden ? current.insert(streamId).inserted : (current.remove(streamId) != nil)
        guard changed else { return }
        UserDefaults.standard.set(Array(current), forKey: Self.xtreamKey(playlistId: playlistId))
        version &+= 1
    }

    // MARK: - M3U

    func hiddenM3UIds(playlistId: UUID) -> Set<String> {
        Self.hiddenM3UIds(playlistId: playlistId)
    }

    /// Non-isolated read for off-main list computations.
    nonisolated static func hiddenM3UIds(playlistId: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: m3uKey(playlistId: playlistId)) ?? [])
    }

    func isHiddenM3U(playlistId: UUID, channelId: String) -> Bool {
        hiddenM3UIds(playlistId: playlistId).contains(channelId)
    }

    func setHiddenM3U(_ hidden: Bool, playlistId: UUID, channelId: String) {
        var current = hiddenM3UIds(playlistId: playlistId)
        let changed = hidden ? current.insert(channelId).inserted : (current.remove(channelId) != nil)
        guard changed else { return }
        UserDefaults.standard.set(Array(current), forKey: Self.m3uKey(playlistId: playlistId))
        version &+= 1
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
