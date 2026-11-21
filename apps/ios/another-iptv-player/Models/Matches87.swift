import Foundation

// MARK: - Build 87 services
//
// Everything in this file is a NEW free source (or a deeper
// cut of an existing one), verified live on 2026-11-21 before
// a line was written — the build-87 report carries the
// per-endpoint evidence. The discipline is the app's standing
// one: keyless sources only, every field decoded as optional,
// nothing fabricated (a source that returns nothing produces
// an honest empty state), and the payloads flow into the
// EXISTING domain models wherever the Matches architecture
// already has one, so the shared surfaces (tabs, Live Now,
// calendar, Watch, kickoff bell, follows, offline cache)
// consume the new sports unchanged.

// MARK: - NHL (item 1) — the NHL's official free API
//
// Source: https://api-web.nhle.com/v1 — the league's own
// public API, no key. Verified live 2026-11-21: schedule
// (200, full game week), standings/now (200 via redirect),
// roster/{abbrev}/current (200, headshots inline),
// club-schedule-season (200), club-stats (200),
// skater-stats-leaders + goalie-stats-leaders (200, headshots
// inline), player/{id}/landing (200), gamecenter/{id}/landing
// + /boxscore (200). The API publishes NO news feed — the NHL
// tab therefore has no News entry (never a fake one), and no
// direct-MP4 highlights (its recap ids point at nhl.com
// pages) — hockey is excluded from the highlights feed for
// exactly that reason (see SportsHubService).

/// The NHL payloads write localized strings as objects
/// ({"default": "Toronto"}); a few endpoints use a bare
/// string for the same field. This decodes BOTH shapes.
struct NHLText: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        if let object = try? decoder.singleValueContainer().decode(ObjectForm.self) {
            value = object.text
            return
        }
        value = try? decoder.singleValueContainer().decode(String.self)
    }
    private struct ObjectForm: Decodable {
        let text: String?
        enum CodingKeys: String, CodingKey { case text = "default" }
    }
}

enum NHLService {
    private static let base = "https://api-web.nhle.com/v1"

    // MARK: Wire models

    struct TeamSide: Decodable {
        let id: Int?
        let abbrev: String?
        let commonName: NHLText?
        let placeName: NHLText?
        let logo: String?
        let score: Int?
    }

    struct PeriodDescriptor: Decodable {
        let number: Int?
        let periodType: String?
    }

    struct Clock: Decodable {
        let timeRemaining: String?
        let running: Bool?
    }

    struct GameOutcome: Decodable {
        let lastPeriodType: String?
    }

    struct Game: Decodable {
        let id: Int?
        let startTimeUTC: String?
        let gameState: String?
        let awayTeam: TeamSide?
        let homeTeam: TeamSide?
        let periodDescriptor: PeriodDescriptor?
        let clock: Clock?
        let gameOutcome: GameOutcome?
        let venue: NHLText?
    }

    private struct ScheduleWire: Decodable {
        let gameWeek: [Day]?
        struct Day: Decodable {
            let date: String?
            let games: [Game]?
        }
    }

    private struct StandingsWire: Decodable {
        let standings: [Entry]?
        struct Entry: Decodable {
            let conferenceName: String?
            let divisionName: String?
            let teamName: NHLText?
            let teamAbbrev: NHLText?
            let teamLogo: String?
            let gamesPlayed: Int?
            let wins: Int?
            let losses: Int?
            let otLosses: Int?
            let points: Int?
            let goalFor: Int?
            let goalAgainst: Int?
            let goalDifferential: Int?
            let streakCode: String?
            let streakCount: Int?
            let winPctg: Double?
        }
    }

    private struct RosterWire: Decodable {
        let forwards: [Player]?
        let defensemen: [Player]?
        let goalies: [Player]?
        struct Player: Decodable {
            let id: Int?
            let headshot: String?
            let firstName: NHLText?
            let lastName: NHLText?
            let sweaterNumber: Int?
            let positionCode: String?
        }
    }

    private struct ClubScheduleWire: Decodable {
        let games: [Game]?
    }

    struct ClubStatsWire: Decodable {
        let skaters: [Skater]?
        let goalies: [Goalie]?
        struct Skater: Decodable {
            let playerId: Int?
            let firstName: NHLText?
            let lastName: NHLText?
            let headshot: String?
            let positionCode: String?
            let gamesPlayed: Int?
            let goals: Int?
            let assists: Int?
            let points: Int?
        }
        struct Goalie: Decodable {
            let playerId: Int?
            let firstName: NHLText?
            let lastName: NHLText?
            let headshot: String?
            let gamesPlayed: Int?
            let wins: Int?
            let savePctg: Double?
        }
    }

    // MARK: Fetch helper (disk-cached like every sports source)

    private static func fetchData(_ urlString: String, cacheKey: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        return await SportsDiskCache.espnData(url: url, cacheKey: cacheKey)?.data
    }

    // MARK: Team logos (PNG)

    /// NHL team logos: the NHL API's own logo URLs are SVG,
    /// which the image pipeline cannot render. ESPN's NHL
    /// teams payload publishes the same clubs' PNG logos —
    /// verified live 2026-11-21 (32 teams, pattern
    /// a.espncdn.com/i/teamlogos/nhl/500/{abbrev}.png). The
    /// map is fetched once per session (disk-cached); the
    /// deterministic CDN pattern is the fallback for an
    /// abbrev the payload somehow omits.
    private final class LogoMapCache: @unchecked Sendable {
        static let shared = LogoMapCache()
        private let lock = NSLock()
        private var map: [String: URL]?
        func get() -> [String: URL]? { lock.lock(); defer { lock.unlock() }; return map }
        func put(_ value: [String: URL]) { lock.lock(); defer { lock.unlock() }; map = value }
    }

    private struct ESPNHockeyTeamsWire: Decodable {
        let sports: [SportNode]?
        struct SportNode: Decodable { let leagues: [LeagueNode]? }
        struct LeagueNode: Decodable { let teams: [TeamWrap]? }
        struct TeamWrap: Decodable { let team: Team? }
        struct Team: Decodable {
            let abbreviation: String?
            let logos: [Logo]?
        }
        struct Logo: Decodable { let href: String? }
    }

    static func logoURL(abbrev: String) async -> URL? {
        if let map = LogoMapCache.shared.get() {
            return map[abbrev] ?? patternLogo(abbrev)
        }
        var map: [String: URL] = [:]
        if let data = await fetchData(
            "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/teams",
            cacheKey: "nhl-logos"
        ), let wire = try? JSONDecoder().decode(ESPNHockeyTeamsWire.self, from: data) {
            for wrap in wire.sports?.first?.leagues?.first?.teams ?? [] {
                guard let team = wrap.team, let abbrev = team.abbreviation,
                      let href = team.logos?.first?.href, let url = URL(string: href)
                else { continue }
                map[abbrev] = url
            }
        }
        LogoMapCache.shared.put(map)
        return map[abbrev] ?? patternLogo(abbrev)
    }

    private static func patternLogo(_ abbrev: String) -> URL? {
        URL(string: "https://a.espncdn.com/i/teamlogos/nhl/500/\(abbrev.lowercased()).png")
    }

    // MARK: Scoreboard (routed from MatchesService.fetchLeague)

    /// One day's games from the NHL schedule endpoint (which
    /// returns a 7-day game week containing the requested
    /// date), mapped into the shared domain models.
    static func scoreboard(dateParameter: String) async throws -> MatchLeagueResult {
        let day = apiDay(from: dateParameter)
        guard let data = await fetchData("\(base)/schedule/\(day)", cacheKey: "sb|nhl|\(dateParameter)"),
              let wire = try? JSONDecoder().decode(ScheduleWire.self, from: data)
        else { throw URLError(.badServerResponse) }
        let games = (wire.gameWeek ?? []).first(where: { $0.date == day })?.games ?? []
        var matches: [MatchEvent] = []
        for game in games {
            if let match = await mapGame(game) { matches.append(match) }
        }
        return MatchLeagueResult(leagueName: "NHL", matches: matches)
    }

    /// yyyyMMdd (the app's day parameter) → yyyy-MM-dd (the
    /// NHL API's day form).
    private static func apiDay(from parameter: String) -> String {
        guard parameter.count == 8 else { return parameter }
        let year = parameter.prefix(4)
        let month = parameter.dropFirst(4).prefix(2)
        let day = parameter.dropFirst(6).prefix(2)
        return "\(year)-\(month)-\(day)"
    }

    static func mapGame(_ game: Game) async -> MatchEvent? {
        guard let id = game.id,
              let away = game.awayTeam, let home = game.homeTeam,
              let awayAbbrev = away.abbrev, let homeAbbrev = home.abbrev
        else { return nil }
        let state: MatchState
        switch game.gameState {
        case "LIVE", "CRIT": state = .live
        case "FINAL", "OFF": state = .finished
        default: state = .upcoming
        }
        async let awayLogo = logoURL(abbrev: awayAbbrev)
        async let homeLogo = logoURL(abbrev: homeAbbrev)
        return MatchEvent(
            id: String(id),
            startDate: game.startTimeUTC.flatMap { MatchesService.parseEventDate($0) },
            state: state,
            displayClock: game.clock?.timeRemaining,
            period: game.periodDescriptor?.number,
            statusDetail: statusDetail(for: game, state: state),
            home: MatchTeamSide(
                teamId: homeAbbrev,
                name: teamName(home),
                logoURL: await homeLogo,
                score: scoreText(home.score, state: state)
            ),
            away: MatchTeamSide(
                teamId: awayAbbrev,
                name: teamName(away),
                logoURL: await awayLogo,
                score: scoreText(away.score, state: state)
            )
        )
    }

    private static func teamName(_ side: TeamSide) -> String? {
        let place = side.placeName?.value ?? ""
        let common = side.commonName?.value ?? ""
        let name = "\(place) \(common)".trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? side.abbrev : name
    }

    private static func scoreText(_ score: Int?, state: MatchState) -> String? {
        guard state != .upcoming, let score else { return nil }
        return String(score)
    }

    /// The row's state label, from the payload's own fields:
    /// live → "2nd · 04:12" (period ordinal + the payload
    /// clock); finished → "Final" / "Final/OT" / "Final/SO"
    /// from the payload's outcome; upcoming → nil (the row
    /// shows the kickoff time instead).
    private static func statusDetail(for game: Game, state: MatchState) -> String? {
        switch state {
        case .live:
            guard let number = game.periodDescriptor?.number else {
                return game.clock?.timeRemaining
            }
            let ordinal: String
            switch (number, game.periodDescriptor?.periodType) {
            case (1, _): ordinal = "1st"
            case (2, _): ordinal = "2nd"
            case (3, _): ordinal = "3rd"
            case (_, "OT"): ordinal = "OT"
            case (_, "SO"): ordinal = "SO"
            default: ordinal = "P\(number)"
            }
            if let clock = game.clock?.timeRemaining, !clock.isEmpty {
                return "\(ordinal) · \(clock)"
            }
            return ordinal
        case .finished:
            switch game.gameOutcome?.lastPeriodType {
            case "OT": return "Final/OT"
            case "SO": return "Final/SO"
            default: return "Final"
            }
        case .upcoming:
            return nil
        }
    }

    // MARK: Standings

    /// Division-grouped standings from standings/now. Stat
    /// keys mirror the ESPN names the shared standings
    /// models already use (gamesPlayed / wins / losses /
    /// points / pointsFor / pointsAgainst /
    /// pointDifferential / streak / winPercent); the labels
    /// are the NHL's own standard abbreviations for its own
    /// fields (the API publishes no label fields). Zone
    /// notes stay nil — the payload publishes no per-team
    /// note text, so no zone bars are drawn.
    static func standings() async -> (groups: [StandingGroup], stamp: Date?) {
        guard let url = URL(string: "\(base)/standings/now"),
              let result = await SportsDiskCache.espnData(url: url, cacheKey: "nhl-standings"),
              let wire = try? JSONDecoder().decode(StandingsWire.self, from: result.data)
        else { return ([], nil) }
        var order: [String] = []
        var byDivision: [String: [StandingEntry]] = [:]
        for entry in wire.standings ?? [] {
            guard let abbrev = entry.teamAbbrev?.value,
                  let name = entry.teamName?.value, !name.isEmpty,
                  let division = entry.divisionName, !division.isEmpty
            else { continue }
            var stats: [String: String] = [:]
            var labels: [String: String] = [:]
            func put(_ key: String, _ label: String, _ value: String?) {
                if let value { stats[key] = value; labels[key] = label }
            }
            put("gamesPlayed", "GP", entry.gamesPlayed.map(String.init))
            put("wins", "W", entry.wins.map(String.init))
            put("losses", "L", entry.losses.map(String.init))
            put("otLosses", "OT", entry.otLosses.map(String.init))
            put("points", "PTS", entry.points.map(String.init))
            put("pointsFor", "GF", entry.goalFor.map(String.init))
            put("pointsAgainst", "GA", entry.goalAgainst.map(String.init))
            if let diff = entry.goalDifferential {
                put("pointDifferential", "DIFF", diff > 0 ? "+\(diff)" : "\(diff)")
            }
            if let code = entry.streakCode, let count = entry.streakCount {
                put("streak", "STRK", "\(code)\(count)")
            }
            if let pct = entry.winPctg {
                var text = String(format: "%.3f", pct)
                if text.hasPrefix("0.") { text = String(text.dropFirst()) }
                put("winPercent", "PCT", text)
            }
            let standing = StandingEntry(
                teamId: abbrev, teamName: name,
                logoURL: nil,
                stats: stats, statLabels: labels,
                noteColorHex: nil, noteText: nil
            )
            if byDivision[division] == nil { order.append(division) }
            byDivision[division, default: []].append(standing)
        }
        // Logos resolve through the cached map (one fetch).
        var groups: [StandingGroup] = []
        for division in order {
            var entries = byDivision[division] ?? []
            for index in entries.indices {
                if let abbrev = entries[index].teamId,
                   let logo = await logoURL(abbrev: abbrev) {
                    entries[index] = StandingEntry(
                        teamId: entries[index].teamId,
                        teamName: entries[index].teamName,
                        logoURL: logo,
                        stats: entries[index].stats,
                        statLabels: entries[index].statLabels,
                        noteColorHex: nil, noteText: nil
                    )
                }
            }
            groups.append(StandingGroup(name: division, entries: entries, legend: []))
        }
        return (groups, result.stamp)
    }

    // MARK: Teams / roster / club schedule / club leaders

    static func allTeams() async -> [TeamRef] {
        let result = await standings()
        return result.groups.flatMap { $0.entries }.compactMap { entry -> TeamRef? in
            guard let abbrev = entry.teamId else { return nil }
            return TeamRef(
                id: abbrev, sport: .nhl, leaguePath: "nhl",
                name: entry.teamName, logoURL: entry.logoURL
            )
        }
    }

    /// The club's roster, flattened in the payload's own
    /// group order (forwards, defensemen, goalies) — the
    /// position code is the payload's own abbreviation.
    static func roster(abbrev: String) async -> [SquadPlayer] {
        guard let data = await fetchData("\(base)/roster/\(abbrev)/current", cacheKey: "nhl-roster|\(abbrev)"),
              let wire = try? JSONDecoder().decode(RosterWire.self, from: data)
        else { return [] }
        let all = (wire.forwards ?? []) + (wire.defensemen ?? []) + (wire.goalies ?? [])
        return all.compactMap { player -> SquadPlayer? in
            guard let id = player.id else { return nil }
            let name = "\((player.firstName?.value) ?? "") \((player.lastName?.value) ?? "")"
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return SquadPlayer(
                id: String(id),
                name: name,
                positionName: player.positionCode,
                headshotURL: player.headshot.flatMap { URL(string: $0) },
                athleteId: String(id)
            )
        }
    }

    /// The NHL season string for a date ("20262027"): the
    /// season opens in October and is keyed by its start
    /// year.
    static func seasonString(now: Date = Date()) -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: now)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        let start = month >= 10 ? year : year - 1
        return "\(start)\(start + 1)"
    }

    static func clubSchedule(abbrev: String) async -> [MatchEvent] {
        let season = seasonString()
        guard let data = await fetchData(
            "\(base)/club-schedule-season/\(abbrev)/\(season)",
            cacheKey: "nhl-club-schedule|\(abbrev)|\(season)"
        ), let wire = try? JSONDecoder().decode(ClubScheduleWire.self, from: data)
        else { return [] }
        var matches: [MatchEvent] = []
        for game in wire.games ?? [] {
            if let match = await mapGame(game) { matches.append(match) }
        }
        return matches.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    /// The club's own leaders from club-stats (season
    /// totals): skaters by points / goals / assists, goalies
    /// by wins — top five each, the payload's own numbers.
    static func clubLeaders(abbrev: String) async -> [(category: String, rows: [LeaderRow84])] {
        let season = seasonString()
        guard let data = await fetchData(
            "\(base)/club-stats/\(abbrev)/\(season)/2",
            cacheKey: "nhl-club-stats|\(abbrev)|\(season)"
        ), let wire = try? JSONDecoder().decode(ClubStatsWire.self, from: data)
        else { return [] }
        func skaterRows(_ keyPath: KeyPath<ClubStatsWire.Skater, Int?>) -> [LeaderRow84] {
            (wire.skaters ?? [])
                .filter { ($0[keyPath: keyPath] ?? 0) > 0 }
                .sorted { ($0[keyPath: keyPath] ?? 0) > ($1[keyPath: keyPath] ?? 0) }
                .prefix(5)
                .compactMap { skater -> LeaderRow84? in
                    guard let id = skater.playerId else { return nil }
                    return LeaderRow84(
                        athleteId: String(id),
                        name: playerName(skater.firstName, skater.lastName),
                        teamName: nil,
                        valueText: String(skater[keyPath: keyPath] ?? 0),
                        headshotURL: skater.headshot.flatMap { URL(string: $0) }
                    )
                }
        }
        var out: [(category: String, rows: [LeaderRow84])] = []
        let points = skaterRows(\.points)
        if !points.isEmpty { out.append((category: "Points", rows: points)) }
        let goals = skaterRows(\.goals)
        if !goals.isEmpty { out.append((category: "Goals", rows: goals)) }
        let assists = skaterRows(\.assists)
        if !assists.isEmpty { out.append((category: "Assists", rows: assists)) }
        let goalieRows = (wire.goalies ?? [])
            .filter { ($0.wins ?? 0) > 0 }
            .sorted { ($0.wins ?? 0) > ($1.wins ?? 0) }
            .prefix(5)
            .compactMap { goalie -> LeaderRow84? in
                guard let id = goalie.playerId else { return nil }
                return LeaderRow84(
                    athleteId: String(id),
                    name: playerName(goalie.firstName, goalie.lastName),
                    teamName: nil,
                    valueText: String(goalie.wins ?? 0),
                    headshotURL: goalie.headshot.flatMap { URL(string: $0) }
                )
            }
        if !goalieRows.isEmpty { out.append((category: "Wins", rows: goalieRows)) }
        return out
    }

    static func playerName(_ first: NHLText?, _ last: NHLText?) -> String {
        "\((first?.value) ?? "") \((last?.value) ?? "")"
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: League leaders

    private struct LeadersWire: Decodable {
        let points: [Leader]?
        let goals: [Leader]?
        let assists: [Leader]?
        let wins: [Leader]?
        let savePctg: [Leader]?
        let shutouts: [Leader]?
        struct Leader: Decodable {
            let id: Int?
            let firstName: NHLText?
            let lastName: NHLText?
            let headshot: String?
            let teamAbbrev: String?
            let teamName: NHLText?
            let value: Double?
        }
    }

    /// League leaders from the NHL's own leaders endpoints
    /// (skaters: points / goals / assists; goalies: wins /
    /// save percentage / shutouts) — categories render only
    /// when the payload returns them.
    static func leaders() async -> (categories: [LeaderCategory84], rows: [String: [LeaderRow84]]) {
        async let skaterData = fetchData(
            "\(base)/skater-stats-leaders/current?categories=points,goals,assists&limit=15",
            cacheKey: "nhl-leaders|skaters"
        )
        async let goalieData = fetchData(
            "\(base)/goalie-stats-leaders/current?categories=wins,savePctg,shutouts&limit=15",
            cacheKey: "nhl-leaders|goalies"
        )
        var rows: [String: [LeaderRow84]] = [:]
        var categories: [LeaderCategory84] = []
        func absorb(_ data: Data?, _ fields: [(String, String, KeyPath<LeadersWire, [LeadersWire.Leader]?>)]) {
            guard let data, let wire = try? JSONDecoder().decode(LeadersWire.self, from: data)
            else { return }
            for (key, display, keyPath) in fields {
                let leaders = wire[keyPath: keyPath] ?? []
                guard !leaders.isEmpty else { continue }
                rows[key] = leaders.compactMap { leader -> LeaderRow84? in
                    guard let id = leader.id else { return nil }
                    return LeaderRow84(
                        athleteId: String(id),
                        name: playerName(leader.firstName, leader.lastName),
                        teamName: leader.teamName?.value ?? leader.teamAbbrev,
                        valueText: valueText(key: key, value: leader.value),
                        headshotURL: leader.headshot.flatMap { URL(string: $0) }
                    )
                }
                categories.append(LeaderCategory84(name: key, displayName: display))
            }
        }
        absorb(await skaterData, [
            ("points", "Points", \.points),
            ("goals", "Goals", \.goals),
            ("assists", "Assists", \.assists)
        ])
        absorb(await goalieData, [
            ("wins", "Wins", \.wins),
            ("savePctg", "Save %", \.savePctg),
            ("shutouts", "Shutouts", \.shutouts)
        ])
        return (categories, rows)
    }

    private static func valueText(key: String, value: Double?) -> String {
        guard let value else { return "" }
        if key == "savePctg" {
            var text = String(format: "%.3f", value)
            if text.hasPrefix("0.") { text = String(text.dropFirst()) }
            return text
        }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: Game detail (gamecenter landing + boxscore)

    struct Goal: Identifiable {
        let id: String
        let scorerName: String
        let scorerId: String?
        let headshotURL: URL?
        let teamAbbrev: String?
        let timeText: String?
        let strength: String?
        let assistsText: String?
        let scoreText: String?
    }

    struct Star: Identifiable {
        let id: String
        let star: Int
        let name: String
        let headshotURL: URL?
        let lineText: String
    }

    struct SkaterLine: Identifiable {
        let id: String
        let name: String
        let position: String?
        let goals: Int
        let assists: Int
        let points: Int
        let toi: String?
        let headshotURL: URL?
    }

    struct GameDetail {
        let venue: String?
        let scoring: [(period: String, goals: [Goal])]
        let stars: [Star]
        let skaterLines: [(teamAbbrev: String, lines: [SkaterLine])]
    }

    private struct LandingWire: Decodable {
        let venue: NHLText?
        let summary: Summary?
        struct Summary: Decodable {
            let scoring: [Period]?
            let threeStars: [StarWire]?
        }
        struct Period: Decodable {
            let periodDescriptor: PeriodDescriptor?
            let goals: [GoalWire]?
        }
        struct GoalWire: Decodable {
            let eventId: Int?
            let playerId: Int?
            let name: NHLText?
            let firstName: NHLText?
            let lastName: NHLText?
            let teamAbbrev: NHLText?
            let headshot: String?
            let timeInPeriod: String?
            let strength: String?
            let assists: [Assist]?
            let homeScore: Int?
            let awayScore: Int?
        }
        struct Assist: Decodable {
            let name: NHLText?
        }
        struct StarWire: Decodable {
            let star: Int?
            let playerId: Int?
            let name: NHLText?
            let headshot: String?
            let goals: Int?
            let assists: Int?
            let points: Int?
        }
    }

    private struct BoxscoreWire: Decodable {
        let playerByGameStats: Teams?
        struct Teams: Decodable {
            let awayTeam: Groups?
            let homeTeam: Groups?
        }
        struct Groups: Decodable {
            let forwards: [Skater]?
            let defense: [Skater]?
            let goalies: [Skater]?
        }
        struct Skater: Decodable {
            let playerId: Int?
            let name: NHLText?
            let position: String?
            let toi: String?
            let goals: Int?
            let assists: Int?
            let points: Int?
            let headshot: String?
        }
    }

    static func gameDetail(eventId: String) async -> GameDetail? {
        async let landingData = fetchData(
            "\(base)/gamecenter/\(eventId)/landing", cacheKey: "nhl-landing|\(eventId)"
        )
        async let boxData = fetchData(
            "\(base)/gamecenter/\(eventId)/boxscore", cacheKey: "nhl-boxscore|\(eventId)"
        )
        guard let landing = await landingData,
              let wire = try? JSONDecoder().decode(LandingWire.self, from: landing)
        else { return nil }
        var scoring: [(period: String, goals: [Goal])] = []
        for period in wire.summary?.scoring ?? [] {
            let goals = (period.goals ?? []).map { goal in
                Goal(
                    id: String(goal.eventId ?? 0),
                    scorerName: goal.name?.value
                        ?? playerName(goal.firstName, goal.lastName),
                    scorerId: goal.playerId.map(String.init),
                    headshotURL: goal.headshot.flatMap { URL(string: $0) },
                    teamAbbrev: goal.teamAbbrev?.value,
                    timeText: goal.timeInPeriod,
                    strength: goal.strength,
                    assistsText: (goal.assists ?? []).compactMap { $0.name?.value }
                        .joined(separator: ", "),
                    scoreText: (goal.homeScore != nil && goal.awayScore != nil)
                        ? "\(goal.awayScore ?? 0) – \(goal.homeScore ?? 0)" : nil
                )
            }
            if !goals.isEmpty {
                let number = period.periodDescriptor?.number ?? 0
                let label = number <= 3 ? "Period \(number)"
                    : (period.periodDescriptor?.periodType == "SO" ? "Shootout" : "Overtime")
                scoring.append((period: label, goals: goals))
            }
        }
        let stars = (wire.summary?.threeStars ?? []).compactMap { star -> Star? in
            guard let number = star.star, let id = star.playerId else { return nil }
            return Star(
                id: String(id),
                star: number,
                name: star.name?.value ?? "",
                headshotURL: star.headshot.flatMap { URL(string: $0) },
                lineText: "\(star.goals ?? 0) G · \(star.assists ?? 0) A · \(star.points ?? 0) P"
            )
        }
        var lines: [(teamAbbrev: String, lines: [SkaterLine])] = []
        if let box = await boxData,
           let boxWire = try? JSONDecoder().decode(BoxscoreWire.self, from: box),
           let teams = boxWire.playerByGameStats {
            // Team abbrevs for the two groups come from the
            // boxscore payload's own team blocks via the
            // landing header — the detail view passes its
            // seed match's abbrevs; here the groups stay in
            // away/home order and the view labels them from
            // the match it already holds.
            for groups in [teams.awayTeam, teams.homeTeam] {
                guard let groups else { continue }
                let skaters = (groups.forwards ?? []) + (groups.defense ?? [])
                let mapped = skaters.compactMap { skater -> SkaterLine? in
                    guard let id = skater.playerId else { return nil }
                    return SkaterLine(
                        id: String(id),
                        name: skater.name?.value ?? "",
                        position: skater.position,
                        goals: skater.goals ?? 0,
                        assists: skater.assists ?? 0,
                        points: skater.points ?? 0,
                        toi: skater.toi,
                        headshotURL: skater.headshot.flatMap { URL(string: $0) }
                    )
                }
                if !mapped.isEmpty {
                    lines.append((teamAbbrev: "", lines: mapped))
                }
            }
        }
        return GameDetail(
            venue: wire.venue?.value,
            scoring: scoring,
            stars: stars,
            skaterLines: lines
        )
    }
}

// MARK: - NHL player profile (item 1, player pages)

enum NHLPlayerService {
    private struct LandingWire: Decodable {
        let playerId: Int?
        let firstName: NHLText?
        let lastName: NHLText?
        let fullTeamName: NHLText?
        let currentTeamAbbrev: String?
        let headshot: String?
        let sweaterNumber: Int?
        let position: String?
        let shootsCatches: String?
        let birthDate: String?
        let birthCity: NHLText?
        let birthCountry: String?
        let featuredStats: Featured?
        let careerTotals: Totals?
        struct Featured: Decodable {
            let regularSeason: Split?
        }
        struct Totals: Decodable {
            let regularSeason: Stats?
        }
        struct Split: Decodable {
            let subSeason: Stats?
            let career: Stats?
        }
        struct Stats: Decodable {
            let gamesPlayed: Int?
            let goals: Int?
            let assists: Int?
            let points: Int?
            let plusMinus: Int?
            let pim: Int?
            let shots: Int?
            let wins: Int?
            let losses: Int?
            let otLosses: Int?
            let shutouts: Int?
            let savePctg: Double?
            let goalsAgainstAvg: Double?
        }
    }

    private final class SessionCache: @unchecked Sendable {
        static let shared = SessionCache()
        private let lock = NSLock()
        private var entries: [String: PlayerProfile] = [:]
        func get(_ key: String) -> PlayerProfile? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }
        func put(_ key: String, _ value: PlayerProfile) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = value
        }
    }

    static func fetch(athleteId: String) async -> PlayerProfile? {
        if let cached = SessionCache.shared.get(athleteId) { return cached }
        guard let url = URL(string: "https://api-web.nhle.com/v1/player/\(athleteId)/landing"),
              let result = await SportsDiskCache.espnData(url: url, cacheKey: "nhl-player|\(athleteId)"),
              let wire = try? JSONDecoder().decode(LandingWire.self, from: result.data)
        else { return nil }
        let name = NHLService.playerName(wire.firstName, wire.lastName)
        guard !name.isEmpty else { return nil }
        let isGoalie = wire.position == "G"
        var lines: [(label: String, value: String)] = []
        if let season = wire.featuredStats?.regularSeason?.subSeason {
            lines += statLines(season, isGoalie: isGoalie, prefix: "")
        }
        let career = wire.featuredStats?.regularSeason?.career
            ?? wire.careerTotals?.regularSeason
        if let career {
            lines += statLines(career, isGoalie: isGoalie, prefix: "\(L("matches.stats.career")) · ")
        }
        let profile = PlayerProfile(
            athleteId: athleteId,
            name: name,
            age: age(from: wire.birthDate),
            jersey: wire.sweaterNumber.map(String.init),
            positionName: wire.position,
            citizenship: wire.birthCountry,
            batsText: nil,
            // The landing's shootsCatches is a shooting /
            // catching hand — the profile's throws row is
            // baseball's labelled field, so hockey leaves it
            // empty rather than mislabel the hand.
            throwsText: nil,
            headshotURL: wire.headshot.flatMap { URL(string: $0) },
            teamId: wire.currentTeamAbbrev,
            teamName: wire.fullTeamName?.value,
            teamLogoURL: await wire.currentTeamAbbrev.asyncFlatMap87URL {
                await NHLService.logoURL(abbrev: $0)
            },
            statLines: lines,
            recentEvents: []
        )
        SessionCache.shared.put(athleteId, profile)
        return profile
    }

    private static func statLines(
        _ stats: LandingWire.Stats, isGoalie: Bool, prefix: String
    ) -> [(label: String, value: String)] {
        var lines: [(label: String, value: String)] = []
        func add(_ label: String, _ value: String?) {
            if let value { lines.append((label: prefix + label, value: value)) }
        }
        add("GP", stats.gamesPlayed.map(String.init))
        if isGoalie {
            add("W", stats.wins.map(String.init))
            add("L", stats.losses.map(String.init))
            add("OT", stats.otLosses.map(String.init))
            add("SO", stats.shutouts.map(String.init))
            add("GAA", stats.goalsAgainstAvg.map { String(format: "%.2f", $0) })
            add("SV%", stats.savePctg.map { value in
                var text = String(format: "%.3f", value)
                if text.hasPrefix("0.") { text = String(text.dropFirst()) }
                return text
            })
        } else {
            add("G", stats.goals.map(String.init))
            add("A", stats.assists.map(String.init))
            add("P", stats.points.map(String.init))
            add("+/-", stats.plusMinus.map { $0 > 0 ? "+\($0)" : "\($0)" })
            add("PIM", stats.pim.map(String.init))
            add("SOG", stats.shots.map(String.init))
        }
        return lines
    }

    private static func age(from birthDate: String?) -> Int? {
        guard let birthDate, let date = MatchesService.parseEventDate(birthDate) else { return nil }
        return Calendar.current.dateComponents([.year], from: date, to: Date()).year
    }
}

extension Optional where Wrapped == String {
    /// Build 87: async flat-map for optional strings (the
    /// MatchesExtras copy is file-private to that file).
    func asyncFlatMap87URL(_ transform: (String) async -> URL?) async -> URL? {
        guard let self else { return nil }
        return await transform(self)
    }
}

// MARK: - Formula 1 (item 2) — the free Jolpica/Ergast API
//
// Source: https://api.jolpi.ca/ergast/f1 — the community
// continuation of the Ergast API, keyless. Verified live
// 2026-11-21: current.json (200, full 2026 schedule),
// current/driverStandings.json (200), current/
// constructorStandings.json (200), current/last/results.json
// (200). The old ergast.com host answers 404 (dead) — only
// the Jolpica host is used. The API publishes no photos —
// driver/constructor rows are text rows (names, teams,
// points), never decorated with invented imagery.

struct F1Race: Identifiable {
    let round: Int
    let name: String
    let circuit: String?
    let locality: String?
    let country: String?
    let date: Date?
    let timeText: String?
    var id: Int { round }
}

struct F1ResultRow: Identifiable {
    let position: String
    let driverName: String
    let driverCode: String?
    let constructorName: String?
    let points: String?
    let status: String?
    let timeText: String?
    var id: String { position + "|" + driverName }
}

struct F1DriverStanding: Identifiable {
    let position: String
    let driverName: String
    let driverCode: String?
    let constructorName: String?
    let points: String?
    let wins: String?
    var id: String { position + "|" + driverName }
}

struct F1ConstructorStanding: Identifiable {
    let position: String
    let name: String
    let points: String?
    let wins: String?
    var id: String { position + "|" + name }
}

enum F1Service {
    private static let base = "https://api.jolpi.ca/ergast/f1"

    private struct Wire: Decodable {
        let mrData: MRData
        enum CodingKeys: String, CodingKey { case mrData = "MRData" }
        struct MRData: Decodable {
            let raceTable: RaceTable?
            let standingsTable: StandingsTable?
            enum CodingKeys: String, CodingKey {
                case raceTable = "RaceTable"
                case standingsTable = "StandingsTable"
            }
        }
        struct RaceTable: Decodable {
            let races: [Race]?
            enum CodingKeys: String, CodingKey { case races = "Races" }
        }
        struct Race: Decodable {
            let round: String?
            let raceName: String?
            let circuit: Circuit?
            let date: String?
            let time: String?
            let results: [RaceResult]?
            enum CodingKeys: String, CodingKey {
                case round, raceName, date, time
                case circuit = "Circuit"
                case results = "Results"
            }
        }
        struct Circuit: Decodable {
            let circuitName: String?
            let location: Location?
            enum CodingKeys: String, CodingKey {
                case circuitName
                case location = "Location"
            }
        }
        struct Location: Decodable {
            let locality: String?
            let country: String?
        }
        struct RaceResult: Decodable {
            let position: String?
            let points: String?
            let driver: Driver?
            let constructor: Constructor?
            let status: String?
            let time: ResultTime?
            enum CodingKeys: String, CodingKey {
                case position, points, status
                case driver = "Driver"
                case constructor = "Constructor"
                case time = "Time"
            }
        }
        struct ResultTime: Decodable { let time: String? }
        struct Driver: Decodable {
            let givenName: String?
            let familyName: String?
            let code: String?
        }
        struct Constructor: Decodable { let name: String? }
        struct StandingsTable: Decodable {
            let standingsLists: [StandingsList]?
            enum CodingKeys: String, CodingKey { case standingsLists = "StandingsLists" }
        }
        struct StandingsList: Decodable {
            let driverStandings: [DriverStanding]?
            let constructorStandings: [ConstructorStanding]?
            enum CodingKeys: String, CodingKey {
                case driverStandings = "DriverStandings"
                case constructorStandings = "ConstructorStandings"
            }
        }
        struct DriverStanding: Decodable {
            let position: String?
            let points: String?
            let wins: String?
            let driver: Driver?
            let constructors: [Constructor]?
            enum CodingKeys: String, CodingKey {
                case position, points, wins
                case driver = "Driver"
                case constructors = "Constructors"
            }
        }
        struct ConstructorStanding: Decodable {
            let position: String?
            let points: String?
            let wins: String?
            let constructor: Constructor?
            enum CodingKeys: String, CodingKey {
                case position, points, wins
                case constructor = "Constructor"
            }
        }
    }

    private static func fetchWire(_ path: String, cacheKey: String) async -> Wire? {
        guard let url = URL(string: "\(base)/\(path)"),
              let result = await SportsDiskCache.espnData(url: url, cacheKey: cacheKey),
              let wire = try? JSONDecoder().decode(Wire.self, from: result.data)
        else { return nil }
        return wire
    }

    static func schedule() async -> [F1Race] {
        guard let wire = await fetchWire("current.json", cacheKey: "f1|schedule") else { return [] }
        return (wire.mrData.raceTable?.races ?? []).compactMap { race -> F1Race? in
            guard let name = race.raceName else { return nil }
            return F1Race(
                round: Int(race.round ?? "") ?? 0,
                name: name,
                circuit: race.circuit?.circuitName,
                locality: race.circuit?.location?.locality,
                country: race.circuit?.location?.country,
                date: raceDate(race.date, race.time),
                timeText: race.time
            )
        }
    }

    /// The most recent completed race and its full result —
    /// the payload's own "last" pointer, never a guess.
    static func lastResults() async -> (raceName: String?, rows: [F1ResultRow]) {
        guard let wire = await fetchWire("current/last/results.json", cacheKey: "f1|last-results"),
              let race = wire.mrData.raceTable?.races?.first
        else { return (nil, []) }
        let rows = (race.results ?? []).compactMap { result -> F1ResultRow? in
            guard let position = result.position,
                  let driver = result.driver,
                  let name = driverName(driver) else { return nil }
            return F1ResultRow(
                position: position,
                driverName: name,
                driverCode: driver.code,
                constructorName: result.constructor?.name,
                points: result.points,
                status: result.status,
                timeText: result.time?.time
            )
        }
        return (race.raceName, rows)
    }

    static func driverStandings() async -> [F1DriverStanding] {
        guard let wire = await fetchWire("current/driverStandings.json", cacheKey: "f1|drivers"),
              let list = wire.mrData.standingsTable?.standingsLists?.first
        else { return [] }
        return (list.driverStandings ?? []).compactMap { standing -> F1DriverStanding? in
            guard let position = standing.position,
                  let driver = standing.driver,
                  let name = driverName(driver) else { return nil }
            return F1DriverStanding(
                position: position,
                driverName: name,
                driverCode: driver.code,
                constructorName: standing.constructors?.first?.name,
                points: standing.points,
                wins: standing.wins
            )
        }
    }

    static func constructorStandings() async -> [F1ConstructorStanding] {
        guard let wire = await fetchWire("current/constructorStandings.json", cacheKey: "f1|constructors"),
              let list = wire.mrData.standingsTable?.standingsLists?.first
        else { return [] }
        return (list.constructorStandings ?? []).compactMap { standing -> F1ConstructorStanding? in
            guard let position = standing.position,
                  let name = standing.constructor?.name else { return nil }
            return F1ConstructorStanding(
                position: position, name: name,
                points: standing.points, wins: standing.wins
            )
        }
    }

    private static func driverName(_ driver: Wire.Driver) -> String? {
        let name = "\((driver.givenName) ?? "") \((driver.familyName) ?? "")"
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func raceDate(_ date: String?, _ time: String?) -> Date? {
        guard let date else { return nil }
        if let time {
            return MatchesService.parseEventDate("\(date)T\(time)")
        }
        return MatchesService.parseEventDate("\(date)T00:00:00Z")
    }
}

// MARK: - MLB Stats API (item 3) — MLB's official free API
//
// Source: https://statsapi.mlb.com/api/v1 — MLB Advanced
// Media's official API, keyless. Verified live 2026-11-21:
// schedule (200), people/search, people/{id} with
// stats hydration (season + career splits returned), teams
// + team roster (200), and the official headshot CDN pattern
// (img.mlbstatic.com …/people/{id}/headshot/67/current →
// 200 image/jpeg). ESPN's MLB ids are NOT MLBAM ids, so a
// person is adopted ONLY when the name search verifies
// exactly one exact-name match — the build-80/86 identity
// discipline. Anything else keeps the ESPN data untouched.

enum MLBStatsService {
    private static let base = "https://statsapi.mlb.com/api/v1"

    private struct SearchWire: Decodable {
        let people: [Person]?
        struct Person: Decodable {
            let id: Int?
            let fullName: String?
        }
    }

    private struct PersonWire: Decodable {
        let people: [Person]?
        struct Person: Decodable {
            let id: Int?
            let fullName: String?
            let stats: [StatGroup]?
        }
        struct StatGroup: Decodable {
            let group: Named?
            let type: Named?
            let splits: [Split]?
        }
        struct Named: Decodable { let displayName: String? }
        struct Split: Decodable {
            let season: String?
            let stat: [String: StatValue]?
        }
    }

    /// A stat value arrives as a string OR a number depending
    /// on the field — both decode to their text form.
    private enum StatValue: Decodable {
        case text(String)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .text(string)
            } else if let number = try? container.decode(Double.self) {
                self = .text(number == number.rounded() ? String(Int(number)) : String(number))
            } else {
                self = .text("")
            }
        }
        var string: String {
            switch self { case .text(let value): return value }
        }
    }

    private struct TeamsWire: Decodable {
        let teams: [Team]?
        struct Team: Decodable {
            let id: Int?
            let name: String?
        }
    }

    private struct RosterWire: Decodable {
        let roster: [Entry]?
        struct Entry: Decodable {
            let person: Person?
        }
        struct Person: Decodable {
            let id: Int?
            let fullName: String?
        }
    }

    private final class PersonCache: @unchecked Sendable {
        static let shared = PersonCache()
        private let lock = NSLock()
        private var ids: [String: Int?] = [:]
        func get(_ key: String) -> Int?? {
            lock.lock(); defer { lock.unlock() }
            return ids[key]
        }
        func put(_ key: String, _ value: Int?) {
            lock.lock(); defer { lock.unlock() }
            ids.updateValue(value, forKey: key)
        }
    }

    static func headshotURL(personId: Int) -> URL? {
        URL(string: "https://img.mlbstatic.com/mlb-images/image/upload/d_people:generic:headshot:67:current.png/w_213,q_auto:best/v1/people/\(personId)/headshot/67/current")
    }

    /// The verified MLBAM person id for an ESPN-named player:
    /// the search must return EXACTLY ONE person whose name
    /// normalizes equal to the query (the shared folding).
    static func verifiedPersonId(name: String) async -> Int? {
        let key = SoccerPhotoResolver.normName(name)
        guard !key.isEmpty else { return nil }
        if let cached = PersonCache.shared.get(key) { return cached }
        var result: Int?
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        if let url = URL(string: "\(base)/people/search?names=\(encoded)"),
           let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "mlbam-search|\(key)"),
           let wire = try? JSONDecoder().decode(SearchWire.self, from: fetched.data) {
            let matches = (wire.people ?? []).filter {
                SoccerPhotoResolver.normName($0.fullName ?? "") == key
            }
            if matches.count == 1 { result = matches[0].id }
        }
        PersonCache.shared.put(key, result)
        return result
    }

    /// Career stat lines for a verified person, in the
    /// sport's standard abbreviation order — values verbatim
    /// from the payload's career splits (hitting and/or
    /// pitching, whichever the payload carries).
    static func careerLines(personId: Int) async -> [(label: String, value: String)] {
        let hydrate = "stats(group=[hitting,pitching],type=[career])"
            .replacingOccurrences(of: "[", with: "%5B")
            .replacingOccurrences(of: "]", with: "%5D")
        guard let url = URL(string: "\(base)/people/\(personId)?hydrate=\(hydrate)"),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "mlbam-career|\(personId)"),
              let wire = try? JSONDecoder().decode(PersonWire.self, from: fetched.data),
              let person = wire.people?.first
        else { return [] }
        var lines: [(label: String, value: String)] = []
        for group in person.stats ?? [] {
            guard let split = group.splits?.first, let stat = split.stat else { continue }
            let order: [(key: String, label: String)]
            switch group.group?.displayName {
            case "hitting":
                order = [("avg", "AVG"), ("homeRuns", "HR"), ("rbi", "RBI"),
                         ("runs", "R"), ("hits", "H"), ("stolenBases", "SB"),
                         ("obp", "OBP"), ("slg", "SLG"), ("ops", "OPS")]
            case "pitching":
                order = [("wins", "W"), ("losses", "L"), ("era", "ERA"),
                         ("strikeouts", "SO"), ("whip", "WHIP"), ("saves", "SV"),
                         ("inningsPitched", "IP")]
            default:
                order = []
            }
            for field in order {
                if let value = stat[field.key]?.string, !value.isEmpty {
                    lines.append((label: "\(L("matches.stats.career")) · \(field.label)", value: value))
                }
            }
        }
        return lines
    }

    /// The item-3 upgrade of an ESPN MLB profile: the
    /// official MLBAM headshot becomes the profile's photo
    /// (adopted only after the image URL itself answers 200
    /// with an image content type, so a dead CDN path can
    /// never strand the page on a monogram the ESPN photo
    /// would have filled), and the verified career lines
    /// append to the stat list. Unverified or unreachable →
    /// the ESPN profile returns untouched.
    static func enrich(_ profile: PlayerProfile) async -> PlayerProfile {
        guard let personId = await verifiedPersonId(name: profile.name) else { return profile }
        async let career = careerLines(personId: personId)
        var headshot = profile.headshotURL
        if let url = headshotURL(personId: personId),
           await imageVerified(url) {
            headshot = url
        }
        let careerResult = await career
        guard headshot != profile.headshotURL || !careerResult.isEmpty else { return profile }
        return PlayerProfile(
            athleteId: profile.athleteId,
            name: profile.name,
            age: profile.age,
            jersey: profile.jersey,
            positionName: profile.positionName,
            citizenship: profile.citizenship,
            batsText: profile.batsText,
            throwsText: profile.throwsText,
            headshotURL: headshot,
            teamId: profile.teamId,
            teamName: profile.teamName,
            teamLogoURL: profile.teamLogoURL,
            statLines: profile.statLines + careerResult,
            recentEvents: profile.recentEvents
        )
    }

    private static func imageVerified(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let type = http.value(forHTTPHeaderField: "Content-Type"),
              type.hasPrefix("image/")
        else { return false }
        return true
    }

    /// Official headshots for a whole MLB squad, keyed by
    /// normalized player name: the MLBAM team is adopted
    /// only on an exactly-one normalized name match against
    /// the ESPN team name, then its roster maps each player
    /// to his official headshot. Used by the MLB team page
    /// to upgrade squad photos (ESPN's stay the fallback).
    static func squadHeadshots(teamName: String) async -> [String: URL] {
        guard let teamsURL = URL(string: "\(base)/teams?sportId=1"),
              let fetched = await SportsDiskCache.espnData(url: teamsURL, cacheKey: "mlbam-teams"),
              let wire = try? JSONDecoder().decode(TeamsWire.self, from: fetched.data)
        else { return [:] }
        let key = SoccerPhotoResolver.normName(teamName)
        let matches = (wire.teams ?? []).filter {
            SoccerPhotoResolver.normName($0.name ?? "") == key
        }
        guard matches.count == 1, let teamId = matches[0].id,
              let rosterURL = URL(string: "\(base)/teams/\(teamId)/roster"),
              let rosterData = await SportsDiskCache.espnData(url: rosterURL, cacheKey: "mlbam-roster|\(teamId)"),
              let roster = try? JSONDecoder().decode(RosterWire.self, from: rosterData.data)
        else { return [:] }
        var out: [String: URL] = [:]
        for entry in roster.roster ?? [] {
            guard let person = entry.person, let id = person.id,
                  let name = person.fullName, let url = headshotURL(personId: id)
            else { continue }
            out[SoccerPhotoResolver.normName(name)] = url
        }
        return out
    }
}

// MARK: - Tennis (item 4) — ESPN tennis scoreboards
//
// Verified live 2026-11-21: site/v2 tennis/atp and
// tennis/wta scoreboards answer 200 with the current
// tournaments; matches nest under events → groupings →
// competitions, each competitor carrying a roster/athlete
// name, per-set linescores and a winner flag.

struct TennisMatch: Identifiable {
    let id: String
    let tournamentName: String
    let groupTitle: String?
    let roundText: String?
    let state: MatchState
    let startDate: Date?
    let name1: String
    let name2: String
    let sets1: [String]
    let sets2: [String]
    let winnerIndex: Int?
}

struct TennisTournament: Identifiable {
    let id: String
    let name: String
    let tour: String
    let groups: [(title: String?, matches: [TennisMatch])]
}

enum TennisService {
    private struct ScoreboardWire: Decodable {
        let events: [Event]?
        struct Event: Decodable {
            let id: String?
            let name: String?
            let groupings: [Grouping]?
        }
        struct Grouping: Decodable {
            let grouping: GroupInfo?
            let competitions: [Competition]?
        }
        struct GroupInfo: Decodable {
            let displayName: String?
            let slug: String?
        }
        struct Competition: Decodable {
            let id: String?
            let date: String?
            let startDate: String?
            let status: ESPNStatus?
            let round: Round?
            let competitors: [Competitor]?
        }
        struct Round: Decodable {
            let displayName: String?
        }
        struct Competitor: Decodable {
            let homeAway: String?
            let winner: Bool?
            let roster: Named?
            let athlete: Named?
            let team: Named?
            let linescores: [SetScore]?
        }
        struct Named: Decodable { let displayName: String? }
        struct SetScore: Decodable {
            let displayValue: String?
            let value: Double?
        }
    }

    static let tours: [(path: String, label: String)] = [
        (path: "tennis/atp", label: "ATP"),
        (path: "tennis/wta", label: "WTA")
    ]

    static func tournaments(tourPath: String) async -> [TennisTournament] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(tourPath)/scoreboard"),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "tennis|\(tourPath)"),
              let wire = try? JSONDecoder().decode(ScoreboardWire.self, from: fetched.data)
        else { return [] }
        return (wire.events ?? []).compactMap { event -> TennisTournament? in
            guard let id = event.id, let name = event.name else { return nil }
            var groups: [(title: String?, matches: [TennisMatch])] = []
            for grouping in event.groupings ?? [] {
                let matches = (grouping.competitions ?? []).compactMap { competition -> TennisMatch? in
                    mapMatch(competition, tournamentName: name, groupTitle: grouping.grouping?.displayName)
                }
                if !matches.isEmpty {
                    groups.append((title: grouping.grouping?.displayName, matches: matches))
                }
            }
            guard !groups.isEmpty else { return nil }
            return TennisTournament(id: id, name: name, tour: tourPath, groups: groups)
        }
    }

    static func allMatches() async -> [TennisMatch] {
        var out: [TennisMatch] = []
        for tour in tours {
            for tournament in await tournaments(tourPath: tour.path) {
                for group in tournament.groups { out += group.matches }
            }
        }
        return out
    }

    private static func mapMatch(
        _ competition: ScoreboardWire.Competition,
        tournamentName: String, groupTitle: String?
    ) -> TennisMatch? {
        let competitors = competition.competitors ?? []
        guard competitors.count >= 2,
              let first = competitors.first(where: { $0.homeAway == "home" }) ?? competitors.first,
              let second = competitors.first(where: { $0.homeAway == "away" }) ?? competitors.dropFirst().first,
              let name1 = competitorName(first), let name2 = competitorName(second)
        else { return nil }
        let state: MatchState
        switch competition.status?.type?.state {
        case "in": state = .live
        case "post": state = .finished
        default: state = (competition.status?.type?.completed == true) ? .finished : .upcoming
        }
        let winnerIndex: Int?
        if first.winner == true { winnerIndex = 0 }
        else if second.winner == true { winnerIndex = 1 }
        else { winnerIndex = nil }
        return TennisMatch(
            id: competition.id ?? "\(name1)|\(name2)",
            tournamentName: tournamentName,
            groupTitle: groupTitle,
            roundText: competition.round?.displayName,
            state: state,
            startDate: (competition.startDate ?? competition.date).flatMap { MatchesService.parseEventDate($0) },
            name1: name1,
            name2: name2,
            sets1: setScores(first),
            sets2: setScores(second),
            winnerIndex: winnerIndex
        )
    }

    private static func competitorName(_ competitor: ScoreboardWire.Competitor) -> String? {
        competitor.roster?.displayName ?? competitor.athlete?.displayName ?? competitor.team?.displayName
    }

    private static func setScores(_ competitor: ScoreboardWire.Competitor) -> [String] {
        (competitor.linescores ?? []).compactMap { set -> String? in
            if let display = set.displayValue, !display.isEmpty { return display }
            guard let value = set.value else { return nil }
            return value == value.rounded() ? String(Int(value)) : String(value)
        }
    }
}

// MARK: - Golf (item 5) — ESPN golf leaderboards
//
// Verified live 2026-11-21: golf/pga (200, 147 competitors),
// golf/eur (200, DP World Tour) and golf/lpga (200) answer
// with the current tournament's leaderboard — competitors in
// leaderboard order (the payload's `order`), each with the
// total score string and per-round linescores. golf/
// champions answers HTTP 400 and is NOT offered.

struct GolfRow: Identifiable {
    let position: Int
    let name: String
    let scoreText: String?
    let roundScores: [String]
    var id: String { "\(position)|\(name)" }
}

struct GolfLeaderboard {
    let tourPath: String
    let leagueName: String?
    let eventName: String?
    let state: MatchState
    let rows: [GolfRow]
}

enum GolfService {
    private struct ScoreboardWire: Decodable {
        let leagues: [League]?
        let events: [Event]?
        struct League: Decodable { let name: String? }
        struct Event: Decodable {
            let name: String?
            let status: ESPNStatus?
            let competitions: [Competition]?
        }
        struct Competition: Decodable {
            let status: ESPNStatus?
            let competitors: [Competitor]?
        }
        struct Competitor: Decodable {
            let order: Int?
            let athlete: Named?
            let score: String?
            let linescores: [RoundScore]?
        }
        struct Named: Decodable { let displayName: String? }
        struct RoundScore: Decodable {
            let displayValue: String?
            let period: Int?
        }
    }

    static let tours: [(path: String, label: String)] = [
        (path: "golf/pga", label: "PGA Tour"),
        (path: "golf/eur", label: "DP World Tour"),
        (path: "golf/lpga", label: "LPGA")
    ]

    static func leaderboard(tourPath: String) async -> GolfLeaderboard? {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(tourPath)/scoreboard"),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "golf|\(tourPath)"),
              let wire = try? JSONDecoder().decode(ScoreboardWire.self, from: fetched.data),
              let event = wire.events?.first,
              let competition = event.competitions?.first
        else { return nil }
        let state: MatchState
        switch (competition.status?.type?.state ?? event.status?.type?.state) {
        case "in": state = .live
        case "post": state = .finished
        default: state = .upcoming
        }
        let rows = (competition.competitors ?? []).enumerated().compactMap { index, competitor -> GolfRow? in
            guard let name = competitor.athlete?.displayName, !name.isEmpty else { return nil }
            let rounds = (competitor.linescores ?? [])
                .sorted { ($0.period ?? 0) < ($1.period ?? 0) }
                .compactMap { $0.displayValue }
            return GolfRow(
                position: competitor.order ?? index + 1,
                name: name,
                scoreText: competitor.score,
                roundScores: rounds
            )
        }
        return GolfLeaderboard(
            tourPath: tourPath,
            leagueName: wire.leagues?.first?.name,
            eventName: event.name,
            state: state,
            rows: rows
        )
    }
}

// MARK: - UFC (item 5) — ESPN MMA scoreboards
//
// Verified live 2026-11-21: mma/ufc scoreboard answers 200
// with the current/next card — 12 fights as competitions,
// each with two athlete competitors (name, record summary,
// winner flag) and the payload's own status text.

struct UFCFight: Identifiable {
    let id: String
    let name1: String
    let record1: String?
    let name2: String
    let record2: String?
    let winnerIndex: Int?
    let state: MatchState
    let detailText: String?
    let startDate: Date?
}

struct UFCCard: Identifiable {
    let id: String
    let name: String
    let date: Date?
    let fights: [UFCFight]
}

enum UFCService {
    private struct ScoreboardWire: Decodable {
        let events: [Event]?
        struct Event: Decodable {
            let id: String?
            let name: String?
            let date: String?
            let competitions: [Fight]?
        }
        struct Fight: Decodable {
            let id: String?
            let date: String?
            let status: ESPNStatus?
            let competitors: [Fighter]?
        }
        struct Fighter: Decodable {
            let homeAway: String?
            let winner: Bool?
            let athlete: Named?
            let records: [Record]?
        }
        struct Named: Decodable { let displayName: String? }
        struct Record: Decodable { let summary: String? }
    }

    /// Cards across the app's schedule window (the scoreboard
    /// takes one day per call, like every ESPN feed here):
    /// recent results, today's card, the next cards.
    static func cards() async -> [UFCCard] {
        let days = MatchesService.dayParameters()
        let perDay = await withTaskGroup(of: [UFCCard].self) { group in
            for day in days {
                group.addTask { await cards(dayParameter: day) }
            }
            var out: [UFCCard] = []
            for await items in group { out += items }
            return out
        }
        var seen = Set<String>()
        return perDay
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    private static func cards(dayParameter: String) async -> [UFCCard] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard?dates=\(dayParameter)"),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "ufc|\(dayParameter)"),
              let wire = try? JSONDecoder().decode(ScoreboardWire.self, from: fetched.data)
        else { return [] }
        return (wire.events ?? []).compactMap { event -> UFCCard? in
            guard let id = event.id, let name = event.name else { return nil }
            let fights = (event.competitions ?? []).compactMap { fight -> UFCFight? in
                let competitors = fight.competitors ?? []
                guard competitors.count >= 2,
                      let first = competitors.first(where: { $0.homeAway == "home" }) ?? competitors.first,
                      let second = competitors.first(where: { $0.homeAway == "away" }) ?? competitors.dropFirst().first,
                      let name1 = first.athlete?.displayName,
                      let name2 = second.athlete?.displayName
                else { return nil }
                let state: MatchState
                switch fight.status?.type?.state {
                case "in": state = .live
                case "post": state = .finished
                default: state = (fight.status?.type?.completed == true) ? .finished : .upcoming
                }
                let winnerIndex: Int?
                if first.winner == true { winnerIndex = 0 }
                else if second.winner == true { winnerIndex = 1 }
                else { winnerIndex = nil }
                return UFCFight(
                    id: fight.id ?? "\(name1)|\(name2)",
                    name1: name1,
                    record1: first.records?.first?.summary,
                    name2: name2,
                    record2: second.records?.first?.summary,
                    winnerIndex: winnerIndex,
                    state: state,
                    detailText: fight.status?.type?.detail ?? fight.status?.type?.shortDetail,
                    startDate: fight.date.flatMap { MatchesService.parseEventDate($0) }
                )
            }
            guard !fights.isEmpty else { return nil }
            return UFCCard(
                id: id, name: name,
                date: event.date.flatMap { MatchesService.parseEventDate($0) },
                fights: fights
            )
        }
    }
}

// MARK: - Cross-league top scorers (item 11)
//
// The goals leaders of ALL 17 catalog leagues on one page:
// the existing per-league scorers service (the build-83
// slug-fixed core leaders path) fanned out concurrently,
// merged and ranked by the payload's own goal counts.

struct CrossScorerRow: Identifiable {
    let entry: ScorerEntry
    let leagueName: String
    let leaguePath: String
    var id: String { "\(leaguePath)|\(entry.athleteId)" }
}

enum CrossLeagueScorersService {
    static func fetch() async -> [CrossScorerRow] {
        let leagues = MatchSport.soccerLeagueCatalog
        let perLeague = await withTaskGroup(of: [CrossScorerRow].self) { group in
            for league in leagues {
                group.addTask {
                    await MatchesScorersService.fetch(leaguePath: league.leaguePath)
                        .map {
                            CrossScorerRow(entry: $0, leagueName: league.name, leaguePath: league.leaguePath)
                        }
                }
            }
            var out: [CrossScorerRow] = []
            for await items in group { out += items }
            return out
        }
        return Array(perLeague.sorted { $0.entry.goals > $1.entry.goals }.prefix(40))
    }
}

// MARK: - Deeper head-to-head (item 12)
//
// The summary's seasonseries covers the current season's
// series (NBA/NFL/MLB) or the last five meetings (soccer).
// Deeper history lives in the CORE API's per-season team
// event lists — verified live 2026-11-21: /seasons/{year}/
// types/{type}/teams/{id}/events returns that season's full
// event $ref list for the PREVIOUS seasons too (the site
// API's schedule endpoint ignores its season parameter —
// verified the same day — so the core lists are the only
// honest route). The two teams' lists are intersected; a
// shared event IS a meeting between them. Scores come from
// each competitor's own score $ref. Bounded: two past
// seasons, at most 8 meetings dereferenced.

enum DeepH2HService {
    private struct EventsWire: Decodable {
        let items: [Ref]?
        struct Ref: Decodable {
            let ref: String?
            enum CodingKeys: String, CodingKey { case ref = "$ref" }
        }
    }

    private struct EventWire: Decodable {
        let date: String?
        let competitions: [Competition]?
        struct Competition: Decodable {
            let competitors: [Competitor]?
        }
        struct Competitor: Decodable {
            let homeAway: String?
            let score: Ref?
        }
        struct Ref: Decodable {
            let ref: String?
            enum CodingKeys: String, CodingKey { case ref = "$ref" }
        }
    }

    private struct ScoreWire: Decodable {
        let displayValue: String?
        let value: Double?
    }

    private final class SessionCache: @unchecked Sendable {
        static let shared = SessionCache()
        private let lock = NSLock()
        private var entries: [String: [MatchH2HMeeting]] = [:]
        func get(_ key: String) -> [MatchH2HMeeting]? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }
        func put(_ key: String, _ value: [MatchH2HMeeting]) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = value
        }
    }

    static func fetch(
        sport: MatchSport, leaguePath: String,
        homeId: String, awayId: String,
        homeName: String?, awayName: String?,
        excludeIds: Set<String>
    ) async -> [MatchH2HMeeting] {
        let cacheKey = "\(sport.rawValue)|\(leaguePath)|\(homeId)|\(awayId)"
        if let cached = SessionCache.shared.get(cacheKey) {
            return cached.filter { !excludeIds.contains($0.id) }
        }
        let segment = CoreCoordinates.segment(for: sport)
        let slug = CoreCoordinates.slug(from: leaguePath)
        let type = CoreCoordinates.seasonType(for: sport)
        let currentSeason = CoreCoordinates.season(for: sport)
        var meetings: [MatchH2HMeeting] = []
        for season in [currentSeason - 1, currentSeason - 2] {
            let homeIds = await eventIds(
                segment: segment, slug: slug, season: season, type: type, teamId: homeId
            )
            guard !homeIds.isEmpty else { continue }
            let awayIds = await eventIds(
                segment: segment, slug: slug, season: season, type: type, teamId: awayId
            )
            let shared = homeIds.intersection(awayIds)
                .filter { !excludeIds.contains($0) }
            let seasonMeetings = await withTaskGroup(of: MatchH2HMeeting?.self) { group in
                for eventId in Array(shared.prefix(8)) {
                    group.addTask {
                        await meeting(
                            segment: segment, slug: slug, eventId: eventId,
                            homeName: homeName, awayName: awayName
                        )
                    }
                }
                var out: [MatchH2HMeeting] = []
                for await item in group { if let item { out.append(item) } }
                return out
            }
            meetings += seasonMeetings
        }
        meetings.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        SessionCache.shared.put(cacheKey, meetings)
        return meetings.filter { !excludeIds.contains($0.id) }
    }

    private static func eventIds(
        segment: String, slug: String, season: Int, type: Int, teamId: String
    ) async -> Set<String> {
        let urlString = "https://sports.core.api.espn.com/v2/sports/\(segment)/leagues/\(slug)/seasons/\(season)/types/\(type)/teams/\(teamId)/events?limit=120"
        guard let url = URL(string: urlString),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "h2h-events|\(urlString)"),
              let wire = try? JSONDecoder().decode(EventsWire.self, from: fetched.data)
        else { return [] }
        return Set((wire.items ?? []).compactMap { item -> String? in
            guard let ref = item.ref else { return nil }
            return ref.split(separator: "/").last?
                .split(separator: "?").first.map(String.init)
        })
    }

    private static func meeting(
        segment: String, slug: String, eventId: String,
        homeName: String?, awayName: String?
    ) async -> MatchH2HMeeting? {
        let urlString = "https://sports.core.api.espn.com/v2/sports/\(segment)/leagues/\(slug)/events/\(eventId)"
        guard let url = URL(string: urlString),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "h2h-event|\(eventId)"),
              let wire = try? JSONDecoder().decode(EventWire.self, from: fetched.data),
              let competitors = wire.competitions?.first?.competitors,
              let home = competitors.first(where: { $0.homeAway == "home" }),
              let away = competitors.first(where: { $0.homeAway == "away" })
        else { return nil }
        async let homeScore = scoreText(home.score?.ref)
        async let awayScore = scoreText(away.score?.ref)
        return MatchH2HMeeting(
            id: eventId,
            date: wire.date.flatMap { MatchesService.parseEventDate($0) },
            homeName: homeName,
            awayName: awayName,
            homeScore: await homeScore,
            awayScore: await awayScore
        )
    }

    private static func scoreText(_ ref: String?) async -> String? {
        guard let ref, let url = URL(string: ref),
              let (data, _) = try? await URLSession.shared.data(for: url),
              let wire = try? JSONDecoder().decode(ScoreWire.self, from: data)
        else { return nil }
        if let display = wire.displayValue, !display.isEmpty { return display }
        guard let value = wire.value else { return nil }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }
}
