import Foundation
import Security

/// Build 61 (B13, N-pack): automatic restore after reinstall.
///
/// `CredentialStore` mirrors every playlist's credential fields
/// into the Keychain as SYNCHRONIZABLE items
/// (`kSecAttrSynchronizable = true`), one item per playlist,
/// keyed by the playlist's UUID. When the user enables iCloud
/// Keychain, those items follow their Apple account: delete +
/// reinstall returns the playlists with zero re-entry (the local
/// DB is rebuilt from them by `PlaylistRestoreService`).
///
/// What is mirrored is exactly what the playlist record already
/// stores locally — Xtream server / username / password, or the
/// M3U URL + name — plus the playlist's EPG URL fields
/// (`epgURLOverride`, `m3uEpgURL`). Nothing new is collected, and
/// the credentials never touch any server of ours: the only sync
/// channel is the user's own iCloud Keychain.
///
/// Mirroring is hooked at the store layer — the two importer
/// gateways (`XtreamImporter.syncAndSave`,
/// `M3UImporter.replace`), the two name-only edit saves, the S5
/// backup import, and `AccountDataDeletion` for removal — never
/// in view code, so no save path can drift past it.
///
/// Extension point (B10's G2): when the playlist model gains
/// per-playlist custom HTTP headers / User-Agent fields, add
/// them to `Record` here and to `makePlaylist()` — one place.
enum CredentialStore {

    private static let service = "com.irqus.superx.playlist-credentials"

    /// The mirrored credential record — Codable JSON in the
    /// keychain item's value data.
    struct Record: Codable, Equatable {
        var id: UUID
        var name: String
        /// `PlaylistKind.rawValue` ("xtream" / "m3u").
        var type: String
        var serverURL: String
        var username: String
        var password: String
        var filterAdultContent: Bool
        var m3uEpgURL: String?
        var epgURLOverride: String?
        var epgEnabled: Bool
        var createdAt: Date

        init(playlist: Playlist) {
            id = playlist.id
            name = playlist.name
            type = playlist.type
            serverURL = playlist.serverURL
            username = playlist.username
            password = playlist.password
            filterAdultContent = playlist.filterAdultContent
            m3uEpgURL = playlist.m3uEpgURL
            epgURLOverride = playlist.epgURLOverride
            epgEnabled = playlist.epgEnabled
            createdAt = playlist.createdAt
        }

        /// Recreates the local playlist record on restore. The
        /// panel-derived fields (server timezone, timeshift
        /// style) are NOT credentials — they re-resolve lazily
        /// through the existing paths after restore.
        func makePlaylist() -> Playlist {
            Playlist(
                id: id,
                name: name,
                serverURL: serverURL,
                username: username,
                password: password,
                createdAt: createdAt,
                filterAdultContent: filterAdultContent,
                type: PlaylistKind(rawValue: type) ?? .xtream,
                m3uEpgURL: m3uEpgURL,
                epgURLOverride: epgURLOverride,
                epgEnabled: epgEnabled
            )
        }
    }

    // MARK: - Mirror (add / edit)

    /// Creates or replaces the keychain item for one playlist.
    /// Best-effort by design: a keychain failure must never fail
    /// the playlist save itself — the local DB stays the working
    /// source of truth, the keychain is the restore source.
    static func mirror(_ playlist: Playlist) {
        let record = Record(playlist: playlist)
        guard let data = try? JSONEncoder().encode(record) else { return }
        let query = baseQuery(account: playlist.id.uuidString)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            Log.error("CredentialStore", "mirror failed for \(playlist.id): OSStatus \(status)")
        }
    }

    // MARK: - Removal (delete / erase)

    /// Removes one playlist's mirrored item (single-playlist
    /// deletion path).
    static func remove(playlistId: UUID) {
        SecItemDelete(baseQuery(account: playlistId.uuidString) as CFDictionary)
    }

    /// Removes EVERY mirrored item — the T6 erase path (N4),
    /// under the same double confirmation as the rest of the
    /// erase. Synchronizable deletion propagates through the
    /// user's iCloud Keychain like any other keychain delete.
    static func deleteAll() {
        var query = baseQuery(account: nil)
        query.removeValue(forKey: kSecAttrAccount as String)
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Read (restore)

    /// Every mirrored record, oldest first (restore recreates
    /// playlists in the order they were added).
    static func allRecords() -> [Record] {
        var query = baseQuery(account: nil)
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else {
            return []
        }
        let decoder = JSONDecoder()
        return list
            .compactMap { $0[kSecValueData as String] as? Data }
            .compactMap { try? decoder.decode(Record.self, from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Query construction

    /// `account == nil` builds the service-wide query (the
    /// account entry is dropped by the caller in that case).
    private static func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // THE N1 requirement: items sync through the user's
            // own iCloud Keychain when it is enabled. There is no
            // separate portal capability for iCloud Keychain
            // (unlike the CloudKit container) — synchronizability
            // is purely this attribute plus a non-device-only
            // accessibility class.
            kSecAttrSynchronizable as String: true
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }
}
