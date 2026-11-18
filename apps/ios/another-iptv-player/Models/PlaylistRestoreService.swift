import Foundation
import Combine
import GRDB

/// Build 61 (B13, N2): first-launch restore after reinstall.
///
/// When the local database holds NO playlists but the
/// synchronizable keychain mirror (`CredentialStore`) does, the
/// playlists are recreated automatically — no re-entry, no
/// prompt to dismiss before the app is usable. Each restored
/// playlist is then re-validated in the background through the
/// EXISTING paths (Xtream: `ProviderExpiryStore.refreshIfStale`,
/// the same verify the dashboard runs; M3U: one fetch of the
/// source URL). Validation NEVER drops a playlist: an expired or
/// unreachable playlist restores in its real state and surfaces
/// through the normal expiry/load paths, exactly as if it had
/// never been deleted.
///
/// The restore runs once from the app root's deferred launch
/// task (after the first frame, next to the fixture seed) and
/// publishes the restored count so ContentView can show the ONE
/// small "playlists restored" notice.
@MainActor
final class PlaylistRestoreService: ObservableObject {
    static let shared = PlaylistRestoreService()

    /// Playlists restored by this launch's pass; ContentView
    /// shows the notice while this is > 0 and calls
    /// `acknowledgeNotice()` when the user dismisses it.
    @Published private(set) var restoredCount = 0

    private var didRun = false

    private init() {}

    func acknowledgeNotice() {
        restoredCount = 0
    }

    /// Recreates playlist records from the keychain mirror when
    /// (and only when) the local playlist table is empty.
    /// Returns the number restored.
    @discardableResult
    func restoreIfNeeded() async -> Int {
        guard !didRun else { return 0 }
        didRun = true

        let existingCount = (try? await AppDatabase.shared.read { db in
            try Playlist.fetchCount(db)
        }) ?? 0
        guard existingCount == 0 else { return 0 }

        let records = CredentialStore.allRecords()
        guard !records.isEmpty else { return 0 }

        let playlists = records.map { $0.makePlaylist() }
        do {
            try await AppDatabase.shared.write { db in
                for playlist in playlists {
                    try playlist.insert(db)
                }
            }
        } catch {
            Log.error("PlaylistRestore", "restore insert failed: \(error.localizedDescription)")
            return 0
        }

        restoredCount = playlists.count
        Log.info("PlaylistRestore", "restored \(playlists.count) playlist(s) from the keychain mirror")

        // Background re-validation — fire-and-forget per playlist;
        // outcomes land in the stores the UI already reads
        // (expiry records, health) and never remove the record.
        for playlist in playlists {
            Task.detached {
                await Self.revalidate(playlist)
            }
        }
        return playlists.count
    }

    /// The existing validation paths, per kind. Failures are
    /// silent here by design: the restored record stays, and its
    /// real state (expired / unreachable / fine) is what the
    /// normal surfaces will show.
    private static func revalidate(_ playlist: Playlist) async {
        switch playlist.kind {
        case .xtream:
            await ProviderExpiryStore.refreshIfStale(playlist: playlist)
        case .m3u:
            let url = playlist.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return }
            _ = try? await M3UService().fetchRemote(urlString: url)
        }
    }
}
