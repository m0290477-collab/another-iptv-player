import Foundation
import Combine

/// Build 61 (B8, J1 + R6): user-created favorite groups.
///
/// A group is a named list of catalog items (live channel / movie /
/// series). Each membership stores a SNAPSHOT of the item's identity
/// plus its display title and image URL at add time. The snapshot is
/// what makes R6 possible: when an item later vanishes from the
/// catalog, the group still renders it — marked "unavailable" —
/// instead of silently dropping the user's data. Deleting a group
/// deletes only the group; content is never touched.
///
/// Persistence mirrors the other lightweight stores: one Codable
/// payload in UserDefaults per playlist under the `favgroups.` key
/// prefix (registered in `ICloudSyncService`'s synced-prefix list and
/// in B3's `BackupService` library scope), with a `@Published version`
/// bump per mutation.
@MainActor
final class FavoriteGroupStore: ObservableObject {
    static let shared = FavoriteGroupStore()

    @Published private(set) var version: Int = 0

    private init() {}

    // MARK: - Model

    struct Item: Codable, Equatable, Identifiable {
        /// "live" | "vod" | "series" | "m3uLive"
        var type: String
        /// Catalog identity as a string: Xtream stream/series id, or
        /// the M3U channel row id for "m3uLive".
        var itemId: String
        /// Display snapshot captured when the item was added (R6).
        var title: String
        var imageURL: String?

        var id: String { "\(type)|\(itemId)" }
    }

    struct Group: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var items: [Item] = []
    }

    // MARK: - Storage

    static func storageKey(playlistId: UUID) -> String {
        "favgroups.\(playlistId.uuidString)"
    }

    func groups(playlistId: UUID) -> [Group] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey(playlistId: playlistId)),
              let decoded = try? JSONDecoder().decode([Group].self, from: data) else { return [] }
        return decoded
    }

    private func save(_ groups: [Group], playlistId: UUID) {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: Self.storageKey(playlistId: playlistId))
        }
        version &+= 1
    }

    // MARK: - Group CRUD

    @discardableResult
    func createGroup(playlistId: UUID, name: String) -> Group {
        let group = Group(id: UUID().uuidString, name: name)
        var all = groups(playlistId: playlistId)
        all.append(group)
        save(all, playlistId: playlistId)
        return group
    }

    func renameGroup(playlistId: UUID, groupId: String, name: String) {
        var all = groups(playlistId: playlistId)
        guard let idx = all.firstIndex(where: { $0.id == groupId }) else { return }
        all[idx].name = name
        save(all, playlistId: playlistId)
    }

    /// Deletes the group ONLY — its items stay in the catalog, in
    /// favorites, and in every other group.
    func deleteGroup(playlistId: UUID, groupId: String) {
        var all = groups(playlistId: playlistId)
        all.removeAll { $0.id == groupId }
        save(all, playlistId: playlistId)
    }

    // MARK: - Membership

    func contains(playlistId: UUID, groupId: String, item: Item) -> Bool {
        groups(playlistId: playlistId).first(where: { $0.id == groupId })?.items.contains(item) ?? false
    }

    func toggle(playlistId: UUID, groupId: String, item: Item) {
        var all = groups(playlistId: playlistId)
        guard let idx = all.firstIndex(where: { $0.id == groupId }) else { return }
        if let existing = all[idx].items.firstIndex(of: item) {
            all[idx].items.remove(at: existing)
        } else {
            all[idx].items.append(item)
        }
        save(all, playlistId: playlistId)
    }

    func removeItem(playlistId: UUID, groupId: String, item: Item) {
        var all = groups(playlistId: playlistId)
        guard let idx = all.firstIndex(where: { $0.id == groupId }) else { return }
        all[idx].items.removeAll { $0 == item }
        save(all, playlistId: playlistId)
    }

    /// Union-merge used by backup import: groups matched by id, items
    /// unioned by identity; new groups appended.
    func mergeImported(_ imported: [Group], playlistId: UUID) {
        var all = groups(playlistId: playlistId)
        for group in imported {
            if let idx = all.firstIndex(where: { $0.id == group.id }) {
                for item in group.items where !all[idx].items.contains(item) {
                    all[idx].items.append(item)
                }
            } else {
                all.append(group)
            }
        }
        save(all, playlistId: playlistId)
    }

    func removeAll(playlistId: UUID) {
        UserDefaults.standard.removeObject(forKey: Self.storageKey(playlistId: playlistId))
        version &+= 1
    }
}
