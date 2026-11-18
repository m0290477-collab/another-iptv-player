import Foundation
import GRDB
import Nuke
import WidgetKit

/// Round 17 (R17-2 + R17-5): THE one account-data deletion
/// implementation. Both entry points — Settings ▸ Privacy & Legal
/// ▸ Delete Account (full wipe) and the playlist gate's saved-
/// account removal (one playlist) — run through here, as does
/// Settings ▸ My Playlists' delete, so the three can never drift
/// apart again.
///
/// Round-16 root cause of the Delete Account failure: the old wipe
/// deleted every table in ONE transaction from a hardcoded list
/// that still named `epgShortCache` and `xmltvGuideCache` — tables
/// the `dropLegacyEPGTables` migration had already dropped. The
/// first `DELETE FROM xmltvGuideCache` threw "no such table", the
/// whole transaction rolled back, and the flow reported "Some data
/// could not be deleted" with NOTHING deleted.
///
/// The fix is structural, not a list edit:
/// - the table list is intersected with the tables that ACTUALLY
///   exist (`sqlite_master`), so a dropped/renamed table can never
///   throw again;
/// - every store is cleared INDEPENDENTLY (own transaction / own
///   step), and a failure is logged and collected — it can never
///   abort the remaining stores;
/// - the per-playlist UserDefaults / file stores the old wipe
///   missed (watchlist, expiry, health, library order, gate
///   session keys), the parental-PIN keychain item, the image
///   caches and the widget snapshot are all part of the wipe.
enum AccountDataDeletion {

    /// Every app table, children before parents. Intersected with
    /// `sqlite_master` at run time — see the header note.
    private static let allTables = [
        "episode", "season",
        "epgProgramme", "epgChannel", "epgSource",
        "epgProgrammeStaging", "epgChannelStaging",
        "watchHistory", "favorite",
        "m3uFavorite", "m3uChannel",
        "downloadedItem",
        "liveStream", "vodStream", "series", "category",
        "playlist"
    ]

    /// Tables carrying a `playlistId` column (episode has none —
    /// its rows cascade from `season`, and are also swept explicitly
    /// through their season below).
    private static let playlistScopedTables = [
        "epgProgramme", "epgChannel", "epgSource",
        "epgProgrammeStaging", "epgChannelStaging",
        "watchHistory", "favorite",
        "m3uFavorite", "m3uChannel",
        "downloadedItem",
        "liveStream", "vodStream", "season", "series", "category"
    ]

    private static func existingTables() async -> Set<String> {
        let names = (try? await AppDatabase.shared.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }) ?? []
        return Set(names)
    }

    // MARK: - Full wipe (Delete Account)

    /// Deletes ALL playlists and ALL account data on this device.
    /// Returns true only when every store reported success; the
    /// stores run independently, so one failure never blocks the
    /// rest — the caller surfaces the aggregate honestly.
    static func deleteAllLocalData() async -> Bool {
        var succeeded = true

        // Playlist ids first — the per-playlist stores below are
        // keyed by them, and the playlist table is wiped in this
        // same pass. A failed read no longer aborts the wipe: the
        // table pass below does not depend on the ids.
        let playlistIds: [UUID] = (try? await AppDatabase.shared.read { db in
            try Playlist.fetchAll(db).map(\.id)
        }) ?? []

        // Downloaded files + their rows (the manager owns the
        // on-disk directories and its own table; it never throws).
        await DownloadManager.shared.deleteAll()

        // Database: one transaction PER TABLE, existing tables
        // only — a missing table is skipped, a failing table is
        // logged and collected, never fatal to the others.
        let existing = await existingTables()
        for table in allTables where existing.contains(table) {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(sql: "DELETE FROM \(table)")
                }
            } catch {
                succeeded = false
                Log.error("DeleteAccount", "table \(table) failed: \(error.localizedDescription)")
            }
        }

        // Per-playlist UserDefaults / file stores.
        for id in playlistIds {
            await clearPerPlaylistStores(playlistId: id)
        }
        ProviderExpiryStore.clearAll()
        PlaylistHealthStore.clearAll()

        // Session / gate state: the next launch must land on a
        // clean gate — no last-playlist pointer, no "Continue
        // with" name, no saved sign-in drafts (they carry the
        // deleted account's server URL and username), no pending
        // Siri/Shortcuts playback request.
        let defaults = UserDefaults.standard
        for key in [
            "lastPlaylistId",
            "gate.lastPlaylistName",
            "gate.draft.xtream.name", "gate.draft.xtream.url", "gate.draft.xtream.username",
            "gate.draft.m3u.name", "gate.draft.m3u.url",
            "intents.pendingPlayback"
        ] {
            defaults.removeObject(forKey: key)
        }

        // Keychain: the parental PIN belongs to the deleted
        // account setup; a fresh start must not inherit it.
        PINStore.clearPIN()

        // === B15 (build 61) W1: the app-open lock belongs to the
        // erased setup too — clear its PIN hash and its enable
        // flag so a fresh start never comes up locked. ===
        AppLockService.clearPIN()
        defaults.removeObject(forKey: AppLockService.enabledKey)
        // === End B15 W1 ===

        // N4 (B13): the erase also deletes the synchronizable
        // playlist-credential mirror items — otherwise a reinstall
        // restore would resurrect playlists the user just erased.
        CredentialStore.deleteAll()

        // Files / caches: poster image caches (memory + disk) and
        // the shared URL cache. The disk cache is the Nuke
        // DataCache directory named in CachedImage's pipeline
        // setup ("com.superx.images" under Caches) — removed
        // directly so the wipe does not depend on cache internals.
        ImagePipeline.shared.cache.removeAll()
        if let cachesDir = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            try? FileManager.default.removeItem(
                at: cachesDir.appendingPathComponent("com.superx.images", isDirectory: true)
            )
        }
        URLCache.shared.removeAllCachedResponses()

        // Widget: replace the snapshot with the honest empty state
        // and reload timelines — the widget must not keep showing
        // a deleted account's favorites/history. Behavior of the
        // widget itself is untouched.
        WidgetSnapshotStore.write(.empty)
        WidgetCenter.shared.reloadAllTimelines()

        // In-memory catalogs.
        await PlaylistContentStore.shared.unload()
        await M3UContentStore.shared.unload()
        await EPGStore.shared.setActivePlaylist(nil)

        return succeeded
    }

    // MARK: - One playlist (gate removal / My Playlists delete)

    /// Removes ONE saved account and all of its local data,
    /// leaving every other playlist untouched. Same independence
    /// rules as the full wipe.
    @discardableResult
    static func deletePlaylistData(_ playlist: Playlist) async -> Bool {
        var succeeded = true
        let id = playlist.id

        // Downloads first (files + rows + directories for this
        // playlist only; never throws).
        await DownloadManager.shared.deleteAll(playlistId: id)

        // Database rows for this playlist only — per-table
        // transactions over existing tables. Episodes are swept
        // through their seasons first (episode has no playlistId
        // column), then the scoped tables, then the playlist row.
        let existing = await existingTables()
        if existing.contains("episode"), existing.contains("season") {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(
                        sql: "DELETE FROM episode WHERE seasonId IN (SELECT id FROM season WHERE playlistId = ?)",
                        arguments: [id.uuidString]
                    )
                }
            } catch {
                succeeded = false
                Log.error("DeletePlaylist", "episode sweep failed: \(error.localizedDescription)")
            }
        }
        for table in playlistScopedTables where existing.contains(table) {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(
                        sql: "DELETE FROM \(table) WHERE playlistId = ?",
                        arguments: [id.uuidString]
                    )
                }
            } catch {
                succeeded = false
                Log.error("DeletePlaylist", "table \(table) failed: \(error.localizedDescription)")
            }
        }
        if existing.contains("playlist") {
            do {
                try await AppDatabase.shared.write { db in
                    try Playlist.deleteAll(db, ids: [id])
                }
            } catch {
                succeeded = false
                Log.error("DeletePlaylist", "playlist row failed: \(error.localizedDescription)")
            }
        }

        await clearPerPlaylistStores(playlistId: id)

        // N1 (B13): removing one playlist also removes its
        // keychain restore mirror item.
        CredentialStore.remove(playlistId: id)

        // Gate/session pointers that named this playlist.
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "gate.lastPlaylistName") == playlist.name {
            defaults.removeObject(forKey: "gate.lastPlaylistName")
        }
        if defaults.string(forKey: "lastPlaylistId") == id.uuidString {
            defaults.removeObject(forKey: "lastPlaylistId")
        }

        return succeeded
    }

    // MARK: - Shared per-playlist stores

    /// The UserDefaults / file stores keyed by playlist id —
    /// identical for the full wipe and the single-playlist removal.
    private static func clearPerPlaylistStores(playlistId: UUID) async {
        ImportedSubtitleStore.removeAll(playlistId: playlistId)
        await HiddenCategoryStore.shared.removeAll(playlistId: playlistId)
        await CategoryOrderStore.shared.removeAll(playlistId: playlistId)
        await WatchlistStore.shared.removeAll(playlistId: playlistId)
        ProviderExpiryStore.remove(playlistId: playlistId)
        PlaylistHealthStore.remove(for: playlistId)
        PlaylistLibraryStore.remove(playlistId: playlistId)
    }
}
