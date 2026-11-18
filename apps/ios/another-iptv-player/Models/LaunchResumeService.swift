import Foundation
import GRDB

/// Build 61 (B3, T2): "Play last channel on launch".
///
/// When the setting (`app.playLastChannelOnLaunch`, default OFF)
/// is on, a fresh app launch queues the most recently watched LIVE
/// channel through the app's EXISTING pending-playback mechanism —
/// the same `PendingPlayback` store the Siri / App Intent requests
/// use, consumed by `DashboardView.consumePendingPlayback()` right
/// after the catalog loads. No new playback path is built: the
/// dashboard presents the channel through `LivePlayerShell`,
/// exactly like a Siri "play channel" request. When the toggle is
/// off, nothing is stored and launch behaviour is unchanged.
///
/// Scope notes (honest): the consuming side exists only in the
/// Xtream dashboard, so the resume fires for Xtream playlists;
/// a stored request whose playlist is not the one auto-loaded is
/// dropped by the consumer's own playlist check. The one-shot
/// process flag keeps the app root's `.task` (which re-runs when
/// the root hierarchy is rebuilt, e.g. on a language change) from
/// re-queuing a resume mid-session.
enum LaunchResumeService {
    static let defaultsKey = "app.playLastChannelOnLaunch"

    private static var didScheduleThisProcess = false

    static func scheduleIfEnabled() async {
        guard !didScheduleThisProcess else { return }
        didScheduleThisProcess = true
        guard UserDefaults.standard.bool(forKey: defaultsKey) else { return }

        // The most recent LIVE history entry across playlists —
        // its playlistId travels with the request, and the
        // dashboard only honours requests for its own playlist.
        let latest = try? await AppDatabase.shared.read { db in
            try DBWatchHistory
                .filter(Column("type") == "live")
                .order(Column("lastWatchedAt").desc)
                .fetchOne(db)
        }
        guard let item = latest ?? nil, let streamId = Int(item.streamId) else { return }
        PendingPlayback.store([
            "kind": "live",
            "streamId": String(streamId),
            "name": item.title,
            "playlistId": item.playlistId.uuidString
        ])
    }
}
