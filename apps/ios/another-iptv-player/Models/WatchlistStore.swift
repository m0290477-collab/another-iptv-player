import Foundation
import Combine

/// Round 15 (C7): the movie Watchlist — a bookmark list SEPARATE from
/// Favorites (different intent: "watch later" vs "loved it"; separate
/// state, separate surface on the Movies tab).
///
/// Persistence mirrors the app's other lightweight per-playlist stores
/// (`HiddenCategoryStore`): a UserDefaults string/int array keyed by
/// playlist, with a `@Published version` bump on every mutation so
/// SwiftUI surfaces refresh. Favorites themselves are DB-backed
/// (`DBFavorite`), but a parallel DB table would need a schema
/// migration in Persistence.swift; the watchlist carries no relational
/// data (just catalog ids), so the UserDefaults store pattern is the
/// minimal honest mirror.
@MainActor
final class WatchlistStore: ObservableObject {
    static let shared = WatchlistStore()

    @Published private(set) var version: Int = 0

    private init() {}

    private static func storageKey(playlistId: UUID) -> String {
        "watchlist.vod.\(playlistId.uuidString)"
    }

    /// Watchlisted movie streamIds for a playlist, in insertion order.
    func movieIds(playlistId: UUID) -> [Int] {
        UserDefaults.standard.array(forKey: Self.storageKey(playlistId: playlistId)) as? [Int] ?? []
    }

    func contains(playlistId: UUID, streamId: Int) -> Bool {
        movieIds(playlistId: playlistId).contains(streamId)
    }

    func toggle(playlistId: UUID, streamId: Int) {
        var ids = movieIds(playlistId: playlistId)
        if let idx = ids.firstIndex(of: streamId) {
            ids.remove(at: idx)
        } else {
            ids.append(streamId)
        }
        UserDefaults.standard.set(ids, forKey: Self.storageKey(playlistId: playlistId))
        version &+= 1
    }

    /// Round 17 (R17-2/R17-5): drop one playlist's whole watchlist
    /// (shared account-data deletion path).
    func removeAll(playlistId: UUID) {
        let key = Self.storageKey(playlistId: playlistId)
        guard UserDefaults.standard.object(forKey: key) != nil else { return }
        UserDefaults.standard.removeObject(forKey: key)
        version &+= 1
    }
}
