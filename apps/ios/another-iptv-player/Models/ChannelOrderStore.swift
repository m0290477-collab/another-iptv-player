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
        Self.applySavedOrder(items, saved: orderedIds(playlistId: playlistId, categoryId: categoryId), id: id)
    }

    /// Build 75 (performance): the ranking itself, split out as a
    /// nonisolated static so off-main catalog passes (the Live tab's
    /// detached recompute) can apply a saved order snapshotted on
    /// the main actor without hopping back per category. Semantics
    /// are exactly `applyOrder`'s: saved ids first in saved
    /// sequence, the remainder in incoming order, duplicate-safe.
    nonisolated static func applySavedOrder<T>(_ items: [T], saved: [String], id: (T) -> String) -> [T] {
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
