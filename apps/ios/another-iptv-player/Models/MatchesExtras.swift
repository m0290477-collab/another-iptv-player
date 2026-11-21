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
        let groups = (wire.children ?? []).compactMap { child in
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

// MARK: - 10b Top scorers (soccer, core API leaders)

struct ScorerEntry: Identifiable {
    var id: String { athleteId }
    let athleteId: String
    let name: String
    let teamName: String?
    let goals: Int
    let headshotURL: URL?
}

enum MatchesScorersService {
    private struct LeadersWire: Decodable {
        let categories: [Category]?
        struct Category: Decodable {
            let name: String?
            let leaders: [Leader]?
        }
        struct Leader: Decodable {
            let value: Double?
            let athlete: Ref?
            let team: Ref?
        }
        struct Ref: Decodable { let ref: String?; enum CodingKeys: String, CodingKey { case ref = "$ref" } }
    }
    private struct NameWire: Decodable { let displayName: String?; let name: String? }

    /// Season leaders live on the CORE api as $ref graphs:
    /// categories → goalsLeaders → leaders(value = goals,
    /// athlete/team = reference URLs whose last path component
    /// is the id — the headshot comes from the item-8c CDN
    /// pattern; names need one small dereference each, fetched
    /// concurrently). Season year = the European season's start
    /// year (Jul–Jun). Leagues that publish no leaders return an
    /// empty list — honest empty upstream.
    static func fetch(leaguePath: String) async -> [ScorerEntry] {
        let now = Date()
        let comps = Calendar.current.dateComponents([.year, .month], from: now)
        let season = (comps.month ?? 1) >= 7 ? (comps.year ?? 2026) : (comps.year ?? 2026) - 1
        // Build 83 (item 3): callers pass the full site path
        // ("soccer/eng.1") — the form every other Matches
        // service takes — but the core API's leagues segment
        // takes the bare slug ("eng.1"). Interpolating the
        // full path produced …/leagues/soccer/eng.1/…, which
        // the core API answers HTTP 400, so Top Scorers had
        // been silently empty for every league. Verified live
        // 2026-11-20: the slug form returns goalsLeaders for
        // all 17 catalog leagues.
        let slug = leaguePath.split(separator: "/").last.map(String.init) ?? leaguePath
        let urlString = "https://sports.core.api.espn.com/v2/sports/soccer/leagues/\(slug)/seasons/\(season)/types/1/leaders"
        guard let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let wire = try? JSONDecoder().decode(LeadersWire.self, from: data),
              let category = (wire.categories ?? []).first(where: { $0.name == "goalsLeaders" })
                ?? wire.categories?.first else { return [] }
        let leaders = Array((category.leaders ?? []).prefix(15))
        return await withTaskGroup(of: ScorerEntry?.self) { group in
            for leader in leaders {
                group.addTask {
                    guard let ref = leader.athlete?.ref,
                          let athleteId = ref.split(separator: "/").last.map(String.init) else { return nil }
                    let name = await derefName(ref)
                    guard let name else { return nil }
                    let teamName = await leader.team?.ref.asyncFlatMap { await derefName($0) }
                    return ScorerEntry(
                        athleteId: athleteId,
                        name: name,
                        teamName: teamName,
                        goals: Int(leader.value ?? 0),
                        headshotURL: URL(string: "https://a.espncdn.com/i/headshots/soccer/players/full/\(athleteId).png")
                    )
                }
            }
            var out: [ScorerEntry] = []
            for await entry in group { if let entry { out.append(entry) } }
            return out.sorted { $0.goals > $1.goals }
        }
    }

    private static func derefName(_ ref: String) async -> String? {
        guard let url = URL(string: ref) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let wire = try? JSONDecoder().decode(NameWire.self, from: data) else { return nil }
        return wire.displayName ?? wire.name
    }
}

private extension Optional where Wrapped == String {
    func asyncFlatMap(_ transform: (String) async -> String?) async -> String? {
        guard let self else { return nil }
        return await transform(self)
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
        }
        struct Headshot: Decodable { let href: String? }
        struct Pos: Decodable { let displayName: String?; let name: String? }
    }

    /// 12c: every team in a sport's leagues (for search).
    static func allTeams(sport: MatchSport) async -> [TeamRef] {
        var out: [TeamRef] = []
        for leaguePath in sport.leaguePaths {
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
    /// headshot or the 8c CDN pattern).
    static func squad(sport: MatchSport, leaguePath: String, teamId: String) async -> [SquadPlayer] {
        let path = leaguePath
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/teams/\(teamId)/roster"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let wire = try? JSONDecoder().decode(RosterWire.self, from: data) else { return [] }
        return (wire.athletes ?? []).compactMap { athlete in
            let name = athlete.displayName
                ?? [athlete.firstName, athlete.lastName].compactMap { $0 }.joined(separator: " ")
            guard !name.isEmpty else { return nil }
            let segment = sport == .nfl ? "nfl" : sport == .nba ? "nba" : "soccer"
            let headshot = athlete.headshot?.href.flatMap { URL(string: $0) }
                ?? athlete.id.flatMap {
                    URL(string: "https://a.espncdn.com/i/headshots/\(segment)/players/full/\($0).png")
                }
            return SquadPlayer(
                id: athlete.id ?? name,
                name: name,
                positionName: athlete.position?.displayName ?? athlete.position?.name,
                headshotURL: headshot,
                athleteId: athlete.id
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
