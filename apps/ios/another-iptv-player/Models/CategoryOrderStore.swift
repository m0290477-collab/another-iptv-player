import Foundation
import Combine

/// Stores the user-chosen category order per playlist + content type in
/// UserDefaults (Strong 8K model, spec section 2.3: categories can be
/// drag-reordered, not only shown/hidden). Mirrors `HiddenCategoryStore`:
/// every write bumps `@Published` `version`, so views observing the store
/// refresh automatically.
@MainActor
final class CategoryOrderStore: ObservableObject {
    static let shared = CategoryOrderStore()

    @Published private(set) var version: Int = 0

    private init() {}

    private static func storageKey(playlistId: UUID, type: String) -> String {
        "category_order.\(playlistId.uuidString).\(type)"
    }

    /// The saved category ids in the user's order; empty when the user
    /// has never reordered this playlist/type.
    func orderedIds(playlistId: UUID, type: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: Self.storageKey(playlistId: playlistId, type: type)) ?? []
    }

    func setOrder(_ ids: [String], playlistId: UUID, type: String) {
        let key = Self.storageKey(playlistId: playlistId, type: type)
        guard orderedIds(playlistId: playlistId, type: type) != ids else { return }
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(ids, forKey: key)
        }
        version &+= 1
    }

    /// Applies the saved order to `items`: items whose id appears in the
    /// saved list come first, in saved sequence; the remainder keep their
    /// incoming order. With no saved order the input is returned as-is.
    func applyOrder<T>(_ items: [T], playlistId: UUID, type: String, id: (T) -> String) -> [T] {
        let saved = orderedIds(playlistId: playlistId, type: type)
        guard !saved.isEmpty else { return items }
        let rank = Dictionary(uniqueKeysWithValues: saved.enumerated().map { ($0.element, $0.offset) })
        return items.enumerated()
            .sorted { a, b in
                let ra = rank[id(a.element)] ?? Int.max
                let rb = rank[id(b.element)] ?? Int.max
                if ra != rb { return ra < rb }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// Called when a playlist is deleted — removes this playlist's saved
    /// order for every content type.
    func removeAll(playlistId: UUID) {
        var changed = false
        for type in ["live", "vod", "series", "m3u"] {
            let key = Self.storageKey(playlistId: playlistId, type: type)
            if UserDefaults.standard.object(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
                changed = true
            }
        }
        if changed { version &+= 1 }
    }
}
