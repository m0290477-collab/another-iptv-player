import Foundation

// MARK: - Today's Matches data (build 61, B12 / M2)
//
// Data source: ESPN's public scoreboard JSON (no API key, HTTPS only).
// Endpoints (coordinator-verified reachable 2026-11-18):
//   soccer: https://site.api.espn.com/apis/site/v2/sports/soccer/{eng.1,esp.1,ita.1,ger.1,fra.1,uefa.champions}/scoreboard
//   NFL:    https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard
//   NBA:    https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard
// Each call passes today's date (user's timezone, yyyyMMdd) via `dates`.
//
// Observed payload shape (live samples fetched 2026-11-18):
//   { "leagues": [ { "name": "English Premier League", ... } ],
//     "events": [ { "id": "401879233",
//                   "date": "2026-11-21T12:30Z",
//                   "status": { "displayClock": "0'", "period": 0,
//                               "type": { "state": "pre", "completed": false,
//                                         "shortDetail": "Scheduled" } },
//                   "competitions": [ { "competitors": [
//                       { "homeAway": "home", "score": "0",
//                         "team": { "displayName": "Manchester City",
//                                   "logo": "https://a.espncdn.com/i/teamlogos/soccer/500/382.png" } },
//                       { "homeAway": "away", ... } ] } ] } ] }
// `status.type.state` is "pre" (scheduled) / "in" (live) / "post" (done).
// `score` arrives as a STRING and is "0" for scheduled events — the UI
// therefore never renders a score for upcoming matches. EVERY field is
// decoded as optional: a missing logo/score/state must neither crash
// nor be replaced with invented data.

// MARK: Sport tabs

enum MatchSport: String, CaseIterable, Identifiable {
    case soccer
    case nfl
    case nba

    var id: String { rawValue }

    /// Scoreboard URL paths, one per league shown under the tab.
    /// Soccer is grouped by league (one call per league); NFL/NBA are
    /// single-league tabs.
    var leaguePaths: [String] {
        switch self {
        case .soccer:
            return [
                "soccer/eng.1",
                "soccer/esp.1",
                "soccer/ita.1",
                "soccer/ger.1",
                "soccer/fra.1",
                "soccer/uefa.champions"
            ]
        case .nfl:
            return ["football/nfl"]
        case .nba:
            return ["basketball/nba"]
        }
    }

    var titleKey: String {
        switch self {
        case .soccer: return "matches.tab.soccer"
        case .nfl: return "matches.tab.nfl"
        case .nba: return "matches.tab.nba"
        }
    }
}

// MARK: Domain models (already sanitized for the UI)

enum MatchState: Equatable {
    case upcoming
    case live
    case finished
}

struct MatchTeamSide {
    /// ESPN team id (stable identity for item 9 team following).
    let teamId: String?
    /// Team name EXACTLY as the payload provides it (never localized).
    let name: String?
    let logoURL: URL?
    /// Raw score string from the payload; only meaningful for
    /// live/finished matches (scheduled events report "0").
    let score: String?
}

struct MatchEvent: Identifiable {
    let id: String
    let startDate: Date?
    let state: MatchState
    /// Live clock text from the payload (e.g. soccer "67'", NBA "2:14").
    let displayClock: String?
    /// Live period from the payload (NBA/NFL quarter etc.); nil for soccer.
    let period: Int?
    let home: MatchTeamSide
    let away: MatchTeamSide
}

struct MatchLeagueResult {
    /// League name EXACTLY as the payload provides it (never localized).
    let leagueName: String?
    let matches: [MatchEvent]
}

/// Per-league outcome of one load pass. Empty (a successful response
/// with zero events) is DISTINCT from failure (M5).
enum MatchLeagueOutcome {
    case loaded(MatchLeagueResult)
    case failed
}

// MARK: Wire models (all fields optional — decode defensively)

private struct ESPNScoreboard: Decodable {
    let leagues: [ESPNLeague]?
    let events: [ESPNEvent]?
}

private struct ESPNLeague: Decodable {
    let name: String?
}

private struct ESPNEvent: Decodable {
    let id: String?
    let date: String?
    let status: ESPNStatus?
    let competitions: [ESPNCompetition]?
}

private struct ESPNStatus: Decodable {
    let displayClock: String?
    let period: Int?
    let type: ESPNStatusType?
}

private struct ESPNStatusType: Decodable {
    let state: String?
    let completed: Bool?
}

private struct ESPNCompetition: Decodable {
    let competitors: [ESPNCompetitor]?
}

private struct ESPNCompetitor: Decodable {
    let homeAway: String?
    let score: String?
    let team: ESPNTeam?
}

private struct ESPNTeam: Decodable {
    let id: String?
    let displayName: String?
    let logo: String?
}

// MARK: Service

enum MatchesService {
    private static let baseURL = "https://site.api.espn.com/apis/site/v2/sports"

    /// Today's date in the USER's timezone, formatted yyyyMMdd for the
    /// ESPN `dates` parameter.
    static func todayParameter(now: Date = Date()) -> String {
        dayParameter(for: now)
    }

    private static func dayParameter(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    /// Build 63 (owner: every sport screen was empty; then, item
    /// 8d: "not just today — today, tomorrow, the day after, a week
    /// ahead"): the schedule window one load pass covers — three
    /// recent past days (final results), today (fixtures + live,
    /// first-class), and seven days ahead. The scoreboard endpoint
    /// takes a SINGLE day per call — a `dates=yyyyMMdd-yyyyMMdd`
    /// range is rejected with HTTP 400 (verified live 2026-11-18)
    /// — and a today-only call returns zero events on any day with
    /// no fixtures (e.g. soccer during the international break,
    /// NFL midweek), which is exactly why build 62's screens were
    /// all empty. Days are therefore fanned out per day, cached
    /// per day (see `DayCache`), and merged.
    static func windowDays(now: Date = Date()) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (-3...7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today)
        }
    }

    static func dayParameters(now: Date = Date()) -> [String] {
        windowDays(now: now).map(dayParameter(for:))
    }

    /// Build 63 (item 8d): per-day response cache. Past days are
    /// final — cached for the session. Today is the live day —
    /// 45 s TTL so the screen's 60 s auto-refresh actually picks
    /// up new scores without re-fetching the whole window. Future
    /// days change rarely — 10 min TTL.
    private final class DayCache: @unchecked Sendable {
        static let shared = DayCache()
        private let lock = NSLock()
        private var entries: [String: (result: MatchLeagueResult, fetchedAt: Date)] = [:]

        func get(_ key: String, ttl: TimeInterval) -> MatchLeagueResult? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[key],
                  Date().timeIntervalSince(entry.fetchedAt) < ttl else { return nil }
            return entry.result
        }

        func put(_ key: String, _ result: MatchLeagueResult) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = (result, Date())
        }
    }

    private static func cacheTTL(forDayParameter day: String) -> TimeInterval {
        let today = todayParameter()
        if day < today { return .infinity }
        if day == today { return 45 }
        return 600
    }

    /// Fetch + decode one league's scoreboard. Runs off the main
    /// thread (async URLSession + JSONDecoder in this context).
    /// Throws on transport/HTTP/decode failure; a successful response
    /// with no events returns an empty matches array (NOT an error).
    static func fetchLeague(path: String, dateParameter: String) async throws -> MatchLeagueResult {
        let cacheKey = "\(path)|\(dateParameter)"
        if let cached = DayCache.shared.get(cacheKey, ttl: cacheTTL(forDayParameter: dateParameter)) {
            return cached
        }
        let result = try await fetchLeagueUncached(path: path, dateParameter: dateParameter)
        DayCache.shared.put(cacheKey, result)
        return result
    }

    private static func fetchLeagueUncached(path: String, dateParameter: String) async throws -> MatchLeagueResult {
        var components = URLComponents(string: "\(baseURL)/\(path)/scoreboard")
        components?.queryItems = [URLQueryItem(name: "dates", value: dateParameter)]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(ESPNScoreboard.self, from: data)
        let leagueName = decoded.leagues?.first?.name
        let matches = (decoded.events ?? []).compactMap(mapEvent)
        return MatchLeagueResult(leagueName: leagueName, matches: matches)
    }

    /// Fetch every league of a sport tab. Leagues load concurrently;
    /// each league's outcome is independent so one failing league
    /// never blanks the whole tab (M5 per-league states).
    /// Build 63: `dateParameter` is kept for call-site compatibility
    /// but the load now fans out over `dayParameters()` (yesterday
    /// → +5 days) and merges — see the note there.
    static func fetchSport(_ sport: MatchSport, dateParameter: String) async -> [MatchLeagueOutcome] {
        let days = dayParameters()
        return await withTaskGroup(of: (Int, MatchLeagueOutcome).self) { group in
            for (index, path) in sport.leaguePaths.enumerated() {
                group.addTask {
                    (index, await fetchLeagueAcrossDays(path: path, dayParameters: days))
                }
            }
            var outcomes: [(Int, MatchLeagueOutcome)] = []
            for await item in group {
                outcomes.append(item)
            }
            return outcomes.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    /// One league across the whole day window: days load
    /// concurrently; events merge de-duplicated by id and sort by
    /// kickoff (today's live/finished first by time, then upcoming
    /// days in order). The league is `.failed` ONLY when every day
    /// failed — a day with no fixtures is a successful empty day,
    /// not an error (M5).
    private static func fetchLeagueAcrossDays(path: String, dayParameters: [String]) async -> MatchLeagueOutcome {
        let perDay = await withTaskGroup(of: (String, MatchLeagueResult?).self) { group in
            for day in dayParameters {
                group.addTask {
                    (day, try? await fetchLeague(path: path, dateParameter: day))
                }
            }
            var results: [(String, MatchLeagueResult)] = []
            for await item in group {
                if let result = item.1 { results.append((item.0, result)) }
            }
            return results.map { $0.1 }
        }
        guard !perDay.isEmpty else { return .failed }
        var seen = Set<String>()
        var merged: [MatchEvent] = []
        for result in perDay {
            for match in result.matches where seen.insert(match.id).inserted {
                merged.append(match)
            }
        }
        merged.sort { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
        return .loaded(MatchLeagueResult(leagueName: perDay.first?.leagueName, matches: merged))
    }

    /// One league, one day (items 10d/12d): the My Teams strip
    /// and the in-app goal poller read through the same per-day
    /// cache as the sport screens.
    static func matches(sport: MatchSport, leaguePath: String, day: Date) async -> [MatchEvent] {
        (try? await fetchLeague(sport: sport, leaguePath: leaguePath, day: day)) ?? []
    }

    /// Today only, for the goal poller.
    static func todaysMatches(sport: MatchSport, leaguePath: String) async -> [MatchEvent] {
        await matches(sport: sport, leaguePath: leaguePath, day: Date())
    }

    // MARK: Mapping

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    /// ESPN also emits timestamps WITHOUT seconds ("2026-11-21T18:00Z"),
    /// which ISO8601DateFormatter rejects — in build 62 every such
    /// event parsed with a nil start date, so upcoming rows had no
    /// kickoff time to show. This format covers that shape.
    private static let iso8601NoSecondsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return formatter
    }()

    static func parseEventDate(_ raw: String) -> Date? {
        if let date = iso8601Formatter.date(from: raw) { return date }
        if let date = iso8601FractionalFormatter.date(from: raw) { return date }
        return iso8601NoSecondsFormatter.date(from: raw)
    }

    static func mapEvent(_ event: ESPNEvent) -> MatchEvent? {
        guard let id = event.id, !id.isEmpty else { return nil }
        let competitors = event.competitions?.first?.competitors ?? []
        // Payload order is not guaranteed; homeAway decides the sides.
        // Without at least the two competitor entries there is no
        // honest row to render.
        guard let homeRaw = competitors.first(where: { $0.homeAway == "home" }) ?? competitors.first,
              let awayRaw = competitors.first(where: { $0.homeAway == "away" }) ?? competitors.dropFirst().first
        else { return nil }

        let state: MatchState
        switch event.status?.type?.state {
        case "in":
            state = .live
        case "post":
            state = .finished
        default:
            // "pre" and anything unrecognized that is not explicitly
            // completed renders as upcoming — never as live.
            state = (event.status?.type?.completed == true) ? .finished : .upcoming
        }

        return MatchEvent(
            id: id,
            startDate: event.date.flatMap { parseEventDate($0) },
            state: state,
            displayClock: event.status?.displayClock,
            period: event.status?.period,
            home: mapSide(homeRaw),
            away: mapSide(awayRaw)
        )
    }

    private static func mapSide(_ competitor: ESPNCompetitor) -> MatchTeamSide {
        MatchTeamSide(
            teamId: competitor.team?.id,
            name: competitor.team?.displayName,
            logoURL: competitor.team?.logo.flatMap { URL(string: $0) },
            score: competitor.score
        )
    }
}

// MARK: - Match detail (build 63, items 8b/8c)
//
// Data source: the SAME free ESPN public data — the per-event
// summary endpoint:
//   https://site.api.espn.com/apis/site/v2/sports/{sport}/{league}/summary?event={id}
// Verified live 2026-11-18 (EPL / NBA / NFL samples): header
// competition `details` carry scoring plays + cards with clock
// minutes and participants; US sports carry top-level
// `scoringPlays` (NFL) or a full `plays` list (NBA); `boxscore`
// carries per-team statistics; `leaders` carries per-team
// top-performer categories. Field population varies by league —
// EVERY field decodes as optional, sections the feed omits are
// simply absent from the result, and nothing is ever invented.

struct MatchTimelineEvent: Identifiable {
    enum Kind: Equatable {
        case goal, yellowCard, redCard, scoring, other
    }
    let id: String
    /// Clock/period text exactly as the payload formats it
    /// (soccer "67'", NFL "Q1 9:12").
    let minuteText: String?
    let title: String
    let detail: String?
    let playerName: String?
    let headshotURL: URL?
    let teamName: String?
    let kind: Kind
}

struct MatchTeamStatLine: Identifiable {
    var id: String { label }
    let label: String
    let homeValue: String?
    let awayValue: String?
}

struct MatchLeaderEntry: Identifiable {
    let id: String
    /// Category label exactly as the payload provides it.
    let category: String
    let athleteName: String
    let headshotURL: URL?
    let valueText: String?
    let teamName: String?
}

/// The detail screen's header, derived from the summary payload
/// itself (used when the screen is opened from a push deep link,
/// where no scoreboard row exists).
struct MatchDetailHeader {
    let home: MatchTeamSide
    let away: MatchTeamSide
    let state: MatchState
    let displayClock: String?
    let period: Int?
}

struct MatchDetail {
    let header: MatchDetailHeader?
    let timeline: [MatchTimelineEvent]
    let stats: [MatchTeamStatLine]
    let leaders: [MatchLeaderEntry]
    /// Item 10f: lineups (rosters + formation) when the summary
    /// carries them; empty → no Lineups entry is shown.
    let lineups: [MatchLineupSide]

    var isEmpty: Bool { timeline.isEmpty && stats.isEmpty && leaders.isEmpty }
}

/// Item 10f: one player in a lineup.
struct MatchLineupPlayer: Identifiable, Equatable {
    let id: String
    let name: String
    let positionAbbreviation: String?
    let positionName: String?
    let isStarter: Bool
    let headshotURL: URL?
}

/// Item 10f: one team's lineup from the summary rosters.
struct MatchLineupSide: Identifiable {
    var id: String { teamId ?? teamName ?? "side" }
    let teamId: String?
    let teamName: String?
    let logoURL: URL?
    let formation: String?
    let players: [MatchLineupPlayer]
    var starters: [MatchLineupPlayer] { players.filter { $0.isStarter } }
    var bench: [MatchLineupPlayer] { players.filter { !$0.isStarter } }
}

// MARK: Summary wire models (all optional — decode defensively)

private struct ESPNSummary: Decodable {
    let header: ESPNHeader?
    let boxscore: ESPNBoxscore?
    let leaders: [ESPNLeaderTeamGroup]?
    let scoringPlays: [ESPNPlay]?
    let plays: [ESPNPlay]?
    let rosters: [ESPNRosterSide]?
}

struct ESPNRosterSide: Decodable {
    let team: ESPNTeam?
    let formation: String?
    let roster: [ESPNRosterEntry]?
}

struct ESPNRosterEntry: Decodable {
    let athlete: ESPNAthlete?
    let starter: Bool?
    let position: ESPNPosition?
}

struct ESPNPosition: Decodable {
    let abbreviation: String?
    let name: String?
    let displayName: String?
}

private struct ESPNHeader: Decodable {
    let competitions: [ESPNHeaderCompetition]?
}

private struct ESPNHeaderCompetition: Decodable {
    let competitors: [ESPNCompetitor]?
    let details: [ESPNDetail]?
    let status: ESPNStatus?
}

private struct ESPNDetail: Decodable {
    let clock: ESPNClock?
    let type: ESPNPlayType?
    let text: String?
    let scoringPlay: Bool?
    let yellowCard: Bool?
    let redCard: Bool?
    let penaltyKick: Bool?
    let ownGoal: Bool?
    let team: ESPNTeam?
    let participants: [ESPNParticipant]?
    let athletesInvolved: [ESPNParticipant]?
}

private struct ESPNPlay: Decodable {
    let id: String?
    let clock: ESPNClock?
    let period: ESPNPeriod?
    let type: ESPNPlayType?
    let text: String?
    let scoringPlay: Bool?
    let homeScore: Int?
    let awayScore: Int?
    let team: ESPNTeam?
    let participants: [ESPNParticipant]?
    let athletesInvolved: [ESPNParticipant]?
}

private struct ESPNClock: Decodable {
    let displayValue: String?
}

private struct ESPNPeriod: Decodable {
    let number: Int?
    let displayValue: String?
}

private struct ESPNPlayType: Decodable {
    let text: String?
}

private struct ESPNParticipant: Decodable {
    let athlete: ESPNAthlete?
}

private struct ESPNAthlete: Decodable {
    let id: String?
    let displayName: String?
    let shortName: String?
    let headshot: ESPNHeadshot?
}

private struct ESPNHeadshot: Decodable {
    let href: String?
}

private struct ESPNBoxscore: Decodable {
    let teams: [ESPNBoxscoreTeam]?
}

private struct ESPNBoxscoreTeam: Decodable {
    let team: ESPNTeam?
    let homeAway: String?
    let statistics: [ESPNStatistic]?
}

private struct ESPNStatistic: Decodable {
    let name: String?
    let label: String?
    let displayValue: String?
}

private struct ESPNLeaderTeamGroup: Decodable {
    let team: ESPNTeam?
    let leaders: [ESPNLeaderCategory]?
}

private struct ESPNLeaderCategory: Decodable {
    let name: String?
    let displayName: String?
    let leaders: [ESPNLeaderEntry]?
}

private struct ESPNLeaderEntry: Decodable {
    let athlete: ESPNAthlete?
    let displayValue: String?
}

// MARK: Summary fetch + mapping

extension MatchesService {

    /// ESPN's per-athlete headshot CDN pattern, used ONLY when the
    /// payload carries an athlete id but no headshot URL of its own
    /// (soccer summaries omit the URL; the id → CDN pattern was
    /// verified live). A wrong/absent image degrades to the
    /// initials disc in the UI — never a broken-image box.
    static func headshotURL(sport: MatchSport, athlete: ESPNAthlete?) -> URL? {
        if let href = athlete?.headshot?.href, let url = URL(string: href) {
            return url
        }
        guard let id = athlete?.id, !id.isEmpty else { return nil }
        let segment: String
        switch sport {
        case .soccer: segment = "soccer"
        case .nba: segment = "nba"
        case .nfl: segment = "nfl"
        }
        return URL(string: "https://a.espncdn.com/i/headshots/\(segment)/players/full/\(id).png")
    }

    static func fetchDetail(sport: MatchSport, leaguePath: String, eventId: String) async throws -> MatchDetail {
        var components = URLComponents(string: "\(baseURL)/\(leaguePath)/summary")
        components?.queryItems = [URLQueryItem(name: "event", value: eventId)]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(ESPNSummary.self, from: data)
        return mapDetail(decoded, sport: sport)
    }

    private static func mapDetail(_ summary: ESPNSummary, sport: MatchSport) -> MatchDetail {
        let competition = summary.header?.competitions?.first
        let header = mapHeader(competition)
        return MatchDetail(
            header: header,
            timeline: mapTimeline(summary, competition: competition, sport: sport),
            stats: mapStats(summary, competition: competition),
            leaders: mapLeaders(summary, sport: sport),
            lineups: mapLineups(summary, sport: sport)
        )
    }

    /// Item 10f: rosters → lineups. Formation and positions are
    /// carried through verbatim; nothing is inferred here — the
    /// VIEW decides whether the formation can be laid out on a
    /// pitch or must fall back to the grouped list.
    private static func mapLineups(_ summary: ESPNSummary, sport: MatchSport) -> [MatchLineupSide] {
        (summary.rosters ?? []).compactMap { side in
            let players = (side.roster ?? []).compactMap { entry -> MatchLineupPlayer? in
                guard let athlete = entry.athlete,
                      let name = athlete.displayName ?? athlete.shortName,
                      !name.isEmpty else { return nil }
                return MatchLineupPlayer(
                    id: athlete.id ?? name,
                    name: name,
                    positionAbbreviation: entry.position?.abbreviation,
                    positionName: entry.position?.name ?? entry.position?.displayName,
                    isStarter: entry.starter ?? false,
                    headshotURL: headshotURL(sport: sport, athlete: athlete)
                )
            }
            guard !players.isEmpty else { return nil }
            return MatchLineupSide(
                teamId: side.team?.id,
                teamName: side.team?.displayName ?? side.team?.name,
                logoURL: logoURL(side.team),
                formation: side.formation,
                players: players
            )
        }
    }

    private static func mapHeader(_ competition: ESPNHeaderCompetition?) -> MatchDetailHeader? {
        guard let competitors = competition?.competitors,
              let homeRaw = competitors.first(where: { $0.homeAway == "home" }) ?? competitors.first,
              let awayRaw = competitors.first(where: { $0.homeAway == "away" }) ?? competitors.dropFirst().first
        else { return nil }
        let state: MatchState
        switch competition?.status?.type?.state {
        case "in": state = .live
        case "post": state = .finished
        default: state = (competition?.status?.type?.completed == true) ? .finished : .upcoming
        }
        return MatchDetailHeader(
            home: mapSide(homeRaw),
            away: mapSide(awayRaw),
            state: state,
            displayClock: competition?.status?.displayClock,
            period: competition?.status?.period
        )
    }

    private static func mapTimeline(
        _ summary: ESPNSummary,
        competition: ESPNHeaderCompetition?,
        sport: MatchSport
    ) -> [MatchTimelineEvent] {
        // 1) Header details — soccer-style scoring plays + cards.
        if let details = competition?.details, !details.isEmpty {
            return details.enumerated().map { index, detail in
                let participants = detail.participants ?? detail.athletesInvolved ?? []
                let scorer = participants.first?.athlete
                let kind: MatchTimelineEvent.Kind
                if detail.redCard == true { kind = .redCard }
                else if detail.yellowCard == true { kind = .yellowCard }
                else if detail.scoringPlay == true { kind = .goal }
                else { kind = .other }
                var title = detail.type?.text ?? detail.text ?? scorer?.displayName ?? ""
                if title.isEmpty, kind == .goal { title = scorer?.displayName ?? "" }
                var detailText = detail.team?.displayName
                if participants.count > 1, let assist = participants[1].athlete?.displayName {
                    detailText = assist
                }
                return MatchTimelineEvent(
                    id: "detail-\(index)",
                    minuteText: detail.clock?.displayValue,
                    title: title,
                    detail: detailText,
                    playerName: scorer?.displayName,
                    headshotURL: headshotURL(sport: sport, athlete: scorer),
                    teamName: detail.team?.displayName,
                    kind: kind
                )
            }
        }
        // 2) Top-level scoring plays — NFL-style.
        if let plays = summary.scoringPlays, !plays.isEmpty {
            return plays.enumerated().map { index, play in
                mapPlay(play, index: index, sport: sport)
            }
        }
        // 3) Full play list filtered to scoring plays — NBA-style
        // (every basket; capped so the list stays sane).
        if let plays = summary.plays {
            let scoring = plays.filter { $0.scoringPlay == true }
            return scoring.prefix(100).enumerated().map { index, play in
                mapPlay(play, index: index, sport: sport)
            }
        }
        return []
    }

    private static func mapPlay(_ play: ESPNPlay, index: Int, sport: MatchSport) -> MatchTimelineEvent {
        let participants = play.participants ?? play.athletesInvolved ?? []
        let athlete = participants.first?.athlete
        var minute = play.clock?.displayValue
        if let period = play.period?.number, sport != .soccer {
            let label = period <= 4 ? "Q\(period)" : "OT"
            minute = [label, minute].compactMap { $0 }.joined(separator: " ")
        }
        var detail = play.team?.displayName
        if let home = play.homeScore, let away = play.awayScore {
            detail = [detail, "\(home)–\(away)"].compactMap { $0 }.joined(separator: " · ")
        }
        return MatchTimelineEvent(
            id: play.id ?? "play-\(index)",
            minuteText: minute,
            title: play.text ?? play.type?.text ?? athlete?.displayName ?? "",
            detail: detail,
            playerName: athlete?.displayName,
            headshotURL: headshotURL(sport: sport, athlete: athlete),
            teamName: play.team?.displayName,
            kind: .scoring
        )
    }

    private static func mapStats(
        _ summary: ESPNSummary,
        competition: ESPNHeaderCompetition?
    ) -> [MatchTeamStatLine] {
        guard let teams = summary.boxscore?.teams, teams.count >= 2 else { return [] }
        // Pair the two boxscore teams to home/away via the header
        // competitors' team ids; fall back to an explicit homeAway
        // field, then to payload order (home first in samples).
        let competitors = competition?.competitors ?? []
        let homeId = competitors.first(where: { $0.homeAway == "home" })?.team?.id
        let awayId = competitors.first(where: { $0.homeAway == "away" })?.team?.id
        let home = teams.first(where: { $0.team?.id != nil && $0.team?.id == homeId })
            ?? teams.first(where: { $0.homeAway == "home" })
            ?? teams[0]
        let away = teams.first(where: { $0.team?.id != nil && $0.team?.id == awayId })
            ?? teams.first(where: { $0.homeAway == "away" })
            ?? teams[1]
        guard home.team?.id != away.team?.id || homeId != nil else {
            // Same team twice means the pairing failed — show no
            // stats rather than a wrong pairing.
            if teams.count != 2 { return [] }
            return pairStats(home: teams[0], away: teams[1])
        }
        return pairStats(home: home, away: away)
    }

    private static func pairStats(home: ESPNBoxscoreTeam, away: ESPNBoxscoreTeam) -> [MatchTeamStatLine] {
        var awayByName: [String: String] = [:]
        for stat in away.statistics ?? [] {
            if let name = stat.name, let value = stat.displayValue, awayByName[name] == nil {
                awayByName[name] = value
            }
        }
        let lines = (home.statistics ?? []).compactMap { stat -> (name: String?, line: MatchTeamStatLine)? in
            guard let label = stat.label ?? stat.name else { return nil }
            return (stat.name, MatchTeamStatLine(
                label: label,
                homeValue: stat.displayValue,
                awayValue: stat.name.flatMap { awayByName[$0] }
            ))
        }
        // Item 12b: the headline stats the owner named lead the
        // block (possession, shots, on target, corners, fouls,
        // offsides for soccer; each sport's own equivalents rank
        // by the same preference list) — everything else follows
        // in feed order. Only stats the feed returned appear.
        let preference = [
            "possessionPct", "totalShots", "shotsOnTarget", "wonCorners",
            "foulsCommitted", "offsides", "yellowCards", "redCards", "saves",
            "fieldGoalPct", "threePointPct", "freeThrowPct", "totalRebounds",
            "assists", "turnovers", "totalYards", "passingYards", "rushingYards"
        ]
        let rank = Dictionary(uniqueKeysWithValues: preference.enumerated().map { ($0.element, $0.offset) })
        return lines
            .enumerated()
            .sorted { a, b in
                let ra = a.element.name.flatMap { rank[$0] } ?? Int.max
                let rb = b.element.name.flatMap { rank[$0] } ?? Int.max
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map { $0.element.line }
    }

    private static func mapLeaders(_ summary: ESPNSummary, sport: MatchSport) -> [MatchLeaderEntry] {
        var entries: [MatchLeaderEntry] = []
        for group in summary.leaders ?? [] {
            for category in group.leaders ?? [] {
                let categoryName = category.displayName ?? category.name ?? ""
                for (index, entry) in (category.leaders ?? []).prefix(3).enumerated() {
                    guard let name = entry.athlete?.displayName, !name.isEmpty else { continue }
                    entries.append(MatchLeaderEntry(
                        id: "leader-\(entries.count)-\(index)",
                        category: categoryName,
                        athleteName: name,
                        headshotURL: headshotURL(sport: sport, athlete: entry.athlete),
                        valueText: entry.displayValue,
                        teamName: group.team?.displayName
                    ))
                    if entries.count >= 12 { return entries }
                }
            }
        }
        return entries
    }
}
