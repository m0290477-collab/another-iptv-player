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
    /// Build 85: Major League Baseball — a full fourth sport on
    /// the same free ESPN public data (site/v2 path
    /// baseball/mlb), verified live 2026-11-21 (scoreboard,
    /// standings, teams/roster/schedule, news, core leaders +
    /// athletes — see the build-85 report).
    case mlb
    /// Build 87 (item 1): NHL hockey — a full fifth sport, but
    /// NOT from ESPN: the NHL's own official free API
    /// (api-web.nhle.com, keyless, verified live 2026-11-21 —
    /// schedule / standings / roster / leaders / player landing
    /// / gamecenter). The sentinel league path "nhl" routes
    /// `fetchLeague` to `NHLService`, which maps the NHL
    /// payloads into the SAME domain models, so every shared
    /// surface (tabs, Live Now, calendar, Watch, bell, follows)
    /// consumes hockey unchanged. ESPN-shaped services
    /// (standings / leaders / team / player) branch on this
    /// sport to their NHL counterparts — see Matches87.swift.
    case nhl

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
        case .mlb:
            return ["baseball/mlb"]
        case .nhl:
            return ["nhl"]
        }
    }

    var titleKey: String {
        switch self {
        case .soccer: return "matches.tab.soccer"
        case .nfl: return "matches.tab.nfl"
        case .nba: return "matches.tab.nba"
        case .mlb: return "matches.tab.mlb"
        case .nhl: return "matches.tab.nhl"
        }
    }
}

// MARK: - Soccer league catalog (build 83, item 3)

/// One soccer league/competition in the league browser.
/// `name` and `logoURL` are EXACTLY what ESPN's scoreboard
/// payload returned for the league when the catalog was
/// verified live (2026-11-20) — never invented, never
/// localized (the same rule the Matches screens already apply
/// to payload league names). A league is in this catalog ONLY
/// because its standings AND scoreboard endpoints verified
/// live with real data on that date; the build-83 report
/// carries the per-league evidence and the excluded
/// candidates (sau.1 — the standings endpoint answers
/// HTTP 400; fifa.world / uefa.euro / conmebol.america /
/// caf.nations — completed tournaments whose endpoints return
/// only final historical tables and no fixtures;
/// afc.asian.cup — a pre-tournament shell with no played
/// matches). `leaguePaths` above stays the FEATURED subset
/// the Matches home loads — the home's behaviour is unchanged;
/// the browser fetches a league's data only when its page
/// opens, so opening the browser fires no network calls.
struct SoccerLeague: Identifiable, Hashable {
    /// ESPN league slug ("eng.1").
    let slug: String
    /// Payload league name, verbatim ("English Premier League").
    let name: String
    /// Payload league logo (the scoreboard's `leagues[].logos`).
    let logoURL: URL?

    var id: String { slug }
    /// The full site/v2 path every Matches service takes
    /// ("soccer/eng.1").
    var leaguePath: String { "soccer/\(slug)" }
}

extension MatchSport {
    /// Build 83 (item 3): the league browser's catalog —
    /// FotMob-style order: the five big leagues, the UEFA
    /// cups, the rest of Europe, then the Americas. Every
    /// entry verified live on 2026-11-20 (standings entries,
    /// scoreboard events, top-scorers leaders, payload logo).
    static let soccerLeagueCatalog: [SoccerLeague] = [
        SoccerLeague(slug: "eng.1", name: "English Premier League", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/23.png")),
        SoccerLeague(slug: "esp.1", name: "Spanish LALIGA", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/15.png")),
        SoccerLeague(slug: "ita.1", name: "Italian Serie A", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/12.png")),
        SoccerLeague(slug: "ger.1", name: "German Bundesliga", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/10.png")),
        SoccerLeague(slug: "fra.1", name: "French Ligue 1", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/9.png")),
        SoccerLeague(slug: "uefa.champions", name: "UEFA Champions League", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/2.png")),
        SoccerLeague(slug: "uefa.europa", name: "UEFA Europa League", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/2310.png")),
        SoccerLeague(slug: "uefa.europa.conf", name: "UEFA Conference League", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/20296.png")),
        SoccerLeague(slug: "ned.1", name: "Dutch Eredivisie", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/11.png")),
        SoccerLeague(slug: "por.1", name: "Portuguese Primeira Liga", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/14.png")),
        SoccerLeague(slug: "tur.1", name: "Turkish Super Lig", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/18.png")),
        SoccerLeague(slug: "sco.1", name: "Scottish Premiership", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/45.png")),
        SoccerLeague(slug: "bel.1", name: "Belgian Pro League", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/6.png")),
        SoccerLeague(slug: "usa.1", name: "MLS", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/19.png")),
        SoccerLeague(slug: "mex.1", name: "Mexican Liga BBVA MX", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/22.png")),
        SoccerLeague(slug: "bra.1", name: "Brazilian Serie A", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/85.png")),
        SoccerLeague(slug: "arg.1", name: "Argentine Liga Profesional de Fútbol", logoURL: URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/1.png"))
    ]
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
    /// Build 85: the payload's own status text
    /// (`status.type.shortDetail`, e.g. baseball's "Top 5th" /
    /// "Final/11"). Baseball rows and the baseball detail
    /// header render THIS as their state label — the inning is
    /// not a quarter and "0:00" is not a clock.
    let statusDetail: String?
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

struct ESPNEvent: Decodable {
    let id: String?
    let date: String?
    let status: ESPNStatus?
    let competitions: [ESPNCompetition]?
}

struct ESPNStatus: Decodable {
    let displayClock: String?
    let period: Int?
    let type: ESPNStatusType?
}

struct ESPNStatusType: Decodable {
    let state: String?
    let completed: Bool?
    /// Build 85: the payload's own state text ("Final/11",
    /// "Top 5th", "Bot 7th" in baseball; short status strings
    /// in the other sports). Baseball's `displayClock` is a
    /// dummy "0:00" and its period is the inning, so the live
    /// label for a baseball game IS this text — rendered
    /// verbatim, never composed.
    let detail: String?
    let shortDetail: String?
}

struct ESPNCompetition: Decodable {
    let competitors: [ESPNCompetitor]?
}

struct ESPNCompetitor: Decodable {
    let homeAway: String?
    let score: String?
    let team: ESPNTeam?
    /// Build 84 (item 20): per-period linescores (NBA/NFL
    /// header competitors carry them; soccer's do not).
    let linescores: [ESPNLinescore]?
    /// Build 85: baseball's R/H/E companions — the summary
    /// header competitors carry total hits and errors next to
    /// the per-inning linescores (verified live in the 2025
    /// World Series Game 7 summary: hits 14 / errors 0).
    let hits: Int?
    let errors: Int?
}

struct ESPNLinescore: Decodable {
    let displayValue: String?
}

struct ESPNTeam: Decodable {
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
        // Build 87 (item 1): the NHL sentinel path routes to
        // the NHL's own official API service, which maps its
        // payloads into the same domain models (and keeps its
        // own week cache + disk fallback). Every other path is
        // an ESPN site/v2 path, unchanged.
        if path == MatchSport.nhl.leaguePaths[0] {
            return try await NHLService.scoreboard(dateParameter: dateParameter)
        }
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
        // Build 84 (item 23): every successful payload is saved
        // to the sports disk cache; when the network fails, the
        // last saved payload for this league+day is served
        // instead of an error, and the serve is recorded so the
        // UI can mark the data stale with its real timestamp.
        let diskKey = "sb|\(path)|\(dateParameter)"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(ESPNScoreboard.self, from: data)
            SportsDiskCache.save(key: diskKey, data: data)
            DiskServeLog.shared.clear(path: path, day: dateParameter)
            let leagueName = decoded.leagues?.first?.name
            let matches = (decoded.events ?? []).compactMap(mapEvent)
            return MatchLeagueResult(leagueName: leagueName, matches: matches)
        } catch {
            if let cached = SportsDiskCache.load(key: diskKey),
               let decoded = try? JSONDecoder().decode(ESPNScoreboard.self, from: cached.data) {
                DiskServeLog.shared.mark(path: path, day: dateParameter, at: cached.at)
                let leagueName = decoded.leagues?.first?.name
                let matches = (decoded.events ?? []).compactMap(mapEvent)
                return MatchLeagueResult(leagueName: leagueName, matches: matches)
            }
            throw error
        }
    }

    /// Build 84 (item 23): the newest disk-cache timestamp any
    /// of the sport's league+day scoreboards was served from
    /// during recent fetches — the Matches view model reads it
    /// after a refresh to mark on-screen data stale with its
    /// real "last updated" time. A network success for a
    /// league+day clears that day's record.
    static func diskServedStamp(for sport: MatchSport) -> Date? {
        var latest: Date?
        for path in sport.leaguePaths {
            for day in dayParameters() {
                if let stamp = DiskServeLog.shared.stamp(path: path, day: day) {
                    latest = max(latest ?? .distantPast, stamp)
                }
            }
        }
        return latest
    }

    private final class DiskServeLog: @unchecked Sendable {
        static let shared = DiskServeLog()
        private let lock = NSLock()
        private var stamps: [String: Date] = [:]

        func mark(path: String, day: String, at: Date) {
            lock.lock(); defer { lock.unlock() }
            stamps["\(path)|\(day)"] = at
        }

        func clear(path: String, day: String) {
            lock.lock(); defer { lock.unlock() }
            stamps["\(path)|\(day)"] = nil
        }

        func stamp(path: String, day: String) -> Date? {
            lock.lock(); defer { lock.unlock() }
            return stamps["\(path)|\(day)"]
        }
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

    /// Build 90 (SP6): ONE league's full-window outcome,
    /// public so the Matches tab's view model can publish
    /// each league as it lands instead of waiting for the
    /// whole sport pass to drain (fetchSport above keeps
    /// serving its existing callers unchanged).
    static func fetchLeagueWindow(path: String) async -> MatchLeagueOutcome {
        await fetchLeagueAcrossDays(path: path, dayParameters: dayParameters())
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
        (try? await fetchLeague(path: leaguePath, dateParameter: dayParameter(for: day)))?.matches ?? []
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
            statusDetail: event.status?.type?.shortDetail ?? event.status?.type?.detail,
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
    /// Build 84 (item 4): the payload athlete id behind
    /// `playerName`, so a timeline row can open the player page.
    let athleteId: String?
    let headshotURL: URL?
    let teamName: String?
    let kind: Kind
    /// Build 90 (SP1): the payload's raw key-event type id
    /// ("substitution", "goal---volley", "penalty---saved", …)
    /// when the row came from the summary's `keyEvents`; nil
    /// for rows built from header details or play lists. The
    /// view can label/icon substitution and penalty rows
    /// distinctly from this without widening the Kind enum
    /// (MatchDetailView's kind switch is exhaustive over the
    /// five shipped cases). Defaulted so every existing
    /// construction site keeps compiling unchanged.
    var keyEventTypeId: String? = nil
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
    /// Build 84 (item 4): payload athlete id — opens the
    /// player page.
    let athleteId: String?
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
    /// Build 85: the summary header's own status text
    /// (baseball's "Top 5th" / "Final/11") — the detail
    /// header's live/final pill renders it for baseball.
    let statusDetail: String?
    /// Build 65: real kickoff from the summary payload (nil when
    /// the payload carries none — the view then shows no date
    /// rather than an invented one).
    let startDate: Date?
}

struct MatchDetail {
    let header: MatchDetailHeader?
    let timeline: [MatchTimelineEvent]
    let stats: [MatchTeamStatLine]
    let leaders: [MatchLeaderEntry]
    /// Item 10f: lineups (rosters + formation) when the summary
    /// carries them; empty → no Lineups entry is shown.
    let lineups: [MatchLineupSide]
    /// Build 80 (items 15/16): FotMob-arrangement data, every
    /// field decoded from the SAME summary payload and rendered
    /// ONLY when present — nothing here is ever invented.
    let info: MatchInfo?
    let h2h: MatchH2H?
    let videos: [MatchVideo]
    let commentary: [MatchCommentaryEntry]
    /// Build 84 (item 11): per-player box score (NBA/NFL
    /// summaries carry `boxscore.players`; soccer summaries
    /// carry no player box score and this stays empty).
    let boxScore: [MatchBoxScoreTeam]
    /// Build 84 (item 19): the play-by-play feed (NBA `plays`;
    /// NFL `drives.previous[].plays`), newest first.
    let playsFeed: [MatchPlayEntry]
    /// Build 84 (item 18): the win-probability series — the
    /// payload's home-win percentages in play order (NBA/NFL
    /// only; soccer summaries publish none).
    let winProbability: [Double]
    /// Build 84 (item 20): per-period linescores from the
    /// header competitors (NBA/NFL quarters; empty when the
    /// payload carries none).
    let homeLinescores: [String]
    let awayLinescores: [String]
    /// Build 84 (item 3b): broadcaster names the summary itself
    /// lists for this match (US feeds; often empty) — extra
    /// Watch-matching needles on the detail screen.
    let broadcastNames: [String]
    /// Build 85: baseball's R/H/E totals from the summary
    /// header competitors (the runs themselves are the header
    /// scores) — the inning linescore grid's trailing columns.
    /// Nil for every other sport.
    let homeHits: String?
    let homeErrors: String?
    let awayHits: String?
    let awayErrors: String?
    /// Build 85 (sweep): the summary's own recap/preview
    /// article (`article` — headline + description + web link,
    /// verified live in MLB, NFL and NBA summaries). Rendered
    /// in Facts; tapping opens the publisher page. Nil when
    /// the payload carries none.
    let article: MatchArticle?
    /// Build 90 (SP3): both teams' last-five form from the
    /// summary's `lastFiveGames` — empty when the payload
    /// carries no form blocks (the Facts form section then
    /// simply doesn't render).
    let form: [MatchTeamForm]

    var isEmpty: Bool {
        timeline.isEmpty && stats.isEmpty && leaders.isEmpty && lineups.isEmpty
            && videos.isEmpty && commentary.isEmpty && h2h == nil
            && boxScore.isEmpty && playsFeed.isEmpty && article == nil
    }
}

/// Build 90 (SP3): one team's recent-form block from the
/// summary's `lastFiveGames`, mapped verbatim.
struct MatchTeamForm: Identifiable {
    let teamId: String?
    let teamName: String?
    let logoURL: URL?
    let results: [MatchFormResult]
    var id: String { teamId ?? teamName ?? "" }
}

/// Build 90 (SP3): one result inside a form block — the
/// opponent, the score as played, and the W/D/L outcome
/// from the form team's perspective, all payload-verbatim.
struct MatchFormResult: Identifiable {
    let id: String
    let date: Date?
    /// "W" / "D" / "L" from the form team's perspective.
    let result: String?
    /// The score as played ("2-1", home–away of that match).
    let scoreText: String?
    let opponentName: String?
    let opponentLogoURL: URL?
    /// "@" when the form team played away, "vs" at home.
    let atVs: String?
    let competitionName: String?
}

/// Build 85 (sweep): the summary payload's own article —
/// ESPN's recap (finished games) or preview (upcoming),
/// headline and description verbatim, with its web link.
struct MatchArticle {
    let headline: String
    let summary: String?
    let webURL: URL?
}

/// Build 84 (item 11): one player line of a box score — the
/// payload's own stat columns, in payload order.
struct MatchBoxScorePlayer: Identifiable {
    let athleteId: String?
    let name: String
    let headshotURL: URL?
    /// Stat values aligned with the group's `columns`.
    let values: [String]
    let didNotPlay: Bool
    let dnpReason: String?
    let isStarter: Bool
    var id: String { athleteId ?? name }
}

/// Build 84 (item 11): one stat group of a team's box score
/// (NBA: a single unnamed group; NFL: passing / rushing /
/// receiving / defensive / …, titled by the payload's `text`).
struct MatchBoxScoreGroup: Identifiable {
    let title: String?
    let columns: [String]
    let players: [MatchBoxScorePlayer]
    let totals: [String]
    var id: String { (title ?? "") + "|" + columns.joined(separator: ",") }
}

/// Build 84 (item 11): one team's box score.
struct MatchBoxScoreTeam: Identifiable {
    let teamName: String?
    let logoURL: URL?
    let homeAway: String?
    let groups: [MatchBoxScoreGroup]
    var id: String { (teamName ?? "") + "|" + (homeAway ?? "") }
}

/// Build 84 (item 19): one play of the play-by-play feed.
struct MatchPlayEntry: Identifiable {
    let id: String
    let periodLabel: String?
    let clockText: String?
    let text: String
    /// Score after the play, "home–away", when the payload
    /// carries both.
    let scoreText: String?
    let scoringPlay: Bool
}

/// Build 80 (item 16, Facts): match information the summary
/// payload itself carries — league name (header.league), venue
/// and attendance (gameInfo), referee (gameInfo.officials, when
/// the payload lists officials). Every field optional; the view
/// renders only the rows the payload actually provided.
struct MatchInfo {
    let leagueName: String?
    let venueText: String?
    let attendance: Int?
    let refereeText: String?
    /// Build 84 (item 16): ESPN's own pre-match predictor
    /// (`predictor.homeTeam.gameProjection` /
    /// `awayTeam.gameProjection`, percentage strings) — verified
    /// live 2026-11-21 in upcoming NBA/NFL summaries; soccer
    /// summaries publish no predictor, so these stay nil there.
    /// Rendered labelled as ESPN's prediction, never as fact.
    let predictorHome: String?
    let predictorAway: String?
}

/// Build 80 (item 15): head-to-head from the summary's
/// `seasonseries` — for soccer the series is literally typed
/// "head-to-head" ("Last 5 Matchups", real past meetings with
/// scores and dates); for the NBA it is the regular-season
/// series between the same two teams. Verified live against the
/// ESPN payloads (e.g. event 401879244, Brighton v Brentford).
struct MatchH2H {
    let title: String?
    let summary: String?
    let meetings: [MatchH2HMeeting]
}

struct MatchH2HMeeting: Identifiable {
    let id: String
    let date: Date?
    let homeName: String?
    let awayName: String?
    let homeScore: String?
    let awayScore: String?
}

/// Build 80 (item 15): an official ESPN video attached to the
/// match (summary `videos[]`). Build 81 (item 3): `url` is the
/// payload's DIRECT playable MP4 (`links.source.href`), played
/// in-app with AVPlayer — a video whose payload carries no
/// direct source never reaches this type (see mapVideos), so
/// nothing in the app links out to ESPN's website for video.
struct MatchVideo: Identifiable {
    let id: String
    let headline: String
    let url: URL
    let thumbnailURL: URL?
    let durationSeconds: Int?
}

/// Build 80 (item 16): one commentary entry from the summary's
/// `commentary[]` (soccer payloads carry it — 100+ entries for a
/// full match; NBA/NFL summaries do not, so those sports simply
/// get no Commentary tab).
struct MatchCommentaryEntry: Identifiable {
    let id: Int
    let minuteText: String?
    let text: String
}

/// Item 10f: one player in a lineup.
struct MatchLineupPlayer: Identifiable, Equatable {
    let id: String
    let name: String
    let positionAbbreviation: String?
    let positionName: String?
    let isStarter: Bool
    let headshotURL: URL?
    /// Build 84 (item 4): the payload athlete id (the same
    /// value `id` falls back from) — nil when the payload
    /// carried none, so a row never links with a fake id.
    let athleteId: String?
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
    /// Build 90 (SP1): the summary's full key-events feed
    /// (goals, cards, substitutions, penalties — see
    /// ESPNKeyEvent). Soccer summaries carry it; US-sport
    /// summaries do not, so it stays nil there and their
    /// timeline paths are untouched.
    let keyEvents: [ESPNKeyEvent]?
    let boxscore: ESPNBoxscore?
    let leaders: [ESPNLeaderTeamGroup]?
    let scoringPlays: [ESPNPlay]?
    let plays: [ESPNPlay]?
    let rosters: [ESPNRosterSide]?
    // Build 80 (items 15/16): the FotMob-arrangement payloads.
    let gameInfo: ESPNGameInfo?
    let seasonseries: [ESPNSeries]?
    let videos: [ESPNVideo]?
    let commentary: [ESPNCommentaryEntry]?
    // Build 84: box-score players, win probability, the
    // pre-match predictor, NFL drives (play-by-play), and the
    // match's own broadcaster list — all verified live
    // 2026-11-21 (see the build-84 report).
    let winprobability: [ESPNWinProbability]?
    let predictor: ESPNPredictor?
    let drives: ESPNDrives?
    let broadcasts: [ESPNBroadcast]?
    // Build 85 (sweep): the summary's recap/preview article.
    let article: ESPNArticle?
    // Build 90 (SP3): both teams' last-five results, carried
    // by the same summary payload (verified live 2026-11-21).
    let lastFiveGames: [ESPNLastFiveTeam]?
}

/// Build 90 (SP3): one team's `lastFiveGames` block — the
/// team plus its recent events (opponent, the score as
/// played, the W/D/L `gameResult` from THIS team's
/// perspective, the competition name; all verbatim).
private struct ESPNLastFiveTeam: Decodable {
    struct Team: Decodable {
        let id: String?
        let displayName: String?
        let logo: String?
    }
    struct Event: Decodable {
        let id: String?
        let gameDate: String?
        let gameResult: String?
        let score: String?
        let competitionName: String?
        let atVs: String?
        let opponent: Team?
        let opponentLogo: String?
    }
    let team: Team?
    let events: [Event]?
}

/// Build 90 (SP1): one entry of the summary's `keyEvents`
/// feed — verified live 2026-11-21 (eng.1 event 401879233:
/// 19 entries; esp.1 401882806: 31; usa.1: 18;
/// uefa.champions: 13). `type.type` is the machine id
/// ("goal---volley", "yellow-card", "substitution",
/// "penalty---saved", "own-goal", plus period markers);
/// `type.text` is its payload label ("Goal - Volley").
/// Participants: for a goal the scorer then the assist; for
/// a substitution the player coming ON then the player
/// going OFF ("Hugo Larsson replaces Josh King" — Larsson
/// is participants[0]); for a card the booked player.
private struct ESPNKeyEvent: Decodable {
    struct EventType: Decodable {
        let text: String?
        let type: String?
    }
    let id: String?
    let type: EventType?
    let text: String?
    let shortText: String?
    let clock: ESPNClock?
    let scoringPlay: Bool?
    let team: ESPNTeam?
    let participants: [ESPNParticipant]?
}

private struct ESPNArticle: Decodable {
    struct Links: Decodable {
        struct Web: Decodable { let href: String? }
        let web: Web?
    }
    let headline: String?
    let description: String?
    let links: Links?
}

private struct ESPNWinProbability: Decodable {
    let homeWinPercentage: Double?
    let playId: String?
}

private struct ESPNPredictor: Decodable {
    struct Team: Decodable { let gameProjection: String? }
    let homeTeam: Team?
    let awayTeam: Team?
}

private struct ESPNDrives: Decodable {
    let previous: [ESPNDrive]?
}

private struct ESPNDrive: Decodable {
    let plays: [ESPNPlay]?
}

private struct ESPNBroadcast: Decodable {
    struct Media: Decodable {
        let name: String?
        let shortName: String?
    }
    let media: Media?
    let station: String?
}

private struct ESPNGameInfo: Decodable {
    struct Venue: Decodable {
        struct Address: Decodable { let city: String? }
        let fullName: String?
        let shortName: String?
        let address: Address?
    }
    struct Official: Decodable { let displayName: String? }
    let venue: Venue?
    let attendance: Int?
    let officials: [Official]?
}

private struct ESPNSeries: Decodable {
    let type: String?
    let title: String?
    let summary: String?
    let events: [ESPNSeriesEvent]?
}

private struct ESPNSeriesEvent: Decodable {
    let id: String?
    let date: String?
    let competitors: [ESPNCompetitor]?
}

private struct ESPNVideo: Decodable {
    struct Links: Decodable {
        struct Web: Decodable { let href: String? }
        let web: Web?
        // Build 81 (item 3): `links.source.href` is a DIRECT
        // playable MP4 on ESPN's media CDN (verified live
        // 2026-11-20 against NFL/NBA/soccer summaries: 17 of 17
        // sampled videos carried one, HTTP 200, Accept-Ranges:
        // bytes) — it is what lets highlights play in-app instead
        // of opening ESPN's website.
        let source: Web?
    }
    let id: Int?
    let headline: String?
    let thumbnail: String?
    let duration: Int?
    let links: Links?
}

private struct ESPNCommentaryEntry: Decodable {
    struct Time: Decodable { let displayValue: String? }
    let sequence: Int?
    let time: Time?
    let text: String?
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
    struct League: Decodable { let name: String? }
    let competitions: [ESPNHeaderCompetition]?
    /// Build 80 (item 16): the payload's own league name
    /// (e.g. "English Premier League") for the Facts tab.
    let league: League?
}

private struct ESPNHeaderCompetition: Decodable {
    let competitors: [ESPNCompetitor]?
    let details: [ESPNDetail]?
    let status: ESPNStatus?
    /// Build 65: the summary payload's own event date — decoded
    /// so a deep-linked match detail (no seed event) can still
    /// show its real kickoff in the scoreboard header.
    let date: String?
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
    /// Build 85: baseball's half-inning marker ("Top" /
    /// "Bottom" / "End") — the payload's own word, paired
    /// with `displayValue` ("1st Inning") for the play
    /// label.
    let type: String?
}

private struct ESPNPlayType: Decodable {
    let text: String?
}

private struct ESPNParticipant: Decodable {
    let athlete: ESPNAthlete?
}

struct ESPNAthlete: Decodable {
    let id: String?
    let displayName: String?
    let shortName: String?
    let headshot: ESPNHeadshot?
}

struct ESPNHeadshot: Decodable {
    let href: String?
}

private struct ESPNBoxscore: Decodable {
    let teams: [ESPNBoxscoreTeam]?
    /// Build 84 (item 11): per-player box score groups
    /// (NBA/NFL summaries; soccer's boxscore has teams only).
    let players: [ESPNBoxscorePlayerTeam]?
}

private struct ESPNBoxscorePlayerTeam: Decodable {
    let team: ESPNTeam?
    let statistics: [ESPNBoxscorePlayerGroup]?
}

private struct ESPNBoxscorePlayerGroup: Decodable {
    /// NFL group name ("passing"); the NBA's single group
    /// carries none.
    let name: String?
    /// NFL group title ("Indianapolis Passing").
    let text: String?
    /// Build 85: baseball's group kind — the MLB payload
    /// names its two groups ONLY here ("batting" /
    /// "pitching"); name and text are both nil.
    let type: String?
    let labels: [String]?
    let athletes: [ESPNBoxscorePlayerEntry]?
    let totals: [String]?
}

private struct ESPNBoxscorePlayerEntry: Decodable {
    let athlete: ESPNAthlete?
    let stats: [String]?
    let didNotPlay: Bool?
    let reason: String?
    let starter: Bool?
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
        case .mlb: segment = "mlb"
        case .nhl:
            // NHL headshots come from the NHL API's own URLs —
            // the ESPN CDN pattern is never used for hockey.
            return nil
        }
        return URL(string: "https://a.espncdn.com/i/headshots/\(segment)/players/full/\(id).png")
    }

    static func fetchDetail(sport: MatchSport, leaguePath: String, eventId: String) async throws -> MatchDetail {
        var components = URLComponents(string: "\(baseURL)/\(leaguePath)/summary")
        components?.queryItems = [URLQueryItem(name: "event", value: eventId)]
        guard let url = components?.url else { throw URLError(.badURL) }
        // Build 90 (SP21): the detail fetch rides the SAME
        // sports disk cache as the scoreboards, standings and
        // leaders — a success saves the payload, a network
        // failure serves the last real payload, and only both
        // failing throws (the old direct fetch was a hard
        // error screen offline, unlike every sibling surface).
        let cacheKey = "detail|\(leaguePath)|\(eventId)"
        guard let result = await SportsDiskCache.espnData(url: url, cacheKey: cacheKey) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(ESPNSummary.self, from: result.data)
        return mapDetail(decoded, sport: sport)
    }

    private static func mapDetail(_ summary: ESPNSummary, sport: MatchSport) -> MatchDetail {
        let competition = summary.header?.competitions?.first
        let header = mapHeader(competition)
        let competitors = competition?.competitors ?? []
        let homeCompetitor = competitors.first(where: { $0.homeAway == "home" }) ?? competitors.first
        let awayCompetitor = competitors.first(where: { $0.homeAway == "away" }) ?? competitors.dropFirst().first
        return MatchDetail(
            header: header,
            timeline: mapTimeline(summary, competition: competition, sport: sport),
            stats: mapStats(summary, competition: competition),
            leaders: mapLeaders(summary, sport: sport),
            lineups: mapLineups(summary, sport: sport),
            info: mapInfo(summary),
            h2h: mapH2H(summary),
            videos: mapVideos(summary),
            commentary: mapCommentary(summary),
            boxScore: mapBoxScore(summary, sport: sport),
            playsFeed: mapPlaysFeed(summary, sport: sport),
            winProbability: (summary.winprobability ?? []).compactMap { $0.homeWinPercentage },
            homeLinescores: (homeCompetitor?.linescores ?? []).compactMap { $0.displayValue },
            awayLinescores: (awayCompetitor?.linescores ?? []).compactMap { $0.displayValue },
            broadcastNames: (summary.broadcasts ?? []).compactMap { $0.media?.name ?? $0.station },
            homeHits: homeCompetitor?.hits.map(String.init),
            homeErrors: homeCompetitor?.errors.map(String.init),
            awayHits: awayCompetitor?.hits.map(String.init),
            awayErrors: awayCompetitor?.errors.map(String.init),
            article: mapArticle(summary),
            form: mapForm(summary)
        )
    }

    /// Build 90 (SP3): the summary's `lastFiveGames` mapped
    /// verbatim — a team block renders only when the payload
    /// carries it AND it holds results; zero new requests
    /// (the summary fetch already downloaded the field).
    private static func mapForm(_ summary: ESPNSummary) -> [MatchTeamForm] {
        (summary.lastFiveGames ?? []).compactMap { block -> MatchTeamForm? in
            guard let team = block.team else { return nil }
            let results = (block.events ?? []).enumerated().map { index, event in
                MatchFormResult(
                    id: event.id ?? "form-\(index)",
                    date: event.gameDate.flatMap { parseEventDate($0) },
                    result: event.gameResult,
                    scoreText: event.score,
                    opponentName: event.opponent?.displayName,
                    opponentLogoURL: (event.opponentLogo ?? event.opponent?.logo)
                        .flatMap { URL(string: $0) },
                    atVs: event.atVs,
                    competitionName: event.competitionName
                )
            }
            guard !results.isEmpty else { return nil }
            return MatchTeamForm(
                teamId: team.id,
                teamName: team.displayName,
                logoURL: team.logo.flatMap { URL(string: $0) },
                results: results
            )
        }
    }

    /// Build 85 (sweep): the summary's recap/preview article —
    /// headline required, everything else verbatim.
    private static func mapArticle(_ summary: ESPNSummary) -> MatchArticle? {
        guard let article = summary.article,
              let headline = article.headline, !headline.isEmpty else { return nil }
        return MatchArticle(
            headline: headline,
            summary: article.description,
            webURL: article.links?.web?.href.flatMap { URL(string: $0) }
        )
    }

    /// Build 84 (item 11): the per-player box score. Groups and
    /// columns are the payload's own (labels aligned with each
    /// athlete's stats array — the payload's contract, verified
    /// live for NBA + NFL); a player the payload marks
    /// didNotPlay renders as DNP with the payload's reason.
    private static func mapBoxScore(_ summary: ESPNSummary, sport: MatchSport) -> [MatchBoxScoreTeam] {
        guard sport != .soccer else { return [] }
        let competitors = summary.header?.competitions?.first?.competitors ?? []
        let homeId = competitors.first(where: { $0.homeAway == "home" })?.team?.id
        let awayId = competitors.first(where: { $0.homeAway == "away" })?.team?.id
        let teams = (summary.boxscore?.players ?? []).compactMap { teamGroup -> MatchBoxScoreTeam? in
            let groups = (teamGroup.statistics ?? []).compactMap { group -> MatchBoxScoreGroup? in
                let players = (group.athletes ?? []).compactMap { entry -> MatchBoxScorePlayer? in
                    guard let athlete = entry.athlete,
                          let name = athlete.displayName ?? athlete.shortName,
                          !name.isEmpty else { return nil }
                    return MatchBoxScorePlayer(
                        athleteId: athlete.id,
                        name: name,
                        headshotURL: headshotURL(sport: sport, athlete: athlete),
                        values: entry.stats ?? [],
                        didNotPlay: entry.didNotPlay ?? false,
                        dnpReason: entry.reason,
                        isStarter: entry.starter ?? false
                    )
                }
                guard !players.isEmpty else { return nil }
                // Build 85: baseball's groups carry neither a
                // name nor a text — only `type` ("batting" /
                // "pitching") — so the title comes from the
                // payload's own kind word, localized.
                let title: String?
                if let text = group.text ?? group.name {
                    title = text
                } else if sport == .mlb, group.type == "batting" {
                    title = L("matches.box.batting")
                } else if sport == .mlb, group.type == "pitching" {
                    title = L("matches.box.pitching")
                } else {
                    title = nil
                }
                return MatchBoxScoreGroup(
                    title: title,
                    columns: group.labels ?? [],
                    players: players,
                    totals: group.totals ?? []
                )
            }
            guard !groups.isEmpty else { return nil }
            let homeAway: String?
            if let teamId = teamGroup.team?.id, teamId == homeId { homeAway = "home" }
            else if let teamId = teamGroup.team?.id, teamId == awayId { homeAway = "away" }
            else { homeAway = nil }
            return MatchBoxScoreTeam(
                teamName: teamGroup.team?.displayName,
                logoURL: teamGroup.team?.logo.flatMap { URL(string: $0) },
                homeAway: homeAway,
                groups: groups
            )
        }
        // Home team first, matching every other detail surface.
        return teams.sorted { a, b in
            (a.homeAway == "home" ? 0 : 1) < (b.homeAway == "home" ? 0 : 1)
        }
    }

    /// Build 84 (item 19): the play-by-play feed — NBA's flat
    /// `plays` list, or the NFL's drives flattened in payload
    /// (chronological) order; either way the result is reversed
    /// to newest-first and capped so the list stays sane.
    private static func mapPlaysFeed(_ summary: ESPNSummary, sport: MatchSport) -> [MatchPlayEntry] {
        guard sport != .soccer else { return [] }
        let plays: [ESPNPlay]
        if let flat = summary.plays, !flat.isEmpty {
            plays = flat
        } else if let drives = summary.drives?.previous {
            plays = drives.flatMap { $0.plays ?? [] }
        } else {
            return []
        }
        let entries = plays.enumerated().compactMap { index, play -> MatchPlayEntry? in
            let text = play.text ?? play.type?.text ?? ""
            guard !text.isEmpty else { return nil }
            let periodLabel: String?
            if sport == .mlb {
                // Build 85: an inning is not a quarter — the
                // label is the payload's own half + inning
                // ("Top" + "1st Inning"), falling back to
                // whichever half the payload carried.
                let parts = [play.period?.type, play.period?.displayValue]
                    .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                periodLabel = parts.isEmpty ? nil : parts.joined(separator: " ")
            } else if let period = play.period?.number, period > 0 {
                periodLabel = period <= 4 ? "Q\(period)" : "OT"
            } else {
                periodLabel = play.period?.displayValue
            }
            let scoreText: String?
            if let home = play.homeScore, let away = play.awayScore {
                scoreText = "\(home)–\(away)"
            } else {
                scoreText = nil
            }
            return MatchPlayEntry(
                id: play.id ?? "feed-\(index)",
                periodLabel: periodLabel,
                clockText: play.clock?.displayValue,
                text: text,
                scoreText: scoreText,
                scoringPlay: play.scoringPlay ?? false
            )
        }
        // Build 85: a baseball game carries ~700+ plays (each
        // pitch is one) against an NBA game's ~450 — the cap
        // rises for baseball so a full game stays readable;
        // the shipped NBA/NFL cap is unchanged.
        return Array(entries.reversed().prefix(sport == .mlb ? 600 : 250))
    }

    /// Build 80 (item 16): Facts-tab match info — only fields the
    /// payload itself carries (league, venue + city, attendance,
    /// first listed official as referee).
    private static func mapInfo(_ summary: ESPNSummary) -> MatchInfo? {
        let venueName = summary.gameInfo?.venue?.fullName ?? summary.gameInfo?.venue?.shortName
        let venueText = [venueName, summary.gameInfo?.venue?.address?.city]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let info = MatchInfo(
            leagueName: summary.header?.league?.name,
            venueText: venueText.isEmpty ? nil : venueText,
            attendance: summary.gameInfo?.attendance,
            refereeText: summary.gameInfo?.officials?.first?.displayName,
            predictorHome: summary.predictor?.homeTeam?.gameProjection,
            predictorAway: summary.predictor?.awayTeam?.gameProjection
        )
        guard info.leagueName != nil || info.venueText != nil
            || info.attendance != nil || info.refereeText != nil
            || info.predictorHome != nil else { return nil }
        return info
    }

    /// Build 80 (item 15): head-to-head / season series — the
    /// FIRST series in the payload, meetings newest first, each
    /// with the payload's own team names and scores.
    private static func mapH2H(_ summary: ESPNSummary) -> MatchH2H? {
        guard let series = summary.seasonseries?.first else { return nil }
        let meetings = (series.events ?? []).compactMap { event -> MatchH2HMeeting? in
            guard let competitors = event.competitors, competitors.count >= 2,
                  let home = competitors.first(where: { $0.homeAway == "home" }) ?? competitors.first,
                  let away = competitors.first(where: { $0.homeAway == "away" }) ?? competitors.dropFirst().first
            else { return nil }
            return MatchH2HMeeting(
                id: event.id ?? "\(event.date ?? "")-\(home.team?.id ?? "")-\(away.team?.id ?? "")",
                date: event.date.flatMap { parseEventDate($0) },
                homeName: home.team?.displayName,
                awayName: away.team?.displayName,
                homeScore: home.score,
                awayScore: away.score
            )
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        guard !meetings.isEmpty else { return nil }
        return MatchH2H(title: series.title, summary: series.summary, meetings: meetings)
    }

    /// Build 80 (item 15): official videos. Build 81 (item 3): a
    /// video renders only with a headline AND a direct playable
    /// source (`links.source.href`) — videos whose payload offers
    /// only the web page link are kept OUT rather than sending
    /// the user to ESPN's website (owner's order). Live sampling
    /// (2026-11-20): NFL 6/6, NBA 8/8, soccer 3/3 sampled videos
    /// carried a direct source.
    private static func mapVideos(_ summary: ESPNSummary) -> [MatchVideo] {
        (summary.videos ?? []).compactMap { video -> MatchVideo? in
            guard let headline = video.headline, !headline.isEmpty,
                  let href = video.links?.source?.href, let url = URL(string: href)
            else { return nil }
            return MatchVideo(
                id: video.id.map(String.init) ?? href,
                headline: headline,
                url: url,
                thumbnailURL: video.thumbnail.flatMap { URL(string: $0) },
                durationSeconds: video.duration
            )
        }
    }

    /// Build 80 (item 16): commentary in payload (chronological)
    /// order; empty-text entries are dropped.
    private static func mapCommentary(_ summary: ESPNSummary) -> [MatchCommentaryEntry] {
        (summary.commentary ?? []).enumerated().compactMap { index, entry -> MatchCommentaryEntry? in
            guard let text = entry.text, !text.isEmpty else { return nil }
            return MatchCommentaryEntry(
                id: index,
                minuteText: entry.time?.displayValue,
                text: text
            )
        }
    }

    /// Item 10f: rosters → lineups. Formation and positions are
    /// carried through verbatim; nothing is inferred here — the
    /// VIEW decides whether the formation can be laid out on a
    /// pitch or must fall back to the grouped list.
    private static func mapLineups(_ summary: ESPNSummary, sport: MatchSport) -> [MatchLineupSide] {
        (summary.rosters ?? []).compactMap { side -> MatchLineupSide? in
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
                    headshotURL: headshotURL(sport: sport, athlete: athlete),
                    athleteId: athlete.id
                )
            }
            guard !players.isEmpty else { return nil }
            return MatchLineupSide(
                teamId: side.team?.id,
                teamName: side.team?.displayName,
                logoURL: side.team?.logo.flatMap { URL(string: $0) },
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
            period: competition?.status?.period,
            statusDetail: competition?.status?.type?.shortDetail
                ?? competition?.status?.type?.detail,
            startDate: competition?.date.flatMap { parseEventDate($0) }
        )
    }

    private static func mapTimeline(
        _ summary: ESPNSummary,
        competition: ESPNHeaderCompetition?,
        sport: MatchSport
    ) -> [MatchTimelineEvent] {
        // 0) Build 90 (SP1): the summary's `keyEvents` — the
        // FULL event feed. In the current feed shape the
        // header `details` below carry only the goals
        // (verified live 2026-11-21: eng.1 details = 2 goals
        // vs keyEvents = 19 events incl. 4 yellow cards and
        // 5 substitutions; esp.1: 4 vs 31, incl. an own goal
        // and a penalty saved), so when keyEvents is present
        // it IS the timeline — same payload, zero new
        // requests. Any league whose summary omits it falls
        // through to the details chain exactly as before.
        if let keyEvents = summary.keyEvents, !keyEvents.isEmpty {
            let mapped = mapKeyEvents(keyEvents, sport: sport)
            if !mapped.isEmpty { return mapped }
        }
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
                // Build 90 (SP1 / S1 A8): the team name and
                // the assist BOTH survive — the old mapping
                // replaced the team name with the assist name,
                // so a row could show one or the other, never
                // both.
                var detailParts: [String] = []
                if let teamName = detail.team?.displayName { detailParts.append(teamName) }
                if participants.count > 1, let assist = participants[1].athlete?.displayName {
                    detailParts.append(assist)
                }
                let detailText = detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")
                return MatchTimelineEvent(
                    id: "detail-\(index)",
                    minuteText: detail.clock?.displayValue,
                    title: title,
                    detail: detailText,
                    playerName: scorer?.displayName,
                    athleteId: scorer?.id,
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

    /// Build 90 (SP1): period markers the keyEvents feed
    /// interleaves with the real events — rendered nowhere
    /// (the detail header already carries the match state).
    private static let keyEventMarkerTypes: Set<String> = [
        "kickoff", "halftime", "start-2nd-half", "end-regular-time",
        "start-delay", "end-delay"
    ]

    /// Build 90 (SP1): keyEvents → timeline rows, in payload
    /// (chronological) order. Every goal in keyEvents matches
    /// a header `details` goal one-for-one in the verified
    /// samples, so the goals the timeline already showed are
    /// unchanged — cards, substitutions and penalty events
    /// are what this adds. Title leads with the player the
    /// event is about (the details path's effective rendering
    /// today: its `type.text` is nil in the current feed, so
    /// its rows already fall back to the scorer's name); the
    /// detail line carries the payload's type label, the
    /// team, and the second participant (the assist on a
    /// goal, the player replaced in a substitution) — the
    /// A8 fix: team and second participant both survive.
    private static func mapKeyEvents(
        _ events: [ESPNKeyEvent], sport: MatchSport
    ) -> [MatchTimelineEvent] {
        events.enumerated().compactMap { index, event -> MatchTimelineEvent? in
            let typeId = event.type?.type ?? ""
            if keyEventMarkerTypes.contains(typeId) { return nil }
            let participants = event.participants ?? []
            let primary = participants.first?.athlete
            let secondary = participants.count > 1 ? participants[1].athlete : nil
            let kind: MatchTimelineEvent.Kind
            let isGoalType = typeId.hasPrefix("goal") || typeId == "own-goal"
            if event.scoringPlay == true || isGoalType {
                kind = .goal
            } else if typeId == "yellow-card" {
                kind = .yellowCard
            } else if typeId == "red-card" {
                kind = .redCard
            } else {
                kind = .other
            }
            var title = primary?.displayName ?? primary?.shortName ?? ""
            if title.isEmpty {
                title = event.type?.text ?? event.shortText ?? event.text ?? ""
            }
            var detailParts: [String] = []
            if let typeText = event.type?.text, typeText != title {
                detailParts.append(typeText)
            }
            if let teamName = event.team?.displayName {
                detailParts.append(teamName)
            }
            if let secondaryName = secondary?.displayName ?? secondary?.shortName {
                detailParts.append(secondaryName)
            }
            return MatchTimelineEvent(
                id: event.id.map { "key-\($0)" } ?? "key-\(index)",
                minuteText: event.clock?.displayValue,
                title: title,
                detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
                playerName: primary?.displayName ?? primary?.shortName,
                athleteId: primary?.id,
                headshotURL: headshotURL(sport: sport, athlete: primary),
                teamName: event.team?.displayName,
                kind: kind,
                keyEventTypeId: typeId.isEmpty ? nil : typeId
            )
        }
    }

    private static func mapPlay(_ play: ESPNPlay, index: Int, sport: MatchSport) -> MatchTimelineEvent {
        let participants = play.participants ?? play.athletesInvolved ?? []
        let athlete = participants.first?.athlete
        var minute = play.clock?.displayValue
        if sport == .mlb {
            // Build 85: the payload's own half + inning text
            // ("Top 9th Inning") — never a quarter label.
            let parts = [play.period?.type, play.period?.displayValue]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { minute = parts.joined(separator: " ") }
        } else if let period = play.period?.number, sport != .soccer {
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
            athleteId: athlete?.id,
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
                        athleteId: entry.athlete?.id,
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
