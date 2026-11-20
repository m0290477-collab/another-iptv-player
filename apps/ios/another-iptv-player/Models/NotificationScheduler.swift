import Foundation
import GRDB
import UserNotifications

/// Round 15 (C11 + C3): the ONE local-notification scheduler, over
/// `UNUserNotificationCenter`. It carries:
///  - subscription-expiry alerts, scheduled from the exp_date
///    timestamps recorded by `ProviderExpiryStore` (the same record
///    the playback gate reads), gated by the EXISTING Settings
///    expiry-alerts toggle (`notifications.expiryAlertsEnabled`).
///    reminders toggle (`reminders.enabled`) — that toggle gates
///    ONLY programme reminders.
///
///
/// Authorization is requested ONLY when there is something real to
/// schedule (a recorded expiry date, or a programme reminder) —
/// never on a bare first launch.
enum NotificationScheduler {
    // MARK: - Settings keys (owned by Settings; read-only here)

    private static var expiryAlertsEnabled: Bool {
        UserDefaults.standard.object(forKey: "notifications.expiryAlertsEnabled") as? Bool ?? true
    }

    /// The scheduler's own record of which expiry timestamp an
    /// at-expiry alert was already scheduled for, per playlist —
    /// prevents re-firing an already-passed expiry on every launch.
    /// (Expiry dates themselves are always read through
    /// `ProviderExpiryStore`'s public API.)
    private static let expiryAlertedKeyPrefix = "notifications.expiryAlertedAt."

    // MARK: - Authorization

    /// Requests alert+sound authorization when undecided; returns
    /// whether notifications may be delivered afterwards.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            return granted
        default:
            return false
        }
    }

    // MARK: - C11: subscription-expiry alerts

    /// Stable identifiers, so re-scheduling REPLACES stale requests
    /// instead of stacking duplicates.
    private static func expiryIdentifiers(playlistId: UUID) -> [String] {
        ["superx.expiry.before.\(playlistId.uuidString)",
         "superx.expiry.at.\(playlistId.uuidString)"]
    }

    /// Schedules, per playlist with a recorded exp_date, one alert
    /// shortly before expiry (3 days) and one at expiry. Playlists
    /// without a recorded date get any stale requests removed.
    /// When the expiry-alerts toggle is off, all expiry requests
    /// are removed and nothing is scheduled.
    static func scheduleExpiryAlerts(for playlists: [Playlist]) async {
        let center = UNUserNotificationCenter.current()
        guard expiryAlertsEnabled else {
            center.removePendingNotificationRequests(
                withIdentifiers: playlists.flatMap { expiryIdentifiers(playlistId: $0.id) })
            return
        }
        // Only ask for authorization when at least one playlist
        // actually has an expiry date to alert about.
        let dated = playlists.compactMap { playlist -> (Playlist, Date)? in
            guard let expiry = ProviderExpiryStore.expiryDate(playlistId: playlist.id) else { return nil }
            return (playlist, expiry)
        }
        guard !dated.isEmpty else {
            center.removePendingNotificationRequests(
                withIdentifiers: playlists.flatMap { expiryIdentifiers(playlistId: $0.id) })
            return
        }
        guard await requestAuthorization() else { return }

        let dateText = Self.dateText
        for (playlist, expiry) in dated {
            let ids = expiryIdentifiers(playlistId: playlist.id)
            center.removePendingNotificationRequests(withIdentifiers: ids)
            let now = Date()

            // "Shortly before": 3 days ahead of the exp_date
            // timestamp, only while that moment is still future.
            let beforeDate = expiry.addingTimeInterval(-3 * 86_400)
            if beforeDate > now {
                let days = max(1, Int(ceil(expiry.timeIntervalSince(beforeDate) / 86_400)))
                let body: String
                if days == 1 {
                    body = L("notifications.expiry.message_one", dateText(expiry))
                } else {
                    body = L("notifications.expiry.message", days, dateText(expiry))
                }
                await add(identifier: ids[0],
                          title: L("notifications.expiry.title"),
                          body: body + " • \(playlist.name)",
                          fireDate: beforeDate)
            }

            // "At expiry": a calendar trigger at the exp_date
            // timestamp. An already-passed expiry fires once,
            // promptly — and is remembered per expiry timestamp so
            // later dashboard loads never re-fire it.
            let alertedKey = expiryAlertedKeyPrefix + playlist.id.uuidString
            let alreadyAlerted = UserDefaults.standard.double(forKey: alertedKey) == expiry.timeIntervalSince1970
            if expiry > now {
                await add(identifier: ids[1],
                          title: L("notifications.expired.title"),
                          body: L("notifications.expired.message", dateText(expiry)) + " • \(playlist.name)",
                          fireDate: expiry)
                UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: alertedKey)
            } else if !alreadyAlerted {
                await add(identifier: ids[1],
                          title: L("notifications.expired.title"),
                          body: L("notifications.expired.message", dateText(expiry)) + " • \(playlist.name)",
                          fireDate: now.addingTimeInterval(5))
                UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: alertedKey)
            }
        }
        // Playlists in the list WITHOUT a date: drop stale requests.
        let undatedIds = playlists
            .filter { ProviderExpiryStore.expiryDate(playlistId: $0.id) == nil }
            .flatMap { expiryIdentifiers(playlistId: $0.id) }
        if !undatedIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: undatedIds)
        }
    }

    /// Enumerating form: every playlist in the local DB, with dates
    /// read back from `ProviderExpiryStore`'s records.
    static func scheduleExpiryAlerts() async {
        let playlists = (try? await AppDatabase.shared.read { db in
            try Playlist.fetchAll(db)
        }) ?? []
        await scheduleExpiryAlerts(for: playlists)
    }

    private static func add(identifier: String, title: String, body: String, fireDate: Date) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static var dateText: (Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return { formatter.string(from: $0) }
    }

}
