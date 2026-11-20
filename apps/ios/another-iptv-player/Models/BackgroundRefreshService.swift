import Foundation
import BackgroundTasks
import GRDB

/// Build 61 (B1, S3): `BGAppRefreshTask` plumbing that keeps the
/// catalog and the guide fresh while the app is backgrounded.
///
/// The task identifier is `com.irqus.superx.refresh`, declared in
/// `App-Info.plist` under `BGTaskSchedulerPermittedIdentifiers`,
/// with `fetch` in `UIBackgroundModes`. Registration happens from
/// the app delegate's launch callback (BGTaskScheduler requires
/// registration before the app finishes launching); the next run is
/// chained at registration time and again at the start of every
/// handling, so the schedule survives each firing.
///
/// When the task fires it runs the EXISTING refresh paths — the
/// same ones the in-app refresh actions use:
///  - Xtream playlists: `PlaylistContentStore.refreshFromNetwork`
///    (full network sync + in-memory reload when active);
///  - M3U playlists: remote re-download + `M3UImporter.replace`
///    (the My Playlists refresh pipeline), or a local reload for
///    file-imported playlists with no source URL;
///  - expiry alerts are re-scheduled from the refreshed records
///    through `NotificationScheduler` (its existing path).
///
/// Honest limits: iOS alone decides when (and whether) an app
/// refresh task fires — `earliestBeginDate` is a hint, not a
/// guarantee — and the system grants a short execution window, so
/// a very large catalog sync may be cut off; whatever completed
/// stays committed, exactly as with an interrupted in-app refresh.
enum BackgroundRefreshService {
    static let taskIdentifier = "com.irqus.superx.refresh"

    private static var didRegister = false

    /// Registers the task handler and submits the first schedule
    /// request. Must be called before the app finishes launching
    /// (the app delegate does); later calls are no-ops.
    static func register() {
        guard !didRegister else { return }
        didRegister = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
        schedule()
    }

    /// Submits the next refresh request. The system treats the
    /// earliest-begin date (~6 hours out) as a hint and typically
    /// fires overnight while the device is charging.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3_600)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // Chain the next run first, so a killed or expired run
        // never breaks the schedule.
        schedule()
        let work = Task { @MainActor in
            await refreshAll()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// Refreshes every saved playlist's catalog through the
    /// existing paths, in stored order. Cancellation (the system's
    /// expiration handler) stops between playlists.
    @MainActor
    private static func refreshAll() async {
        let playlists = (try? await AppDatabase.shared.read { db in
            try Playlist.fetchAll(db)
        }) ?? []
        // === Build 61 (B9, P6): data saver — while the toggle is
        // on and the device is on cellular, the network-heavy
        // catalog refresh is skipped; only the local
        // expiry-alert rescheduling (no network of its own beyond
        // already-recorded dates) still runs. ===
        if DataSaverService.isActive {
            for playlist in playlists {
                if Task.isCancelled { return }
                await NotificationScheduler.scheduleExpiryAlerts(for: [playlist])
            }
            return
        }
        for playlist in playlists {
            if Task.isCancelled { return }
            if playlist.kind == .m3u {
                if playlist.serverURL.isEmpty {
                    await M3UContentStore.shared.reloadIfActive(playlist: playlist)
                } else if let content = try? await M3UService().fetchRemote(urlString: playlist.serverURL, playlist: playlist),
                          let parsed = try? await M3UParser.parseAsync(content) {
                    try? await M3UImporter.replace(
                        playlist: playlist,
                        channels: parsed.channels,
                        epgURL: parsed.epgURL
                    )
                    await M3UContentStore.shared.reloadIfActive(playlist: playlist)
                }
            } else {
                await PlaylistContentStore.shared.refreshFromNetwork(playlist: playlist)
            }
            if Task.isCancelled { return }
            await NotificationScheduler.scheduleExpiryAlerts(for: [playlist])
        }
    }
}
