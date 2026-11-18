import Foundation

/// The same logic as the GRDB `localized_*` SQL functions (Persistence.swift).
/// Pure stateless namespace — used from detached filtering tasks, so it must not be MainActor.
nonisolated enum CatalogTextSearch {
    private static let foldLocale = Locale(identifier: "en_US_POSIX")
    private static let alphanumericSet = CharacterSet.alphanumerics

    /// Locale-invariant fold: tr_TR lowercasing maps "I"→"ı" and breaks queries like
    /// "history" against ALL-CAPS catalog names ("HISTORY HD" → "hıstory hd").
    /// The extra "ı"→"i" pass keeps Turkish dotless-ı queries matching ALL-CAPS
    /// Turkish text ("IŞIK" and "ışık" both normalize to "isik").
    private static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldLocale)
        return folded
            .replacingOccurrences(of: "ı", with: "i")
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

    // MARK: - Build 61 (B10, Q13): fuzzy / typo-tolerant matching
    //
    // `matches` above stays the strict core (its `normalize` is
    // mirrored by the GRDB `localized_*` SQL functions — do not
    // change it). The fuzzy layer is separate and additive:
    // token-preserving normalization + a bounded edit distance, so
    // "histroy" still finds "History HD" and "beın" finds "Bein".
    // Ranking: exact < prefix < substring < fuzzy, so strict hits
    // always lead and typo-tolerant hits follow.

    /// Diacritic/case fold that KEEPS word boundaries (unlike
    /// `normalize`, which strips separators for substring search).
    private static func normalizeTokens(_ s: String) -> [String] {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldLocale)
            .replacingOccurrences(of: "ı", with: "i")
        return folded
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
