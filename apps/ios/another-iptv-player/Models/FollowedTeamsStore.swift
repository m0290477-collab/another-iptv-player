import Foundation

/// Build 63 (owner, item 9): followed teams for goal/kickoff/
/// full-time push notifications.
///
/// Persistence: a JSON record in UserDefaults, mirrored into the
/// user's iCloud key-value store so the follow set syncs across
/// their devices like the app's other preferences. The store is
/// touched ONLY from the Matches UI (first access creates the
/// shared instance) — nothing here runs at cold launch beyond
/// what a screen the user opened asks for (hard launch rule).
///
/// Identity is (sport, leaguePath, teamId): ESPN team ids are
/// per-league in the feed, and the server watcher matches
/// fixtures per league, so the same club in two competitions is
/// two follows — exactly how the feed is structured.
struct FollowedTeam: Codable, Equatable, Identifiable {
    var id: String { "\(sportRaw)|\(leaguePath)|\(teamId)" }
    let sportRaw: String
    let leaguePath: String
    let teamId: String
    let teamName: String
    /// Per-team notification preferences (owner's spec): goals
    /// default ON; kickoff and full-time default OFF.
    var notifyGoals: Bool = true
    var notifyKickoff: Bool = false
    var notifyFullTime: Bool = false
}

final class FollowedTeamsStore: ObservableObject {
    static let shared = FollowedTeamsStore()

    private static let defaultsKey = "matches.followedTeams.v1"

    @Published private(set) var teams: [FollowedTeam] = []

    private init() {
        teams = Self.loadLocal()
        // iCloud KVS mirror: pull a newer synced set in when the
        // store changes externally (another device). Registered
        // here — i.e. on first USE of the store, never at launch.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvsDidChangeExternally),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )
        if let synced = Self.loadFromKVS(), synced != teams {
            teams = synced
            Self.saveLocal(synced)
        }
    }

    // MARK: Queries

    func isFollowing(sport: MatchSport, leaguePath: String, teamId: String) -> Bool {
        teams.contains {
            $0.sportRaw == sport.rawValue && $0.leaguePath == leaguePath && $0.teamId == teamId
        }
    }

    func team(sport: MatchSport, leaguePath: String, teamId: String) -> FollowedTeam? {
        teams.first {
            $0.sportRaw == sport.rawValue && $0.leaguePath == leaguePath && $0.teamId == teamId
        }
    }

    // MARK: Mutations

    func follow(sport: MatchSport, leaguePath: String, teamId: String, teamName: String) {
        guard !isFollowing(sport: sport, leaguePath: leaguePath, teamId: teamId) else { return }
        let wasEmpty = teams.isEmpty
        teams.append(FollowedTeam(
            sportRaw: sport.rawValue, leaguePath: leaguePath,
            teamId: teamId, teamName: teamName
        ))
        persistAndSync()
        // APNs authorization is requested at THIS moment — the
        // user's first follow — never at cold launch (item 9).
        if wasEmpty {
            PushNotificationService.shared.ensureAuthorizationAndRegister()
        } else {
            PushNotificationService.shared.uploadRegistration()
        }
    }

    func unfollow(sport: MatchSport, leaguePath: String, teamId: String) {
        teams.removeAll {
            $0.sportRaw == sport.rawValue && $0.leaguePath == leaguePath && $0.teamId == teamId
        }
        persistAndSync()
        PushNotificationService.shared.uploadRegistration()
    }

    func updatePreferences(_ updated: FollowedTeam) {
        guard let index = teams.firstIndex(where: { $0.id == updated.id }) else { return }
        teams[index] = updated
        persistAndSync()
        PushNotificationService.shared.uploadRegistration()
    }

    // MARK: Persistence + sync

    private func persistAndSync() {
        Self.saveLocal(teams)
        if let data = try? JSONEncoder().encode(teams) {
            NSUbiquitousKeyValueStore.default.set(data, forKey: Self.defaultsKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    private static func loadLocal() -> [FollowedTeam] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([FollowedTeam].self, from: data)
        else { return [] }
        return decoded
    }

    private static func saveLocal(_ teams: [FollowedTeam]) {
        if let data = try? JSONEncoder().encode(teams) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func loadFromKVS() -> [FollowedTeam]? {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([FollowedTeam].self, from: data)
        else { return nil }
        return decoded
    }

    @objc private func kvsDidChangeExternally() {
        guard let synced = Self.loadFromKVS(), synced != teams else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.teams != synced else { return }
            self.teams = synced
            Self.saveLocal(synced)
        }
    }
}
