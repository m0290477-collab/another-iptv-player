import SwiftUI

enum ContentRating {
    /// C9 one-locale law (finisher wiring): bound to the APP's chosen
    /// language (`AppTheme.appLocale`), never the device locale.
    /// Computed per access so an in-app language change rebinds it —
    /// a once-created static formatter would keep the old locale.
    private static var roundedFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.locale = AppTheme.appLocale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        f.roundingMode = .halfUp
        return f
    }

    /// Parses the panel `rating` field as a 0–10 score. The field is, in the Xtream
    /// contract, a TMDB-style 0–10 average; but some panels fill the same
    /// field with a vote count ("602") or a percentage ("63.3"). These cannot be converted
    /// to a score — a value whose scale cannot be verified is NOT RESCALED; the score
    /// is treated as absent. Only numeric values in the (0, 10] range are valid.
    static func parseRating10(_ rating: String?) -> Double? {
        guard let r = rating?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
        let forParse = r.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(forParse), value > 0, value <= 10 else { return nil }
        return value
    }

    /// The SINGLE normalization point: the display and the "Top/Popular" ranking use the same
    /// value. First the API's special 0–5 field (`rating_5based`) —
    /// it is verified and carried ×2 onto the 0–10 axis; if out of range, it falls back to the panel `rating`
    /// text; if that is also outside (0, 10], there is no score (nil).
    static func normalizedRating10(rating: String?, rating5Based: Double?) -> Double? {
        if let five = rating5Based, five > 0, five <= 5 {
            return five * 2
        }
        return parseRating10(rating)
    }

    /// We do not show scores that are empty, non-numeric, or outside the (0, 10] range.
    /// Valid values are rounded to a single decimal place
    /// (ör. 6.665 → 6.7).
    static func displayText(_ rating: String?) -> String? {
        guard let value = parseRating10(rating) else { return nil }
        return roundedFormatter.string(from: NSNumber(value: value))
    }

    /// Round 5: display form of the NORMALIZED value (the same number the
    /// Top/Popular rankings sort by), so a ranked card can never show a
    /// different score than the one that earned its rank — including the
    /// `rating_5based`-only records `displayText` alone would miss.
    static func normalizedDisplayText(rating: String?, rating5Based: Double?) -> String? {
        guard let value = normalizedRating10(rating: rating, rating5Based: rating5Based) else { return nil }
        return roundedFormatter.string(from: NSNumber(value: value))
    }
}

struct RatingLabel: View {
    let rating: String?
    var style: Style = .compact

    enum Style {
        case compact
        case standard
    }

    var body: some View {
        if let text = ContentRating.displayText(rating) {
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(iconFont)
                    .foregroundStyle(AppTheme.ratingGold.opacity(0.95))
                Text(text)
                    .font(textFont)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
    }

    private var iconFont: Font {
        switch style {
        case .compact: return .caption2
        case .standard: return .caption
        }
    }

    private var textFont: Font {
        switch style {
        case .compact: return .caption2.weight(.medium)
        case .standard: return .caption
        }
    }
}

/// A dark translucent badge for the top-right corner of the poster / cover image.
struct PosterRatingBadge: View {
    let rating: String?

    var body: some View {
        if let text = ContentRating.displayText(rating) {
            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(text)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.55), in: Capsule())
        }
    }
}
