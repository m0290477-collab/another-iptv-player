import Foundation
import GRDB

/// Build 61 (B3, S5): the library half of backup/restore —
/// favorites (both stores) and the Watch Later list — carried by
/// the ONE existing backup format (`SuperXBackupFile` in
/// SettingsComponents.swift, extended with optional fields so old
/// backup files still decode and old readers ignore the library).
///
/// Exactly the fields the app already stores are exported —
/// nothing new is persisted anywhere, and no credential of any
/// kind is part of this service (playlist definitions and their
/// password handling stay with the existing C5/C3 flows).
///
/// Mapping rule: favorites and watch-later entries are keyed by
/// playlist UUID, which changes when a backup is imported onto a
/// fresh install. Every playlist DTO therefore also carries its
/// source `id`, and import builds a source→target id map from the
/// playlists actually present after the playlist import step;
/// library entries whose playlist cannot be mapped are skipped
/// and reported in the import result — never attached to the
/// wrong playlist.
enum BackupService {

    // MARK: - DTOs (exactly the stored fields)

    /// One `DBFavorite` row (favorite table).
    struct FavoriteDTO: Codable, Equatable {
        var streamId: Int
        var playlistId: String
        var type: String // "live", "vod", "series"
        var createdAt: TimeInterval
    }

    /// One `DBM3UFavorite` row (m3uFavorite table).
    struct M3UFavoriteDTO: Codable, Equatable {
        var channelId: String
        var playlistId: String
        var createdAt: TimeInterval
    }

    /// One playlist's Watch Later list (`WatchlistStore`:
    /// VOD streamIds in insertion order).
    struct WatchlistDTO: Codable, Equatable {
        var playlistId: String
        var movieIds: [Int]
    }

    /// Build 61 (B8, J1): one favorite group, mirroring
    /// `FavoriteGroupStore.Group` field-for-field (including the R6
    /// display snapshots). Optional in the payload so pre-B8 backup
    /// files still decode.
    struct GroupItemDTO: Codable, Equatable {
        var type: String
        var itemId: String
        var title: String
        var imageURL: String?
    }

    struct GroupDTO: Codable, Equatable {
        var id: String
        var name: String
        var items: [GroupItemDTO] = []
    }

    struct GroupsDTO: Codable, Equatable {
        var playlistId: String
        var groups: [GroupDTO] = []
    }

    /// Build 61 (B8, C2): one playlist's series Watch Later list.
    struct SeriesWatchlistDTO: Codable, Equatable {
        var playlistId: String
        var seriesIds: [Int]
    }

    struct LibraryDTO: Codable, Equatable {
        var favorites: [FavoriteDTO] = []
        var m3uFavorites: [M3UFavoriteDTO] = []
        var watchlist: [WatchlistDTO] = []
        // Build 61 (B8) additive fields — defaulted, so old backup
        // files decode unchanged.
        var groups: [GroupsDTO] = []
        var seriesWatchlist: [SeriesWatchlistDTO] = []
    }

    // MARK: - Export

    /// Reads the current library for the given playlists from the
    /// two favorite tables and the watchlist store.
    static func collectLibrary(playlistIds: [UUID]) async -> LibraryDTO {
        var library = LibraryDTO()
        let favorites = (try? await AppDatabase.shared.read { db in
            try DBFavorite.fetchAll(db)
        }) ?? []
        library.favorites = favorites.map {
            FavoriteDTO(streamId: $0.streamId,
                        playlistId: $0.playlistId.uuidString,
                        type: $0.type,
                        createdAt: $0.createdAt.timeIntervalSince1970)
        }
        let m3uFavorites = (try? await AppDatabase.shared.read { db in
            try DBM3UFavorite.fetchAll(db)
        }) ?? []
        library.m3uFavorites = m3uFavorites.map {
            M3UFavoriteDTO(channelId: $0.channelId,
                           playlistId: $0.playlistId.uuidString,
                           createdAt: $0.createdAt.timeIntervalSince1970)
        }
        for id in playlistIds {
            let ids = await WatchlistStore.shared.movieIds(playlistId: id)
            if !ids.isEmpty {
                library.watchlist.append(WatchlistDTO(playlistId: id.uuidString, movieIds: ids))
            }
            // Build 61 (B8): series Watch Later + favorite groups.
            let seriesIds = await WatchlistStore.shared.seriesIds(playlistId: id)
            if !seriesIds.isEmpty {
                library.seriesWatchlist.append(SeriesWatchlistDTO(playlistId: id.uuidString, seriesIds: seriesIds))
            }
            let groups = await FavoriteGroupStore.shared.groups(playlistId: id)
            if !groups.isEmpty {
                library.groups.append(GroupsDTO(
                    playlistId: id.uuidString,
                    groups: groups.map { group in
                        GroupDTO(id: group.id, name: group.name, items: group.items.map {
                            GroupItemDTO(type: $0.type, itemId: $0.itemId, title: $0.title, imageURL: $0.imageURL)
                        })
                    }
                ))
            }
        }
        return library
    }

    // MARK: - Import

    struct ApplyResult: Equatable {
        var favoritesImported: Int = 0
        var watchlistImported: Int = 0
        var skippedUnmapped: Int = 0
        // Build 61 (B8) additive counters.
        var groupsImported: Int = 0
        var seriesWatchlistImported: Int = 0
    }

    /// Applies a backup's library through the id map (source
    /// playlist UUID string → target playlist UUID). Existing
    /// rows are never duplicated: favorites are inserted only
    /// when the same (playlist, stream, type) / (playlist,
    /// channel) row is absent, and watch-later ids are unioned
    /// into the target playlist's existing list.
    static func applyLibrary(_ library: LibraryDTO, playlistIdMap: [String: UUID]) async -> ApplyResult {
        var result = ApplyResult()

        let favDTOs = library.favorites
        let m3uDTOs = library.m3uFavorites
        let importedFavorites = (try? await AppDatabase.shared.write { db -> Int in
            var count = 0
            for dto in favDTOs {
                guard let target = playlistIdMap[dto.playlistId] else { continue }
                let exists = try DBFavorite
                    .filter(Column("playlistId") == target)
                    .filter(Column("streamId") == dto.streamId)
                    .filter(Column("type") == dto.type)
                    .fetchCount(db) > 0
                guard !exists else { continue }
                try DBFavorite(streamId: dto.streamId,
                               playlistId: target,
                               type: dto.type,
                               createdAt: Date(timeIntervalSince1970: dto.createdAt)).insert(db)
                count += 1
            }
            for dto in m3uDTOs {
                guard let target = playlistIdMap[dto.playlistId] else { continue }
                let exists = try DBM3UFavorite
                    .filter(Column("playlistId") == target)
                    .filter(Column("channelId") == dto.channelId)
                    .fetchCount(db) > 0
                guard !exists else { continue }
                try DBM3UFavorite(channelId: dto.channelId,
                                  playlistId: target,
                                  createdAt: Date(timeIntervalSince1970: dto.createdAt)).insert(db)
                count += 1
            }
            return count
        }) ?? 0
        result.favoritesImported = importedFavorites
        result.skippedUnmapped += library.favorites.filter { playlistIdMap[$0.playlistId] == nil }.count
        result.skippedUnmapped += library.m3uFavorites.filter { playlistIdMap[$0.playlistId] == nil }.count

        // Watch Later: union into the target playlist's list.
        // Written through the store's own UserDefaults key format
        // ("watchlist.vod.<playlistId>", see WatchlistStore) —
        // the store reads UserDefaults on every access, so the
        // merged list is live immediately.
        for dto in library.watchlist {
            guard let target = playlistIdMap[dto.playlistId] else {
                result.skippedUnmapped += 1
                continue
            }
            let key = "watchlist.vod.\(target.uuidString)"
            let existing = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
            var merged = existing
            var added = 0
            for id in dto.movieIds where !merged.contains(id) {
                merged.append(id)
                added += 1
            }
            if added > 0 {
                UserDefaults.standard.set(merged, forKey: key)
                result.watchlistImported += added
            }
        }

        // Build 61 (B8): series Watch Later — same union rule through
        // the store's own key format ("watchlist.series.<playlistId>").
        for dto in library.seriesWatchlist {
            guard let target = playlistIdMap[dto.playlistId] else {
                result.skippedUnmapped += 1
                continue
            }
            let key = "watchlist.series.\(target.uuidString)"
            let existing = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
            var merged = existing
            var added = 0
            for id in dto.seriesIds where !merged.contains(id) {
                merged.append(id)
                added += 1
            }
            if added > 0 {
                UserDefaults.standard.set(merged, forKey: key)
                result.seriesWatchlistImported += added
            }
        }

        // Build 61 (B8, J1): favorite groups — union-merged into the
        // target playlist's store (group ids are UUIDs, stable
        // across devices; items union by identity).
        for dto in library.groups {
            guard let target = playlistIdMap[dto.playlistId] else {
                result.skippedUnmapped += 1
                continue
            }
            let storeGroups = dto.groups.map { group in
                FavoriteGroupStore.Group(id: group.id, name: group.name, items: group.items.map {
                    FavoriteGroupStore.Item(type: $0.type, itemId: $0.itemId, title: $0.title, imageURL: $0.imageURL)
                })
            }
            await FavoriteGroupStore.shared.mergeImported(storeGroups, playlistId: target)
            result.groupsImported += storeGroups.count
        }
        return result
    }
}
