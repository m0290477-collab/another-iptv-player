import Foundation

/// Build 61 (B8, C1): advanced filter facets for Movies / Series.
///
/// Facets are built ONLY from values actually present in the loaded
/// catalog (genres split from the records' own `genre` strings, years
/// parsed from their own `releaseDate`s, countries from their own
/// `country` field where the provider supplied one). A facet with no
/// values in the catalog produces no UI — nothing is invented.
///
/// Country honesty note: the Xtream list endpoints
/// (get_vod_streams / get_series) carry no country field; a movie's
/// country arrives only via get_vod_info (persisted to
/// `DBVODStream.country` when the provider returns one), and series
/// records carry no country at all. The country facet therefore
/// appears only when at least one loaded record actually has one.
nonisolated enum CatalogFacets {
    static func splitGenres(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func year(of releaseDate: String?) -> Int? {
        DetailFormatting.releaseYear(from: releaseDate)
    }

    /// Distinct facet values present in a movie list.
    static func vodFacets(in items: [DBVODStream]) -> (genres: [String], years: [Int], countries: [String]) {
        var genres = Set<String>()
        var years = Set<Int>()
        var countries = Set<String>()
        for item in items {
            for genre in splitGenres(item.genre) { genres.insert(genre) }
            if let year = year(of: item.releaseDate) { years.insert(year) }
            if let country = item.country?.trimmingCharacters(in: .whitespaces), !country.isEmpty {
                countries.insert(country)
            }
        }
        return (
            genres.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            years.sorted(by: >),
            countries.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        )
    }

    /// Distinct facet values present in a series list (no country —
    /// series records carry none; see the honesty note above).
    static func seriesFacets(in items: [DBSeries]) -> (genres: [String], years: [Int]) {
        var genres = Set<String>()
        var years = Set<Int>()
        for item in items {
            for genre in splitGenres(item.genre) { genres.insert(genre) }
            if let year = year(of: item.releaseDate) { years.insert(year) }
        }
        return (
            genres.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            years.sorted(by: >)
        )
    }
}

/// The user's facet selection for one list screen (screen-local state,
/// like the existing file-type / genre filters).
nonisolated struct CatalogFacetSelection: Equatable {
    var genres: Set<String> = []
    var years: Set<Int> = []
    var countries: Set<String> = []
    /// Minimum rating on the provider's 0–10 scale; nil = no floor.
    var minRating: Double? = nil

    var isEmpty: Bool {
        genres.isEmpty && years.isEmpty && countries.isEmpty && minRating == nil
    }

    mutating func clear() {
        genres.removeAll()
        years.removeAll()
        countries.removeAll()
        minRating = nil
    }

    func matches(genre: String?, releaseDate: String?, country: String?, rating: String?, rating5Based: Double?) -> Bool {
        if !genres.isEmpty {
            let itemGenres = Set(CatalogFacets.splitGenres(genre))
            if itemGenres.isDisjoint(with: genres) { return false }
        }
        if !years.isEmpty {
            guard let year = CatalogFacets.year(of: releaseDate), years.contains(year) else { return false }
        }
        if !countries.isEmpty {
            guard let country = country?.trimmingCharacters(in: .whitespaces), !country.isEmpty,
                  countries.contains(country) else { return false }
        }
        if let minRating {
            let value = ContentRating.normalizedRating10(rating: rating, rating5Based: rating5Based) ?? -1
            if value < minRating { return false }
        }
        return true
    }
}

nonisolated extension CatalogFacetSelection {
    func apply(to items: [VODWithCategory]) -> [VODWithCategory] {
        guard !isEmpty else { return items }
        return items.filter {
            matches(genre: $0.stream.genre, releaseDate: $0.stream.releaseDate,
                    country: $0.stream.country, rating: $0.stream.rating,
                    rating5Based: $0.stream.rating5Based)
        }
    }

    func apply(to items: [SeriesWithCategory]) -> [SeriesWithCategory] {
        guard !isEmpty else { return items }
        return items.filter {
            matches(genre: $0.series.genre, releaseDate: $0.series.releaseDate,
                    country: nil, rating: $0.series.rating,
                    rating5Based: $0.series.rating5Based)
        }
    }
}
