import Foundation
import Combine

/// B2 (build 61, item 12 — channel half): the user's persisted
/// per-category channel order for Xtream live lists. Mirrors
/// `CategoryOrderStore` exactly (same UserDefaults + `@Published`
/// version pattern), keyed by playlist + category instead of
/// playlist + content type. This is tier 3 of the O7 in-category
/// order (pinned → favorites → custom order → alphabetical):
/// `LiveStreamsView.recomputeFilter` applies it to the category's
/// channel array when the sort is the default order.
@MainActor
final class ChannelOrderStore: ObservableObject {
    static let shared = ChannelOrderStore()

    @Published private(set) var version: Int = 0

    private init() {}

    private static func storageKey(playlistId: UUID, categoryId: String) -> String {
        "channel_order.\(playlistId.uuidString).\(categoryId)"
    }

    /// The saved channel ids (as strings of `DBLiveStream.streamId`)
    /// in the user's order; empty when the user has never reordered
    /// this category.
    func orderedIds(playlistId: UUID, categoryId: String) -> [String] {
        UserDefaults.standard.stringArray(
            forKey: Self.storageKey(playlistId: playlistId, categoryId: categoryId)
        ) ?? []
    }

    func hasCustomOrder(playlistId: UUID, categoryId: String) -> Bool {
        !orderedIds(playlistId: playlistId, categoryId: categoryId).isEmpty
    }

    func setOrder(_ ids: [String], playlistId: UUID, categoryId: String) {
        let key = Self.storageKey(playlistId: playlistId, categoryId: categoryId)
        guard orderedIds(playlistId: playlistId, categoryId: categoryId) != ids else { return }
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(ids, forKey: key)
        }
        version &+= 1
    }

    /// Applies the saved order to `items`: items whose id appears in
    /// the saved list come first, in saved sequence; the remainder
    /// keep their incoming order. With no saved order the input is
    /// returned as-is. Duplicate-safe, like `CategoryOrderStore`.
    func applyOrder<T>(_ items: [T], playlistId: UUID, categoryId: String, id: (T) -> String) -> [T] {
        let saved = orderedIds(playlistId: playlistId, categoryId: categoryId)
        guard !saved.isEmpty else { return items }
        let rank = Dictionary(saved.enumerated().map { ($0.element, $0.offset) },
                              uniquingKeysWith: { first, _ in first })
        return items.enumerated()
            .sorted { a, b in
                let ra = rank[id(a.element)] ?? Int.max
                let rb = rank[id(b.element)] ?? Int.max
                if ra != rb { return ra < rb }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// Build 68 (W-C): every saved (categoryId → ordered channel
    /// ids) pair for a playlist, for backup export. Category ids
    /// are not known ahead of time, so the playlist's key prefix
    /// is scanned — the same scan `removeAll` performs.
    func allOrders(playlistId: UUID) -> [String: [String]] {
        let prefix = "channel_order.\(playlistId.uuidString)."
        var result: [String: [String]] = [:]
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let ids = UserDefaults.standard.stringArray(forKey: key) ?? []
            if !ids.isEmpty {
                result[String(key.dropFirst(prefix.count))] = ids
            }
        }
        return result
    }

    /// Build 68 (W-C): applies imported channel orders (backup
    /// restore). Like `CategoryOrderStore`, an order is one
    /// authoritative list per category, so the imported list
    /// REPLACES the local one for every category the backup
    /// carries, through `setOrder` (which bumps `version` per
    /// change). Categories absent from the import are untouched.
    func applyImportedOrders(_ ordersByCategory: [String: [String]], playlistId: UUID) {
        for (categoryId, ids) in ordersByCategory {
            setOrder(ids, playlistId: playlistId, categoryId: categoryId)
        }
    }

    /// Called when a playlist is deleted — removes every saved
    /// channel order belonging to it (category ids are not known
    /// ahead of time, so the playlist's key prefix is scanned).
    func removeAll(playlistId: UUID) {
        let prefix = "channel_order.\(playlistId.uuidString)."
        var changed = false
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
            changed = true
        }
        if changed { version &+= 1 }
    }
}
