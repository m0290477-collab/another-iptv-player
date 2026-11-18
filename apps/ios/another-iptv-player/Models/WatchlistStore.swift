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
        var changed = false
        for key in [Self.storageKey(playlistId: playlistId),
                    Self.seriesStorageKey(playlistId: playlistId),
                    Self.snapshotKey(playlistId: playlistId)] {
            if UserDefaults.standard.object(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
                changed = true
            }
        }
        if changed { version &+= 1 }
    }

    // MARK: - Build 61 (B8, C2): series watch-later + R6 snapshots
    //
    // Watch Later was movie-only. Series get the SAME store (one
    // Watch Later concept, O6) under a parallel key, following the
    // exact pattern B3's BackupService already uses for the movie
    // list ("watchlist.vod.<playlistId>" is in the S5 backup scope
    // and the iCloud KVS whitelist; "watchlist.series.<playlistId>"
    // is registered in both by B8).

    private static func seriesStorageKey(playlistId: UUID) -> String {
        "watchlist.series.\(playlistId.uuidString)"
    }

    func seriesIds(playlistId: UUID) -> [Int] {
        UserDefaults.standard.array(forKey: Self.seriesStorageKey(playlistId: playlistId)) as? [Int] ?? []
    }

    func containsSeries(playlistId: UUID, seriesId: Int) -> Bool {
        seriesIds(playlistId: playlistId).contains(seriesId)
    }

    func toggleSeries(playlistId: UUID, seriesId: Int, title: String? = nil, imageURL: String? = nil) {
        var ids = seriesIds(playlistId: playlistId)
        if let idx = ids.firstIndex(of: seriesId) {
            ids.remove(at: idx)
            clearSnapshot(playlistId: playlistId, key: "series:\(seriesId)")
        } else {
            ids.append(seriesId)
            if let title { setSnapshot(playlistId: playlistId, key: "series:\(seriesId)", title: title, imageURL: imageURL) }
        }
        UserDefaults.standard.set(ids, forKey: Self.seriesStorageKey(playlistId: playlistId))
        version &+= 1
    }

    /// Movie toggle with an R6 display snapshot (title + image at add
    /// time). The existing `toggle(playlistId:streamId:)` stays for
    /// call sites that have no display data at hand.
    func toggleMovie(playlistId: UUID, streamId: Int, title: String, imageURL: String?) {
        let wasPresent = contains(playlistId: playlistId, streamId: streamId)
        toggle(playlistId: playlistId, streamId: streamId)
        if wasPresent {
            clearSnapshot(playlistId: playlistId, key: "vod:\(streamId)")
        } else {
            setSnapshot(playlistId: playlistId, key: "vod:\(streamId)", title: title, imageURL: imageURL)
        }
    }

    // MARK: R6 snapshots
    //
    // A watch-later entry whose catalog record later vanishes must
    // stay visible, marked unavailable, instead of being silently
    // dropped by the catalog-resolution in the shelves. The snapshot
    // (title + image captured at add time) is what such a row renders.

    private static func snapshotKey(playlistId: UUID) -> String {
        "watchlist.snapshots.\(playlistId.uuidString)"
    }

    /// [itemKey: [title, imageURL]] — itemKey is "vod:<id>"/"series:<id>".
    func snapshots(playlistId: UUID) -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: Self.snapshotKey(playlistId: playlistId)) as? [String: [String]] ?? [:]
    }

    private func setSnapshot(playlistId: UUID, key: String, title: String, imageURL: String?) {
        var all = snapshots(playlistId: playlistId)
        all[key] = [title, imageURL ?? ""]
        UserDefaults.standard.set(all, forKey: Self.snapshotKey(playlistId: playlistId))
    }

    private func clearSnapshot(playlistId: UUID, key: String) {
        var all = snapshots(playlistId: playlistId)
        guard all.removeValue(forKey: key) != nil else { return }
        UserDefaults.standard.set(all, forKey: Self.snapshotKey(playlistId: playlistId))
    }
}
