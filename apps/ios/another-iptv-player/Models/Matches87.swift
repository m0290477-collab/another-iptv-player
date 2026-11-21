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
            // Build 90 (SP18): the Full-set splits — verified
            // live 2026-11-21 in standings/now (home/road/L10
            // W-L-OT triples on every entry).
            let homeWins: Int?
            let homeLosses: Int?
            let homeOtLosses: Int?
            let roadWins: Int?
            let roadLosses: Int?
            let roadOtLosses: Int?
            let l10Wins: Int?
            let l10Losses: Int?
            let l10OtLosses: Int?
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
            // Build 90 (SP18): Home / Road / Last-10 records,
            // composed from the payload's own split triples
            // under the standard abbreviations — the Full set
            // now matches the other three US sports.
            func record(_ wins: Int?, _ losses: Int?, _ otLosses: Int?) -> String? {
                guard let wins, let losses, let otLosses else { return nil }
                return "\(wins)-\(losses)-\(otLosses)"
            }
            put("homeRecord", "HOME", record(entry.homeWins, entry.homeLosses, entry.homeOtLosses))
            put("roadRecord", "ROAD", record(entry.roadWins, entry.roadLosses, entry.roadOtLosses))
            put("lastTen", "L10", record(entry.l10Wins, entry.l10Losses, entry.l10OtLosses))
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
        let goalsAgainstAverage: [Leader]?
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
            "\(base)/goalie-stats-leaders/current?categories=wins,savePctg,shutouts,goalsAgainstAverage&limit=15",
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
            ("shutouts", "Shutouts", \.shutouts),
            // Build 90 (SP17): goals-against average — the one
            // further goalie category the endpoint verifies
            // (checked live 2026-11-21: 200, real values;
            // unverified skater categories answer 400 and
            // none are requested).
            ("goalsAgainstAverage", "GAA", \.goalsAgainstAverage)
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
        if key == "goalsAgainstAverage" {
            return String(format: "%.2f", value)
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

    /// Build 90 (SP13): one goalie's line from the boxscore —
    /// the payload fields verified live 2026-11-21 (game
    /// 2026020359: 2 goalies per team with saves / shots
    /// against / goals against / save percentage / decision /
    /// TOI / starter). Build 87 decoded the goalies array
    /// into the skater shape and never read it.
    struct GoalieLine: Identifiable {
        let id: String
        let name: String
        let saves: Int
        let shotsAgainst: Int
        let goalsAgainst: Int
        let savePctgText: String?
        let decision: String?
        let toi: String?
        let starter: Bool
        let headshotURL: URL?
    }

    struct GameDetail {
        let venue: String?
        let scoring: [(period: String, goals: [Goal])]
        let stars: [Star]
        let skaterLines: [(teamAbbrev: String, lines: [SkaterLine])]
        let goalieLines: [(teamAbbrev: String, lines: [GoalieLine])]
        /// Build 90 (SP19): the match rebuilt from the landing
        /// payload itself (teams, scores, state, start time) —
        /// the seedless page (a push tap) renders its header,
        /// Watch and reminder sections from this.
        let matchEvent: MatchEvent?
    }

    private struct LandingWire: Decodable {
        // Build 90 (SP19): the landing payload carries the
        // full game header (verified live 2026-11-21: id,
        // startTimeUTC, gameState, period/clock, and both
        // team sides in the schedule's TeamSide shape,
        // scores included).
        let id: Int?
        let startTimeUTC: String?
        let gameState: String?
        let awayTeam: TeamSide?
        let homeTeam: TeamSide?
        let periodDescriptor: PeriodDescriptor?
        let clock: Clock?
        let gameOutcome: GameOutcome?
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
            let goalies: [Goalie]?
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
        /// Build 90 (SP13): the goalie shape — the fields the
        /// boxscore actually publishes for goaltenders.
        struct Goalie: Decodable {
            let playerId: Int?
            let name: NHLText?
            let toi: String?
            let saves: Int?
            let shotsAgainst: Int?
            let goalsAgainst: Int?
            let savePctg: Double?
            let decision: String?
            let starter: Bool?
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
                    // Build 90 (SP14): HOME – AWAY, like the
                    // page's own header and every other
                    // surface (build 87 composed away – home).
                    scoreText: (goal.homeScore != nil && goal.awayScore != nil)
                        ? "\(goal.homeScore ?? 0) – \(goal.awayScore ?? 0)" : nil
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
        var goalies: [(teamAbbrev: String, lines: [GoalieLine])] = []
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
                // Build 90 (SP13): the goalie lines the
                // build-87 mapping discarded.
                let mappedGoalies = (groups.goalies ?? []).compactMap { goalie -> GoalieLine? in
                    guard let id = goalie.playerId else { return nil }
                    let pctText = goalie.savePctg.map { value -> String in
                        var text = String(format: "%.3f", value)
                        if text.hasPrefix("0.") { text = String(text.dropFirst()) }
                        return text
                    }
                    return GoalieLine(
                        id: String(id),
                        name: goalie.name?.value ?? "",
                        saves: goalie.saves ?? 0,
                        shotsAgainst: goalie.shotsAgainst ?? 0,
                        goalsAgainst: goalie.goalsAgainst ?? 0,
                        savePctgText: pctText,
                        decision: goalie.decision,
                        toi: goalie.toi,
                        starter: goalie.starter ?? false,
                        headshotURL: goalie.headshot.flatMap { URL(string: $0) }
                    )
                }
                if !mappedGoalies.isEmpty {
                    goalies.append((teamAbbrev: "", lines: mappedGoalies))
                }
            }
        }
        // Build 90 (SP19): rebuild the match from the landing
        // payload through the SAME mapper the scoreboard
        // uses, so a seedless page shows the identical header.
        var rebuilt: MatchEvent?
        if let away = wire.awayTeam, let home = wire.homeTeam {
            let game = Game(
                id: wire.id, startTimeUTC: wire.startTimeUTC,
                gameState: wire.gameState,
                awayTeam: away, homeTeam: home,
                periodDescriptor: wire.periodDescriptor,
                clock: wire.clock, gameOutcome: wire.gameOutcome,
                venue: wire.venue
            )
            rebuilt = await mapGame(game)
        }
        return GameDetail(
            venue: wire.venue?.value,
            scoring: scoring,
            stars: stars,
            skaterLines: lines,
            goalieLines: goalies,
            matchEvent: rebuilt
        )
    }

    // MARK: Play-by-play (build 90, SP18)
    //
    // Verified live 2026-11-21: gamecenter/{id}/play-by-play
    // answers 200 (~141 KB, 339 plays for game 2026020359)
    // with a typeDescKey taxonomy and per-play details. The
    // feed the page shows is the EVENTFUL plays — goals,
    // penalties, shots (on goal / missed / blocked) and hits;
    // faceoffs, stoppages, giveaways/takeaways and the period
    // markers are payload noise for a reader. Player names
    // are NOT in this payload (ids only) — they resolve
    // through the boxscore the page already fetched (a disk-
    // cache hit), and goals take their scorer/assists text
    // from the landing's scoring, matched by eventId. A play
    // whose name cannot be resolved still renders with its
    // type label — never an invented name. Goal plays carry
    // only a Brightcove id + nhl.com URL (re-verified in the
    // S3 audit) — no video is offered, by the standing rule.

    struct PlayItem: Identifiable {
        let id: String
        let periodLabel: String
        let timeText: String?
        /// The payload's own typeDescKey ("goal", "penalty", …).
        let typeKey: String
        /// The composed line: scorer + assists for a goal, the
        /// penalized player + the payload's infraction key for
        /// a penalty, the shooter for a shot, the hitter for a
        /// hit — nil when no name resolved.
        let text: String?
        /// Running score after a goal, HOME – AWAY.
        let scoreText: String?
        let isGoal: Bool
    }

    private struct PlayByPlayWire: Decodable {
        let plays: [Play]?
        struct Play: Decodable {
            let eventId: Int?
            let periodDescriptor: PeriodDescriptor?
            let timeInPeriod: String?
            let typeDescKey: String?
            let details: Details?
        }
        struct Details: Decodable {
            let scoringPlayerId: Int?
            let committedByPlayerId: Int?
            let shootingPlayerId: Int?
            let hittingPlayerId: Int?
            let descKey: String?
            let duration: Int?
            let homeScore: Int?
            let awayScore: Int?
        }
    }

    private static let playTypesShown: Set<String> = [
        "goal", "penalty", "shot-on-goal", "missed-shot", "blocked-shot", "hit"
    ]

    static func playByPlay(eventId: String) async -> [PlayItem] {
        async let pbpData = fetchData(
            "\(base)/gamecenter/\(eventId)/play-by-play", cacheKey: "nhl-pbp|\(eventId)"
        )
        guard let data = await pbpData,
              let wire = try? JSONDecoder().decode(PlayByPlayWire.self, from: data)
        else { return [] }
        // Names: the boxscore's skaters + goalies by id (the
        // page's own fetch — served from the disk cache), and
        // the landing's goal texts by eventId.
        var names: [String: String] = [:]
        if let box = await fetchData(
            "\(base)/gamecenter/\(eventId)/boxscore", cacheKey: "nhl-boxscore|\(eventId)"
        ), let boxWire = try? JSONDecoder().decode(BoxscoreWire.self, from: box),
           let teams = boxWire.playerByGameStats {
            for groups in [teams.awayTeam, teams.homeTeam] {
                guard let groups else { continue }
                for skater in (groups.forwards ?? []) + (groups.defense ?? []) {
                    if let id = skater.playerId, let name = skater.name?.value {
                        names[String(id)] = name
                    }
                }
                for goalie in groups.goalies ?? [] {
                    if let id = goalie.playerId, let name = goalie.name?.value {
                        names[String(id)] = name
                    }
                }
            }
        }
        var goalTexts: [String: String] = [:]
        if let detail = await gameDetail(eventId: eventId) {
            for period in detail.scoring {
                for goal in period.goals {
                    var text = goal.scorerName
                    if let assists = goal.assistsText, !assists.isEmpty {
                        text += " (\(assists))"
                    }
                    goalTexts[goal.id] = text
                }
            }
        }
        let plays = (wire.plays ?? []).filter { play in
            guard let key = play.typeDescKey else { return false }
            return playTypesShown.contains(key)
        }
        // Newest first, the play-by-play convention.
        return plays.reversed().compactMap { play -> PlayItem? in
            guard let key = play.typeDescKey, let eventIdValue = play.eventId
            else { return nil }
            let id = String(eventIdValue)
            let number = play.periodDescriptor?.number ?? 0
            let periodLabel: String
            if play.periodDescriptor?.periodType == "SO" {
                periodLabel = "SO"
            } else if play.periodDescriptor?.periodType == "OT" {
                periodLabel = "OT"
            } else if number > 0 {
                periodLabel = "P\(number)"
            } else {
                periodLabel = ""
            }
            let details = play.details
            var text: String?
            var scoreText: String?
            switch key {
            case "goal":
                text = goalTexts[id]
                    ?? details?.scoringPlayerId.flatMap { names[String($0)] }
                if let home = details?.homeScore, let away = details?.awayScore {
                    scoreText = "\(home) – \(away)"
                }
            case "penalty":
                let who = details?.committedByPlayerId.flatMap { names[String($0)] }
                var parts: [String] = []
                if let who { parts.append(who) }
                if let desc = details?.descKey, !desc.isEmpty { parts.append(desc) }
                if let duration = details?.duration { parts.append("\(duration) min") }
                text = parts.isEmpty ? nil : parts.joined(separator: " · ")
            case "shot-on-goal", "missed-shot", "blocked-shot":
                text = details?.shootingPlayerId.flatMap { names[String($0)] }
            case "hit":
                text = details?.hittingPlayerId.flatMap { names[String($0)] }
            default:
                text = nil
            }
            return PlayItem(
                id: id,
                periodLabel: periodLabel,
                timeText: play.timeInPeriod,
                typeKey: key,
                text: text,
                scoreText: scoreText,
                isGoal: key == "goal"
            )
        }
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

/// One session of a race weekend (build 90, SP26): the
/// schedule payload carries every session's date + time —
/// build 87 decoded none of them, so a race weekend was one
/// date instead of a weekend.
struct F1Session: Identifiable {
    let label: String
    let date: Date?
    var id: String { label }
}

struct F1Race: Identifiable {
    let round: Int
    let name: String
    let circuit: String?
    let locality: String?
    let country: String?
    let date: Date?
    let timeText: String?
    let sessions: [F1Session]
    var id: Int { round }
}

struct F1ResultRow: Identifiable {
    let position: String
    /// The payload's positionText ("R" retired, "W" withdrew)
    /// — a retired driver is NOT classified at his numeric
    /// position (build 90, SP26).
    let positionText: String?
    let driverName: String
    let driverCode: String?
    let constructorName: String?
    let points: String?
    let status: String?
    let timeText: String?
    let grid: String?
    let laps: String?
    let fastestLap: Bool
    var id: String { position + "|" + driverName }
}

/// One qualifying row (build 90, SP26): Q1/Q2/Q3 times
/// verbatim from the payload (a knocked-out driver simply
/// has no Q2/Q3).
struct F1QualifyingRow: Identifiable {
    let position: String
    let driverName: String
    let driverCode: String?
    let constructorName: String?
    let q1: String?
    let q2: String?
    let q3: String?
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
            let qualifyingResults: [QualifyingResult]?
            let sprintResults: [RaceResult]?
            // Build 90 (SP26): the weekend's sessions, all
            // present in current.json (verified 2026-11-21).
            let firstPractice: Session?
            let secondPractice: Session?
            let thirdPractice: Session?
            let qualifying: Session?
            let sprint: Session?
            let sprintQualifying: Session?
            enum CodingKeys: String, CodingKey {
                case round, raceName, date, time
                case circuit = "Circuit"
                case results = "Results"
                case qualifyingResults = "QualifyingResults"
                case sprintResults = "SprintResults"
                case firstPractice = "FirstPractice"
                case secondPractice = "SecondPractice"
                case thirdPractice = "ThirdPractice"
                case qualifying = "Qualifying"
                case sprint = "Sprint"
                case sprintQualifying = "SprintQualifying"
            }
        }
        struct Session: Decodable {
            let date: String?
            let time: String?
        }
        struct QualifyingResult: Decodable {
            let position: String?
            let driver: Driver?
            let constructor: Constructor?
            let q1: String?
            let q2: String?
            let q3: String?
            enum CodingKeys: String, CodingKey {
                case position
                case driver = "Driver"
                case constructor = "Constructor"
                case q1 = "Q1"
                case q2 = "Q2"
                case q3 = "Q3"
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
            let positionText: String?
            let points: String?
            let driver: Driver?
            let constructor: Constructor?
            let status: String?
            let time: ResultTime?
            let grid: String?
            let laps: String?
            let fastestLap: FastestLap?
            enum CodingKeys: String, CodingKey {
                case position, positionText, points, status, grid, laps
                case driver = "Driver"
                case constructor = "Constructor"
                case time = "Time"
                case fastestLap = "FastestLap"
            }
        }
        struct ResultTime: Decodable { let time: String? }
        struct FastestLap: Decodable { let rank: String? }
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
        await fetchWireStamped(path, cacheKey: cacheKey)?.wire
    }

    /// Build 90 (SP30): the stamp-carrying form — the disk
    /// cache's stamp is non-nil exactly when the payload was
    /// served from disk, and the page shows it.
    private static func fetchWireStamped(
        _ path: String, cacheKey: String
    ) async -> (wire: Wire, stamp: Date?)? {
        guard let url = URL(string: "\(base)/\(path)"),
              let result = await SportsDiskCache.espnData(url: url, cacheKey: cacheKey),
              let wire = try? JSONDecoder().decode(Wire.self, from: result.data)
        else { return nil }
        return (wire, result.stamp)
    }

    static func schedule() async -> [F1Race] {
        await scheduleStamped().races
    }

    static func scheduleStamped() async -> (races: [F1Race], stamp: Date?) {
        guard let fetched = await fetchWireStamped("current.json", cacheKey: "f1|schedule")
        else { return ([], nil) }
        let races = (fetched.wire.mrData.raceTable?.races ?? []).compactMap { race -> F1Race? in
            guard let name = race.raceName else { return nil }
            return F1Race(
                round: Int(race.round ?? "") ?? 0,
                name: name,
                circuit: race.circuit?.circuitName,
                locality: race.circuit?.location?.locality,
                country: race.circuit?.location?.country,
                date: raceDate(race.date, race.time),
                timeText: race.time,
                sessions: sessions(of: race)
            )
        }
        return (races, fetched.stamp)
    }

    /// The weekend's sessions in chronological order (race
    /// itself excluded — the race row carries its own time).
    private static func sessions(of race: Wire.Race) -> [F1Session] {
        let labelled: [(label: String, session: Wire.Session?)] = [
            ("FP1", race.firstPractice),
            ("FP2", race.secondPractice),
            ("FP3", race.thirdPractice),
            ("Sprint Qualifying", race.sprintQualifying),
            ("Sprint", race.sprint),
            ("Qualifying", race.qualifying)
        ]
        return labelled.compactMap { entry -> F1Session? in
            guard let session = entry.session else { return nil }
            return F1Session(label: entry.label, date: raceDate(session.date, session.time))
        }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    /// Build 90 (SP26): one round's full race classification
    /// — the per-round endpoint replaces the build-87
    /// "last race only" results (verified live 2026-11-21:
    /// current/19/results.json, full 22-driver classification
    /// with grid, laps, status, times, fastest laps).
    static func raceResults(round: Int) async -> [F1ResultRow] {
        guard let wire = await fetchWire(
            "current/\(round)/results.json", cacheKey: "f1|results|\(round)"
        ), let race = wire.mrData.raceTable?.races?.first else { return [] }
        return mapResultRows(race.results)
    }

    /// One round's sprint classification — present on sprint
    /// weekends only; other rounds answer without the array
    /// and the section simply doesn't render.
    static func raceSprint(round: Int) async -> [F1ResultRow] {
        guard let wire = await fetchWire(
            "current/\(round)/sprint.json", cacheKey: "f1|sprint|\(round)"
        ), let race = wire.mrData.raceTable?.races?.first else { return [] }
        return mapResultRows(race.sprintResults)
    }

    /// One round's qualifying table (Q1/Q2/Q3 verbatim).
    static func raceQualifying(round: Int) async -> [F1QualifyingRow] {
        guard let wire = await fetchWire(
            "current/\(round)/qualifying.json", cacheKey: "f1|qualifying|\(round)"
        ), let race = wire.mrData.raceTable?.races?.first else { return [] }
        return (race.qualifyingResults ?? []).compactMap { result -> F1QualifyingRow? in
            guard let position = result.position,
                  let driver = result.driver,
                  let name = driverName(driver) else { return nil }
            return F1QualifyingRow(
                position: position,
                driverName: name,
                driverCode: driver.code,
                constructorName: result.constructor?.name,
                q1: result.q1, q2: result.q2, q3: result.q3
            )
        }
    }

    private static func mapResultRows(_ results: [Wire.RaceResult]?) -> [F1ResultRow] {
        (results ?? []).compactMap { result -> F1ResultRow? in
            guard let position = result.position,
                  let driver = result.driver,
                  let name = driverName(driver) else { return nil }
            return F1ResultRow(
                position: position,
                positionText: result.positionText,
                driverName: name,
                driverCode: driver.code,
                constructorName: result.constructor?.name,
                points: result.points,
                status: result.status,
                timeText: result.time?.time,
                grid: result.grid,
                laps: result.laps,
                fastestLap: result.fastestLap?.rank == "1"
            )
        }
    }

    static func driverStandings() async -> [F1DriverStanding] {
        await driverStandingsStamped().rows
    }

    static func driverStandingsStamped() async -> (rows: [F1DriverStanding], stamp: Date?) {
        guard let fetched = await fetchWireStamped("current/driverStandings.json", cacheKey: "f1|drivers"),
              let list = fetched.wire.mrData.standingsTable?.standingsLists?.first
        else { return ([], nil) }
        let rows = (list.driverStandings ?? []).compactMap { standing -> F1DriverStanding? in
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
        return (rows, fetched.stamp)
    }

    static func constructorStandings() async -> [F1ConstructorStanding] {
        await constructorStandingsStamped().rows
    }

    static func constructorStandingsStamped() async -> (rows: [F1ConstructorStanding], stamp: Date?) {
        guard let fetched = await fetchWireStamped("current/constructorStandings.json", cacheKey: "f1|constructors"),
              let list = fetched.wire.mrData.standingsTable?.standingsLists?.first
        else { return ([], nil) }
        let rows = (list.constructorStandings ?? []).compactMap { standing -> F1ConstructorStanding? in
            guard let position = standing.position,
                  let name = standing.constructor?.name else { return nil }
            return F1ConstructorStanding(
                position: position, name: name,
                points: standing.points, wins: standing.wins
            )
        }
        return (rows, fetched.stamp)
    }

    /// Build 90 (SP30): the F1 page's whole load in one call,
    /// carrying the OLDEST disk stamp among its fetches (the
    /// honest "last updated" when any part was served stale).
    static func overview() async -> (
        races: [F1Race], drivers: [F1DriverStanding],
        constructors: [F1ConstructorStanding], stamp: Date?
    ) {
        async let schedule = scheduleStamped()
        async let drivers = driverStandingsStamped()
        async let constructors = constructorStandingsStamped()
        let scheduleResult = await schedule
        let driversResult = await drivers
        let constructorsResult = await constructors
        let stamp = [scheduleResult.stamp, driversResult.stamp, constructorsResult.stamp]
            .compactMap { $0 }.min()
        return (scheduleResult.races, driversResult.rows, constructorsResult.rows, stamp)
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
    /// Build 90 (SP27): the payload's own curatedRank per
    /// competitor (verified live 2026-11-21 in the scoreboard
    /// payload). The same payload carries NO seed and NO flag
    /// fields — those are not shown, not invented.
    let rank1: Int?
    let rank2: Int?
}

/// One rankings row (build 90, SP27): rank, previous rank,
/// points and trend — the payload's own fields from the
/// verified rankings endpoint (site/v2 tennis/{tour}/
/// rankings, 200, 150 deep for both tours, 2026-11-21).
struct TennisRankingRow: Identifiable {
    let rank: Int
    let previous: Int?
    let pointsText: String?
    let trend: String?
    let name: String
    let athleteId: String?
    var id: String { "\(rank)|\(name)" }
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
            let curatedRank: CuratedRank?
        }
        struct CuratedRank: Decodable {
            let current: Int?
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
        await tournamentsStamped(tourPath: tourPath).tournaments
    }

    /// Build 90 (SP30): the stamp-carrying form (the page
    /// shows "last updated" when the board was served from
    /// the disk cache).
    static func tournamentsStamped(
        tourPath: String
    ) async -> (tournaments: [TennisTournament], stamp: Date?) {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(tourPath)/scoreboard"),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "tennis|\(tourPath)"),
              let wire = try? JSONDecoder().decode(ScoreboardWire.self, from: fetched.data)
        else { return ([], nil) }
        let tournaments = (wire.events ?? []).compactMap { event -> TennisTournament? in
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
        return (tournaments, fetched.stamp)
    }

    // MARK: Rankings (build 90, SP27)
    //
    // Verified live 2026-11-21: site/v2/sports/tennis/atp/
    // rankings and …/wta/rankings answer 200 (~390 KB) with
    // rankings[0].ranks 150 deep — current / previous /
    // points / trend + the athlete's display name and id.
    // The season-calendar idea does NOT ship: the scoreboard
    // payload's league calendar is a bare list of date
    // strings with no tournament names (verified in the same
    // pass), so there is nothing truthful to render.

    private struct RankingsWire: Decodable {
        let rankings: [Group]?
        struct Group: Decodable {
            let ranks: [Rank]?
        }
        struct Rank: Decodable {
            let current: Int?
            let previous: Int?
            let points: Double?
            let trend: String?
            let athlete: Athlete?
        }
        struct Athlete: Decodable {
            let id: String?
            let displayName: String?
        }
    }

    /// The tour's rankings, top 100 (the payload runs 150
    /// deep; the page stays light). Points render verbatim —
    /// whole numbers without a fraction, the payload's own
    /// precision otherwise.
    static func rankings(
        tourPath: String
    ) async -> (rows: [TennisRankingRow], stamp: Date?) {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(tourPath)/rankings"),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "tennis-rank|\(tourPath)"),
              let wire = try? JSONDecoder().decode(RankingsWire.self, from: fetched.data),
              let group = wire.rankings?.first
        else { return ([], nil) }
        let rows = (group.ranks ?? []).prefix(100).compactMap { rank -> TennisRankingRow? in
            guard let current = rank.current,
                  let name = rank.athlete?.displayName, !name.isEmpty
            else { return nil }
            let pointsText = rank.points.map { value -> String in
                value == value.rounded() ? String(Int(value)) : String(value)
            }
            return TennisRankingRow(
                rank: current,
                previous: rank.previous,
                pointsText: pointsText,
                trend: rank.trend,
                name: name,
                athleteId: rank.athlete?.id
            )
        }
        return (rows, fetched.stamp)
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
            winnerIndex: winnerIndex,
            rank1: first.curatedRank?.current,
            rank2: second.curatedRank?.current
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

/// One hole of one round (build 90, SP29): the scoreboard
/// payload nests 18 per-hole linescores inside each round
/// linescore — verified live 2026-11-21 (PGA scoreboard:
/// value + displayValue + period + scoreType per hole).
struct GolfHole: Identifiable {
    let number: Int
    let scoreText: String?
    let scoreTypeText: String?
    var id: Int { number }
}

/// One round of a player's tournament (build 90, SP29).
struct GolfRound: Identifiable {
    let number: Int
    let scoreText: String?
    let holes: [GolfHole]
    var id: Int { number }
}

struct GolfRow: Identifiable {
    let position: Int
    /// Build 90 (SP29): the tie-aware position label —
    /// players level on score share one position with a "T"
    /// prefix (the payload's raw `order` numbered tied
    /// players sequentially, which is not how golf tables
    /// read).
    let positionText: String
    let name: String
    let scoreText: String?
    let roundScores: [String]
    let rounds: [GolfRound]
    var id: String { "\(position)|\(name)" }
}

struct GolfLeaderboard {
    let tourPath: String
    let leagueName: String?
    let eventName: String?
    let state: MatchState
    /// Build 90 (SP29): the payload's own status line
    /// ("Round 3 - Suspended") — the board's computed state,
    /// previously derived in the service and never shown.
    let stateText: String?
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
            // Build 90 (SP29): the nested per-hole linescores.
            let linescores: [HoleScore]?
        }
        struct HoleScore: Decodable {
            let displayValue: String?
            let period: Int?
            let scoreType: ScoreType?
        }
        struct ScoreType: Decodable {
            let displayValue: String?
        }
    }

    static let tours: [(path: String, label: String)] = [
        (path: "golf/pga", label: "PGA Tour"),
        (path: "golf/eur", label: "DP World Tour"),
        (path: "golf/lpga", label: "LPGA")
    ]

    static func leaderboard(tourPath: String) async -> GolfLeaderboard? {
        await leaderboardStamped(tourPath: tourPath).board
    }

    /// Build 90 (SP30): the stamp-carrying form.
    static func leaderboardStamped(
        tourPath: String
    ) async -> (board: GolfLeaderboard?, stamp: Date?) {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(tourPath)/scoreboard"),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "golf|\(tourPath)"),
              let wire = try? JSONDecoder().decode(ScoreboardWire.self, from: fetched.data),
              let event = wire.events?.first,
              let competition = event.competitions?.first
        else { return (nil, nil) }
        let state: MatchState
        switch (competition.status?.type?.state ?? event.status?.type?.state) {
        case "in": state = .live
        case "post": state = .finished
        default: state = .upcoming
        }
        let stateText = competition.status?.type?.detail
            ?? competition.status?.type?.shortDetail
            ?? event.status?.type?.detail
            ?? event.status?.type?.shortDetail
        let rawRows = (competition.competitors ?? []).enumerated().compactMap {
            index, competitor -> (position: Int, name: String, score: String?, rounds: [GolfRound], roundScores: [String])? in
            guard let name = competitor.athlete?.displayName, !name.isEmpty else { return nil }
            let roundWires = (competitor.linescores ?? [])
                .sorted { ($0.period ?? 0) < ($1.period ?? 0) }
            let rounds = roundWires.map { round -> GolfRound in
                let holes = (round.linescores ?? [])
                    .sorted { ($0.period ?? 0) < ($1.period ?? 0) }
                    .map { hole in
                        GolfHole(
                            number: hole.period ?? 0,
                            scoreText: hole.displayValue,
                            scoreTypeText: hole.scoreType?.displayValue
                        )
                    }
                return GolfRound(
                    number: round.period ?? 0,
                    scoreText: round.displayValue,
                    holes: holes
                )
            }
            return (
                position: competitor.order ?? index + 1,
                name: name,
                score: competitor.score,
                rounds: rounds,
                roundScores: roundWires.compactMap { $0.displayValue }
            )
        }
        // Build 90 (SP29): tie-aware positions from the
        // payload's own scores — level players share a rank.
        let parsedScores = rawRows.map { scoreValue($0.score) }
        let rows = rawRows.enumerated().map { index, raw -> GolfRow in
            var positionText = "\(raw.position)"
            if let mine = parsedScores[index] {
                let better = parsedScores.filter { ($0 ?? Int.max) < mine }.count
                let tied = parsedScores.filter { $0 == mine }.count
                positionText = tied > 1 ? "T\(better + 1)" : "\(better + 1)"
            }
            return GolfRow(
                position: raw.position,
                positionText: positionText,
                name: raw.name,
                scoreText: raw.score,
                roundScores: raw.roundScores,
                rounds: raw.rounds
            )
        }
        let board = GolfLeaderboard(
            tourPath: tourPath,
            leagueName: wire.leagues?.first?.name,
            eventName: event.name,
            state: state,
            stateText: stateText,
            rows: rows
        )
        return (board, fetched.stamp)
    }

    /// "-12" → -12, "E" → 0, "+3" → 3; anything else nil.
    private static func scoreValue(_ text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty
        else { return nil }
        if text == "E" { return 0 }
        return Int(text)
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
    /// Build 90 (SP28): the fight's weight class — the
    /// payload's own competition type ("Lightweight"),
    /// verified live 2026-11-21. Build 87 decoded it nowhere,
    /// so fights rendered with no class context at all.
    let weightClass: String?
}

/// One UFC ranking list offered by the core index (build 90,
/// SP28): the slug from the payload's own $ref, the title
/// derived mechanically from it.
struct UFCRankingListRef: Identifiable {
    let slug: String
    let title: String
    var id: String { slug }
}

/// One fighter in a ranking list: rank + trend from the
/// list payload, the name from the athlete $ref deref.
struct UFCRankRow: Identifiable {
    let rank: Int
    let trend: String?
    let name: String
    var id: String { "\(rank)|\(name)" }
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
        // Build 90 (SP28): the undated scoreboard carries the
        // league's season calendar (label + startDate per
        // event) — the schedule source that replaces the
        // 11-request day fan-out.
        let leagues: [League]?
        struct League: Decodable {
            let calendar: [CalendarEntry]?
        }
        struct CalendarEntry: Decodable {
            let label: String?
            let startDate: String?
        }
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
            let type: FightType?
        }
        struct FightType: Decodable {
            let abbreviation: String?
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

    static func cards() async -> [UFCCard] {
        await cardsStamped().cards
    }

    /// Build 90 (SP28): the schedule now comes from ONE
    /// undated scoreboard fetch — verified live 2026-11-21:
    /// it returns today's card (when there is one) PLUS the
    /// league's full season calendar (53 events with labels
    /// and start dates). The calendar names the most recent
    /// past card day and the next card day — even beyond the
    /// old +7-day reach, which fixes the dark-week empty page
    /// — and only those (at most two) days are fetched with
    /// the dated form. Total: 1–3 requests instead of 11.
    /// The old −3…+7 fan-out survives ONLY as the fallback
    /// for a payload with no calendar at all.
    static func cardsStamped() async -> (cards: [UFCCard], stamp: Date?) {
        var stamps: [Date] = []
        var collected: [UFCCard] = []
        var calendarDays: [Date] = []
        if let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard"),
           let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "ufc|undated"),
           let wire = try? JSONDecoder().decode(ScoreboardWire.self, from: fetched.data) {
            collected += mapCards(wire)
            if let stamp = fetched.stamp { stamps.append(stamp) }
            calendarDays = (wire.leagues?.first?.calendar ?? []).compactMap {
                $0.startDate.flatMap { MatchesService.parseEventDate($0) }
            }
        }
        if calendarDays.isEmpty {
            // Fallback: the build-87 day fan-out.
            let days = MatchesService.dayParameters()
            let perDay = await withTaskGroup(of: (cards: [UFCCard], stamp: Date?).self) { group in
                for day in days {
                    group.addTask { await cards(dayParameter: day) }
                }
                var out: [(cards: [UFCCard], stamp: Date?)] = []
                for await items in group { out.append(items) }
                return out
            }
            for result in perDay {
                collected += result.cards
                if let stamp = result.stamp { stamps.append(stamp) }
            }
        } else {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let coveredDays = Set(collected.compactMap { card -> String? in
                card.date.map { dayParameter(for: $0) }
            })
            var targets = Set<String>()
            if let last = calendarDays.filter({ calendar.startOfDay(for: $0) < today }).max() {
                targets.insert(dayParameter(for: last))
            }
            if let next = calendarDays.filter({ calendar.startOfDay(for: $0) > today }).min() {
                targets.insert(dayParameter(for: next))
            }
            // Today's own calendar entry needs no fetch — the
            // undated payload already carried today's card.
            targets.subtract(coveredDays)
            for day in targets {
                let result = await cards(dayParameter: day)
                collected += result.cards
                if let stamp = result.stamp { stamps.append(stamp) }
            }
        }
        var seen = Set<String>()
        let merged = collected
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        return (merged, stamps.min())
    }

    private static func dayParameter(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func cards(
        dayParameter: String
    ) async -> (cards: [UFCCard], stamp: Date?) {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard?dates=\(dayParameter)"),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "ufc|\(dayParameter)"),
              let wire = try? JSONDecoder().decode(ScoreboardWire.self, from: fetched.data)
        else { return ([], nil) }
        return (mapCards(wire), fetched.stamp)
    }

    private static func mapCards(_ wire: ScoreboardWire) -> [UFCCard] {
        (wire.events ?? []).compactMap { event -> UFCCard? in
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
                    startDate: fight.date.flatMap { MatchesService.parseEventDate($0) },
                    weightClass: fight.type?.abbreviation
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

    // MARK: Rankings (build 90, SP28)
    //
    // Verified live 2026-11-21: the ESPN core index
    // (v2/sports/mma/leagues/ufc/rankings) lists 24 ranking
    // lists by $ref (pound-for-pound, the divisional lists,
    // the champions lists); each list payload is small
    // (~2 KB) with ranks carrying current / trend and an
    // athlete $ref. Names come from the athlete derefs —
    // the app's existing core pattern — fanned out at most
    // 8 at a time and session-cached per list, so a list is
    // resolved once per app run. Lists load LAZILY (only the
    // division the user opens), never all 24 up front.

    private struct RankingsIndexWire: Decodable {
        let items: [RefItem]?
        struct RefItem: Decodable {
            let ref: String?
            enum CodingKeys: String, CodingKey { case ref = "$ref" }
        }
    }

    private struct RankingListWire: Decodable {
        let ranks: [Rank]?
        struct Rank: Decodable {
            let current: Int?
            let trend: String?
            let athlete: RefItem?
        }
        struct RefItem: Decodable {
            let ref: String?
            enum CodingKeys: String, CodingKey { case ref = "$ref" }
        }
    }

    private struct AthleteWire: Decodable {
        let displayName: String?
        let fullName: String?
        let shortName: String?
    }

    private final class RankingsCache: @unchecked Sendable {
        static let shared = RankingsCache()
        private let lock = NSLock()
        private var lists: [String: [UFCRankRow]] = [:]
        func get(_ key: String) -> [UFCRankRow]? {
            lock.lock(); defer { lock.unlock() }
            return lists[key]
        }
        func put(_ key: String, _ value: [UFCRankRow]) {
            lock.lock(); defer { lock.unlock() }
            lists[key] = value
        }
    }

    static func rankingLists() async -> [UFCRankingListRef] {
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/mma/leagues/ufc/rankings"),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "ufc-rank|index"),
              let wire = try? JSONDecoder().decode(RankingsIndexWire.self, from: fetched.data)
        else { return [] }
        return (wire.items ?? []).compactMap { item -> UFCRankingListRef? in
            guard let ref = item.ref,
                  let slug = ref.split(separator: "/").last?
                      .split(separator: "?").first.map(String.init),
                  !slug.isEmpty
            else { return nil }
            let title = slug
                .split(separator: "-")
                .map { $0.capitalized }
                .joined(separator: " ")
            return UFCRankingListRef(slug: slug, title: title)
        }
    }

    static func rankingList(slug: String) async -> [UFCRankRow] {
        if let cached = RankingsCache.shared.get(slug) { return cached }
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/mma/leagues/ufc/rankings/\(slug)"),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "ufc-rank|\(slug)"),
              let wire = try? JSONDecoder().decode(RankingListWire.self, from: fetched.data)
        else { return [] }
        let ranks = (wire.ranks ?? []).filter { $0.current != nil }
        // Athlete names by $ref deref, at most 8 in flight.
        var names: [Int: String] = [:]
        var cursor = 0
        while cursor < ranks.count {
            let batch = Array(ranks[cursor..<min(cursor + 8, ranks.count)])
            let resolved = await withTaskGroup(of: (Int, String?).self) { group in
                for (offset, rank) in batch.enumerated() {
                    group.addTask {
                        (cursor + offset, await athleteName(ref: rank.athlete?.ref))
                    }
                }
                var out: [(Int, String?)] = []
                for await item in group { out.append(item) }
                return out
            }
            for (index, name) in resolved { names[index] = name }
            cursor += batch.count
        }
        let rows = ranks.enumerated().compactMap { index, rank -> UFCRankRow? in
            guard let current = rank.current, let name = names[index], !name.isEmpty
            else { return nil }
            return UFCRankRow(rank: current, trend: rank.trend, name: name)
        }.sorted { $0.rank < $1.rank }
        RankingsCache.shared.put(slug, rows)
        return rows
    }

    private static func athleteName(ref: String?) async -> String? {
        guard let ref, let url = URL(string: ref),
              let fetched = await SportsDiskCache.espnData(url: url, cacheKey: "ufc-athlete|\(ref)"),
              let wire = try? JSONDecoder().decode(AthleteWire.self, from: fetched.data)
        else { return nil }
        return wire.displayName ?? wire.fullName ?? wire.shortName
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
              let (data, _) = try? await URLSession.shared.data(from: url),
              let wire = try? JSONDecoder().decode(ScoreWire.self, from: data)
        else { return nil }
        if let display = wire.displayValue, !display.isEmpty { return display }
        guard let value = wire.value else { return nil }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }
}
