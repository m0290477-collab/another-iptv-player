import Foundation
import GRDB

/// Build 61 (B9) — Q19 subscription-expiry auto-refresh on app
/// open.
///
/// The dashboards already re-verify the playlist they open, but
/// only when the last successful verify is more than 6 hours old
/// (`ProviderExpiryStore.refreshIfStale`). Q19 makes the APP OPEN
/// itself refresh the ACTIVE playlist's provider account: one
/// forced `get_user_info` verify through the existing API client,
/// the result recorded into `ProviderExpiryStore` (the same
/// record the playback gate, the Settings account card and the
/// Home expiry banner read), and the expiry alerts rescheduled
/// from the fresh date through `NotificationScheduler`.
///
/// Which playlist is "active": the last-used one (the root view's
/// `lastPlaylistId`), else the user's marked default, else the
/// first in library order — the same pick order the root view's
/// auto-load uses. M3U playlists carry no provider account and
/// are skipped. Failures are silent by design: the previously
/// recorded state keeps governing, exactly as with the dashboard
/// refresh. Runs from the app root's deferred launch task, never
/// on the cold-start critical path.
enum AppOpenRefreshService {
    static func refreshActivePlaylistOnAppOpen() async {
        let playlists = (try? await AppDatabase.shared.read { db in
            try Playlist.fetchAll(db)
        }) ?? []
        guard !playlists.isEmpty else { return }

        let lastId = UserDefaults.standard.string(forKey: "lastPlaylistId")
            .flatMap(UUID.init(uuidString:))
        let active = playlists.first { $0.id == lastId }
            ?? playlists.first { $0.id == PlaylistLibraryStore.defaultId }
            ?? PlaylistLibraryStore.sorted(playlists).first
        guard let active, active.kind == .xtream else { return }

        let client = XtreamAPIClient(playlist: active)
        guard let response = try? await client.verify() else { return }
        ProviderExpiryStore.record(playlistId: active.id, expDate: response.userInfo?.expDate)
        await NotificationScheduler.scheduleExpiryAlerts(for: [active])
    }
}
