import Foundation

/// The same logic as the GRDB `localized_*` SQL functions (Persistence.swift).
/// Pure stateless namespace — used from detached filtering tasks, so it must not be MainActor.
nonisolated enum CatalogTextSearch {
    private static let foldLocale = Locale(identifier: "en_US_POSIX")
    private static let alphanumericSet = CharacterSet.alphanumerics

    /// Build 66 (item 16): the ONE fold every search path shares —
    /// strict, fuzzy and section alike (previously the Arabic
    /// equivalences below lived only in `sectionFold`, so global
    /// search silently missed Arabic titles that in-section search
    /// found). Locale-invariant fold: tr_TR lowercasing maps "I"→"ı"
    /// and breaks queries like "history" against ALL-CAPS catalog
    /// names ("HISTORY HD" → "hıstory hd"); the "ı"→"i" pass keeps
    /// Turkish dotless-ı queries matching ALL-CAPS Turkish text
    /// ("IŞIK" and "ışık" both normalize to "isik").
    ///
    /// The Arabic equivalences: ة (U+0629) has no canonical
    /// decomposition to ه (U+0647), and ى (U+0649) none to ي
    /// (U+064A) — yet users type ه for ة and ي for ى constantly.
    /// Persian keyboard variants ک (U+06A9) / ی (U+06CC) map to
    /// their Arabic counterparts, and the tatweel (U+0640, category
    /// Lm — it survives the alphanumeric split) is stripped.
    ///
    /// IDEMPOTENT: every replacement's OUTPUT (ه، ي، ك، i) is never
    /// another replacement's INPUT, and the tatweel pass deletes
    /// its only input — so applying this fold (or the equivalence
    /// pass alone) twice is a no-op, and stacking the old section
    /// fold on top changes nothing.
    ///
    /// SQL MIRROR: `Persistence.swift`'s `localized_*` functions
    /// carry their own copy of the pre-66 fold ("must stay in sync"
    /// there). Those SQL requests have no live search consumer
    /// today (global/section search is all in-memory through this
    /// enum), but the mirror copy needs the same five replacements
    /// added to stay in sync — flagged for that file's owner.
    private static func baseFold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldLocale)
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "\u{0629}", with: "\u{0647}")
            .replacingOccurrences(of: "\u{0649}", with: "\u{064A}")
            .replacingOccurrences(of: "\u{06A9}", with: "\u{0643}")
            .replacingOccurrences(of: "\u{06CC}", with: "\u{064A}")
            .replacingOccurrences(of: "\u{0640}", with: "")
    }

    private static func normalize(_ s: String) -> String {
        baseFold(s)
            .components(separatedBy: alphanumericSet.inverted)
            .joined()
    }

    static func matches(search: String, text: String) -> Bool {
        let normalizedText = normalize(text)
        let queryWords = search
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        if queryWords.isEmpty { return true }
        return queryWords.allSatisfy { word in
            normalizedText.contains(normalize(word))
        }
    }

    // MARK: - Build 63 (item 15): in-section search matching
    //
    // Section search (the Series / Movies / Live category + grid
    // searches) keeps its own matcher API, but since Build 66
    // (item 16) its fold IS the shared `baseFold` — the Arabic
    // equivalences that used to live only here now apply to the
    // strict and fuzzy paths too, so global and in-section search
    // fold identically. `sectionFold` stays as the named entry
    // point; it adds nothing on top of `baseFold` (and could not:
    // the equivalence pass is idempotent, see `baseFold`).
    /// The shared section fold (= `baseFold`), before token splitting.
    private static func sectionFold(_ s: String) -> String {
        baseFold(s)
    }

    private static func normalizeSection(_ s: String) -> String {
        sectionFold(s)
            .components(separatedBy: alphanumericSet.inverted)
            .joined()
    }

    /// Token-tolerant contains over the section-normalized text:
    /// every query word's normalized form must appear in the
    /// joined normalized title (same all-words rule as `matches`).
    static func matchesSection(search: String, text: String) -> Bool {
        let normalizedText = normalizeSection(text)
        let queryWords = search
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        if queryWords.isEmpty { return true }
        return queryWords.allSatisfy { word in
            normalizedText.contains(normalizeSection(word))
        }
    }

    /// Section fold that KEEPS word boundaries (the fuzzy layer's
    /// token shape, with the section equivalences applied).
    private static func normalizeSectionTokens(_ s: String) -> [String] {
        sectionFold(s)
            .components(separatedBy: alphanumericSet.inverted)
            .filter { !$0.isEmpty }
    }

    /// The Q13 fuzzy score computed over section-normalized
    /// tokens: identical tiers to `fuzzyScore` (exact token <
    /// prefix < substring < bounded-typo), so section search keeps
    /// the typo tolerance it already had AND gains the Arabic
    /// equivalences.
    static func sectionFuzzyScore(search: String, text: String) -> Int? {
        let queryWords = normalizeSectionTokens(search)
        if queryWords.isEmpty { return 0 }
        let tokens = normalizeSectionTokens(text)
        let joined = tokens.joined()
        var total = 0
        for word in queryWords {
            guard let score = wordScore(word, tokens: tokens, joined: joined) else { return nil }
            total += score
        }
        return total
    }

    static func matchesSectionFuzzy(search: String, text: String) -> Bool {
        sectionFuzzyScore(search: search, text: text) != nil
    }

    // MARK: - Build 61 (B10, Q13): fuzzy / typo-tolerant matching
    //
    // The fuzzy layer is separate and additive: token-preserving
    // normalization + a bounded edit distance, so "histroy" still
    // finds "History HD" and "beın" finds "Bein". Ranking: exact <
    // prefix < substring < fuzzy, so strict hits always lead and
    // typo-tolerant hits follow. Build 66 (item 16): its tokens now
    // come from the same `baseFold` as every other path — this is
    // the fold global search's title matching actually runs on, so
    // the Arabic equivalences reach global search through here AND
    // through `normalize` (exact/prefix ranking, cast/director).

    /// Shared fold that KEEPS word boundaries (unlike `normalize`,
    /// which strips separators for substring search).
    private static func normalizeTokens(_ s: String) -> [String] {
        baseFold(s)
            .components(separatedBy: alphanumericSet.inverted)
            .filter { !$0.isEmpty }
    }

    /// Bounded Levenshtein distance: returns `limit + 1` as soon
    /// as the true distance provably exceeds `limit`.
    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if abs(aChars.count - bChars.count) > limit { return limit + 1 }
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }

    /// Typo budget by word length: short words stay strict (a
    /// 3-letter query at distance 1 matches half the catalog).
    private static func typoBudget(forWordLength length: Int) -> Int {
        switch length {
        case ..<4: return 0
        case 4...6: return 1
        default: return 2
        }
    }

    /// Match score for one query word against the text's tokens:
    /// 0 exact token, 1 token prefix, 2 substring of the joined
    /// text, 3+distance for a typo hit; nil = no match.
    private static func wordScore(_ word: String, tokens: [String], joined: String) -> Int? {
        if tokens.contains(word) { return 0 }
        if tokens.contains(where: { $0.hasPrefix(word) }) { return 1 }
        if joined.contains(word) { return 2 }
        let budget = typoBudget(forWordLength: word.count)
        guard budget > 0 else { return nil }
        var best: Int?
        for token in tokens {
            // Only compare similarly-sized tokens (the bounded
            // distance rejects the rest immediately anyway).
            guard abs(token.count - word.count) <= budget else { continue }
            let d = editDistance(word, token, limit: budget)
            if d <= budget { best = min(best ?? .max, d) }
        }
        return best.map { 3 + $0 }
    }

    /// Fuzzy match: EVERY query word must hit (strictly or by
    /// typo), mirroring `matches`' all-words rule.
    static func matchesFuzzy(search: String, text: String) -> Bool {
        fuzzyScore(search: search, text: text) != nil
    }

    /// Total fuzzy score (lower = better); nil when any query
    /// word misses. An empty query scores 0 (matches everything,
    /// like `matches`).
    static func fuzzyScore(search: String, text: String) -> Int? {
        let queryWords = normalizeTokens(search)
        if queryWords.isEmpty { return 0 }
        let tokens = normalizeTokens(text)
        let joined = tokens.joined()
        var total = 0
        for word in queryWords {
            guard let score = wordScore(word, tokens: tokens, joined: joined) else { return nil }
            total += score
        }
        return total
    }

    /// Build 61 (B10, Z8): THE deterministic ranking tier for a
    /// title against a query — 0 exact name match, 1 prefix
    /// match, 2 fuzzy-tier match (substring or typo-tolerant;
    /// Q13 tolerance applies ONLY inside this tier). Used by the
    /// EPG section's ordering; the live/VOD/series sort functions
    /// below implement the identical tiering (exact → prefix →
    /// fuzzy score → name) so every section orders the same way.
    static func rankingTier(search: String, text: String) -> Int {
        if equals(search: search, text: text) { return 0 }
        if startsWith(search: search, text: text) { return 1 }
        return 2
    }

    /// Multi-field fuzzy match (B10, H5 search half): the query
    /// hits when it fuzzy-matches ANY supplied field — used by
    /// global search to include auxiliary fields (category, and
    /// the provider channel number when B8's capture lands it on
    /// the model) alongside the title.
    static func matchesFuzzyAny(search: String, fields: [String?]) -> Bool {
        fields.contains { field in
            guard let field, !field.isEmpty else { return false }
            return matchesFuzzy(search: search, text: field)
        }
    }

    static func equals(search: String, text: String) -> Bool {
        normalize(text) == normalize(search)
    }

    static func startsWith(search: String, text: String) -> Bool {
        normalize(text).hasPrefix(normalize(search))
    }

    static func sortLiveByRelevance(_ items: [LiveStreamWithCategory], search: String) -> [LiveStreamWithCategory] {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return items.sorted { $0.stream.sortIndex < $1.stream.sortIndex }
        }
        return items.sorted { a, b in
            let n1 = a.stream.name, n2 = b.stream.name
            let e1 = equals(search: trimmed, text: n1), e2 = equals(search: trimmed, text: n2)
            if e1 != e2 { return e1 && !e2 }
            let s1 = startsWith(search: trimmed, text: n1), s2 = startsWith(search: trimmed, text: n2)
            if s1 != s2 { return s1 && !s2 }
            // Q13: typo-tolerant hits rank after strict hits.
            let f1 = fuzzyScore(search: trimmed, text: n1) ?? .max
            let f2 = fuzzyScore(search: trimmed, text: n2) ?? .max
            if f1 != f2 { return f1 < f2 }
            return n1.localizedCaseInsensitiveCompare(n2) == .orderedAscending
        }
    }

    static func sortVODByRelevance(_ items: [VODWithCategory], search: String) -> [VODWithCategory] {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return items.sorted { $0.stream.sortIndex < $1.stream.sortIndex }
        }
        return items.sorted { a, b in
            let n1 = a.stream.name, n2 = b.stream.name
            let e1 = equals(search: trimmed, text: n1), e2 = equals(search: trimmed, text: n2)
            if e1 != e2 { return e1 && !e2 }
            let s1 = startsWith(search: trimmed, text: n1), s2 = startsWith(search: trimmed, text: n2)
            if s1 != s2 { return s1 && !s2 }
            // Q13: typo-tolerant hits rank after strict hits.
            let f1 = fuzzyScore(search: trimmed, text: n1) ?? .max
            let f2 = fuzzyScore(search: trimmed, text: n2) ?? .max
            if f1 != f2 { return f1 < f2 }
            return n1.localizedCaseInsensitiveCompare(n2) == .orderedAscending
        }
    }

    static func sortSeriesByRelevance(_ items: [SeriesWithCategory], search: String) -> [SeriesWithCategory] {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return items.sorted { $0.series.sortIndex < $1.series.sortIndex }
        }
        return items.sorted { a, b in
            let n1 = a.series.name, n2 = b.series.name
            let e1 = equals(search: trimmed, text: n1), e2 = equals(search: trimmed, text: n2)
            if e1 != e2 { return e1 && !e2 }
            let s1 = startsWith(search: trimmed, text: n1), s2 = startsWith(search: trimmed, text: n2)
            if s1 != s2 { return s1 && !s2 }
            // Q13: typo-tolerant hits rank after strict hits.
            let f1 = fuzzyScore(search: trimmed, text: n1) ?? .max
            let f2 = fuzzyScore(search: trimmed, text: n2) ?? .max
            if f1 != f2 { return f1 < f2 }
            return n1.localizedCaseInsensitiveCompare(n2) == .orderedAscending
        }
    }
}
