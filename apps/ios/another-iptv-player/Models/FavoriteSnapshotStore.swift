import Foundation

/// Build 61 (B8, R6): title/image snapshots of favorited items,
/// recorded at favorite time. Favorites are DB rows keyed by
/// (playlistId, type, streamId) with no title of their own — the
/// Favorites surface joins them against the catalog, so a favorite
/// whose catalog entry vanishes would silently disappear. With a
/// snapshot it can instead render as "unavailable" (R6: user data
/// is never silently deleted).
///
/// Snapshots are recorded best-effort at the favorite toggle sites;
/// an item favorited before snapshots existed (or via a site that
/// didn't record one) renders with the generic unavailable label.
@MainActor
final class FavoriteSnapshotStore: ObservableObject {
    static let shared = FavoriteSnapshotStore()

    @Published private(set) var version: Int = 0

    private init() {}

    private static func key(playlistId: UUID) -> String { "favsnaps.\(playlistId.uuidString)" }

    private func load(playlistId: UUID) -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: Self.key(playlistId: playlistId)) as? [String: [String]] ?? [:]
    }

    func record(playlistId: UUID, type: String, streamId: Int, title: String, imageURL: String?) {
        var map = load(playlistId: playlistId)
        map["\(type):\(streamId)"] = [title, imageURL ?? ""]
        UserDefaults.standard.set(map, forKey: Self.key(playlistId: playlistId))
        version += 1
    }

    func remove(playlistId: UUID, type: String, streamId: Int) {
        var map = load(playlistId: playlistId)
        map.removeValue(forKey: "\(type):\(streamId)")
        UserDefaults.standard.set(map, forKey: Self.key(playlistId: playlistId))
        version += 1
    }

    func snapshot(playlistId: UUID, type: String, streamId: Int) -> (title: String, imageURL: String?)? {
        guard let pair = load(playlistId: playlistId)["\(type):\(streamId)"], let title = pair.first else { return nil }
        let image = pair.count > 1 ? pair[1] : ""
        return (title, image.isEmpty ? nil : image)
    }
}
