import Foundation
import GRDB
import CryptoKit

/// The single gateway that writes M3U channels to the database. Both the add and refresh flows use the same path.
///
/// The whole operation runs in a single transaction on GRDB's write queue:
/// - The playlist is saved (with an optional update).
/// - The old `m3uChannel` records are deleted.
/// - The new channels are batch-written by `sortIndex`.
///
/// The channel ID is **deterministic** (SHA256 of `playlistId:url`). After a reimport the same URL gets the same ID,
/// so favorites and watch history are preserved.
enum M3UImporter {

    /// Full refresh for playlist + channels. Deletes the old records, writes the new ones.
    ///
    /// - Parameter clearServerURL: In a local-file import the playlist URL is cleared (a refresh asks for the file again).
    static func replace(
        playlist: Playlist,
        channels: [ParsedM3UChannel],
        epgURL: String?,
        clearServerURL: Bool = false
    ) async throws {
        var updated = playlist
        updated.m3uEpgURL = epgURL
        if clearServerURL { updated.serverURL = "" }

        let pid = playlist.id
        try await AppDatabase.shared.write { db in
            try updated.save(db)
            try db.execute(sql: "DELETE FROM m3uChannel WHERE playlistId = ?", arguments: [pid])
            // The same URL can appear in multiple groups (like "ALL" + a country group) — previously
            // INSERT OR REPLACE collapsed them all into a single row and channels silently
            // disappeared from groups. The first occurrence keeps its old URL-based identity (so favorites
            // and watch history survive a reimport); later duplicates become separate rows with a deterministic
            // `#n` suffix.
            var urlOccurrences: [String: Int] = [:]
            for (index, ch) in channels.enumerated() {
                let trimmedURL = ch.url.trimmingCharacters(in: .whitespacesAndNewlines)
                let occurrence = urlOccurrences[trimmedURL, default: 0]
                urlOccurrences[trimmedURL] = occurrence + 1
                let row = DBM3UChannel(
                    id: stableChannelID(playlistId: pid, url: ch.url, fallbackIndex: index, occurrence: occurrence),
                    playlistId: pid,
                    name: ch.name,
                    url: ch.url,
                    tvgId: ch.tvgId,
                    tvgName: ch.tvgName,
                    tvgLogo: ch.tvgLogo,
                    tvgCountry: ch.tvgCountry,
                    groupTitle: ch.groupTitle,
                    userAgent: ch.userAgent,
                    sortIndex: index,
                    catchup: ch.catchup,
                    catchupSource: ch.catchupSource,
                    catchupDays: ch.catchupDays,
                    tvgChno: ch.tvgChno
                )
                try row.save(db)
            }
        }
    }

    /// Deterministic channel ID generation: after a reimport the same URL gets the same ID.
    /// If the URL is empty, sortIndex is used as a fallback (rare, but a safeguard).
    /// `occurrence`: which repetition of the same URL this is (0 = first). The first occurrence produces the same identity
    /// as the old format; duplicates are distinguished with the `#n` suffix and, as long as the playlist order
    /// does not change, get the same identity on reimport too.
    static func stableChannelID(playlistId: UUID, url: String, fallbackIndex: Int = 0, occurrence: Int = 0) -> String {
        var key: String
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            key = "\(playlistId.uuidString):__idx:\(fallbackIndex)"
        } else {
            key = "\(playlistId.uuidString):\(trimmed)"
        }
        if occurrence > 0 {
            key += "#\(occurrence)"
        }
        let data = Data(key.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
