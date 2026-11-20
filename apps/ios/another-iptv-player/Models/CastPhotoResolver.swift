import Foundation

/// Build 80 (item 10): cast photos from FREE, key-less public
/// sources — Wikidata + Wikipedia — at the owner's decision
/// (provider cast data carries names only, so detail pages showed
/// monograms).
///
/// Resolution for one name:
///  1. `wbsearchentities` finds candidate entities for the name.
///  2. Each candidate is verified through `wbgetentities`
///     (claims + enwiki sitelink):
///       - instance of (P31) must include Q5 (human), AND
///       - occupation (P106) must include an acting occupation
///         (Q33999 actor, Q10800557 film actor, Q2259451 stage
///         actor) or the English description must say actor/
///         actress, AND
///       - an image must exist: P18 (Wikimedia Commons file), or
///         the enwiki article's lead thumbnail as the fallback for
///         the SAME verified entity.
///  3. WRONG-PERSON GUARD: a photo is used ONLY when exactly ONE
///     candidate passes every check. Zero or 2+ qualifying
///     candidates → NO photo (the monogram stays). A missing photo
///     is acceptable; a wrong person's photo is a defect.
///
/// Results (photo AND no-photo) persist in UserDefaults keyed by
/// the normalized name, so repeat visits never re-query. Lookups
/// run only when a detail page with cast is opened, are deduped
/// in flight, and never block rendering — the cast row shows
/// monograms immediately and swaps photos in as they arrive.
actor CastPhotoResolver {
    static let shared = CastPhotoResolver()

    /// Persistent cache: normalized name → image URL string;
    /// the empty string marks a resolved NO-PHOTO result.
    private var cache: [String: String]
    private var inFlight: [String: Task<URL?, Never>] = [:]

    private static let cacheKey = "castphoto.cache.v1"
    private static let actorOccupations: Set<String> = ["Q33999", "Q10800557", "Q2259451"]

    init() {
        cache = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: String] ?? [:]
    }

    /// The verified photo URL for a cast name, or nil (monogram).
    func photo(for name: String) async -> URL? {
        let key = Self.normalize(name)
        guard !key.isEmpty else { return nil }
        if let cached = cache[key] {
            return cached.isEmpty ? nil : URL(string: cached)
        }
        if let task = inFlight[key] {
            return await task.value
        }
        let queryName = Self.queryName(from: name)
        let task = Task<URL?, Never> { await self.resolve(queryName: queryName) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        cache[key] = result?.absoluteString ?? ""
        UserDefaults.standard.set(cache, forKey: Self.cacheKey)
        return result
    }

    // MARK: - Resolution

    private func resolve(queryName: String) async -> URL? {
        guard let searchData = await fetchJSON(
            "https://www.wikidata.org/w/api.php?action=wbsearchentities&search=\(Self.encode(queryName))&language=en&format=json&limit=5"
        ),
        let search = try? JSONDecoder().decode(WikiSearchResponse.self, from: searchData) else {
            return nil
        }
        let candidateIds = search.search.map(\.id).filter { !$0.isEmpty }
        guard !candidateIds.isEmpty else { return nil }

        var qualifying: [URL] = []
        for id in candidateIds {
            if let url = await verifiedPhoto(entityId: id) {
                qualifying.append(url)
            }
        }
        // The guard: exactly ONE fully-verified person may supply
        // the photo; ambiguity resolves to NO photo.
        guard qualifying.count == 1 else { return nil }
        return qualifying.first
    }

    /// Verifies one entity and returns its photo URL when it is a
    /// human actor WITH an image (P18 first; the enwiki lead image
    /// of the same entity as fallback). Nil otherwise.
    private func verifiedPhoto(entityId: String) async -> URL? {
        guard let data = await fetchJSON(
            "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=\(entityId)&props=claims%7Cdescriptions%7Csitelinks&languages=en&format=json"
        ),
        let response = try? JSONDecoder().decode(WikiEntitiesResponse.self, from: data),
        let entity = response.entities[entityId] else {
            return nil
        }
        // Person gate: instance of Q5 (human).
        guard entity.claims["P31"]?.contains(where: { $0.mainsnak.datavalue?.entityId == "Q5" }) == true else {
            return nil
        }
        // Actor gate: an acting occupation, or an English
        // description that says actor/actress.
        let occupations = Set((entity.claims["P106"] ?? []).compactMap { $0.mainsnak.datavalue?.entityId })
        let description = entity.descriptions["en"]?.value.lowercased() ?? ""
        let isActor = !occupations.isDisjoint(with: Self.actorOccupations)
            || description.contains("actor") || description.contains("actress")
        guard isActor else { return nil }

        // Image: P18 → Wikimedia Commons file path.
        if let fileName = entity.claims["P18"]?.first?.mainsnak.datavalue?.stringValue,
           !fileName.isEmpty {
            let encoded = Self.encode(fileName.replacingOccurrences(of: " ", with: "_"))
            return URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width=224")
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

    // MARK: - Helpers

    private func fetchJSON(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("SuperX/2.4 (iOS; cast photo lookup)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return data
    }

    private static func normalize(_ name: String) -> String {
        name.lowercased()
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The lookup name: provider cast strings sometimes carry a
    /// parenthetical note ("Name (voice)") — query the bare name.
    private static func queryName(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = trimmed.firstIndex(of: "(") {
            return String(trimmed[..<paren]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
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
                /// A claim's datavalue: entity-valued claims (P31,
                /// P106) carry an object with an id; P18 carries a
                /// plain string (the Commons file name). Decode
                /// leniently into one of the two slots.
                struct DataValue: Decodable {
                    struct EntityId: Decodable { let id: String? }
                    let entityId: String?
                    let stringValue: String?
                    enum CodingKeys: String, CodingKey { case value }
                    init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        if let text = try? container.decode(String.self, forKey: .value) {
                            stringValue = text
                            entityId = nil
                        } else if let object = try? container.decode(EntityId.self, forKey: .value) {
                            entityId = object.id
                            stringValue = nil
                        } else {
                            stringValue = nil
                            entityId = nil
                        }
                    }
                }
                let datavalue: DataValue?
            }
            let mainsnak: Snak
        }
        struct Description: Decodable { let value: String }
        struct Sitelink: Decodable { let title: String? }
        let claims: [String: [Claim]]
        let descriptions: [String: Description]
        let sitelinks: [String: Sitelink]

        enum CodingKeys: String, CodingKey { case claims, descriptions, sitelinks }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Missing pieces decode as empty — the gates then
            // simply fail closed (no photo) for that entity.
            claims = try container.decodeIfPresent([String: [Claim]].self, forKey: .claims) ?? [:]
            descriptions = try container.decodeIfPresent([String: Description].self, forKey: .descriptions) ?? [:]
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
