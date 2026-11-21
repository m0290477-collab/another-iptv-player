import Foundation

// Build 86: soccer player photos from FREE, key-less public
// sources — the owner's order after build 85 measured ESPN's
// own soccer coverage (site rosters: 2/31 Arsenal and 2/34
// Hearts athletes carry a headshot href; the CDN pattern
// resolves for a small minority). NBA and MLB photos come
// from ESPN and are NOT touched by anything in this file.
//
// The fallback chain wired into `PlayerPhotoDisc` for SOCCER
// surfaces only (squad rows, lineups, leaders, player page,
// player search), after the ESPN href / CDN pattern the data
// layer already resolved:
//   1. Fantasy Premier League (eng.1 only): the official PL
//      photo by player `code`, from the key-less
//      bootstrap-static payload — ONE cached fetch resolves a
//      whole squad, where Wikidata would cost dozens of
//      per-player queries (performance guard).
//   2. Wikidata / Wikipedia — the build-80 cast discipline:
//      a photo is used ONLY when exactly ONE candidate passes
//      every gate (human, association-football occupation,
//      normalized name match, an image) AND a corroborating
//      fact agrees (team membership P54, or date of birth
//      P569, or — when the entity carries no team claims —
//      citizenship P27). Ambiguity resolves to NO photo.
//   3. TheSportsDB (their sanctioned free test key "123" —
//      the retired key "3" answers 403 directing free users
//      to it; verified live 2026-11-21): name match AND team
//      corroboration (strTeam vs the ESPN team, normalized;
//      date of birth / nationality substitute only when the
//      record carries no team), exactly one candidate, a real
//      photo field (strCutout → strThumb → strRender).
//   4. The monogram (unchanged).
//
// A wrong person's photo is a worse failure than a monogram —
// every gate fails closed. PHOTO results persist in
// UserDefaults keyed by athlete id, so a player with a photo
// is resolved at most once, ever, until eviction; lookups run
// lazily per visible row, in flight-deduped, at most four at
// a time, and never block rendering.
//
// Build 90 (SP9): NO-PHOTO results no longer persist forever.
// A negative recorded today may be wrong next month — a
// Wikipedia article gets an infobox image, a Wikidata item
// gains P18, a squad turns over — so a negative now carries
// a 7-day TTL: after it lapses the chain runs again and the
// coverage can grow. (Build 86's 77% was frozen by the old
// permanent negatives.)
//
// Build 90 (SP11): between the FPL step and the per-player
// Wikidata search sits a CLUB BATCH step — one SPARQL query
// per club returns every Wikidata player with a P54
// membership of that club AND a P18 image (verified live
// 2026-11-21: Arsenal Q9617 → 463 bindings / 444 distinct
// players, each with image + date of birth). Club membership
// in the payload IS the team corroboration; the name gate
// stays exact-normalized, two entities sharing one normalized
// name in a club are ambiguous and excluded, and when both
// the query and the entity carry a date of birth they must
// agree. One query replaces dozens of per-player searches
// for the common case (a whole squad page opening at once).

/// Everything a soccer surface knows about the player whose
/// photo is missing — the resolver's corroboration inputs.
struct SoccerPhotoQuery {
    let athleteId: String
    let name: String
    let teamName: String?
    let leaguePath: String?
    let citizenship: String?
    /// ESPN's date string ("1994-10-03T07:00Z") or plain date;
    /// only the leading YYYY-MM-DD is compared.
    let dateOfBirth: String?
}

actor SoccerPhotoResolver {
    static let shared = SoccerPhotoResolver()

    /// Positive results only (athlete id → photo URL string).
    private var cache: [String: String]
    /// Build 90 (SP9): no-photo results with the epoch second
    /// they were recorded; a negative older than the TTL is
    /// re-resolved instead of served.
    private var negatives: [String: TimeInterval]
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var slots = 4
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var fplData: Data?
    private var fplTask: Task<Data?, Never>?
    /// Build 90 (SP11): club photo maps (normalized team name
    /// → normalized player name → photo), session-cached and
    /// in-flight deduped, one SPARQL query per club.
    private var clubMaps: [String: [String: ClubPhoto]] = [:]
    private var clubTasks: [String: Task<[String: ClubPhoto], Never>] = [:]

    private static let cacheKey = "soccerphoto.cache.v1"
    private static let negativesKey = "soccerphoto.negatives.v1"
    /// Seven days: long enough that a squad page doesn't
    /// re-run the chain on every open, short enough that new
    /// photos surface within a week of appearing upstream.
    private static let negativeTTL: TimeInterval = 7 * 24 * 60 * 60
    private static let footballerOccupation = "Q937857"

    /// One club-batch hit: the Commons image URL and the
    /// entity's date of birth (leading YYYY-MM-DD) when the
    /// payload carries one.
    private struct ClubPhoto {
        let url: URL
        let dateOfBirth: String?
    }

    init() {
        var stored = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: String] ?? [:]
        var storedNegatives = UserDefaults.standard.dictionary(forKey: Self.negativesKey) as? [String: TimeInterval] ?? [:]
        // Migration: the pre-SP9 cache stored negatives as
        // empty strings with no timestamp. They become TTL
        // negatives stamped NOW — no re-resolution storm on
        // upgrade, and they lapse a week later like any other.
        let legacyNegatives = stored.filter { $0.value.isEmpty }.map { $0.key }
        if !legacyNegatives.isEmpty {
            let now = Date().timeIntervalSince1970
            for key in legacyNegatives {
                stored[key] = nil
                if storedNegatives[key] == nil { storedNegatives[key] = now }
            }
            UserDefaults.standard.set(stored, forKey: Self.cacheKey)
            UserDefaults.standard.set(storedNegatives, forKey: Self.negativesKey)
        }
        cache = stored
        negatives = storedNegatives
    }

    /// The verified fallback photo URL for a soccer player, or
    /// nil (the monogram stays).
    func photo(for query: SoccerPhotoQuery) async -> URL? {
        let key = query.athleteId.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !query.name.isEmpty else { return nil }
        if let cached = cache[key], !cached.isEmpty {
            return URL(string: cached)
        }
        if let stamped = negatives[key],
           Date().timeIntervalSince1970 - stamped < Self.negativeTTL {
            return nil
        }
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task<URL?, Never> { await self.resolve(query) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            cache[key] = result.absoluteString
            negatives[key] = nil
            UserDefaults.standard.set(cache, forKey: Self.cacheKey)
            UserDefaults.standard.set(negatives, forKey: Self.negativesKey)
        } else {
            negatives[key] = Date().timeIntervalSince1970
            UserDefaults.standard.set(negatives, forKey: Self.negativesKey)
        }
        return result
    }

    // MARK: - Concurrency cap (max 4 resolutions in flight)

    private func acquire() async {
        if slots > 0 { slots -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { slots += 1 }
        else { waiters.removeFirst().resume() }
    }

    // MARK: - The chain

    private func resolve(_ query: SoccerPhotoQuery) async -> URL? {
        await acquire()
        defer { release() }
        if query.leaguePath == "soccer/eng.1", let url = await fplPhoto(query) {
            return url
        }
        if let url = await clubBatchPhoto(query) {
            return url
        }
        if let url = await wikidataPhoto(query) {
            return url
        }
        if let url = await sportsDBPhoto(query) {
            return url
        }
        return nil
    }

    // MARK: - Step 1: Fantasy Premier League (eng.1 only)

    private struct FPLWire: Decodable {
        struct Team: Decodable { let id: Int; let name: String?; let shortName: String?
            enum CodingKeys: String, CodingKey { case id, name; case shortName = "short_name" } }
        struct Element: Decodable { let firstName: String?; let secondName: String?
            let team: Int?; let code: Int?
            enum CodingKeys: String, CodingKey {
                case firstName = "first_name"; case secondName = "second_name"; case team, code
            } }
        let teams: [Team]?
        let elements: [Element]?
    }

    private func fplPayload() async -> FPLWire? {
        if let fplData, let wire = try? JSONDecoder().decode(FPLWire.self, from: fplData) {
            return wire
        }
        if let task = fplTask {
            guard let data = await task.value else { return nil }
            return try? JSONDecoder().decode(FPLWire.self, from: data)
        }
        let task = Task<Data?, Never> {
            let url = URL(string: "https://fantasy.premierleague.com/api/bootstrap-static/")!
            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                SportsDiskCache.save(key: "fpl|bootstrap", data: data)
                return data
            }
            return SportsDiskCache.load(key: "fpl|bootstrap")?.data
        }
        fplTask = task
        let data = await task.value
        fplTask = nil
        fplData = data
        guard let data else { return nil }
        return try? JSONDecoder().decode(FPLWire.self, from: data)
    }

    private func fplPhoto(_ query: SoccerPhotoQuery) async -> URL? {
        guard let wire = await fplPayload(),
              let teamName = query.teamName, !teamName.isEmpty else { return nil }
        let teamsById = Dictionary(uniqueKeysWithValues: (wire.teams ?? []).map { ($0.id, $0) })
        let wanted = Self.normName(query.name)
        var hits: [FPLWire.Element] = []
        for element in wire.elements ?? [] {
            let full = [element.firstName, element.secondName]
                .compactMap { $0 }.joined(separator: " ")
            guard Self.normName(full) == wanted,
                  let teamId = element.team, let team = teamsById[teamId]
            else { continue }
            if Self.teamMatch(team.name ?? "", teamName)
                || Self.teamMatch(team.shortName ?? "", teamName) {
                hits.append(element)
            }
        }
        guard hits.count == 1, let code = hits[0].code else { return nil }
        return URL(string: "https://resources.premierleague.com/premierleague/photos/players/110x140/p\(code).png")
    }

    // MARK: - Step 1.5: Wikidata club batch (build 90, SP11)

    /// The club-batch step: the player's club is resolved to
    /// exactly ONE Wikidata entity whose label team-matches
    /// the ESPN team name, then ONE SPARQL query returns every
    /// player with a P54 membership of that club and a P18
    /// image. The map is intersected with the squad by
    /// normalized name. Gates: P54 membership of THIS club is
    /// the team corroboration (the payload's own claim, not a
    /// text guess); two entities sharing one normalized name
    /// in the same club are ambiguous and excluded; when both
    /// sides carry a date of birth they must agree — a
    /// mismatch means a different person and the chain falls
    /// through to the per-player steps rather than failing.
    private func clubBatchPhoto(_ query: SoccerPhotoQuery) async -> URL? {
        guard let teamName = query.teamName, !teamName.isEmpty else { return nil }
        let map = await clubPhotoMap(teamName: teamName)
        guard let hit = map[Self.normName(query.name)] else { return nil }
        if let queryDob = query.dateOfBirth, queryDob.count >= 10,
           let entityDob = hit.dateOfBirth {
            guard String(queryDob.prefix(10)) == entityDob else { return nil }
        }
        return hit.url
    }

    private func clubPhotoMap(teamName: String) async -> [String: ClubPhoto] {
        let key = Self.normName(teamName)
        if let cached = clubMaps[key] { return cached }
        if let task = clubTasks[key] { return await task.value }
        let task = Task<[String: ClubPhoto], Never> {
            await self.fetchClubPhotoMap(teamName: teamName)
        }
        clubTasks[key] = task
        let map = await task.value
        clubTasks[key] = nil
        clubMaps[key] = map
        return map
    }

    private func fetchClubPhotoMap(teamName: String) async -> [String: ClubPhoto] {
        guard let clubId = await wikidataClubId(teamName: teamName) else { return [:] }
        let sparql = """
            SELECT ?player ?playerLabel ?image ?dob WHERE {
              ?player wdt:P54 wd:\(clubId); wdt:P18 ?image.
              OPTIONAL { ?player wdt:P569 ?dob. }
              SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
            }
            """
        guard let data = await fetchSPARQL(sparql),
              let wire = try? JSONDecoder().decode(SPARQLResponse.self, from: data)
        else { return [:] }
        var map: [String: ClubPhoto] = [:]
        var ambiguous = Set<String>()
        var seenEntities: [String: String] = [:]
        for binding in wire.results.bindings {
            guard let label = binding.playerLabel?.value, !label.isEmpty,
                  let image = binding.image?.value, !image.isEmpty,
                  let entity = binding.player?.value, !entity.isEmpty
            else { continue }
            let nameKey = Self.normName(label)
            guard !nameKey.isEmpty else { continue }
            if let previous = seenEntities[nameKey], previous != entity {
                ambiguous.insert(nameKey)
                continue
            }
            seenEntities[nameKey] = entity
            let dob = binding.dob?.value.flatMap { value -> String? in
                let trimmed = value.hasPrefix("+") ? String(value.dropFirst()) : value
                guard trimmed.count >= 10 else { return nil }
                return String(trimmed.prefix(10))
            }
            let separator = image.contains("?") ? "&" : "?"
            if let url = URL(string: "\(image)\(separator)width=200") {
                map[nameKey] = ClubPhoto(url: url, dateOfBirth: dob)
            }
        }
        for nameKey in ambiguous { map[nameKey] = nil }
        return map
    }

    /// The ONE Wikidata entity for a club name: search
    /// candidates whose English label team-matches the ESPN
    /// name; ambiguity (or none) resolves to no batch step.
    private func wikidataClubId(teamName: String) async -> String? {
        guard let searchData = await fetchJSON(
            "https://www.wikidata.org/w/api.php?action=wbsearchentities&search=\(Self.encode(teamName))&language=en&format=json&limit=5"
        ),
        let search = try? JSONDecoder().decode(WikiSearchResponse.self, from: searchData)
        else { return nil }
        let candidateIds = search.search.map(\.id).filter { !$0.isEmpty }
        guard !candidateIds.isEmpty else { return nil }
        guard let labelData = await fetchJSON(
            "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=\(candidateIds.joined(separator: "%7C"))&props=labels&languages=en&format=json"
        ),
        let entities = (try? JSONDecoder().decode(WikiEntitiesResponse.self, from: labelData))?.entities
        else { return nil }
        let matching = candidateIds.filter { id in
            guard let label = entities[id]?.labels["en"]?.value else { return false }
            return Self.teamMatch(label, teamName)
        }
        guard matching.count == 1 else { return nil }
        return matching.first
    }

    private func fetchSPARQL(_ query: String) async -> Data? {
        var components = URLComponents(string: "https://query.wikidata.org/sparql")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return data
    }

    // MARK: - Step 2: Wikidata / Wikipedia

    private func wikidataPhoto(_ query: SoccerPhotoQuery) async -> URL? {
        guard let searchData = await fetchJSON(
            "https://www.wikidata.org/w/api.php?action=wbsearchentities&search=\(Self.encode(query.name))&language=en&format=json&limit=5"
        ),
        let search = try? JSONDecoder().decode(WikiSearchResponse.self, from: searchData) else {
            return nil
        }
        let candidateIds = search.search.map(\.id).filter { !$0.isEmpty }
        guard !candidateIds.isEmpty else { return nil }
        guard let entitiesData = await fetchJSON(
            "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=\(candidateIds.joined(separator: "%7C"))&props=claims%7Cdescriptions%7Csitelinks%7Clabels%7Caliases&languages=en&format=json"
        ),
        let entities = (try? JSONDecoder().decode(WikiEntitiesResponse.self, from: entitiesData))?.entities
        else { return nil }

        // Labels for every team / country entity the candidates
        // reference — one batched call, used only to corroborate.
        var corrIds = Set<String>()
        for id in candidateIds {
            guard let entity = entities[id] else { continue }
            corrIds.formUnion(Self.claimEntityIds(entity, "P54"))
            corrIds.formUnion(Self.claimEntityIds(entity, "P27"))
        }
        var corrLabels: [String: String] = [:]
        if !corrIds.isEmpty,
           let labelData = await fetchJSON(
               "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=\(corrIds.sorted().joined(separator: "%7C"))&props=labels&languages=en&format=json"
           ),
           let labelEntities = (try? JSONDecoder().decode(WikiEntitiesResponse.self, from: labelData))?.entities {
            for (id, entity) in labelEntities {
                if let label = entity.labels["en"]?.value { corrLabels[id] = label }
            }
        }

        var qualifying: [URL] = []
        for id in candidateIds {
            guard let entity = entities[id],
                  let url = await verifiedFootballerPhoto(entity: entity, query: query, corrLabels: corrLabels)
            else { continue }
            qualifying.append(url)
        }
        // The guard: exactly ONE fully-verified footballer may
        // supply the photo; ambiguity resolves to NO photo.
        guard qualifying.count == 1 else { return nil }
        return qualifying.first
    }

    /// Verifies one candidate entity and returns its photo URL
    /// when it is THE player: human, footballer, name match,
    /// a corroborating fact, and an image (P18 first; the
    /// enwiki lead image of the same entity as fallback).
    private func verifiedFootballerPhoto(
        entity: WikiEntitiesResponse.Entity,
        query: SoccerPhotoQuery,
        corrLabels: [String: String]
    ) async -> URL? {
        // Person gate: instance of Q5 (human).
        guard Self.claimEntityIds(entity, "P31").contains("Q5") else { return nil }
        // Footballer gate: the association-football occupation,
        // or an English description that says footballer.
        let occupations = Set(Self.claimEntityIds(entity, "P106"))
        let description = entity.descriptions["en"]?.value.lowercased() ?? ""
        guard occupations.contains(Self.footballerOccupation)
            || description.contains("footballer") || description.contains("soccer player")
        else { return nil }
        // Name gate: the entity label or one of its aliases
        // must equal the ESPN name after normalization.
        let wanted = Self.normName(query.name)
        let label = entity.labels["en"]?.value ?? ""
        let aliases = (entity.aliases["en"] ?? []).map { $0.value }
        guard Self.normName(label) == wanted
            || aliases.contains(where: { Self.normName($0) == wanted })
        else { return nil }
        // Corroboration: at least one comparable fact agrees.
        guard Self.corroborates(entity: entity, query: query, corrLabels: corrLabels)
        else { return nil }
        // Image: P18 → Wikimedia Commons file path.
        if let fileName = entity.claims["P18"]?.first?.mainsnak.datavalue?.stringValue,
           !fileName.isEmpty {
            let encoded = Self.encode(fileName.replacingOccurrences(of: " ", with: "_"))
            return URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width=200")
        }
        // Fallback: the SAME entity's English Wikipedia article
        // lead image (identity stays anchored to the verified
        // entity — no new wrong-person risk).
        if let title = entity.sitelinks["enwiki"]?.title, !title.isEmpty {
            let encoded = Self.encode(title.replacingOccurrences(of: " ", with: "_"))
            if let summaryData = await fetchJSON("https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)"),
               let summary = try? JSONDecoder().decode(WikiSummaryResponse.self, from: summaryData),
               summary.type != "disambiguation",
               let thumb = summary.thumbnail?.source, !thumb.isEmpty {
                return URL(string: thumb)
            }
        }
        return nil
    }

    /// The corroboration rule, exactly as measured: a team
    /// (P54) match OR a date-of-birth (P569) match qualifies;
    /// citizenship (P27) qualifies only when the entity carries
    /// no team claims to compare. When the surface supplied NO
    /// inputs at all (player search), a lone candidate passing
    /// the identity gates qualifies; when inputs exist but no
    /// fact is comparable, the candidate fails closed.
    private static func corroborates(
        entity: WikiEntitiesResponse.Entity,
        query: SoccerPhotoQuery,
        corrLabels: [String: String]
    ) -> Bool {
        let teamIds = claimEntityIds(entity, "P54")
        var teamComparable = false
        if let teamName = query.teamName, !teamName.isEmpty, !teamIds.isEmpty {
            teamComparable = true
            if teamIds.contains(where: { id in
                guard let label = corrLabels[id] else { return false }
                return teamMatch(label, teamName)
            }) { return true }
        }
        if let dob = query.dateOfBirth, dob.count >= 10,
           let born = entity.claims["P569"]?.first?.mainsnak.datavalue?.timeValue {
            if born.hasPrefix("+"), String(born.dropFirst().prefix(10)) == String(dob.prefix(10)) {
                return true
            }
        }
        if !teamComparable,
           let citizenship = query.citizenship, !citizenship.isEmpty {
            let countryIds = claimEntityIds(entity, "P27")
            if countryIds.contains(where: { id in
                guard let label = corrLabels[id] else { return false }
                return normName(label) == normName(citizenship)
            }) { return true }
        }
        let hasInputs = (query.teamName?.isEmpty == false)
            || (query.citizenship?.isEmpty == false)
            || (query.dateOfBirth?.isEmpty == false)
        return !hasInputs
    }

    // MARK: - Step 3: TheSportsDB

    private struct TSDBPlayersWire: Decodable {
        struct Player: Decodable {
            let strPlayer: String?
            let strTeam: String?
            let strSport: String?
            let strCutout: String?
            let strThumb: String?
            let strRender: String?
            let strNationality: String?
            let dateBorn: String?
        }
        let player: [Player]?
    }

    private func sportsDBPhoto(_ query: SoccerPhotoQuery) async -> URL? {
        guard let data = await fetchJSON(
            "\(Self.sportsDBBase)/searchplayers.php?p=\(Self.encode(query.name))"
        ),
        let wire = try? JSONDecoder().decode(TSDBPlayersWire.self, from: data) else {
            return nil
        }
        let wanted = Self.normName(query.name)
        var hits: [URL] = []
        for player in wire.player ?? [] {
            guard player.strSport == "Soccer",
                  Self.normName(player.strPlayer ?? "") == wanted,
                  Self.sportsDBCorroborates(player: player, query: query),
                  let photo = [player.strCutout, player.strThumb, player.strRender]
                      .compactMap({ $0 }).first(where: { !$0.isEmpty }),
                  let url = URL(string: photo)
            else { continue }
            hits.append(url)
        }
        guard hits.count == 1 else { return nil }
        return hits.first
    }

    /// TheSportsDB corroboration: the record's team must match
    /// the ESPN team (normalized); date of birth / nationality
    /// substitute only when the record carries no team at all.
    private static func sportsDBCorroborates(
        player: TSDBPlayersWire.Player, query: SoccerPhotoQuery
    ) -> Bool {
        if let team = player.strTeam, !team.isEmpty {
            guard let teamName = query.teamName, !teamName.isEmpty else { return false }
            return teamMatch(team, teamName)
        }
        if let born = player.dateBorn, let dob = query.dateOfBirth, dob.count >= 10 {
            return born == String(dob.prefix(10))
        }
        if let nationality = player.strNationality, let citizenship = query.citizenship {
            return normName(nationality) == normName(citizenship)
        }
        return false
    }

    // MARK: - Shared helpers

    fileprivate static let sportsDBBase = "https://www.thesportsdb.com/api/v1/json/123"
    fileprivate static let userAgent = "SuperX/2.4 (iOS; soccer photo lookup)"

    private func fetchJSON(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return data
    }

    private static func claimEntityIds(_ entity: WikiEntitiesResponse.Entity, _ property: String) -> [String] {
        (entity.claims[property] ?? []).compactMap { $0.mainsnak.datavalue?.entityId }
    }

    /// Name folding shared by every gate: case- and
    /// diacritic-insensitive, punctuation becomes spaces.
    static func normName(_ value: String) -> String {
        let folded = value.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
        let mapped = folded.map { char -> String in
            switch char {
            case "ø": return "o"
            case "æ": return "ae"
            case "ß": return "ss"
            case "ł": return "l"
            case "đ": return "d"
            case "þ": return "th"
            case "ð": return "d"
            case "ı": return "i"
            default: return String(char)
            }
        }.joined()
        let parts = mapped.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return parts.joined(separator: " ")
    }

    private static let teamStopwords: Set<String> = [
        "fc", "afc", "cf", "sc", "rc", "cd", "club", "of", "the", "de", "football", "fk", "sk", "ac", "as",
    ]
    private static let teamAliases: [String: String] = [
        "man city": "manchester city", "man utd": "manchester united",
        "spurs": "tottenham hotspur", "wolves": "wolverhampton wanderers",
        "brighton": "brighton hove albion", "west ham": "west ham united",
        "newcastle": "newcastle united", "leeds": "leeds united",
        "nott m forest": "nottingham forest", "forest": "nottingham forest",
        "sheffield utd": "sheffield united", "qpr": "queens park rangers",
    ]

    static func teamTokens(_ value: String) -> Set<String> {
        let normalized = normName(teamAliases[normName(value)] ?? value)
        var tokens = Set<String>()
        for token in normalized.split(separator: " ") {
            var word = String(token)
            if teamStopwords.contains(word) { continue }
            if word.count > 3, word.hasSuffix("s") { word.removeLast() }
            tokens.insert(word)
        }
        return tokens
    }

    /// Two team names match when their distinctive token sets
    /// are equal or one contains the other ("Hearts" ⊂ "Heart
    /// of Midlothian"; "Arsenal" == "Arsenal F.C.").
    static func teamMatch(_ a: String, _ b: String) -> Bool {
        let ta = teamTokens(a)
        let tb = teamTokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        if ta == tb { return true }
        let (small, big) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        guard small.isSubset(of: big) else { return false }
        if small.count == 1, let only = small.first, only.count < 4 { return false }
        return true
    }

    fileprivate static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

// MARK: - TheSportsDB team / player text (owner scope extension)
//
// Additive text for soccer pages from the same verified free
// source: a club's stadium name + description on the team
// page, and a player's biography on the player page. The
// stadium PHOTO field does not exist in the current free
// payload (verified 2026-11-21: searchteams returns strStadium
// and strDescriptionEN but no stadium-thumb field), so no
// photo is shown for it — fanart is never mislabeled as a
// stadium photo. Identity discipline is the photo chain's:
// exact normalized name match (plus team corroboration for
// players), exactly one record.

enum SportsDBService {
    struct TeamDetails {
        let stadium: String?
        let descriptionText: String?
    }

    private struct TeamsWire: Decodable {
        struct Team: Decodable {
            let strTeam: String?
            let strSport: String?
            let strStadium: String?
            let strDescriptionEN: String?
        }
        let teams: [Team]?
    }

    private struct PlayersWire: Decodable {
        struct Player: Decodable {
            let strPlayer: String?
            let strTeam: String?
            let strSport: String?
            let strDescriptionEN: String?
        }
        let player: [Player]?
    }

    private final class SessionCache: @unchecked Sendable {
        static let shared = SessionCache()
        private let lock = NSLock()
        private var teams: [String: TeamDetails?] = [:]
        private var bios: [String: String?] = [:]
        func team(_ key: String) -> TeamDetails?? {
            lock.lock(); defer { lock.unlock() }
            return teams[key]
        }
        func putTeam(_ key: String, _ value: TeamDetails?) {
            lock.lock(); defer { lock.unlock() }
            // updateValue, not subscript assignment: a nil
            // VALUE here is a cached negative and must be
            // stored, not treated as a key removal.
            teams.updateValue(value, forKey: key)
        }
        func bio(_ key: String) -> String?? {
            lock.lock(); defer { lock.unlock() }
            return bios[key]
        }
        func putBio(_ key: String, _ value: String?) {
            lock.lock(); defer { lock.unlock() }
            bios.updateValue(value, forKey: key)
        }
    }

    static func teamDetails(teamName: String) async -> TeamDetails? {
        await teamDetails(teamName: teamName, expectedSport: "Soccer")
    }

    /// Build 87 (item 9): the same verified lookup for the
    /// other sports' team pages — TheSportsDB carries NBA /
    /// NFL / MLB / NHL clubs with the same stadium +
    /// description fields (verified live 2026-11-21: Lakers →
    /// "Crypto.com Arena" + 3,058-char description; Maple
    /// Leafs → "Scotiabank Arena" + 1,586 chars). The identity
    /// discipline is unchanged: the record's sport must equal
    /// `expectedSport` (TheSportsDB's own sport names:
    /// "Basketball", "American Football", "Baseball",
    /// "Ice Hockey"), the normalized name must match exactly,
    /// and exactly one record may qualify. The free payload
    /// still carries NO stadium-photo field (re-verified
    /// 2026-11-21 — fanart fields exist and are never shown
    /// as a stadium photo).
    static func teamDetails(teamName: String, expectedSport: String) async -> TeamDetails? {
        let key = SoccerPhotoResolver.normName(teamName) + "|" + expectedSport
        guard !key.isEmpty else { return nil }
        if let cached = SessionCache.shared.team(key) { return cached }
        var result: TeamDetails?
        if let data = await fetch(
            "\(SoccerPhotoResolver.sportsDBBase)/searchteams.php?t=\(SoccerPhotoResolver.encode(teamName))"
        ),
        let wire = try? JSONDecoder().decode(TeamsWire.self, from: data) {
            let nameKey = SoccerPhotoResolver.normName(teamName)
            let matches = (wire.teams ?? []).filter {
                $0.strSport == expectedSport
                    && SoccerPhotoResolver.normName($0.strTeam ?? "") == nameKey
            }
            if matches.count == 1 {
                let stadium = matches[0].strStadium?.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = matches[0].strDescriptionEN?.trimmingCharacters(in: .whitespacesAndNewlines)
                result = TeamDetails(
                    stadium: (stadium?.isEmpty == false) ? stadium : nil,
                    descriptionText: (text?.isEmpty == false) ? text : nil
                )
            }
        }
        SessionCache.shared.putTeam(key, result)
        return result
    }

    static func playerBio(name: String, teamName: String?) async -> String? {
        let key = SoccerPhotoResolver.normName(name) + "|"
            + SoccerPhotoResolver.normName(teamName ?? "")
        if let cached = SessionCache.shared.bio(key) { return cached }
        var result: String?
        if let data = await fetch(
            "\(SoccerPhotoResolver.sportsDBBase)/searchplayers.php?p=\(SoccerPhotoResolver.encode(name))"
        ),
        let wire = try? JSONDecoder().decode(PlayersWire.self, from: data) {
            let wanted = SoccerPhotoResolver.normName(name)
            let matches = (wire.player ?? []).filter { player in
                guard player.strSport == "Soccer",
                      SoccerPhotoResolver.normName(player.strPlayer ?? "") == wanted
                else { return false }
                if let team = player.strTeam, !team.isEmpty,
                   let teamName, !teamName.isEmpty {
                    return SoccerPhotoResolver.teamMatch(team, teamName)
                }
                return teamName == nil
            }
            if matches.count == 1 {
                let text = matches[0].strDescriptionEN?.trimmingCharacters(in: .whitespacesAndNewlines)
                result = (text?.isEmpty == false) ? text : nil
            }
        }
        SessionCache.shared.putBio(key, result)
        return result
    }

    private static func fetch(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(SoccerPhotoResolver.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return data
    }
}

// MARK: - Wire models (defensive, all optional where the API varies)

private struct WikiSearchResponse: Decodable {
    struct Hit: Decodable { let id: String }
    let search: [Hit]
}

private struct WikiEntitiesResponse: Decodable {
    struct Entity: Decodable {
        struct Claim: Decodable {
            struct Snak: Decodable {
                /// A claim's datavalue: entity-valued claims
                /// (P31, P106, P54, P27) carry an object with an
                /// id; P18 carries a plain string (the Commons
                /// file name); P569 carries an object with a
                /// time string. Decode leniently into slots.
                struct DataValue: Decodable {
                    struct ObjectValue: Decodable { let id: String?; let time: String? }
                    let entityId: String?
                    let stringValue: String?
                    let timeValue: String?
                    enum CodingKeys: String, CodingKey { case value }
                    init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        if let text = try? container.decode(String.self, forKey: .value) {
                            stringValue = text
                            entityId = nil
                            timeValue = nil
                        } else if let object = try? container.decode(ObjectValue.self, forKey: .value) {
                            entityId = object.id
                            timeValue = object.time
                            stringValue = nil
                        } else {
                            stringValue = nil
                            entityId = nil
                            timeValue = nil
                        }
                    }
                }
                let datavalue: DataValue?
            }
            let mainsnak: Snak
        }
        struct Term: Decodable { let value: String }
        struct Sitelink: Decodable { let title: String? }
        let claims: [String: [Claim]]
        let descriptions: [String: Term]
        let labels: [String: Term]
        let aliases: [String: [Term]]
        let sitelinks: [String: Sitelink]

        enum CodingKeys: String, CodingKey { case claims, descriptions, labels, aliases, sitelinks }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Missing pieces decode as empty — the gates then
            // simply fail closed (no photo) for that entity.
            claims = try container.decodeIfPresent([String: [Claim]].self, forKey: .claims) ?? [:]
            descriptions = try container.decodeIfPresent([String: Term].self, forKey: .descriptions) ?? [:]
            labels = try container.decodeIfPresent([String: Term].self, forKey: .labels) ?? [:]
            aliases = try container.decodeIfPresent([String: [Term]].self, forKey: .aliases) ?? [:]
            sitelinks = try container.decodeIfPresent([String: Sitelink].self, forKey: .sitelinks) ?? [:]
        }
    }
    let entities: [String: Entity]
}

private struct WikiSummaryResponse: Decodable {
    struct Thumbnail: Decodable { let source: String? }
    let type: String?
    let thumbnail: Thumbnail?
}

/// Build 90 (SP11): the SPARQL results shape — every field a
/// binding carries arrives as a {type, value} term.
private struct SPARQLResponse: Decodable {
    struct Results: Decodable {
        struct Binding: Decodable {
            struct Term: Decodable { let value: String? }
            let player: Term?
            let playerLabel: Term?
            let image: Term?
            let dob: Term?
        }
        let bindings: [Binding]
    }
    let results: Results
}
