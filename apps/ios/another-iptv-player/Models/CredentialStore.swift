import Foundation
import Security

/// Build 61 (B13, N-pack): automatic restore after reinstall.
/// Build 66 (W2, item 6): INVERTED — the Keychain is now the
/// PRIMARY working store for playlist passwords; the database
/// `password` column is legacy and is written EMPTY on every
/// add/edit going forward (the column itself stays for schema
/// compatibility — no migration adds or drops it).
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
/// Every password USE in the app resolves through
/// `password(for:)` below — the API client and the playback URL
/// builder (the two funnels every other call site builds from),
/// the EPG refresh coordinator's redaction parameters, the
/// settings password row and the credential-bearing backup
/// export. No other code reads `Playlist.password` as a working
/// value; the only remaining reads of that property are inside
/// this file (mirror capture + the legacy fallback/migration)
/// and in-memory form merges, documented at those sites.
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
        // Coordinator integration (build 61): B10's connection
        // fields (G2 headers/UA, Q18 backup URL) ride the mirror
        // too — N1 names them explicitly. Optional + defaulted so
        // records written before this extension still decode.
        var backupURL: String? = nil
        var customUserAgent: String? = nil
        var customHeadersJSON: String? = nil
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
            backupURL = playlist.backupURL
            customUserAgent = playlist.customUserAgent
            customHeadersJSON = playlist.customHeadersJSON
            createdAt = playlist.createdAt
        }

        /// Recreates the local playlist record on restore. The
        /// record carries the real password IN MEMORY (background
        /// re-validation verifies with it); the restore service
        /// writes a password-blanked copy to the database. The
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
                epgEnabled: epgEnabled,
                backupURL: backupURL,
                customUserAgent: customUserAgent,
                customHeadersJSON: customHeadersJSON
            )
        }
    }

    // MARK: - Mirror (add / edit)

    /// Creates or replaces the keychain item for one playlist.
    /// Best-effort by design: a keychain failure must never fail
    /// the playlist save itself.
    ///
    /// Build 66 guard: an incoming playlist whose password is
    /// EMPTY never erases a stored password. Refresh and
    /// name-only paths legitimately re-mirror database-read
    /// records (whose column is blank by design now); without
    /// this guard those paths would wipe the working credential.
    static func mirror(_ playlist: Playlist) {
        var newRecord = Record(playlist: playlist)
        if newRecord.password.isEmpty,
           let existing = record(for: playlist.id),
           !existing.password.isEmpty {
            newRecord.password = existing.password
        }
        guard let data = try? JSONEncoder().encode(newRecord) else { return }
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

    // MARK: - Password resolution (build 66: the single resolver)

    /// The ONE mirrored record for a playlist id, if any.
    static func record(for playlistId: UUID) -> Record? {
        var query = baseQuery(account: playlistId.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// THE working password for a playlist — every use site in
    /// the app resolves through here. The Keychain record wins.
    /// The legacy database value is only a fallback for the two
    /// states where no Keychain record can exist yet: a brand-new
    /// playlist still being probed before its first mirror (the
    /// struct carries the form-entered password in memory), and
    /// a pre-build-66 row the launch migration has not reached.
    static func password(for playlist: Playlist) -> String? {
        if let record = record(for: playlist.id), !record.password.isEmpty {
            return record.password
        }
        let legacy = playlist.password
        return legacy.isEmpty ? nil : legacy
    }

    /// Build 66 one-time migration for existing installs, called
    /// per playlist from `PlaylistRestoreService` (the launch /
    /// restore path). When the Keychain has no usable password
    /// for the playlist but the database row still holds one,
    /// the row is mirrored into the Keychain; either way, when
    /// the database row holds a password this returns a copy of
    /// the playlist with the column blanked for the caller to
    /// write back — or nil when there is nothing to migrate
    /// (column already empty, or the Keychain write could not
    /// be verified, in which case the column is left untouched
    /// so the only copy is never destroyed).
    static func migrateLegacyPasswordIfNeeded(_ playlist: Playlist) -> Playlist? {
        guard !playlist.password.isEmpty else { return nil }
        if let existing = record(for: playlist.id), !existing.password.isEmpty {
            // The Keychain is already authoritative for this
            // playlist — the database copy is a stale duplicate.
            var blanked = playlist
            blanked.password = ""
            return blanked
        }
        mirror(playlist)
        guard let stored = record(for: playlist.id), !stored.password.isEmpty else {
            return nil
        }
        var blanked = playlist
        blanked.password = ""
        return blanked
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
