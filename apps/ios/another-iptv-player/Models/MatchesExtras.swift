import Combine
import Foundation
import GRDB
import UserNotifications

// Build 63 (items 10/12): the matches additions — standings,
// top scorers, "watch on your channels", match reminders, team
// pages/search, and the in-app goal celebration. All data is
// the same free ESPN public feed family (no key) or the user's
// OWN local playlist/EPG data. Nothing is fabricated: a source
// that returns nothing produces an honest empty state.

// MARK: - 10a Standings

struct StandingEntry: Identifiable {
    var id: String { teamId ?? teamName }
    let teamId: String?
    let teamName: String
    let logoURL: URL?
    /// Stat display values keyed by ESPN stat name
    /// (gamesPlayed, wins, ties, losses, points,
    /// pointDifferential, …) — only what the feed returned.
    let stats: [String: String]
    /// Build 83 (item 2): the payload's OWN label for each
    /// stat — its `abbreviation`, falling back to its
    /// `shortDisplayName` — keyed by the same stat name. The
    /// standings header prints THESE labels, so a column can
    /// never be titled with a word ESPN didn't publish.
    let statLabels: [String: String]
    /// Build 83 (item 2): the entry's zone note, verbatim from
    /// the payload (`note.color` / `note.description` — e.g.
    /// "#81D6AC" / "Champions League"). Nil when the feed
    /// attaches no note to this entry (the whole NBA/NFL feed
    /// and some soccer leagues carry none) — no bar, no
    /// legend, nothing inferred from the rank.
    let noteColorHex: String?
    let noteText: String?
}

/// Build 83 (item 2): one legend row of a standings group —
/// a zone color + its payload description, deduplicated from
/// the group's entry notes in first-appearance order.
struct StandingLegendItem: Identifiable {
    var id: String { "\(colorHex)|\(text)" }
    let colorHex: String
    let text: String
}

struct StandingGroup: Identifiable {
    var id: String { name }
    let name: String
    let entries: [StandingEntry]
    /// Zone legend derived from the entries' payload notes;
    /// empty when the feed published no notes for the group.
    let legend: [StandingLegendItem]
}

enum MatchesStandingsService {
    private struct Wire: Decodable {
        let children: [Child]?
        struct Child: Decodable {
            let name: String?
            let standings: Standings?
        }
        struct Standings: Decodable { let entries: [Entry]? }
        struct Entry: Decodable {
            let team: Team?
            let stats: [Stat]?
            /// Build 83 (item 2): the zone note (singular in
            /// the payload): {color: "#81D6AC", description:
            /// "Champions League", rank: 1}.
            let note: Note?
        }
        struct Note: Decodable {
            let color: String?
            let description: String?
        }
        struct Team: Decodable {
            let id: String?
            let displayName: String?
            let name: String?
            let logos: [Logo]?
            let logo: String?
        }
        struct Logo: Decodable { let href: String? }
        struct Stat: Decodable {
            let name: String?
            let displayValue: String?
            /// Build 83 (item 2): the payload's own column
            /// labels (abbreviation "GD", shortDisplayName
            /// "GD") — decoded so the header never invents one.
            let abbreviation: String?
            let shortDisplayName: String?
        }
    }

    /// The league standings endpoint lives on the `apis/v2`
    /// family (the site/v2 path 404s): children carry conference
    /// / division / overall groups as the feed defines them.
    /// Build 84 (item 23): the payload goes through the sports
    /// disk cache — offline, the last real table renders with
    /// its `stamp` so the view can show when it was fetched.
    static func fetch(sport: MatchSport, leaguePath: String) async -> (groups: [StandingGroup], stamp: Date?) {
        let path = leaguePath
        guard let url = URL(string: "https://site.api.espn.com/apis/v2/sports/\(path)/standings"),
              let result = await SportsDiskCache.espnData(url: url, cacheKey: "st|\(path)"),
              let wire = try? JSONDecoder().decode(Wire.self, from: result.data)
        else { return ([], nil) }
        let groups = (wire.children ?? []).compactMap { child -> StandingGroup? in
            let entries = (child.standings?.entries ?? []).compactMap { entry -> StandingEntry? in
                guard let team = entry.team,
                      let name = team.displayName ?? team.name, !name.isEmpty else { return nil }
                var stats: [String: String] = [:]
                var statLabels: [String: String] = [:]
                for stat in entry.stats ?? [] {
                    guard let name = stat.name else { continue }
                    if let value = stat.displayValue { stats[name] = value }
                    if let label = stat.abbreviation ?? stat.shortDisplayName, !label.isEmpty {
                        statLabels[name] = label
                    }
                }
                let logo = team.logos?.first?.href ?? team.logo
                return StandingEntry(
                    teamId: team.id, teamName: name,
                    logoURL: logo.flatMap { URL(string: $0) },
                    stats: stats,
                    statLabels: statLabels,
                    noteColorHex: entry.note?.color,
                    noteText: entry.note?.description
                )
            }
            guard !entries.isEmpty else { return nil }
            // The group's legend: the distinct zone notes its
            // entries carry, in table order.
            var legend: [StandingLegendItem] = []
            for entry in entries {
                guard let color = entry.noteColorHex, let text = entry.noteText,
                      !legend.contains(where: { $0.colorHex == color && $0.text == text })
                else { continue }
                legend.append(StandingLegendItem(colorHex: color, text: text))
            }
            return StandingGroup(name: child.name ?? "", entries: entries, legend: legend)
        }
        return (groups, result.stamp)
    }
}

// MARK: - 10c Watch on your channels (local data only)

struct WatchChannelHit: Identifiable {
    var id: String { "\(playlistId.uuidString)|\(channelName)" }
    let playlistId: UUID
    let playlistName: String
    let channelName: String
    let channelLogoURL: URL?
    /// Everything the player needs, resolved at tap time.
    let streamRef: WatchStreamRef
}

enum WatchStreamRef {
    case xtreamLive(playlistId: UUID, streamId: Int)
    case m3u(url: URL, name: String, logoURL: URL?)
}

/// Searches the USER'S OWN playlists for a channel airing the
/// match: channel names against the two team names (and
/// against the league name). Local database only — no network,
/// and no broadcast claim is ever invented: a row appears only
/// when text in the user's own data literally matches.
/// (Build 80, fix round 1: the former EPG now/next
/// programme-title path was removed with the TV Guide/EPG
/// system — the guide data source no longer exists;
/// channel-name matching is unaffected.)
enum WatchChannelSearch {
    static func search(homeName: String?, awayName: String?, leagueName: String?) async -> [WatchChannelHit] {
        let needles = [homeName, awayName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }
        guard !needles.isEmpty else { return [] }
        let leagueNeedle = leagueName.flatMap { $0.count >= 4 ? $0 : nil }
        return (try? await AppDatabase.shared.read { db in
            var hits: [WatchChannelHit] = []
            var seen = Set<String>()
            let playlists = try Playlist.fetchAll(db)
            let namesById = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0.name) })

            func like(_ needle: String) -> String { "%" + needle + "%" }
            func xtreamHit(_ stream: DBLiveStream) -> WatchChannelHit {
                WatchChannelHit(
                    playlistId: stream.playlistId,
                    playlistName: namesById[stream.playlistId] ?? "",
                    channelName: stream.name,
                    channelLogoURL: stream.streamIcon.flatMap { URL(string: $0) },
                    streamRef: .xtreamLive(playlistId: stream.playlistId, streamId: stream.streamId)
                )
            }
            func m3uHit(_ channel: DBM3UChannel) -> WatchChannelHit? {
                guard let url = URL(string: channel.url) else { return nil }
                return WatchChannelHit(
                    playlistId: channel.playlistId,
                    playlistName: namesById[channel.playlistId] ?? "",
                    channelName: channel.name,
                    channelLogoURL: channel.tvgLogo.flatMap { URL(string: $0) },
                    streamRef: .m3u(url: url, name: channel.name, logoURL: channel.tvgLogo.flatMap { URL(string: $0) })
                )
            }

            // Channel names themselves (teams, then league).
            var nameNeedles = needles
            if let leagueNeedle { nameNeedles.append(leagueNeedle) }
            for needle in nameNeedles {
                let streams = try DBLiveStream
                    .filter(Column("name").like(like(needle)))
                    .limit(10)
                    .fetchAll(db)
                for stream in streams
                where seen.insert("x|\(stream.playlistId)|\(stream.streamId)").inserted {
                    hits.append(xtreamHit(stream))
                }
                let channels = try DBM3UChannel
                    .filter(Column("name").like(like(needle)))
                    .limit(10)
                    .fetchAll(db)
                for channel in channels where seen.insert("m|\(channel.id)").inserted {
                    if let hit = m3uHit(channel) { hits.append(hit) }
                }
            }
            return Array(hits.prefix(20))
        }) ?? []
    }
}

// MARK: - 10e Match reminders (local notifications)

/// A reminder is a LOCAL notification ~15 minutes before
/// kickoff, scheduled on-device only. Authorization is requested
/// in context (the first time a reminder is switched on) — never
/// at launch. Scheduled ids persist in UserDefaults so the
/// toggle state survives relaunch; the payload carries the same
/// deep-link contract as item 9 pushes.
final class MatchReminderService {
    static let shared = MatchReminderService()
    private let defaultsKey = "matches.reminders.v1"
    private init() {}

    func isScheduled(eventId: String) -> Bool {
        scheduledIds.contains(eventId)
    }

    private var scheduledIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: defaultsKey) }
    }

    /// Build 90 (SP22): prune reminders whose fire date has
    /// passed. The id set previously grew one-way — a fired
    /// reminder's id reported "scheduled" forever and could
    /// never be cleaned from any UI (S5 A6). The pending
    /// requests are the truth: an id survives only while its
    /// request is still pending with a future trigger date,
    /// and elapsed requests are removed outright.
    func prunePast() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let prefix = "match-reminder-"
        var liveIds = Set<String>()
        var deadRequestIds: [String] = []
        for request in pending where request.identifier.hasPrefix(prefix) {
            let eventId = String(request.identifier.dropFirst(prefix.count))
            let trigger = request.trigger as? UNCalendarNotificationTrigger
            if let next = trigger?.nextTriggerDate(), next > Date() {
                liveIds.insert(eventId)
            } else {
                deadRequestIds.append(request.identifier)
            }
        }
        if !deadRequestIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: deadRequestIds)
        }
        scheduledIds = scheduledIds.intersection(liveIds)
    }

    /// Build 66 (item 18): reports its CONFIRMED outcome — the
    /// returned Bool is the post-operation `isScheduled(eventId:)`
    /// state, never an optimistic claim. Enabling returns false
    /// (and records nothing) when there is no start date, when
    /// the fire date has already passed, when authorization is
    /// denied, or when the system refuses the request; the id is
    /// recorded only after the request was actually accepted.
    @discardableResult
    func setReminder(match: MatchEvent, leaguePath: String, sport: MatchSport, enabled: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        if enabled {
            guard let start = match.startDate else { return isScheduled(eventId: match.id) }
            let fireDate = start.addingTimeInterval(-15 * 60)
            guard fireDate > Date() else { return isScheduled(eventId: match.id) }
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return isScheduled(eventId: match.id) }
            let content = UNMutableNotificationContent()
            let home = match.home.name ?? ""
            let away = match.away.name ?? ""
            content.title = "\(home) – \(away)"
            content.body = L("matches.reminder.body")
            content.sound = .default
            content.userInfo = [
                "eventId": match.id, "leaguePath": leaguePath, "sport": sport.rawValue
            ]
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: "match-reminder-\(match.id)", content: content, trigger: trigger
            )
            do {
                try await center.add(request)
            } catch {
                return isScheduled(eventId: match.id)
            }
            var ids = scheduledIds
            ids.insert(match.id)
            scheduledIds = ids
            return isScheduled(eventId: match.id)
        } else {
            center.removePendingNotificationRequests(withIdentifiers: ["match-reminder-\(match.id)"])
            var ids = scheduledIds
            ids.remove(match.id)
            scheduledIds = ids
            return isScheduled(eventId: match.id)
        }
    }
}

// MARK: - 12a/12c Team pages + team search

struct TeamRef: Identifiable, Hashable {
    let id: String
    let sport: MatchSport
    let leaguePath: String
    let name: String
    let logoURL: URL?
}

struct SquadPlayer: Identifiable {
    let id: String
    let name: String
    let positionName: String?
    let headshotURL: URL?
    /// Build 84 (item 4): payload athlete id for the player
    /// page; nil when the payload carried none.
    var athleteId: String? = nil
    /// Build 86: the site roster payload's own citizenship /
    /// date of birth — corroboration inputs for the soccer
    /// photo fallback's identity gates (never rendered).
    var citizenship: String? = nil
    var dateOfBirth: String? = nil
    /// Build 90 (SP12): the roster payload's jersey number,
    /// rendered on the team page's squad rows.
    var jersey: String? = nil
}

enum TeamService {
    private struct TeamsWire: Decodable {
        let sports: [SportNode]?
        struct SportNode: Decodable { let leagues: [LeagueNode]? }
        struct LeagueNode: Decodable { let teams: [TeamWrap]? }
        struct TeamWrap: Decodable { let team: Team? }
        struct Team: Decodable {
            let id: String?
            let displayName: String?
            let name: String?
            let logos: [Logo]?
        }
        struct Logo: Decodable { let href: String? }
    }

    private struct ScheduleWire: Decodable { let events: [ESPNEvent]? }

    private struct RosterWire: Decodable {
        let athletes: [Athlete]?
        struct Athlete: Decodable {
            let id: String?
            let displayName: String?
            let firstName: String?
            let lastName: String?
            let headshot: Headshot?
            let position: Pos?
            /// Build 86: corroboration inputs for the soccer
            /// photo fallback (the soccer roster payload
            /// carries both; other sports may not).
            let citizenship: String?
            let dateOfBirth: String?
            /// Build 90 (SP12): the roster payload's jersey
            /// number (verified live 2026-11-21: present for
            /// 31/31 Arsenal athletes) — decoded but never
            /// rendered until now.
            let jersey: String?
            /// Build 85: baseball's roster payload GROUPS its
            /// athletes by position — each top-level entry is a
            /// group ({position: "Pitchers", items: [...]})
            /// rather than a player. The other sports' rosters
            /// are flat (no `items`), so this stays nil there.
            let items: [Athlete]?
        }
        struct Headshot: Decodable { let href: String? }
        struct Pos: Decodable { let displayName: String?; let name: String? }
    }

    /// Build 90 (SP4): the per-sport session cache for
    /// `allTeams` — team search is the sole caller and it
    /// opens on demand, so the first open pays the fetches
    /// and every repeat open this session is free. Only
    /// non-empty results are cached, so a failed open can
    /// retry on the next open.
    private final class AllTeamsCache: @unchecked Sendable {
        static let shared = AllTeamsCache()
        private let lock = NSLock()
        private var entries: [String: [TeamRef]] = [:]
        func get(_ sport: MatchSport) -> [TeamRef]? {
            lock.lock(); defer { lock.unlock() }
            return entries[sport.rawValue]
        }
        func put(_ sport: MatchSport, _ teams: [TeamRef]) {
            lock.lock(); defer { lock.unlock() }
            entries[sport.rawValue] = teams
        }
    }

    /// 12c: every team in a sport's leagues (for search).
    /// Build 90 (SP4): for soccer this iterates the full
    /// 17-league browser catalog, not just the featured six
    /// in `leaguePaths` — Ajax, Celtic, Porto, Club América,
    /// Palmeiras, every MLS side and the Europa/Conference
    /// clubs could not be searched (and therefore not
    /// followed) before. The site/v2 teams endpoint serves
    /// every catalog league in the identical wire shape
    /// (ned.1 verified live 2026-11-21: 18 teams).
    static func allTeams(sport: MatchSport) async -> [TeamRef] {
        // Build 87 (item 1): NHL teams come from the NHL API's
        // standings payload (abbrev-keyed TeamRefs), never the
        // ESPN teams endpoint.
        if sport == .nhl {
            return await NHLService.allTeams()
        }
        if let cached = AllTeamsCache.shared.get(sport) {
            return cached
        }
        let paths = sport == .soccer
            ? MatchSport.soccerLeagueCatalog.map { $0.leaguePath }
            : sport.leaguePaths
        var out: [TeamRef] = []
        for leaguePath in paths {
            let path = leaguePath
            guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/teams"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let wire = try? JSONDecoder().decode(TeamsWire.self, from: data) else { continue }
            for wrap in wire.sports?.first?.leagues?.first?.teams ?? [] {
                guard let team = wrap.team, let id = team.id,
                      let name = team.displayName ?? team.name else { continue }
                out.append(TeamRef(
                    id: id, sport: sport, leaguePath: leaguePath, name: name,
                    logoURL: team.logos?.first?.href.flatMap { URL(string: $0) }
                ))
            }
        }
        if !out.isEmpty {
            AllTeamsCache.shared.put(sport, out)
        }
        return out
    }

    /// 12a: the team's fixtures + results (the schedule endpoint
    /// returns the season's events in the scoreboard shape).
    static func schedule(sport: MatchSport, leaguePath: String, teamId: String) async -> [MatchEvent] {
        let path = leaguePath
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/teams/\(teamId)/schedule"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let wire = try? JSONDecoder().decode(ScheduleWire.self, from: data) else { return [] }
        return (wire.events ?? []).compactMap { MatchesService.mapEvent($0) }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    /// 12a: the squad as the feed lists it (photos via payload
    /// headshot or the 8c CDN pattern). Build 85: baseball's
    /// GROUPED roster is flattened in payload order, each
    /// player keeping his own position (the group's position
    /// name is the fallback when an entry carries none).
    static func squad(sport: MatchSport, leaguePath: String, teamId: String) async -> [SquadPlayer] {
        let path = leaguePath
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/teams/\(teamId)/roster"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let wire = try? JSONDecoder().decode(RosterWire.self, from: data) else { return [] }
        var flat: [(athlete: RosterWire.Athlete, groupPosition: String?)] = []
        for entry in wire.athletes ?? [] {
            if let items = entry.items, !items.isEmpty {
                let groupName = entry.position?.displayName ?? entry.position?.name
                for item in items { flat.append((item, groupName)) }
            } else {
                flat.append((entry, nil))
            }
        }
        return flat.compactMap { pair in
            let athlete = pair.athlete
            let name = athlete.displayName
                ?? [athlete.firstName, athlete.lastName].compactMap { $0 }.joined(separator: " ")
            guard !name.isEmpty else { return nil }
            let segment: String
            switch sport {
            case .soccer: segment = "soccer"
            case .nba: segment = "nba"
            case .nfl: segment = "nfl"
            case .mlb: segment = "mlb"
            // Build 87: NHL squads come from the NHL API
            // (NHLTeamPageView) — this ESPN roster path is
            // never called for hockey; the case keeps the
            // switch exhaustive.
            case .nhl: segment = "nhl"
            }
            let headshot = athlete.headshot?.href.flatMap { URL(string: $0) }
                ?? athlete.id.flatMap {
                    URL(string: "https://a.espncdn.com/i/headshots/\(segment)/players/full/\($0).png")
                }
            return SquadPlayer(
                id: athlete.id ?? name,
                name: name,
                positionName: athlete.position?.displayName ?? athlete.position?.name
                    ?? pair.groupPosition,
                headshotURL: headshot,
                athleteId: athlete.id,
                citizenship: athlete.citizenship,
                dateOfBirth: athlete.dateOfBirth,
                jersey: athlete.jersey
            )
        }
    }
}

// MARK: - 12d In-app goal celebration (corrected rule)

struct GoalAlert: Identifiable {
    let id = UUID()
    let teamName: String
    let scorerName: String?
    let minuteText: String?
    let scoreText: String
    let headshotURL: URL?
}

/// Presents goal celebrations inside the app. CORRECTED RULE
/// (owner, item 12d): while the player is on screen — watching
/// ANYTHING — nothing is presented, ever; there is no setting
/// and no banner. Presentation happens only while browsing.
final class GoalAlertPresenter: ObservableObject {
    static let shared = GoalAlertPresenter()
    @Published var current: GoalAlert?
    private var dismissTask: Task<Void, Never>?
    private init() {}

    func present(_ alert: GoalAlert) {
        // Hard suppression: player presented (fullscreen OR
        // mini) → the alert is dropped, silently. Scores still
        // refresh through the normal Matches data paths.
        guard PlayerOverlayController.presentationActiveCount == 0 else { return }
        dismissTask?.cancel()
        current = alert
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { self.current = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

/// Detects goals for followed teams while the app is in the
/// foreground: polls today's scoreboard for the followed leagues
/// on a 60-second interval (through the shared day cache, so the
/// Matches screens and the poller share one fetch), diffs live
/// scores against the last seen snapshot, and celebrates an
/// increase for a followed team whose goal toggle is on.
///
/// LAUNCH RULE: the poller starts ONLY from a user context —
/// following a team, or a dashboard appearing while follows
/// exist — never from app launch code, and all its work is
/// async network + a UserDefaults snapshot (no blocking, no
/// observers on the launch path).
final class GoalAlertService {
    static let shared = GoalAlertService()
    private var timerTask: Task<Void, Never>?
    private let snapshotKey = "matches.liveScoreSnapshot.v1"
    private init() {}

    func startIfNeeded() {
        guard timerTask == nil else { return }
        guard !FollowedTeamsStore.shared.teams.isEmpty else { return }
        timerTask = Task {
            while !Task.isCancelled {
                await self.poll()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func poll() async {
        let follows = FollowedTeamsStore.shared.teams.filter { $0.notifyGoals }
        guard !follows.isEmpty else { return }
        var snapshot = UserDefaults.standard.dictionary(forKey: snapshotKey) as? [String: String] ?? [:]
        var changed = false
        var leagues = Set<String>()
        for team in follows { leagues.insert("\(team.sportRaw)|\(team.leaguePath)") }
        for key in leagues {
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 2, let sport = MatchSport(rawValue: parts[0]) else { continue }
            // Build 85: baseball has no goals — the in-app
            // celebration (a soccer-scored moment by design)
            // never fires for an MLB follow; run alerts are
            // out of scope for this sport entirely.
            if sport == .mlb { continue }
            let events = await MatchesService.todaysMatches(sport: sport, leaguePath: parts[1])
            for event in events where event.state == .live {
                let scoreKey = "\(event.id)"
                let current = "\(event.home.score ?? "")-\(event.away.score ?? "")"
                let previous = snapshot[scoreKey]
                snapshot[scoreKey] = current
                changed = true
                guard let previous, previous != current else { continue }
                // Which side scored? The side whose number rose.
                let prevParts = previous.split(separator: "-").map { Int($0) ?? 0 }
                let curParts = current.split(separator: "-").map { Int($0) ?? 0 }
                guard prevParts.count == 2, curParts.count == 2 else { continue }
                let scoredSide: MatchTeamSide?
                if curParts[0] > prevParts[0] { scoredSide = event.home }
                else if curParts[1] > prevParts[1] { scoredSide = event.away }
                else { scoredSide = nil }
                guard let side = scoredSide, let teamId = side.teamId,
                      follows.contains(where: {
                          $0.teamId == teamId && $0.leaguePath == parts[1] && $0.sportRaw == parts[0]
                      }) else { continue }
                // Scorer + minute from the detail timeline
                // (best effort — the alert fires without them
                // if the summary lags the scoreboard).
                var scorer: String?
                var minute: String?
                var photo: URL?
                if let detail = try? await MatchesService.fetchDetail(
                    sport: sport, leaguePath: parts[1], eventId: event.id
                ), let goal = detail.timeline.last(where: {
                    ($0.kind == .goal || $0.kind == .scoring) && $0.teamName == side.name
                }) {
                    scorer = goal.playerName
                    minute = goal.minuteText
                    photo = goal.headshotURL
                }
                let alert = GoalAlert(
                    teamName: side.name ?? "",
                    scorerName: scorer,
                    minuteText: minute,
                    scoreText: "\(event.home.name ?? "") \(event.home.score ?? "") – \(event.away.score ?? "") \(event.away.name ?? "")",
                    headshotURL: photo
                )
                await MainActor.run { GoalAlertPresenter.shared.present(alert) }
            }
        }
        if changed {
            UserDefaults.standard.set(snapshot, forKey: snapshotKey)
        }
    }
}
