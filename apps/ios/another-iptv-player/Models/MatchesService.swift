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
    let displayName: String?
    let logo: String?
}

// MARK: Service

enum MatchesService {
    private static let baseURL = "https://site.api.espn.com/apis/site/v2/sports"

    /// Today's date in the USER's timezone, formatted yyyyMMdd for the
    /// ESPN `dates` parameter.
    static func todayParameter(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: now)
    }

    /// Fetch + decode one league's scoreboard. Runs off the main
    /// thread (async URLSession + JSONDecoder in this context).
    /// Throws on transport/HTTP/decode failure; a successful response
    /// with no events returns an empty matches array (NOT an error).
    static func fetchLeague(path: String, dateParameter: String) async throws -> MatchLeagueResult {
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
    static func fetchSport(_ sport: MatchSport, dateParameter: String) async -> [MatchLeagueOutcome] {
        await withTaskGroup(of: (Int, MatchLeagueOutcome).self) { group in
            for (index, path) in sport.leaguePaths.enumerated() {
                group.addTask {
                    do {
                        let result = try await fetchLeague(path: path, dateParameter: dateParameter)
                        return (index, .loaded(result))
                    } catch {
                        return (index, .failed)
                    }
                }
            }
            var outcomes: [(Int, MatchLeagueOutcome)] = []
            for await item in group {
                outcomes.append(item)
            }
            return outcomes.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    // MARK: Mapping

    private static let iso8601Formatter = ISO8601DateFormatter()

    private static func mapEvent(_ event: ESPNEvent) -> MatchEvent? {
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
            startDate: event.date.flatMap { iso8601Formatter.date(from: $0) },
            state: state,
            displayClock: event.status?.displayClock,
            period: event.status?.period,
            home: mapSide(homeRaw),
            away: mapSide(awayRaw)
        )
    }

    private static func mapSide(_ competitor: ESPNCompetitor) -> MatchTeamSide {
        MatchTeamSide(
            name: competitor.team?.displayName,
            logoURL: competitor.team?.logo.flatMap { URL(string: $0) },
            score: competitor.score
        )
    }
}
