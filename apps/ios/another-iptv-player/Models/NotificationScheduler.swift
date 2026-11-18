import Foundation
import GRDB
import UserNotifications

/// Round 15 (C11 + C3): the ONE local-notification scheduler, over
/// `UNUserNotificationCenter`. It carries:
///  - subscription-expiry alerts, scheduled from the exp_date
///    timestamps recorded by `ProviderExpiryStore` (the same record
///    the playback gate reads), gated by the EXISTING Settings
///    expiry-alerts toggle (`notifications.expiryAlertsEnabled`);
///  - new-episode alerts for favorite / in-progress series, gated
///    by the programme-reminders toggle (`reminders.enabled`).
///
/// EPG programme reminders ARE routed through here as of build 61
/// (B1): `scheduleProgrammeReminder(title:channelName:startDate:id:)`
/// is the §5 contract the programme detail sheet calls; the sheet
/// previously scheduled directly on `UNUserNotificationCenter`.
///
/// Authorization is requested ONLY when there is something real to
/// schedule (a recorded expiry date, or genuinely new episodes) —
/// never on a bare first launch.
enum NotificationScheduler {
    // MARK: - Settings keys (owned by Settings; read-only here)

    private static var expiryAlertsEnabled: Bool {
        UserDefaults.standard.object(forKey: "notifications.expiryAlertsEnabled") as? Bool ?? true
    }
    private static var remindersEnabled: Bool {
        UserDefaults.standard.object(forKey: "reminders.enabled") as? Bool ?? true
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

    // MARK: - Programme reminders (build 61, B1 — SPEC §5 contract)

    /// The Settings-owned lead time (minutes before programme start)
    /// the reminder fires at; the picker lives in Settings
    /// (`reminders.leadTimeMinutes`, default 10).
    private static var reminderLeadMinutes: Int {
        UserDefaults.standard.object(forKey: "reminders.leadTimeMinutes") as? Int ?? 10
    }

    /// Stable request identifier for a programme reminder. `id` is
    /// the caller-supplied programme identity (the detail sheet
    /// passes `"<channelKey>|<start epoch seconds>"`, which produces
    /// exactly the identifier earlier builds scheduled under, so
    /// reminders set before this refactor stay visible/cancellable).
    static func programmeReminderIdentifier(id: String) -> String {
        "epg.reminder.\(id)"
    }

    /// Schedules a local notification for one programme, firing at
    /// `startDate` minus the Settings lead time. Title is the
    /// programme title, body the channel name (the same content the
    /// detail sheet used when it scheduled directly). Re-scheduling
    /// the same `id` replaces the pending request. Returns false —
    /// and schedules nothing — when the reminders toggle is off,
    /// when the fire moment has already passed, or when
    /// authorization is not granted.
    @discardableResult
    static func scheduleProgrammeReminder(title: String, channelName: String, startDate: Date, id: String) async -> Bool {
        guard remindersEnabled else { return false }
        let fireDate = startDate.addingTimeInterval(-Double(reminderLeadMinutes) * 60)
        guard fireDate > Date() else { return false }
        guard await requestAuthorization() else { return false }
        await add(identifier: programmeReminderIdentifier(id: id),
                  title: title,
                  body: channelName,
                  fireDate: fireDate)
        return await isProgrammeReminderSet(id: id)
    }

    /// Removes the pending reminder for `id`, if any.
    static func cancelProgrammeReminder(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [programmeReminderIdentifier(id: id)])
    }

    /// Whether a reminder for `id` is currently pending.
    static func isProgrammeReminderSet(id: String) async -> Bool {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.contains { $0.identifier == programmeReminderIdentifier(id: id) }
    }

    // MARK: - C3: new-episode alerts

    /// Schedules ONE immediate local notification naming the series
    /// and its genuinely new episodes (count + real episode titles
    /// where the caller has them). No-ops when reminders are off,
    /// when there is nothing new, or when authorization is denied.
    static func scheduleNewEpisodeAlerts(forSeries seriesName: String, episodeTitles: [String]) async {
        guard remindersEnabled, !episodeTitles.isEmpty else { return }
        guard await requestAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = seriesName
        content.body = episodeTitles.count == 1
            ? episodeTitles[0]
            : L("series.new_episodes_format", episodeTitles.count)
        content.sound = .default
        // Stable per (series, batch): re-running the same diff
        // replaces rather than duplicates.
        let digest = (seriesName + "|" + episodeTitles.joined(separator: "|")).hashValue & Int.max
        let request = UNNotificationRequest(
            identifier: "superx.newepisode.\(digest)",
            content: content,
            trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Diffs the locally stored episode IDs of every favorite and
    /// in-progress (watched) series of this playlist against the
    /// per-series baseline in UserDefaults
    /// (`alerts.knownEpisodeIds.<seriesId>`).
    ///
    /// FIRST run per series only records the baseline — no alert.
    /// Later runs with genuinely new episode IDs schedule one
    /// immediate alert per series (via `scheduleNewEpisodeAlerts`)
    /// and advance the baseline. Series whose episodes were never
    /// loaded locally have nothing real to diff and are skipped.
    /// This key namespace is the alerts framework's own; the
    /// series-detail "new" badge uses a separate store.
    static func checkNewEpisodes(playlist: Playlist) async {
        guard remindersEnabled else { return }

        struct SeriesEpisodes {
            let seriesId: Int
            let name: String
            let episodeIds: [String]
            let titlesById: [String: String]
        }

        let found: [SeriesEpisodes] = (try? await AppDatabase.shared.read { db -> [SeriesEpisodes] in
            // Candidate series: favorites (type "series") plus
            // series with watch history (in-progress / watched).
            var candidateIds = Set<Int>()
            let favorites = try DBFavorite
                .filter(Column("playlistId") == playlist.id && Column("type") == "series")
                .fetchAll(db)
            candidateIds.formUnion(favorites.map(\.streamId))
            let history = try DBWatchHistory
                .filter(Column("playlistId") == playlist.id && Column("type") == "series")
                .fetchAll(db)
            for row in history {
                if let sid = row.seriesId.flatMap(Int.init) { candidateIds.insert(sid) }
            }
            guard !candidateIds.isEmpty else { return [] }

            var result: [SeriesEpisodes] = []
            for seriesId in candidateIds {
                guard let series = try DBSeries
                    .filter(Column("seriesId") == seriesId && Column("playlistId") == playlist.id)
                    .fetchOne(db) else { continue }
                let seasonIds = try DBSeason
                    .filter(Column("seriesId") == seriesId && Column("playlistId") == playlist.id)
                    .fetchAll(db)
                    .map(\.id)
                guard !seasonIds.isEmpty else { continue }
                let episodes = try DBEpisode
                    .filter(seasonIds.contains(Column("seasonId")))
                    .fetchAll(db)
                guard !episodes.isEmpty else { continue }
                var titles: [String: String] = [:]
                var ids: [String] = []
                for episode in episodes {
                    let stableId = episode.episodeId ?? episode.id
                    ids.append(stableId)
                    if let title = episode.title, !title.isEmpty { titles[stableId] = title }
                }
                result.append(SeriesEpisodes(
                    seriesId: seriesId, name: series.name,
                    episodeIds: ids, titlesById: titles))
            }
            return result
        }) ?? []

        let defaults = UserDefaults.standard
        for series in found {
            let key = "alerts.knownEpisodeIds.\(series.seriesId)"
            let current = Set(series.episodeIds)
            guard let known = defaults.stringArray(forKey: key) else {
                // First run for this series: baseline only.
                defaults.set(series.episodeIds, forKey: key)
                continue
            }
            let newIds = current.subtracting(Set(known))
            if newIds.isEmpty {
                // Removals only (e.g. ghost-episode cleanup):
                // silently re-baseline, never alert.
                if current != Set(known) { defaults.set(series.episodeIds, forKey: key) }
                continue
            }
            let newTitles = newIds
                .sorted()
                .map { series.titlesById[$0] ?? $0 }
            defaults.set(series.episodeIds, forKey: key)
            await scheduleNewEpisodeAlerts(forSeries: series.name, episodeTitles: newTitles)
        }
    }
}
