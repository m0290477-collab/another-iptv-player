import Foundation

// Pure stateless namespace (immutable Sendable keyword tables only) — called from
// GRDB db closures, so it must not be MainActor.
nonisolated enum AdultContentFilter {

    // MARK: - Keywords

    /// Counts as adult content if it appears as a separate word in the category name.
    /// (Case-insensitive; matches as a token surrounded by punctuation/whitespace.)
    private static let adultTokens: Set<String> = [
        "XXX",
        "ADULT", "ADULTS",
        "PORN", "PORNO",
        "EROTIC", "EROTICA",
        "HENTAI",
        "NUDE", "NUDITY",
        "SEX",           // the token check is enough to avoid false positives like "Essex"
        "NSFW",
        "EXPLICIT",
        "X-RATED",
        "HARDCORE",
        "SOFTCORE",
        "PLAYBOY",
    ]

    /// Counts as adult content if it appears anywhere in the category name.
    private static let adultSubstrings: [String] = [
        "18+",
        "18 +",
        "XVIDEOS",
        "XHAMSTER",
        "PORNHUB",
    ]

    // MARK: - Category Check

    /// Returns whether the given category name contains adult content.
    static func isAdultCategoryName(_ name: String) -> Bool {
        let upper = name.uppercased()

        // Split on non-alphanumeric characters, drop empty tokens
        let tokens = upper.components(separatedBy: CharacterSet.alphanumerics.inverted)
                          .filter { !$0.isEmpty }
        if tokens.contains(where: { adultTokens.contains($0) }) {
            return true
        }

        // Patterns containing special characters (like 18+) are checked as substrings
        return adultSubstrings.contains(where: { upper.contains($0) })
    }

    // MARK: - Stream Checks

    /// Returns whether a live stream is adult content.
    /// - Filter if the `is_adult: 1` flag is set or its category is an adult category.
    static func isAdultLiveStream(_ stream: XtreamLiveStream, adultCategoryIds: Set<String>) -> Bool {
        if (stream.isAdult ?? 0) == 1 { return true }
        if let cid = stream.categoryId, adultCategoryIds.contains(cid) { return true }
        return false
    }

    /// Returns whether a movie (VOD) stream is adult content.
    static func isAdultVODStream(_ stream: XtreamVODStream, adultCategoryIds: Set<String>) -> Bool {
        if (stream.isAdult ?? 0) == 1 { return true }
        if let cid = stream.categoryId, adultCategoryIds.contains(cid) { return true }
        return false
    }

    // MARK: - Helpers

    /// Extracts the IDs of the adult categories from the category list.
    static func adultCategoryIds(from categories: [XtreamCategory]) -> Set<String> {
        Set(categories.compactMap { cat in
            guard let name = cat.categoryName, isAdultCategoryName(name) else { return nil }
            return cat.categoryId
        })
    }
}
