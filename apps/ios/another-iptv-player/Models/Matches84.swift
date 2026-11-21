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
        }
    }

    /// Headshot CDN segment (the a.espncdn.com pattern).
    static func headshotSegment(for sport: MatchSport) -> String {
        switch sport {
        case .soccer: return "soccer"
        case .nba: return "nba"
        case .nfl: return "nfl"
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
        }
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

// MARK: - League leaders (item 7)

struct LeaderRow84: Identifiable {
    let athleteId: String
    let name: String
    let teamName: String?
    let valueText: String
    let headshotURL: URL?
    var id: String { athleteId }
}

struct LeaderCategory84: Identifiable {
    let name: String
    let displayName: String
    var id: String { name }
}

/// Season leaders from the CORE api, all categories in ONE
/// payload per league (verified live 2026-11-21: soccer carries
/// goalsLeaders AND assistsLeaders; the NBA payload carries
/// pointsPerGame / assistsPerGame / reboundsPerGame; the NFL
/// payload carries passingYards / rushingYards /
/// receivingYards). The view offers exactly the categories the
/// payload returned — a category ESPN doesn't publish for a
/// league simply never appears.
enum MatchesLeadersService {
    /// The categories this build surfaces, per sport — every
    /// one of them confirmed present in the live payload.
    static func surfacedCategories(sport: MatchSport) -> [String] {
        switch sport {
        case .soccer: return ["goalsLeaders", "assistsLeaders"]
        case .nba: return ["pointsPerGame", "assistsPerGame", "reboundsPerGame"]
        case .nfl: return ["passingYards", "rushingYards", "receivingYards"]
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
        let season = CoreCoordinates.season(for: sport)
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
            let leaders = Array((category.leaders ?? []).prefix(15))
            let mapped = await withTaskGroup(of: LeaderRow84?.self) { group in
                for leader in leaders {
                    group.addTask {
                        guard let ref = leader.athlete?.ref,
                              let athleteId = ref.split(separator: "/").last?.split(separator: "?").first.map(String.init),
                              let athleteName = await CoreDeref.name(ref) else { return nil }
                        let teamName = await leader.team?.ref.asyncFlatMap84 { await CoreDeref.name($0) }
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
            // the numeric value the payload carried.
            var values: [String: Double] = [:]
            for leader in leaders {
                guard let ref = leader.athlete?.ref,
                      let id = ref.split(separator: "/").last?.split(separator: "?").first.map(String.init)
                else { continue }
                values[id] = leader.value ?? 0
            }
            rows[name] = mapped.sorted { (values[$0.athleteId] ?? 0) > (values[$1.athleteId] ?? 0) }
        }
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
        let season = CoreCoordinates.season(for: sport)
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
                              let athleteName = await CoreDeref.name(ref) else { return nil }
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
            if !rows.isEmpty {
                output.append((category: category.displayName ?? category.name ?? "", rows: rows))
            }
            if output.count >= 4 { break }
        }
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
    let headshotURL: URL?
    let teamId: String?
    let teamName: String?
    let teamLogoURL: URL?
    let statLines: [(label: String, value: String)]
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
        let headshot: Headshot?
        let team: Ref?
        let statistics: Ref?
        let events: Ref?
        struct Position: Decodable { let displayName: String?; let name: String? }
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
                SessionCache.shared.put(cacheKey, profile)
                return profile
            }
        }
        return nil
    }

    private static func fetchScoped(sport: MatchSport, slug: String, athleteId: String) async -> PlayerProfile? {
        let season = CoreCoordinates.season(for: sport)
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
            headshotURL: CoreCoordinates.headshotURL(sport: sport, athleteId: athleteId, href: athlete.headshot?.href),
            teamId: teamId,
            teamName: team?.name,
            teamLogoURL: team?.logoURL,
            statLines: await stats,
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
    private static func fetchStats(ref: String?) async -> [(label: String, value: String)] {
        guard let ref, let url = URL(string: ref) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let wire = try? JSONDecoder().decode(StatsWire.self, from: data)
        else { return [] }
        var lines: [(label: String, value: String)] = []
        for category in wire.splits?.categories ?? [] {
            for stat in category.stats ?? [] {
                guard let value = stat.displayValue, !value.isEmpty else { continue }
                let statName = (stat.name ?? "").lowercased()
                if statName.contains("rating") { continue }
                lines.append((label: stat.displayName ?? stat.name ?? "", value: value))
                if lines.count >= 16 { return lines }
            }
        }
        return lines
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
            case .nba, .nfl:
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
        case .nba, .nfl:
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
                let pct = Double(wins) / Double(total)
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

    func set(match: MatchEvent, leaguePath: String, sport: MatchSport, enabled: Bool) {
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
    /// type note).
    var payload: [[String: Any]] {
        reminders.map {
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

struct HubHighlight: Identifiable {
    let video: MatchVideo
    let homeName: String?
    let awayName: String?
    let leagueName: String?
    let date: Date?
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
    /// All 19 competitions: the 17-league soccer catalog plus
    /// the NFL and NBA.
    static var allCompetitions: [(sport: MatchSport, leaguePath: String)] {
        MatchSport.soccerLeagueCatalog.map { (sport: MatchSport.soccer, leaguePath: $0.leaguePath) }
            + [(sport: MatchSport.nfl, leaguePath: "football/nfl"),
               (sport: MatchSport.nba, leaguePath: "basketball/nba")]
    }

    static func liveNow() async -> [LiveNowGroup] {
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
        return groups.sorted { (order[$0.leaguePath] ?? 0) < (order[$1.leaguePath] ?? 0) }
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
        let calendar = Calendar.current
        let days = [Date(), calendar.date(byAdding: .day, value: -1, to: Date())].compactMap { $0 }
        var candidates: [(sport: MatchSport, leaguePath: String, leagueName: String?, match: MatchEvent)] = []
        for day in days {
            let parameter = dayParameter(for: day)
            let perLeague = await withTaskGroup(
                of: [(sport: MatchSport, leaguePath: String, leagueName: String?, match: MatchEvent)].self
            ) { group in
                for competition in allCompetitions {
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
                                date: candidate.match.startDate
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
