import Foundation
import GRDB

// Build 84: the combined sports update's data layer — player
// profiles, league leaders (goals/assists, PPG/APG/RPG, passing/
// rushing/receiving), league news, player search, standings form,
// the live table, broadcaster Watch matching, kickoff push
// reminders, the Live Now / Highlights aggregations, and the
// sports disk cache (offline stamps).
//
// EVERY endpoint below was verified live on 2026-11-21 against
// real ESPN payloads before a single line of UI was wired to it
// (the build-84 report carries the per-endpoint evidence). A
// source that returns nothing produces an honest empty result —
// nothing here fabricates a stat, a photo, or a headline.

// MARK: - Sports disk cache (item 23)

/// Last-good ESPN payloads on disk, one JSON envelope per key
/// ({at, data: base64}) under Caches/superx-sports. Written on
/// every successful fetch, read ONLY when the network fails, so
/// a sports screen can render its last real data with a visible
/// "last updated" stamp instead of an error. Deliberately tiny:
/// no eviction bookkeeping beyond a 7-day sweep on write.
enum SportsDiskCache {
    private static let directory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = caches.appendingPathComponent("superx-sports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private struct Envelope: Codable {
        let at: TimeInterval
        let data: Data
    }

    private static func fileURL(for key: String) -> URL? {
        let safe = key.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        return directory?.appendingPathComponent(String(safe) + ".json")
    }

    static func save(key: String, data: Data) {
        guard let url = fileURL(for: key) else { return }
        let envelope = Envelope(at: Date().timeIntervalSince1970, data: data)
        guard let encoded = try? JSONEncoder().encode(envelope) else { return }
        try? encoded.write(to: url, options: [.atomic])
        sweepOldFiles()
    }

    static func load(key: String) -> (data: Data, at: Date)? {
        guard let url = fileURL(for: key),
              let raw = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: raw)
        else { return nil }
        return (envelope.data, Date(timeIntervalSince1970: envelope.at))
    }

    private static func sweepOldFiles() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > 7 * 24 * 3600 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// One ESPN GET with the disk fallback: success saves the
    /// payload and returns (data, nil, false); failure falls back
    /// to the last saved payload as (data, savedAt, true); both
    /// failing returns nil. `stamp` is therefore non-nil exactly
    /// when the data came from the disk cache.
    static func espnData(url: URL, cacheKey: String) async -> (data: Data, stamp: Date?, fromCache: Bool)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let (data, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            save(key: cacheKey, data: data)
            return (data, nil, false)
        }
        if let cached = load(key: cacheKey) {
            return (cached.data, cached.at, true)
        }
        return nil
    }
}

// MARK: - Core API plumbing (leaders / athletes)

/// ESPN core-API coordinates per sport. The season is the
/// calendar year the season STARTS in — verified live
/// 2026-11-21 from the payloads' own $refs (soccer eng.1 →
/// seasons/2026 types/1; NBA → seasons/2026 types/2; NFL →
/// seasons/2026 types/2, all during their 2026 seasons).
enum CoreCoordinates {
    static func segment(for sport: MatchSport) -> String {
        switch sport {
        case .soccer: return "soccer"
        case .nba: return "basketball"
        case .nfl: return "football"
        case .mlb: return "baseball"
        // Build 87: hockey's segment names the NHL search
        // leaguePath only — NHL data never flows through the
        // ESPN core URLs this segment builds (every ESPN-core
        // consumer branches on .nhl before reaching them).
        case .nhl: return "hockey"
        }
    }

    /// Headshot CDN segment (the a.espncdn.com pattern).
    static func headshotSegment(for sport: MatchSport) -> String {
        switch sport {
        case .soccer: return "soccer"
        case .nba: return "nba"
        case .nfl: return "nfl"
        case .mlb: return "mlb"
        case .nhl: return "nhl"
        }
    }

    static func season(for sport: MatchSport, now: Date = Date()) -> Int {
        let comps = Calendar.current.dateComponents([.year, .month], from: now)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        switch sport {
        case .soccer: return month >= 7 ? year : year - 1
        case .nba: return month >= 10 ? year : year - 1
        case .nfl: return month >= 9 ? year : year - 1
        // Build 85: the MLB season is a single calendar year
        // (spring training opens in February) — before
        // February the completed season is last year's.
        case .mlb: return month >= 2 ? year : year - 1
        // Build 87: the NHL season opens in October; its start
        // year keys the (unused-by-NHL) core season math the
        // same way the NBA's does.
        case .nhl: return month >= 10 ? year : year - 1
        }
    }

    /// Build 90 (SP5): soccer leagues whose season is the
    /// CALENDAR year — MLS, the Brazilian Série A and the
    /// Argentine Liga Profesional run roughly Feb–Dec. The
    /// Jul–Jun rule above requested the PREVIOUS, completed
    /// season for them from January to June and presented
    /// its leaders/profiles as the current race. Verified
    /// live 2026-11-21: usa.1 / bra.1 / arg.1 all publish
    /// their full leaders sets at seasons/<calendar year>.
    /// The February threshold mirrors MLB's rule (before
    /// the season opens, the just-completed season is the
    /// latest real one). mex.1 is deliberately NOT in this
    /// set: ESPN keys Liga MX as a Jun–Jun year — its
    /// scoreboard season displayName is "2026-27 Liga BBVA
    /// MX" (verified live 2026-11-21) — so the Jul–Jun rule
    /// is already correct for it.
    static let calendarYearSoccerLeagues: Set<String> = ["usa.1", "bra.1", "arg.1"]

    /// The league-aware season: calendar-year soccer
    /// leagues key by the calendar year; every other sport
    /// and league keeps the rule above.
    static func season(for sport: MatchSport, leaguePath: String, now: Date = Date()) -> Int {
        guard sport == .soccer,
              calendarYearSoccerLeagues.contains(slug(from: leaguePath))
        else { return season(for: sport, now: now) }
        let comps = Calendar.current.dateComponents([.year, .month], from: now)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        return month >= 2 ? year : year - 1
    }

    static func seasonType(for sport: MatchSport) -> Int {
        sport == .soccer ? 1 : 2
    }

    /// The bare league slug ("eng.1") from a site path
    /// ("soccer/eng.1").
    static func slug(from leaguePath: String) -> String {
        leaguePath.split(separator: "/").last.map(String.init) ?? leaguePath
    }

    /// The league a sport's player surfaces fall back to when a
    /// search result's own league slug doesn't resolve.
    static func primarySlug(for sport: MatchSport) -> String {
        switch sport {
        case .soccer: return "eng.1"
        case .nba: return "nba"
        case .nfl: return "nfl"
        case .mlb: return "mlb"
        case .nhl: return "nhl"
        }
    }

    static func headshotURL(sport: MatchSport, athleteId: String?, href: String?) -> URL? {
        if let href, let url = URL(string: href) { return url }
        guard let athleteId, !athleteId.isEmpty else { return nil }
        return URL(string: "https://a.espncdn.com/i/headshots/\(headshotSegment(for: sport))/players/full/\(athleteId).png")
    }
}

/// Small $ref dereference helpers shared by the core-API
/// services (the scorers service has its own copy; this one also
/// reads team logos).
enum CoreDeref {
    struct NameLogo: Decodable {
        let displayName: String?
        let name: String?
        let logos: [Logo]?
        struct Logo: Decodable { let href: String? }
    }

    static func name(_ ref: String) async -> String? {
        guard let url = URL(string: ref) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let wire = try? JSONDecoder().decode(NameLogo.self, from: data) else { return nil }
        return wire.displayName ?? wire.name
    }

    static func nameLogo(_ ref: String) async -> (name: String?, logoURL: URL?) {
        guard let url = URL(string: ref) else { return (nil, nil) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let wire = try? JSONDecoder().decode(NameLogo.self, from: data) else { return (nil, nil) }
        return (wire.displayName ?? wire.name, wire.logos?.first?.href.flatMap { URL(string: $0) })
    }
}

// MARK: - Leaders name cache (build 90, SP17)

/// Disk cache for the leaders services' $ref name derefs.
/// A cold leaders open used to fire one small core-API GET
/// per athlete (and per team) — up to ~540 for MLB's eighteen
/// categories — and the session cache only helped until the
/// app relaunched. Resolved names now persist per league per
/// day through the existing SportsDiskCache (key:
/// leadernames|<leaguePath>|<yyyyMMdd> — the refs themselves
/// are league-scoped URLs, so one map serves every category
/// of that league), seeded lazily on first use and flushed
/// once per fetch, never per name. Names are stable identity
/// data; the day scope bounds staleness and the disk cache's
/// own 7-day sweep bounds growth.
enum LeaderNameCache {
    private final class Store: @unchecked Sendable {
        static let shared = Store()
        private let lock = NSLock()
        /// leaguePath → (athlete/team $ref → display name)
        private var maps: [String: [String: String]] = [:]
        private var seeded: Set<String> = []
        private var dirty: Set<String> = []

        func name(_ ref: String, leaguePath: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            seedLocked(leaguePath)
            return maps[leaguePath]?[ref]
        }

        func store(_ name: String, for ref: String, leaguePath: String) {
            lock.lock(); defer { lock.unlock() }
            seedLocked(leaguePath)
            maps[leaguePath, default: [:]][ref] = name
            dirty.insert(leaguePath)
        }

        func flush(leaguePath: String) {
            lock.lock()
            guard dirty.contains(leaguePath), let map = maps[leaguePath] else {
                lock.unlock()
                return
            }
            dirty.remove(leaguePath)
            lock.unlock()
            if let encoded = try? JSONEncoder().encode(map) {
                SportsDiskCache.save(key: diskKey(leaguePath), data: encoded)
            }
        }

        private func seedLocked(_ leaguePath: String) {
            guard !seeded.contains(leaguePath) else { return }
            seeded.insert(leaguePath)
            if maps[leaguePath] == nil { maps[leaguePath] = [:] }
            if let cached = SportsDiskCache.load(key: diskKey(leaguePath)),
               let decoded = try? JSONDecoder().decode([String: String].self, from: cached.data) {
                maps[leaguePath] = decoded
            }
        }

        private func diskKey(_ leaguePath: String) -> String {
            "leadernames|\(leaguePath)|\(MatchesService.todayParameter())"
        }
    }

    /// The cached name when this league's map already holds
    /// the ref; otherwise one live deref (the previous
    /// behaviour), stored for every later caller — including
    /// the next cold launch.
    static func name(_ ref: String, leaguePath: String) async -> String? {
        if let cached = Store.shared.name(ref, leaguePath: leaguePath) {
            return cached
        }
        guard let resolved = await CoreDeref.name(ref) else { return nil }
        Store.shared.store(resolved, for: ref, leaguePath: leaguePath)
        return resolved
    }

    /// Persist a league's map once its fetch has resolved any
    /// new names (a no-op when nothing was fetched).
    static func flush(leaguePath: String) {
        Store.shared.flush(leaguePath: leaguePath)
    }
}

// MARK: - League leaders (item 7)

struct LeaderRow84: Identifiable {
    let athleteId: String
    let name: String
    let teamName: String?
    let valueText: String
    let headshotURL: URL?
    /// Build 90 (SP35): the payload's numeric value behind
    /// `valueText`, surfaced so cross-league ranking can
    /// merge rows from several leagues' fetchAll results
    /// without re-parsing display text. Stamped by
    /// MatchesLeadersService from the same `values` map its
    /// sort already computes. Defaulted so the NHL-side
    /// constructions in Matches87.swift (a separate service
    /// whose rows are never merged cross-league) compile
    /// unchanged.
    var value: Double = 0
    var id: String { athleteId }
}

struct LeaderCategory84: Identifiable {
    let name: String
    let displayName: String
    var id: String { name }
}

/// Season leaders from the CORE api, all categories in ONE
/// payload per league (verified live 2026-11-21: soccer
/// carries twelve categories; the NBA and NFL payloads carry
/// sixteen each). The view offers exactly the categories the
/// payload returned — a category ESPN doesn't publish for a
/// league simply never appears.
enum MatchesLeadersService {
    /// The categories this build surfaces, per sport — every
    /// one of them confirmed present in the live payload.
    static func surfacedCategories(sport: MatchSport) -> [String] {
        switch sport {
        // Build 90 (SP2): the soccer core leaders payload
        // returns TWELVE categories (verified live
        // 2026-11-21, 25 leaders each, in eng.1, usa.1,
        // bra.1, arg.1, mex.1 and uefa.champions) — the app
        // used to whitelist two. Now surfaced: the two races
        // plus shots on target, accurate passes, SAVES (the
        // goalkeeper race — keepers were invisible in every
        // leaders surface) and the two card counts. The
        // payload's `goals` / `assists` categories stay
        // excluded: verified byte-identical duplicates of
        // goalsLeaders / assistsLeaders (same ids, values
        // and order). foulsCommitted / foulsSuffered /
        // totalShots ride the same payload but stay
        // unsurfaced (trivia-grade, per the S2 audit). A
        // category a league doesn't publish simply never
        // appears — fetchAll intersects with the payload.
        case .soccer: return [
            "goalsLeaders", "assistsLeaders",
            "shotsOnTarget", "accuratePasses", "saves",
            "yellowCards", "redCards"
        ]
        // Build 90 (SP17): the NBA core leaders payload
        // returns SIXTEEN categories (verified live
        // 2026-11-21, 25 leaders each) — the app used to
        // whitelist three. Now surfaced: the three races
        // plus steals, blocks, the three shooting
        // percentages, made threes, double-doubles and
        // minutes. Four payload categories stay excluded:
        // `NBARating` and `PER` (ratings — this app never
        // shows player ratings, the same rule as MLB's
        // MLBRating), and `avgTurnovers` / `foulsPerGame`
        // (negative trivia-grade counts, per the S3 audit).
        // A category a league doesn't publish simply never
        // appears — fetchAll intersects with the payload.
        case .nba: return [
            "pointsPerGame", "assistsPerGame", "reboundsPerGame",
            "stealsPerGame", "blocksPerGame",
            "fieldGoalPercentage", "3PointPct", "FreeThrowPct",
            "3PointsMadePerGame", "doubleDouble", "minutesPerGame"
        ]
        // Build 90 (SP17): the NFL core leaders payload
        // returns SIXTEEN categories (verified live
        // 2026-11-21, 25 leaders each) — the app used to
        // whitelist three. Now surfaced: the three yardage
        // races plus the touchdown races (passing, rushing,
        // receiving and total), receptions, and the
        // defensive races — sacks, interceptions, total
        // tackles and passes defended. `quarterbackRating`
        // stays excluded: a rating, and this app never
        // shows player ratings (the same rule as MLB's
        // MLBRating and the NBA ratings above). A category
        // a league doesn't publish simply never appears —
        // fetchAll intersects with the payload.
        case .nfl: return [
            "passingYards", "rushingYards", "receivingYards",
            "passingTouchdowns", "rushingTouchdowns", "receivingTouchdowns",
            "receptions", "sacks", "interceptions",
            "totalTackles", "passesDefended", "totalTouchdowns"
        ]
        // Build 85: EVERY category the MLB core leaders
        // payload verified live 2026-11-21 (25 leaders each,
        // seasons/2026/types/2) — batting first, then
        // pitching. Two payload categories are deliberately
        // NOT surfaced: "MLBRating" (a rating — this app
        // never shows player ratings) and "opponentAvg"
        // (its leaderboard is topped by a 1.0-inning pitcher:
        // the payload applies no minimum qualifier, so the
        // ranking is meaningless as published).
        case .mlb: return [
            "avg", "homeRuns", "RBIs", "hits", "runs", "stolenBases",
            "OPS", "onBasePct", "slugAvg", "WARBR",
            "ERA", "WHIP", "wins", "strikeouts", "saves",
            "qualityStarts", "holds", "avgGameScore"
        ]
        // Build 87: the ESPN core leaders payload is never
        // queried for hockey — NHL leaders come from the NHL
        // API's own leaders endpoints (NHLLeadersView). This
        // case exists so the switch stays exhaustive.
        case .nhl: return []
        }
    }

    private struct LeadersWire: Decodable {
        let categories: [Category]?
        struct Category: Decodable {
            let name: String?
            let displayName: String?
            let leaders: [Leader]?
        }
        struct Leader: Decodable {
            let value: Double?
            let displayValue: String?
            let athlete: Ref?
            let team: Ref?
        }
        struct Ref: Decodable { let ref: String?; enum CodingKeys: String, CodingKey { case ref = "$ref" } }
    }

    private final class SessionCache: @unchecked Sendable {
        static let shared = SessionCache()
        private let lock = NSLock()
        private var entries: [String: (rows: [String: [LeaderRow84]], displayNames: [String: String])] = [:]
        func get(_ key: String) -> (rows: [String: [LeaderRow84]], displayNames: [String: String])? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }
        func put(_ key: String, _ value: (rows: [String: [LeaderRow84]], displayNames: [String: String])) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = value
        }
    }

    /// All surfaced categories for one league:
    /// category name → (payload display name, rows). Plus the
    /// offline stamp when the payload came from the disk cache.
    static func fetchAll(
        sport: MatchSport, leaguePath: String
    ) async -> (categories: [LeaderCategory84], rows: [String: [LeaderRow84]], stamp: Date?) {
        let cacheKey = "leaders|\(sport.rawValue)|\(leaguePath)"
        if let cached = SessionCache.shared.get(cacheKey) {
            let categories = surfacedCategories(sport: sport)
                .filter { cached.rows[$0] != nil }
                .map { LeaderCategory84(name: $0, displayName: cached.displayNames[$0] ?? $0) }
            return (categories, cached.rows, nil)
        }
        let slug = CoreCoordinates.slug(from: leaguePath)
        // Build 90 (SP5): the league-aware season (calendar-
        // year soccer leagues key by calendar year).
        let season = CoreCoordinates.season(for: sport, leaguePath: leaguePath)
        let type = CoreCoordinates.seasonType(for: sport)
        let urlString = "https://sports.core.api.espn.com/v2/sports/\(CoreCoordinates.segment(for: sport))/leagues/\(slug)/seasons/\(season)/types/\(type)/leaders"
        guard let url = URL(string: urlString),
              let result = await SportsDiskCache.espnData(url: url, cacheKey: cacheKey),
              let wire = try? JSONDecoder().decode(LeadersWire.self, from: result.data)
        else { return ([], [:], nil) }

        let wanted = surfacedCategories(sport: sport)
        var rows: [String: [LeaderRow84]] = [:]
        var displayNames: [String: String] = [:]
        for category in wire.categories ?? [] {
            guard let name = category.name, wanted.contains(name) else { continue }
            displayNames[name] = category.displayName ?? name
            // Build 90 (SP2 / S2 A3): the payload publishes
            // 25 leaders per category (verified live across
            // the sampled leagues) — the old cap threw ranks
            // 16–25 away after fetching them.
            let leaders = Array((category.leaders ?? []).prefix(25))
            let mapped = await withTaskGroup(of: LeaderRow84?.self) { group in
                for leader in leaders {
                    group.addTask {
                        guard let ref = leader.athlete?.ref,
                              let athleteId = ref.split(separator: "/").last?.split(separator: "?").first.map(String.init),
                              let athleteName = await LeaderNameCache.name(ref, leaguePath: leaguePath) else { return nil }
                        let teamName = await leader.team?.ref.asyncFlatMap84 {
                            await LeaderNameCache.name($0, leaguePath: leaguePath)
                        }
                        return LeaderRow84(
                            athleteId: athleteId,
                            name: athleteName,
                            teamName: teamName,
                            valueText: leader.displayValue ?? formatValue(leader.value),
                            headshotURL: CoreCoordinates.headshotURL(sport: sport, athleteId: athleteId, href: nil)
                        )
                    }
                }
                var out: [LeaderRow84] = []
                for await row in group { if let row { out.append(row) } }
                return out
            }
            // The payload orders leaders by value already; the
            // task group doesn't preserve order, so re-sort by
            // the numeric value the payload carried. Build 90
            // (S2 A7): ties fall back to the payload's own
            // ranking order — sorting by value alone stabilised
            // the task-group's completion order, so tied rows
            // shuffled between visits.
            var values: [String: Double] = [:]
            var payloadOrder: [String: Int] = [:]
            for (index, leader) in leaders.enumerated() {
                guard let ref = leader.athlete?.ref,
                      let id = ref.split(separator: "/").last?.split(separator: "?").first.map(String.init)
                else { continue }
                values[id] = leader.value ?? 0
                payloadOrder[id] = index
            }
            let sorted = mapped.sorted { a, b in
                let valueA = values[a.athleteId] ?? 0
                let valueB = values[b.athleteId] ?? 0
                if valueA != valueB { return valueA > valueB }
                let orderA = payloadOrder[a.athleteId] ?? Int.max
                let orderB = payloadOrder[b.athleteId] ?? Int.max
                return orderA < orderB
            }
            // Build 90 (SP35): stamp each row with the
            // numeric value the sort just used, so
            // cross-league consumers (the scorers adapter in
            // MatchesExtras.swift, the cross-league page) can
            // merge and re-rank rows without re-parsing
            // display text.
            rows[name] = sorted.map { row in
                var stamped = row
                stamped.value = values[row.athleteId] ?? 0
                return stamped
            }
        }
        LeaderNameCache.flush(leaguePath: leaguePath)
        SessionCache.shared.put(cacheKey, (rows, displayNames))
        var categories: [LeaderCategory84] = []
        for name in wanted where rows[name] != nil {
            categories.append(LeaderCategory84(name: name, displayName: displayNames[name] ?? name))
        }
        return (categories, rows, result.stamp)
    }

    private static func formatValue(_ value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    /// Build 84 (item 12): ONE TEAM's leaders from the core
    /// team-leaders endpoint — verified live 2026-11-21 for
    /// all three sports (same categories wire shape as the
    /// league payload; the NFL/soccer team payloads name some
    /// categories differently and give composite displayValues
    /// like "Matches: 9, Goals: 7" — the payload's own text,
    /// shown as-is). Every category the payload returns is
    /// surfaced (no whitelist), top three per category, at
    /// most four categories.
    static func fetchTeam(
        sport: MatchSport, leaguePath: String, teamId: String
    ) async -> [(category: String, rows: [LeaderRow84])] {
        let slug = CoreCoordinates.slug(from: leaguePath)
        // Build 90 (SP5): the league-aware season, as in fetchAll.
        let season = CoreCoordinates.season(for: sport, leaguePath: leaguePath)
        let type = CoreCoordinates.seasonType(for: sport)
        let urlString = "https://sports.core.api.espn.com/v2/sports/\(CoreCoordinates.segment(for: sport))/leagues/\(slug)/seasons/\(season)/types/\(type)/teams/\(teamId)/leaders"
        guard let url = URL(string: urlString),
              let result = await SportsDiskCache.espnData(
                url: url, cacheKey: "tleaders|\(sport.rawValue)|\(leaguePath)|\(teamId)"
              ),
              let wire = try? JSONDecoder().decode(LeadersWire.self, from: result.data)
        else { return [] }
        var output: [(category: String, rows: [LeaderRow84])] = []
        for category in wire.categories ?? [] {
            let leaders = Array((category.leaders ?? []).prefix(3))
            guard !leaders.isEmpty else { continue }
            let rows = await withTaskGroup(of: LeaderRow84?.self) { group in
                for leader in leaders {
                    group.addTask {
                        guard let ref = leader.athlete?.ref,
                              let athleteId = ref.split(separator: "/").last?.split(separator: "?").first.map(String.init),
                              let athleteName = await LeaderNameCache.name(ref, leaguePath: leaguePath) else { return nil }
                        return LeaderRow84(
                            athleteId: athleteId,
                            name: athleteName,
                            teamName: nil,
                            valueText: leader.displayValue ?? formatValue(leader.value),
                            headshotURL: CoreCoordinates.headshotURL(sport: sport, athleteId: athleteId, href: nil)
                        )
                    }
                }
                var out: [LeaderRow84] = []
                for await row in group { if let row { out.append(row) } }
                return out
            }
            // Build 90 (SP8 / S2 A2): the task group appends in
            // COMPLETION order and this path never re-sorted —
            // a team's top scorer could render 2nd or 3rd in
            // his own category. Mirror fetchAll: numeric value
            // descending, ties in the payload's own order.
            var values: [String: Double] = [:]
            var payloadOrder: [String: Int] = [:]
            for (index, leader) in leaders.enumerated() {
                guard let ref = leader.athlete?.ref,
                      let id = ref.split(separator: "/").last?.split(separator: "?").first.map(String.init)
                else { continue }
                values[id] = leader.value ?? 0
                payloadOrder[id] = index
            }
            let sortedRows = rows.sorted { a, b in
                let valueA = values[a.athleteId] ?? 0
                let valueB = values[b.athleteId] ?? 0
                if valueA != valueB { return valueA > valueB }
                let orderA = payloadOrder[a.athleteId] ?? Int.max
                let orderB = payloadOrder[b.athleteId] ?? Int.max
                return orderA < orderB
            }
            // Build 90 (SP35): the same value stamping as
            // fetchAll, so team rows carry their numeric
            // value too.
            let stampedRows = sortedRows.map { row in
                var stamped = row
                stamped.value = values[row.athleteId] ?? 0
                return stamped
            }
            if !stampedRows.isEmpty {
                output.append((category: category.displayName ?? category.name ?? "", rows: stampedRows))
            }
            if output.count >= 4 { break }
        }
        LeaderNameCache.flush(leaguePath: leaguePath)
        return output
    }
}

private extension Optional where Wrapped == String {
    func asyncFlatMap84(_ transform: (String) async -> String?) async -> String? {
        guard let self else { return nil }
        return await transform(self)
    }
}

// MARK: - League news (item 8)

struct NewsArticle84: Identifiable {
    let id: String
    let headline: String
    let published: Date?
    let summary: String?
    let imageURL: URL?
    let webURL: URL?
}

/// Headlines from the site/v2 news endpoint — verified live
/// 2026-11-21 for soccer leagues, the NBA and the NFL
/// (articles[] with headline / published / description /
/// images[] / links.web.href). A league whose feed returns no
/// articles gets no News section — never a placeholder story.
enum LeagueNewsService {
    private struct Wire: Decodable {
        let articles: [Article]?
        struct Article: Decodable {
            let headline: String?
            let published: String?
            let description: String?
            let images: [Image]?
            let links: Links?
        }
        struct Image: Decodable { let url: String? }
        struct Links: Decodable {
            let web: Web?
            struct Web: Decodable { let href: String? }
        }
    }

    static func fetch(leaguePath: String) async -> (articles: [NewsArticle84], stamp: Date?) {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(leaguePath)/news?limit=12"),
              let result = await SportsDiskCache.espnData(url: url, cacheKey: "news|\(leaguePath)"),
              let wire = try? JSONDecoder().decode(Wire.self, from: result.data)
        else { return ([], nil) }
        let articles = (wire.articles ?? []).compactMap { article -> NewsArticle84? in
            guard let headline = article.headline, !headline.isEmpty else { return nil }
            let web = article.links?.web?.href
            return NewsArticle84(
                id: web ?? headline,
                headline: headline,
                published: article.published.flatMap { MatchesService.parseEventDate($0) },
                summary: article.description,
                imageURL: article.images?.first?.url.flatMap { URL(string: $0) },
                webURL: web.flatMap { URL(string: $0) }
            )
        }
        return (articles, result.stamp)
    }
}

// MARK: - Player profile (item 4)

struct PlayerProfile {
    let athleteId: String
    let name: String
    let age: Int?
    let jersey: String?
    let positionName: String?
    let citizenship: String?
    /// Build 85: baseball's batting / throwing hands — the
    /// core athlete payload carries them as objects with a
    /// displayValue ("Left" / "Right"); nil for every other
    /// sport (their payloads carry no such fields).
    let batsText: String?
    let throwsText: String?
    let headshotURL: URL?
    let teamId: String?
    let teamName: String?
    let teamLogoURL: URL?
    let statLines: [(label: String, value: String)]
    /// Build 90 (SP7): the same season stats GROUPED under
    /// the payload's own category names, headline lines first
    /// (see PlayerProfileService.fetchStats). Defaulted so
    /// the NHL / MLB-enrichment constructors keep building
    /// their profiles exactly as before — they leave this
    /// empty and their pages render the flat `statLines`.
    let statGroups: [(category: String?, lines: [(label: String, value: String)])] = []
    let recentEvents: [(name: String, date: Date)]
}

/// A player's page data from the CORE athlete endpoint —
/// verified live 2026-11-21 for all three sports (Haaland /
/// Doncic / Jordan Love): displayName, age, jersey, position
/// (inline displayName), citizenship (soccer), headshot (NBA /
/// NFL inline; soccer via the CDN pattern), the team $ref, the
/// season-statistics $ref (splits → categories → stats, each
/// with its own displayName + displayValue), and the events
/// $ref (the athlete's own event log — real involvement only).
/// "Ratings" stats the payload carries (correspondent / editor
/// / user averages, all 0.0 in samples) are excluded: this app
/// never shows player ratings.
enum PlayerProfileService {
    private struct AthleteWire: Decodable {
        let displayName: String?
        let age: Int?
        let jersey: String?
        let position: Position?
        let citizenship: String?
        /// Build 85: baseball's bats/throws objects
        /// ({type, abbreviation, displayValue}). The throwing
        /// hand's Swift name is `throwingHand` — `throws` is a
        /// reserved keyword and cannot be a bare identifier;
        /// the payload's wire key stays "throws" via CodingKeys
        /// (build 85 fix round 1).
        let bats: Hand?
        let throwingHand: Hand?
        let headshot: Headshot?
        let team: Ref?
        let statistics: Ref?
        let events: Ref?
        enum CodingKeys: String, CodingKey {
            case displayName, age, jersey, position, citizenship, bats
            case throwingHand = "throws"
            case headshot, team, statistics, events
        }
        struct Position: Decodable { let displayName: String?; let name: String? }
        struct Hand: Decodable { let displayValue: String?; let abbreviation: String? }
        struct Headshot: Decodable { let href: String? }
        struct Ref: Decodable { let ref: String?; enum CodingKeys: String, CodingKey { case ref = "$ref" } }
    }

    private struct StatsWire: Decodable {
        let splits: Splits?
        struct Splits: Decodable { let categories: [Category]? }
        struct Category: Decodable {
            let name: String?
            let stats: [Stat]?
        }
        struct Stat: Decodable {
            let name: String?
            let displayName: String?
            let displayValue: String?
        }
    }

    private struct EventsWire: Decodable {
        let items: [AthleteWire.Ref]?
    }

    private struct EventWire: Decodable {
        let name: String?
        let date: String?
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

    static func fetch(sport: MatchSport, leaguePath: String, athleteId: String) async -> PlayerProfile? {
        // Build 87 (item 1): NHL player pages come from the
        // NHL API's player landing endpoint (official
        // headshot, bio, featured + career stats) — the ESPN
        // core athlete graph below is never queried for
        // hockey.
        if sport == .nhl {
            return await NHLPlayerService.fetch(athleteId: athleteId)
        }
        let cacheKey = "\(sport.rawValue)|\(athleteId)"
        if let cached = SessionCache.shared.get(cacheKey) { return cached }
        // Candidate league slugs: the surface's own league
        // first, then the sport's primary league (a player found
        // through search may carry a national-team slug whose
        // season scope doesn't resolve his club record).
        var slugs = [CoreCoordinates.slug(from: leaguePath)]
        let primary = CoreCoordinates.primarySlug(for: sport)
        if !slugs.contains(primary) { slugs.append(primary) }
        for slug in slugs {
            if let profile = await fetchScoped(sport: sport, slug: slug, athleteId: athleteId) {
                // Build 87 (item 3): MLB player pages upgrade
                // through the official MLB Stats API — its
                // headshot becomes primary (ESPN's stays the
                // fallback inside the disc chain) and its
                // season + career lines append to the stat
                // list, but ONLY when the name search verifies
                // exactly one matching person (see
                // MLBStatsService). Any failure keeps the
                // ESPN profile untouched.
                if sport == .mlb {
                    let enriched = await MLBStatsService.enrich(profile)
                    SessionCache.shared.put(cacheKey, enriched)
                    return enriched
                }
                SessionCache.shared.put(cacheKey, profile)
                return profile
            }
        }
        return nil
    }

    private static func fetchScoped(sport: MatchSport, slug: String, athleteId: String) async -> PlayerProfile? {
        // Build 90 (SP5): profiles scope by the same
        // league-aware season as the leaders services — the
        // slug this function receives keys the calendar-year
        // rule identically (slug(from:) passes a bare slug
        // through unchanged).
        let season = CoreCoordinates.season(for: sport, leaguePath: slug)
        let urlString = "https://sports.core.api.espn.com/v2/sports/\(CoreCoordinates.segment(for: sport))/leagues/\(slug)/seasons/\(season)/athletes/\(athleteId)"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let athlete = try? JSONDecoder().decode(AthleteWire.self, from: data),
              let name = athlete.displayName, !name.isEmpty
        else { return nil }

        async let teamInfo = fetchTeamInfo(ref: athlete.team?.ref)
        async let stats = fetchStats(ref: athlete.statistics?.ref)
        async let events = fetchRecentEvents(ref: athlete.events?.ref)
        let team = await teamInfo
        let statsResult = await stats
        let teamId = athlete.team?.ref
            .flatMap { $0.split(separator: "/").last?.split(separator: "?").first }
            .map(String.init)
        return PlayerProfile(
            athleteId: athleteId,
            name: name,
            age: athlete.age,
            jersey: athlete.jersey,
            positionName: athlete.position?.displayName ?? athlete.position?.name,
            citizenship: athlete.citizenship,
            batsText: athlete.bats?.displayValue ?? athlete.bats?.abbreviation,
            throwsText: athlete.throwingHand?.displayValue ?? athlete.throwingHand?.abbreviation,
            headshotURL: CoreCoordinates.headshotURL(sport: sport, athleteId: athleteId, href: athlete.headshot?.href),
            teamId: teamId,
            teamName: team.name,
            teamLogoURL: team.logoURL,
            statLines: statsResult.lines,
            statGroups: statsResult.groups,
            recentEvents: await events
        )
    }

    private static func fetchTeamInfo(ref: String?) async -> (name: String?, logoURL: URL?) {
        guard let ref else { return (nil, nil) }
        return await CoreDeref.nameLogo(ref)
    }

    /// Season stats via the athlete payload's OWN statistics
    /// $ref — the exact season/type scope ESPN chose for this
    /// athlete. Ratings-named stats are filtered out (see the
    /// type note); empty values never render.
    ///
    /// Build 90 (SP7 / S2 A1+C7): the old walk flattened the
    /// categories in PAYLOAD ORDER and stopped at 16 lines.
    /// The payload orders defensive → general → goalKeeping →
    /// offensive (106 lines for a top striker), so the cap cut
    /// long before his Goals/Assists ever rendered — a
    /// forward's page showed tackles. The lines are now
    /// grouped under the payload's own category names with a
    /// headline group pulled to the top, and the full lists
    /// are kept (bounded at 140 lines — the largest verified
    /// payload carries ~106).
    private static func fetchStats(
        ref: String?
    ) async -> (lines: [(label: String, value: String)],
                groups: [(category: String?, lines: [(label: String, value: String)])]) {
        guard let ref, let url = URL(string: ref) else { return ([], []) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let wire = try? JSONDecoder().decode(StatsWire.self, from: data)
        else { return ([], []) }

        // Per-category lines, in payload order, ratings and
        // empty values dropped — the payload's own labels.
        var byCategory: [(name: String, lines: [(label: String, value: String, key: String)])] = []
        for category in wire.splits?.categories ?? [] {
            var lines: [(label: String, value: String, key: String)] = []
            for stat in category.stats ?? [] {
                guard let value = stat.displayValue, !value.isEmpty else { continue }
                let key = (stat.name ?? "").lowercased()
                if key.contains("rating") { continue }
                lines.append((label: stat.displayName ?? stat.name ?? "", value: value, key: key))
            }
            if !lines.isEmpty {
                byCategory.append((name: category.name ?? "", lines: lines))
            }
        }
        guard !byCategory.isEmpty else { return ([], []) }

        // The headline group: the lines a player's page exists
        // to show, pulled from whichever category carries them
        // (outfield and goalkeeper sets in one priority list —
        // a player only ever matches his own role's lines).
        // Matching is by the payload's stat names; each line
        // is used at most once.
        let headlineRules: [(String) -> Bool] = [
            { $0.contains("appearance") },
            { $0 == "goals" },
            { $0 == "assists" },
            { $0.contains("shotsontarget") },
            { $0 == "shots" || $0 == "totalshots" },
            { $0 == "saves" },
            { $0.contains("cleansheet") },
            { $0.contains("goalsagainst") }
        ]
        // Identity per line: category index + line index.
        var usedIds = Set<String>()
        var headline: [(label: String, value: String)] = []
        for rule in headlineRules {
            for (categoryIndex, category) in byCategory.enumerated() {
                for (lineIndex, line) in category.lines.enumerated() {
                    let identity = "\(categoryIndex)|\(lineIndex)"
                    if usedIds.contains(identity) { continue }
                    if rule(line.key) {
                        usedIds.insert(identity)
                        headline.append((label: line.label, value: line.value))
                    }
                }
            }
        }

        // Category groups in reading order — offensive first,
        // then general, goalkeeping, defensive; any other
        // payload category keeps its relative order after
        // those. Headline lines stay in their groups too (the
        // group is the complete list; the headline is a
        // summary, not a move).
        let categoryPriority = ["offensive", "general", "goalkeeping", "defensive"]
        let orderedCategories = byCategory.enumerated().sorted { a, b in
            let rankA = categoryPriority.firstIndex(of: a.element.name.lowercased()) ?? categoryPriority.count
            let rankB = categoryPriority.firstIndex(of: b.element.name.lowercased()) ?? categoryPriority.count
            if rankA != rankB { return rankA < rankB }
            return a.offset < b.offset
        }

        var groups: [(category: String?, lines: [(label: String, value: String)])] = []
        if !headline.isEmpty {
            groups.append((category: nil, lines: headline))
        }
        for entry in orderedCategories {
            let lines = entry.element.lines.map { (label: $0.label, value: $0.value) }
            groups.append((category: entry.element.name, lines: lines))
        }
        let flat = groups.flatMap { $0.lines }
        return (Array(flat.prefix(140)), groups)
    }

    /// Recent matches from the athlete's own event log: the
    /// event $refs are dereferenced (bounded, concurrent), past
    /// events kept, newest first, at most five. An event's name
    /// ("Norway at England") and date are the payload's own —
    /// scores are NOT shown because the core event exposes them
    /// only through further per-competitor $ref derefs.
    private static func fetchRecentEvents(ref: String?) async -> [(name: String, date: Date)] {
        guard let ref, let url = URL(string: ref) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let wire = try? JSONDecoder().decode(EventsWire.self, from: data)
        else { return [] }
        let refs = Array((wire.items ?? []).prefix(10)).compactMap { $0.ref }
        let events = await withTaskGroup(of: (name: String, date: Date)?.self) { group in
            for ref in refs {
                group.addTask {
                    guard let url = URL(string: ref) else { return nil }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 15
                    guard let (data, _) = try? await URLSession.shared.data(for: request),
                          let event = try? JSONDecoder().decode(EventWire.self, from: data),
                          let name = event.name,
                          let date = event.date.flatMap({ MatchesService.parseEventDate($0) })
                    else { return nil }
                    return (name, date)
                }
            }
            var out: [(name: String, date: Date)] = []
            for await event in group { if let event { out.append(event) } }
            return out
        }
        let now = Date()
        return Array(events.filter { $0.date < now }
            .sorted { $0.date > $1.date }
            .prefix(5))
    }
}

// MARK: - Player search (item 9)

struct PlayerSearchHit: Identifiable {
    let athleteId: String
    let name: String
    let sport: MatchSport
    /// The player's own default league slug from the search
    /// payload ("eng.1", "nba", …) when it carries one.
    let leagueSlug: String?
    var id: String { "\(sport.rawValue)|\(athleteId)" }
    var leaguePath: String {
        "\(CoreCoordinates.segment(for: sport))/\(leagueSlug ?? CoreCoordinates.primarySlug(for: sport))"
    }
}

/// Player results from ESPN's public search (verified live
/// 2026-11-21: site.web.api.espn.com/apis/search/v2 returns
/// grouped results; player contents carry a uid of the form
/// "s:600~a:{athleteId}", a displayName, a sport string and a
/// defaultLeagueSlug). Team results are NOT read here — team
/// search stays the existing local team-list filter.
enum PlayerSearchService {
    private struct Wire: Decodable {
        let results: [Group]?
        struct Group: Decodable {
            let type: String?
            let contents: [Content]?
        }
        struct Content: Decodable {
            let uid: String?
            let displayName: String?
            let sport: String?
            let defaultLeagueSlug: String?
        }
    }

    static func search(query: String) async -> [PlayerSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://site.web.api.espn.com/apis/search/v2?query=\(encoded)&limit=10")
        else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let wire = try? JSONDecoder().decode(Wire.self, from: data)
        else { return [] }
        var hits: [PlayerSearchHit] = []
        for group in wire.results ?? [] where group.type == "player" {
            for content in group.contents ?? [] {
                guard let uid = content.uid,
                      let athleteId = uid.split(separator: "~")
                        .last(where: { $0.hasPrefix("a:") })
                        .map({ String($0.dropFirst(2)) }),
                      !athleteId.isEmpty,
                      let name = content.displayName, !name.isEmpty,
                      let sport = sport(forSearchString: content.sport)
                else { continue }
                hits.append(PlayerSearchHit(
                    athleteId: athleteId, name: name, sport: sport,
                    leagueSlug: content.defaultLeagueSlug
                ))
            }
        }
        return Array(hits.prefix(10))
    }

    private static func sport(forSearchString raw: String?) -> MatchSport? {
        switch raw {
        case "soccer": return .soccer
        case "basketball": return .nba
        case "football": return .nfl
        // Build 85: verified live 2026-11-21 — baseball
        // players carry sport "baseball" and
        // defaultLeagueSlug "mlb" in the search payload.
        case "baseball": return .mlb
        // Build 87: hockey players resolve to the NHL tab;
        // their pages come from the NHL API (the profile
        // service branches on the sport), never ESPN core.
        case "hockey": return .nhl
        default: return nil
        }
    }
}

// MARK: - Standings form (item 5)

/// Last-5 form per team, derived from REAL finished results in
/// the league's own scoreboard payloads — ESPN publishes no
/// form field in the standings payload (verified again
/// 2026-11-21: the entry stats carry no form/last-5 entry), so
/// the chips are computed from results the scoreboard itself
/// reported. The scan walks BACK over past days through the
/// shared per-day cache (`MatchesService.fetchLeague`), in
/// parallel batches, hard-capped at 46 days; the computed map
/// is disk-cached per league per day, so a table re-open costs
/// nothing. A team renders exactly the results the scan found
/// for it (early season: fewer than five — the count itself is
/// the honest label; nothing is padded or invented).
enum TeamFormService {
    private static let maxScanDays = 46
    private static let batchSize = 7

    /// teamId → results in chronological order (oldest first,
    /// newest last), each "W" / "D" / "L" from that team's
    /// perspective, at most five.
    static func form(sport: MatchSport, leaguePath: String) async -> [String: [String]] {
        let today = MatchesService.todayParameter()
        let cacheKey = "form|\(leaguePath)|\(today)"
        if let cached = SportsDiskCache.load(key: cacheKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: cached.data) {
            return decoded
        }
        // Newest-first collection per team.
        var collected: [String: [String]] = [:]
        var teamsSeen = Set<String>()
        let calendar = Calendar.current
        let todayDate = calendar.startOfDay(for: Date())
        var scanned = 0
        while scanned < maxScanDays {
            let batchDays = (0..<batchSize).compactMap { i -> Date? in
                calendar.date(byAdding: .day, value: -(scanned + i), to: todayDate)
            }
            let results = await withTaskGroup(of: (day: Date, result: MatchLeagueResult)?.self) { group in
                for day in batchDays {
                    group.addTask {
                        guard let result = try? await MatchesService.fetchLeague(
                            path: leaguePath, dateParameter: dayParameter(for: day)
                        ) else { return nil }
                        return (day: day, result: result)
                    }
                }
                var out: [(day: Date, result: MatchLeagueResult)] = []
                for await item in group { if let item { out.append(item) } }
                return out
            }
            // Within a batch, process newest day first so the
            // per-team lists stay newest-first.
            let ordered = results.sorted { $0.day > $1.day }.map { $0.result }
            for result in ordered {
                for match in result.matches where match.state == .finished {
                    guard let homeId = match.home.teamId, let awayId = match.away.teamId,
                          let homeScore = Int(match.home.score ?? ""),
                          let awayScore = Int(match.away.score ?? "") else { continue }
                    teamsSeen.insert(homeId)
                    teamsSeen.insert(awayId)
                    if (collected[homeId]?.count ?? 0) < 5 {
                        collected[homeId, default: []].append(
                            homeScore > awayScore ? "W" : homeScore < awayScore ? "L" : "D"
                        )
                    }
                    if (collected[awayId]?.count ?? 0) < 5 {
                        collected[awayId, default: []].append(
                            awayScore > homeScore ? "W" : awayScore < homeScore ? "L" : "D"
                        )
                    }
                }
            }
            scanned += batchSize
            // Stop early once every team we've seen has five.
            if teamsSeen.count >= 8,
               teamsSeen.allSatisfy({ (collected[$0]?.count ?? 0) >= 5 }) {
                break
            }
        }
        // Chronological for display: reverse the newest-first lists.
        let form = collected.mapValues { Array($0.reversed()) }
        if let encoded = try? JSONEncoder().encode(form) {
            SportsDiskCache.save(key: cacheKey, data: encoded)
        }
        return form
    }

    private static func dayParameter(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

// MARK: - Live table (item 6)

/// The as-it-stands table: the OFFICIAL standings entries with
/// the currently-live matches' scores applied on top. A live
/// match is never in the official table yet (ESPN updates it at
/// full time), so each live match adds one played game, the
/// points/record its current score implies, and its goals —
/// pure arithmetic on payload values, badged LIVE in the UI.
/// Games-behind (NBA/NFL) is recomputed against the group's
/// adjusted leader. Zone notes are the OFFICIAL table's, so the
/// view suppresses zone bars/legend in live mode.
enum LiveTableAdjuster {
    static func adjusted(
        entries: [StandingEntry], liveMatches: [MatchEvent], sport: MatchSport
    ) -> [StandingEntry] {
        guard !liveMatches.isEmpty else { return entries }
        var byId: [String: StandingEntry] = [:]
        for entry in entries {
            if let teamId = entry.teamId { byId[teamId] = entry }
        }
        var statsById: [String: [String: String]] = byId.mapValues { $0.stats }
        for match in liveMatches where match.state == .live {
            guard let homeId = match.home.teamId, let awayId = match.away.teamId,
                  let homeScore = Int(match.home.score ?? ""),
                  let awayScore = Int(match.away.score ?? ""),
                  statsById[homeId] != nil, statsById[awayId] != nil else { continue }
            apply(&statsById, teamId: homeId, scored: homeScore, conceded: awayScore, sport: sport)
            apply(&statsById, teamId: awayId, scored: awayScore, conceded: homeScore, sport: sport)
        }
        var adjusted = entries.map { entry -> StandingEntry in
            guard let teamId = entry.teamId, let stats = statsById[teamId] else { return entry }
            return StandingEntry(
                teamId: entry.teamId, teamName: entry.teamName, logoURL: entry.logoURL,
                stats: stats, statLabels: entry.statLabels,
                noteColorHex: entry.noteColorHex, noteText: entry.noteText
            )
        }
        // Re-sort the group by the sport's ranking arithmetic.
        adjusted.sort { a, b in
            switch sport {
            case .soccer:
                let pa = int(a.stats["points"]), pb = int(b.stats["points"])
                if pa != pb { return pa > pb }
                let ga = int(a.stats["pointDifferential"]), gb = int(b.stats["pointDifferential"])
                if ga != gb { return ga > gb }
                return int(a.stats["pointsFor"]) > int(b.stats["pointsFor"])
            case .nba, .nfl, .mlb, .nhl:
                let wa = double(a.stats["winPercent"]), wb = double(b.stats["winPercent"])
                if wa != wb { return wa > wb }
                return int(a.stats["wins"]) > int(b.stats["wins"])
            }
        }
        if sport != .soccer {
            recomputeGamesBehind(&adjusted)
        }
        return adjusted
    }

    private static func apply(
        _ statsById: inout [String: [String: String]],
        teamId: String, scored: Int, conceded: Int, sport: MatchSport
    ) {
        guard var stats = statsById[teamId] else { return }
        func bump(_ key: String, by delta: Int) {
            stats[key] = String(int(stats[key]) + delta)
        }
        switch sport {
        case .soccer:
            bump("gamesPlayed", by: 1)
            bump("pointsFor", by: scored)
            bump("pointsAgainst", by: conceded)
            if scored > conceded { bump("wins", by: 1); bump("points", by: 3) }
            else if scored < conceded { bump("losses", by: 1) }
            else { bump("ties", by: 1); bump("points", by: 1) }
            let diff = int(stats["pointsFor"]) - int(stats["pointsAgainst"])
            stats["pointDifferential"] = diff > 0 ? "+\(diff)" : "\(diff)"
        case .nba, .nfl, .mlb, .nhl:
            if scored > conceded { bump("wins", by: 1) }
            else if scored < conceded { bump("losses", by: 1) }
            else if stats["ties"] != nil { bump("ties", by: 1) }
            bump("pointsFor", by: scored)
            bump("pointsAgainst", by: conceded)
            let diff = int(stats["pointsFor"]) - int(stats["pointsAgainst"])
            stats["pointDifferential"] = "\(diff)"
            let wins = int(stats["wins"]), losses = int(stats["losses"]), ties = int(stats["ties"])
            let total = wins + losses + ties
            if total > 0 {
                // Build 90 (SP15): a tie counts as HALF a win —
                // ESPN's own published PCT for a 5-3-1 team is
                // .611 = (5 + 0.5) / 9; the old W/(W+L+T)
                // printed .556 for the same record. (Sports
                // without ties are unaffected: their ties are 0.)
                let pct = (Double(wins) + 0.5 * Double(ties)) / Double(total)
                var text = String(format: "%.3f", pct)
                if text.hasPrefix("0.") { text = String(text.dropFirst()) }
                stats["winPercent"] = text
            }
        }
        statsById[teamId] = stats
    }

    private static func recomputeGamesBehind(_ entries: inout [StandingEntry]) {
        guard let leader = entries.first else { return }
        let leaderWins = int(leader.stats["wins"]), leaderLosses = int(leader.stats["losses"])
        for index in entries.indices {
            var stats = entries[index].stats
            if stats["gamesBehind"] != nil {
                if index == 0 {
                    stats["gamesBehind"] = "-"
                } else {
                    let gb = (Double(leaderWins - int(stats["wins"])) + Double(int(stats["losses"]) - leaderLosses)) / 2
                    stats["gamesBehind"] = gb == gb.rounded() ? String(Int(gb)) : String(format: "%.1f", gb)
                }
            }
            entries[index] = StandingEntry(
                teamId: entries[index].teamId, teamName: entries[index].teamName,
                logoURL: entries[index].logoURL, stats: stats,
                statLabels: entries[index].statLabels,
                noteColorHex: entries[index].noteColorHex, noteText: entries[index].noteText
            )
        }
    }

    private static func int(_ value: String?) -> Int {
        guard let value else { return 0 }
        return Int(value.replacingOccurrences(of: "+", with: "")) ?? 0
    }

    private static func double(_ value: String?) -> Double {
        guard let value else { return 0 }
        return Double(value) ?? 0
    }
}

// MARK: - Team league position (build 90, SP12)

/// A team's 1-based position within its standings group —
/// the payload's own ordering, exactly as the table renders
/// it. The team page already fetches the standings for its
/// header record line; this turns that SAME fetch into the
/// position with zero extra network (the view half renders
/// it beside the record — see the build-90 SP-B report).
enum StandingPositionService {
    static func position(ofTeamId teamId: String, in groups: [StandingGroup]) -> Int? {
        for group in groups {
            if let index = group.entries.firstIndex(where: { $0.teamId == teamId }) {
                return index + 1
            }
        }
        return nil
    }
}

// MARK: - Broadcaster Watch matching (item 3b)

/// The Watch action's channel matching: the user's ACTIVE
/// playlist (falling back to all playlists when none is active)
/// searched LOCALLY — no network — for channels that broadcast
/// the match: first the league's known broadcaster names, then
/// channels carrying a team name, then (on the detail screen)
/// the broadcaster names the match's own summary payload lists.
/// A hit is a channel whose name literally contains a needle;
/// no hit → no Watch button, never a dead end.
enum MatchWatchService {
    /// Broadcaster name patterns per league path. These are
    /// search needles against the USER'S OWN channel names —
    /// not broadcast claims: a button appears only when a
    /// matching channel exists in the user's playlist.
    static func broadcasterPatterns(sport: MatchSport, leaguePath: String) -> [String] {
        switch sport {
        case .nba:
            return ["ESPN", "ABC", "TNT", "NBA TV", "Prime Video"]
        case .nfl:
            return ["CBS", "FOX", "NBC", "ESPN", "Prime Video", "NFL Network", "Peacock", "Paramount"]
        case .mlb:
            // Build 85: MLB's national carriers (the WS
            // sample's scoreboard payload itself lists Fox) —
            // needles against the user's own channel names,
            // exactly like the other sports.
            return ["ESPN", "FOX", "FS1", "TBS", "MLB Network", "Apple TV", "Peacock", "NBC", "ABC"]
        case .nhl:
            // Build 87: the NHL's national carriers (US:
            // ESPN/ABC, TNT/truTV, NHL Network; Canada:
            // Sportsnet, TSN, CBC) — needles against the
            // user's own channel names, exactly like the
            // other sports.
            return ["ESPN", "ABC", "TNT", "truTV", "NHL Network", "Sportsnet", "TSN", "CBC"]
        case .soccer:
            var patterns = ["beIN Sports", "beIN"]
            switch CoreCoordinates.slug(from: leaguePath) {
            case "eng.1":
                patterns += ["Sky Sports", "TNT Sports", "USA Network", "Peacock", "NBC"]
            case "esp.1":
                patterns += ["Movistar", "DAZN", "LaLiga TV"]
            case "ita.1":
                patterns += ["DAZN", "Sky Sport", "Paramount"]
            case "ger.1":
                patterns += ["Sky Sport", "DAZN", "Sat.1"]
            case "fra.1":
                patterns += ["Canal+", "DAZN"]
            case "uefa.champions", "uefa.europa", "uefa.europa.conf":
                patterns += ["Paramount", "CBS", "TNT Sports", "DAZN", "Canal+"]
            case "ned.1":
                patterns += ["ESPN", "Ziggo"]
            case "por.1":
                patterns += ["Sport TV", "Benfica TV"]
            case "tur.1":
                patterns += ["beIN", "TOD"]
            case "sco.1":
                patterns += ["Sky Sports", "Premier Sports"]
            case "bel.1":
                patterns += ["DAZN", "Eleven Sports"]
            case "usa.1":
                patterns += ["MLS Season Pass", "Apple TV", "FOX", "FS1"]
            case "mex.1":
                patterns += ["TUDN", "ViX", "Azteca"]
            case "bra.1":
                patterns += ["Premiere", "SporTV", "Globo", "CazéTV"]
            case "arg.1":
                patterns += ["ESPN Premium", "TNT Sports", "TyC Sports", "TV Pública"]
            default:
                break
            }
            return patterns
        }
    }

    private final class HitsCache: @unchecked Sendable {
        static let shared = HitsCache()
        private let lock = NSLock()
        private var entries: [String: (hits: [WatchChannelHit], at: Date)] = [:]
        func get(_ key: String) -> [WatchChannelHit]? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[key],
                  Date().timeIntervalSince(entry.at) < 120 else { return nil }
            return entry.hits
        }
        func put(_ key: String, _ hits: [WatchChannelHit]) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = (hits, Date())
        }
    }

    /// Ordered hits: broadcaster-pattern matches first (in
    /// table order), then team-name matches, then any extra
    /// needles (the summary's own broadcaster list on the
    /// detail screen). Capped at 8; cached per match for two
    /// minutes so list rows don't re-query the database.
    static func hits(
        sport: MatchSport, leaguePath: String, match: MatchEvent, extraNeedles: [String] = []
    ) async -> [WatchChannelHit] {
        let cacheKey = match.id + "|" + extraNeedles.joined(separator: ",")
        if let cached = HitsCache.shared.get(cacheKey) { return cached }
        let activeId = await MainActor.run {
            PlaylistContentStore.shared.activePlaylistId ?? M3UContentStore.shared.activePlaylistId
        }
        var needles = broadcasterPatterns(sport: sport, leaguePath: leaguePath)
        needles += [match.home.name, match.away.name].compactMap { $0 }
        needles += extraNeedles
        let hits = (try? await AppDatabase.shared.read { db -> [WatchChannelHit] in
            var hits: [WatchChannelHit] = []
            var seen = Set<String>()
            let playlists = try Playlist.fetchAll(db)
            let namesById = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0.name) })
            func like(_ needle: String) -> String { "%" + needle + "%" }
            for needle in needles {
                let trimmed = needle.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 2 else { continue }
                var streamQuery = DBLiveStream.filter(Column("name").like(like(trimmed)))
                var channelQuery = DBM3UChannel.filter(Column("name").like(like(trimmed)))
                if let activeId {
                    streamQuery = streamQuery.filter(Column("playlistId") == activeId)
                    channelQuery = channelQuery.filter(Column("playlistId") == activeId)
                }
                let streams = try streamQuery.limit(6).fetchAll(db)
                for stream in streams
                where seen.insert("x|\(stream.playlistId)|\(stream.streamId)").inserted {
                    hits.append(WatchChannelHit(
                        playlistId: stream.playlistId,
                        playlistName: namesById[stream.playlistId] ?? "",
                        channelName: stream.name,
                        channelLogoURL: stream.streamIcon.flatMap { URL(string: $0) },
                        streamRef: .xtreamLive(playlistId: stream.playlistId, streamId: stream.streamId)
                    ))
                }
                let channels = try channelQuery.limit(6).fetchAll(db)
                for channel in channels
                where seen.insert("m|\(channel.id)").inserted {
                    guard let url = URL(string: channel.url) else { continue }
                    hits.append(WatchChannelHit(
                        playlistId: channel.playlistId,
                        playlistName: namesById[channel.playlistId] ?? "",
                        channelName: channel.name,
                        channelLogoURL: channel.tvgLogo.flatMap { URL(string: $0) },
                        streamRef: .m3u(url: url, name: channel.name, logoURL: channel.tvgLogo.flatMap { URL(string: $0) })
                    ))
                }
                if hits.count >= 8 { break }
            }
            return Array(hits.prefix(8))
        }) ?? []
        HitsCache.shared.put(cacheKey, hits)
        return hits
    }
}

// MARK: - Kickoff push reminders (item 15, app side)

struct MatchKickoffReminder: Codable, Identifiable {
    let eventId: String
    let leaguePath: String
    let sport: String
    let homeName: String
    let awayName: String
    let kickoffISO: String
    var id: String { eventId }
}

/// Any-match kickoff pushes. The toggle state lives on-device
/// (UserDefaults); the set is uploaded to the watcher with the
/// follow registration (PushNotificationService includes it as
/// the payload's `matches` array — additive: older server
/// builds ignore the field, the shipped teams contract is
/// untouched). The watcher fires ONE push at kickoff per
/// registered match and drops it.
final class MatchKickoffPushStore {
    static let shared = MatchKickoffPushStore()
    private let defaultsKey = "matches.kickoffPush.v1"
    private init() {}

    private(set) var reminders: [MatchKickoffReminder] {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let decoded = try? JSONDecoder().decode([MatchKickoffReminder].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func contains(eventId: String) -> Bool {
        reminders.contains { $0.eventId == eventId }
    }

    /// Build 90 (SP22): drop every reminder whose kickoff is
    /// in the past. The store previously only ever shrank on
    /// a manual toggle-off — and past matches render no
    /// toggle — so every match ever armed stayed in
    /// UserDefaults and rode EVERY watcher registration
    /// payload forever (S5 A6). Called from the detail
    /// page's load and before every payload build.
    func prunePast() {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let kept = reminders.filter { reminder in
            guard let kickoff = formatter.date(from: reminder.kickoffISO) else {
                // An unparseable stamp can't be proven past —
                // keep it rather than silently disarming a
                // reminder the user set.
                return true
            }
            return kickoff > now
        }
        if kept.count != reminders.count {
            reminders = kept
        }
    }

    func set(match: MatchEvent, leaguePath: String, sport: MatchSport, enabled: Bool) {
        prunePast()
        var current = reminders
        current.removeAll { $0.eventId == match.id }
        if enabled, let start = match.startDate {
            let formatter = ISO8601DateFormatter()
            current.append(MatchKickoffReminder(
                eventId: match.id,
                leaguePath: leaguePath,
                sport: sport.rawValue,
                homeName: match.home.name ?? "",
                awayName: match.away.name ?? "",
                kickoffISO: formatter.string(from: start)
            ))
        }
        reminders = current
    }

    /// The watcher's payload shape (additive field — see the
    /// type note). Build 90 (SP22): pruned first, so a stale
    /// entry can never ride an upload again even if no detail
    /// page has opened since its kickoff passed.
    var payload: [[String: Any]] {
        prunePast()
        return reminders.map {
            [
                "eventId": $0.eventId,
                "leaguePath": $0.leaguePath,
                "sport": $0.sport,
                "homeName": $0.homeName,
                "awayName": $0.awayName,
                "kickoffISO": $0.kickoffISO
            ]
        }
    }
}

// MARK: - Live Now + Highlights aggregation (items 13/14)

struct LiveNowGroup: Identifiable {
    let leagueName: String?
    let leaguePath: String
    let sport: MatchSport
    let matches: [MatchEvent]
    var id: String { leaguePath }
}

/// Build 88 (F11): one sport's slice of today's full
/// schedule, as Live Now's Today mode renders it (build 90:
/// formerly the Live Wall) — the sport (the section header)
/// plus its matches in kickoff order, each match still
/// PAIRED with the competition group it came from. The pairing is load-bearing: `MatchEvent` carries
/// no leaguePath of its own, and detail routing + Watch
/// matching need the REAL competition path. Merging a
/// sport's matches into a single group stamped a synthetic
/// "sport|…" path that fetched nothing (critic catch,
/// build 88) — the F10 calendar keeps the same
/// (group, match) pairing for the same reason.
struct TodaySportSchedule: Identifiable {
    let sport: MatchSport
    let entries: [(group: LiveNowGroup, match: MatchEvent)]
    var id: MatchSport { sport }
}

struct HubHighlight: Identifiable {
    let video: MatchVideo
    let homeName: String?
    let awayName: String?
    let leagueName: String?
    let date: Date?
    /// Build 87 (item 13): the highlight's sport — the hub
    /// groups its feed by sport (never one mixed list), and
    /// the per-section pages filter on it.
    let sport: MatchSport
    /// Scoped by its match so two summaries can never collide
    /// in the feed's identity space.
    var id: String { "\(video.id)|\(leagueName ?? "")|\(homeName ?? "")" }
}

/// Cross-competition aggregations over the SAME per-day
/// scoreboard cache the Matches screens use — no parallel fetch
/// system, no extra polling: Live Now reads today's cached
/// scoreboards; Highlights reads today's + yesterday's finished
/// matches and their summaries' verified videos.
enum SportsHubService {
    /// All 21 competitions: the 17-league soccer catalog plus
    /// the NFL, the NBA, MLB (build 85) and the NHL (build
    /// 87 — its scoreboard routes through NHLService inside
    /// `MatchesService.fetchLeague`).
    static var allCompetitions: [(sport: MatchSport, leaguePath: String)] {
        MatchSport.soccerLeagueCatalog.map { (sport: MatchSport.soccer, leaguePath: $0.leaguePath) }
            + [(sport: MatchSport.nfl, leaguePath: "football/nfl"),
               (sport: MatchSport.nba, leaguePath: "basketball/nba"),
               (sport: MatchSport.mlb, leaguePath: "baseball/mlb"),
               (sport: MatchSport.nhl, leaguePath: "nhl")]
    }

    /// The competitions whose highlights the ESPN summary
    /// pipeline can serve — every competition EXCEPT the NHL:
    /// hockey summaries don't come from ESPN (the NHL API
    /// publishes no direct-MP4 highlight feed — its recap ids
    /// point at nhl.com pages, which this app never links out
    /// to for video), so hockey contributes to Live Now and
    /// the calendar but not to the highlights feed.
    static var highlightCompetitions: [(sport: MatchSport, leaguePath: String)] {
        allCompetitions.filter { $0.sport != .nhl }
    }

    static func liveNow() async -> [LiveNowGroup] {
        await liveNowSnapshot().groups
    }

    /// Build 88 (F11): ONE pass over today's scoreboards that
    /// answers both of Live Now's questions — which matches are
    /// live (grouped by competition, as before) and whether
    /// today has any fixtures at all. The second answer drives
    /// the page's empty copy: "No matches live right now" is
    /// only honest when fixtures exist; the two states used to
    /// render the same "No matches today" line.
    static func liveNowSnapshot() async -> (groups: [LiveNowGroup], todayHasFixtures: Bool) {
        let today = MatchesService.todayParameter()
        let groups = await withTaskGroup(of: LiveNowGroup?.self) { group in
            for competition in allCompetitions {
                group.addTask {
                    guard let result = try? await MatchesService.fetchLeague(
                        path: competition.leaguePath, dateParameter: today
                    ) else { return nil }
                    let live = result.matches.filter { $0.state == .live }
                    guard !live.isEmpty else { return nil }
                    return LiveNowGroup(
                        leagueName: result.leagueName,
                        leaguePath: competition.leaguePath,
                        sport: competition.sport,
                        matches: live
                    )
                }
            }
            var out: [LiveNowGroup] = []
            for await item in group { if let item { out.append(item) } }
            return out
        }
        let order = Dictionary(uniqueKeysWithValues: allCompetitions.enumerated().map { ($0.element.leaguePath, $0.offset) })
        let sorted = groups.sorted { (order[$0.leaguePath] ?? 0) < (order[$1.leaguePath] ?? 0) }
        // Fixtures check: today's scoreboards again — every one
        // of these reads is served by the shared disk cache the
        // pass above just warmed, so this costs no new network.
        var hasFixtures = !sorted.isEmpty
        if !hasFixtures {
            hasFixtures = await withTaskGroup(of: Bool.self) { group in
                for competition in allCompetitions {
                    group.addTask {
                        guard let result = try? await MatchesService.fetchLeague(
                            path: competition.leaguePath, dateParameter: today
                        ) else { return false }
                        return !result.matches.isEmpty
                    }
                }
                for await hit in group { if hit { group.cancelAll(); return true } }
                return false
            }
        }
        return (sorted, hasFixtures)
    }

    /// Build 88 (F11): TODAY'S FULL schedule (live, upcoming
    /// and finished), bucketed by SPORT in the app's sport
    /// order with each sport's matches sorted by kickoff.
    /// Build 90 (SP32): this is now the data behind Live Now's
    /// Today mode — the separate Live Wall page is removed
    /// (two audits found it duplicated Live Now + the
    /// Calendar's today section). Deliberately a different
    /// shape from the live snapshot (live-only, grouped by
    /// competition). The bucketing is DISPLAY-ONLY: every
    /// match stays paired with its competition group
    /// (`TodaySportSchedule`), so the rows route detail and
    /// Watch matching through the real leaguePath — never a
    /// synthetic sport path.
    static func todaySchedule() async -> [TodaySportSchedule] {
        let today = MatchesService.todayParameter()
        let perCompetition = await withTaskGroup(of: LiveNowGroup?.self) { group in
            for competition in allCompetitions {
                group.addTask {
                    guard let result = try? await MatchesService.fetchLeague(
                        path: competition.leaguePath, dateParameter: today
                    ), !result.matches.isEmpty else { return nil }
                    return LiveNowGroup(
                        leagueName: result.leagueName,
                        leaguePath: competition.leaguePath,
                        sport: competition.sport,
                        matches: result.matches
                    )
                }
            }
            var out: [LiveNowGroup] = []
            for await item in group { if let item { out.append(item) } }
            return out
        }
        return MatchSport.allCases.compactMap { sport in
            let entries: [(group: LiveNowGroup, match: MatchEvent)] = perCompetition
                .filter { $0.sport == sport }
                .flatMap { competition in
                    competition.matches.map { (group: competition, match: $0) }
                }
                .sorted { ($0.match.startDate ?? .distantFuture) < ($1.match.startDate ?? .distantFuture) }
            guard !entries.isEmpty else { return nil }
            return TodaySportSchedule(sport: sport, entries: entries)
        }
    }

    static func liveCount() async -> Int {
        await liveNow().reduce(0) { $0 + $1.matches.count }
    }

    /// Highlight videos from finished matches (today, then
    /// yesterday), newest matches first. Bounded: at most 36
    /// candidate matches, summaries fetched six at a time; a
    /// match contributes only the videos its own summary
    /// payload carries (the build-81 verified direct-MP4 set).
    static func highlights() async -> [HubHighlight] {
        await highlights(competitions: highlightCompetitions)
    }

    /// Build 90 (S5 C5, hub half): a short in-memory cache
    /// over the aggregation below. A hub or section open used
    /// to re-download up to 36 full summary payloads EVERY
    /// time (fetchDetail itself has no cache); finished
    /// matches' summaries are immutable in practice, so a
    /// 120-second memory of the finished feed turns repeat
    /// opens into memory reads. The fetchDetail-level cache
    /// S5 proposed lives in MatchesService.swift — see the
    /// build-90 SP-B report.
    private final class HighlightsCache: @unchecked Sendable {
        static let shared = HighlightsCache()
        private let lock = NSLock()
        private var entries: [String: (highlights: [HubHighlight], at: Date)] = [:]
        func get(_ key: String) -> [HubHighlight]? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[key],
                  Date().timeIntervalSince(entry.at) < 120 else { return nil }
            return entry.highlights
        }
        func put(_ key: String, _ highlights: [HubHighlight]) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = (highlights, Date())
        }
    }

    /// Build 87 (item 13): ONE section's own highlights — the
    /// same aggregation scoped to a caller-chosen competition
    /// set (one league for a league page, one sport's leagues
    /// for a sport page). The hub above passes every
    /// highlight-capable competition.
    static func highlights(
        competitions: [(sport: MatchSport, leaguePath: String)]
    ) async -> [HubHighlight] {
        let cacheKey = competitions.map { $0.leaguePath }.joined(separator: ",")
        if let cached = HighlightsCache.shared.get(cacheKey) { return cached }
        let result = await computeHighlights(competitions: competitions)
        HighlightsCache.shared.put(cacheKey, result)
        return result
    }

    private static func computeHighlights(
        competitions: [(sport: MatchSport, leaguePath: String)]
    ) async -> [HubHighlight] {
        let calendar = Calendar.current
        let days = [Date(), calendar.date(byAdding: .day, value: -1, to: Date())].compactMap { $0 }
        var candidates: [(sport: MatchSport, leaguePath: String, leagueName: String?, match: MatchEvent)] = []
        for day in days {
            let parameter = dayParameter(for: day)
            let perLeague = await withTaskGroup(
                of: [(sport: MatchSport, leaguePath: String, leagueName: String?, match: MatchEvent)].self
            ) { group in
                for competition in competitions {
                    group.addTask {
                        guard let result = try? await MatchesService.fetchLeague(
                            path: competition.leaguePath, dateParameter: parameter
                        ) else { return [] }
                        return result.matches
                            .filter { $0.state == .finished }
                            .map { (sport: competition.sport, leaguePath: competition.leaguePath,
                                    leagueName: result.leagueName, match: $0) }
                    }
                }
                var out: [(sport: MatchSport, leaguePath: String, leagueName: String?, match: MatchEvent)] = []
                for await items in group { out += items }
                return out
            }
            candidates += perLeague
        }
        candidates.sort { ($0.match.startDate ?? .distantPast) > ($1.match.startDate ?? .distantPast) }
        let capped = Array(candidates.prefix(36))
        var highlights: [HubHighlight] = []
        for batchStart in stride(from: 0, to: capped.count, by: 6) {
            let batch = Array(capped[batchStart..<min(batchStart + 6, capped.count)])
            let batchResults = await withTaskGroup(of: [HubHighlight].self) { group in
                for candidate in batch {
                    group.addTask {
                        guard let detail = try? await MatchesService.fetchDetail(
                            sport: candidate.sport, leaguePath: candidate.leaguePath,
                            eventId: candidate.match.id
                        ) else { return [] }
                        return detail.videos.map {
                            HubHighlight(
                                video: $0,
                                homeName: candidate.match.home.name,
                                awayName: candidate.match.away.name,
                                leagueName: candidate.leagueName,
                                date: candidate.match.startDate,
                                sport: candidate.sport
                            )
                        }
                    }
                }
                var out: [HubHighlight] = []
                for await items in group { out += items }
                return out
            }
            highlights += batchResults
        }
        return highlights
    }

    private static func dayParameter(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}
