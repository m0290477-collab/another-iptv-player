import SwiftUI

// MARK: - Detail navigation routes (round 15, C7)

/// The detail pages' secondary navigation: genre grids and people
/// browsing. One enum so each detail view registers exactly ONE
/// `navigationDestination(item:)` for it (SwiftUI forbids two
/// destinations for the same type in one hierarchy).
enum MovieDetailRoute: Hashable {
    case genre(String)
    case person(String)
}

// MARK: - Hero Config

struct DetailHeroConfig {
    var title: String
    var backdropURL: URL?
    var posterURL: URL?
    var year: String?
    /// Round 10: the record's full real release-date string when it
    /// carries one ("2026-05-12"); the meta row shows it as a chip
    /// instead of the bare year. Nil/short values fall back to
    /// `year`. (No country field exists in any model — see the
    /// round-10 report.)
    var releaseDate: String? = nil
    var runtime: String?
    var rating10: Double?
    var ratingText: String?
    var posterIconName: String
    var backdropIconName: String
}

// MARK: - Cinematic Hero

struct DetailHero: View {
    let config: DetailHeroConfig
    var heroHeight: CGFloat = 380
    var onPosterTap: ((URL) -> Void)? = nil

    @Environment(\.posterMetrics) private var metrics

    /// Round 19 (R19-2): load-failure state for the hero art. A
    /// backdrop URL that exists but FAILS to load (empty/relative/
    /// dead panel values) used to stay on screen as CachedImage's
    /// warning-triangle placeholder. Now the failure swaps the
    /// backdrop for the poster (blurred, the existing fallback
    /// treatment), and if the poster fails too, for the plain
    /// gradient — never a warning glyph.
    @State private var backdropLoadFailed = false
    @State private var posterBackdropLoadFailed = false

    private var resolvedBackdropURL: URL? {
        if let backdrop = config.backdropURL, !backdropLoadFailed {
            return backdrop
        }
        if let poster = config.posterURL, !posterBackdropLoadFailed {
            return poster
        }
        return nil
    }

    private var backdropIsFallback: Bool {
        config.backdropURL == nil || backdropLoadFailed
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdropLayer
            gradientLayer
            overlayLayer
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .onChange(of: config.backdropURL) { _, _ in backdropLoadFailed = false }
        .onChange(of: config.posterURL) { _, _ in posterBackdropLoadFailed = false }
    }

    @ViewBuilder
    private var backdropLayer: some View {
        if let url = resolvedBackdropURL {
            let h = heroHeight
            GeometryReader { proxy in
                CachedImage(
                    url: url,
                    width: proxy.size.width,
                    height: h,
                    cornerRadius: 0,
                    contentMode: .fill,
                    iconName: config.backdropIconName,
                    loadProfile: .high,
                    onLoadFailed: {
                        if url == config.backdropURL {
                            backdropLoadFailed = true
                        } else {
                            posterBackdropLoadFailed = true
                        }
                    }
                )
                .frame(width: proxy.size.width, height: h)
                .blur(radius: backdropIsFallback ? 28 : 0)
                .opacity(backdropIsFallback ? 0.55 : 1)
                .visualEffect { content, proxy in
                    let minY = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    let overscroll = max(0, minY)
                    let parallax = min(0, minY * 0.18)
                    return content
                        .scaleEffect(1 + overscroll / h, anchor: .bottom)
                        .offset(y: parallax)
                }
            }
            .frame(height: heroHeight)
        } else {
            LinearGradient(
                colors: [
                    AppTheme.accent.opacity(0.28),
                    AppTheme.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: heroHeight)
        }
    }

    private var gradientLayer: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.5),
                .init(color: AppTheme.background.opacity(0.78), location: 0.85),
                .init(color: AppTheme.background, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: heroHeight)
        .allowsHitTesting(false)
    }

    private var overlayLayer: some View {
        HStack(alignment: .bottom, spacing: 16) {
            CachedImage(
                url: config.posterURL,
                width: metrics.seriesDetailHeroWidth,
                height: metrics.seriesDetailHeroHeight,
                cornerRadius: AppTheme.cornerRadius,
                contentMode: .fill,
                iconName: config.posterIconName
            )
            .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if let url = config.posterURL {
                    onPosterTap?(url)
                }
            }
            .allowsHitTesting(config.posterURL != nil)

            VStack(alignment: .leading, spacing: 10) {
                Text(config.title)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)

                DetailHeroMetaRow(
                    year: config.year,
                    releaseDate: config.releaseDate,
                    runtime: config.runtime,
                    rating10: config.rating10,
                    ratingText: config.ratingText
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
    }
}

private struct DetailHeroMetaRow: View {
    let year: String?
    var releaseDate: String? = nil
    let runtime: String?
    let rating10: Double?
    let ratingText: String?

    /// A full date string (longer than a bare 4-digit year) is shown
    /// as the release-date chip; anything else falls back to `year`.
    private var fullReleaseDate: String? {
        guard let raw = releaseDate?.trimmingCharacters(in: .whitespaces),
              raw.count > 4 else { return nil }
        return raw
    }

    var body: some View {
        HStack(spacing: 10) {
            if let rating10, rating10 > 0, rating10 <= 10 {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.ratingGold)
                    Text(String(format: "%.1f", locale: DetailFormatting.appLocale, rating10))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.ultraThinMaterial))
            } else if let ratingText, !ratingText.isEmpty {
                RatingLabel(rating: ratingText, style: .standard)
            }

            if let fullReleaseDate {
                HStack(spacing: 3) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                    Text(fullReleaseDate)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            } else if let year, !year.isEmpty {
                Text(year)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let runtime, !runtime.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(runtime)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Action Bar

struct DetailActionBar: View {
    let primaryTitle: String
    var primarySubtitle: String? = nil
    var primaryIcon: String = "play.fill"
    var progress: Double? = nil
    let onPrimary: () -> Void

    var restartTitle: String? = nil
    var onRestart: (() -> Void)? = nil

    var trailerURL: URL? = nil

    var body: some View {
        VStack(spacing: 10) {
            primaryCTA
            secondaryRow
        }
        .padding(.horizontal, 16)
    }

    private var primaryCTA: some View {
        Button(action: onPrimary) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: primaryIcon)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(primaryTitle)
                            .font(.subheadline.weight(.bold))
                        if let sub = primarySubtitle, !sub.isEmpty {
                            Text(sub)
                                .font(.caption2)
                                .opacity(0.82)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .tint(.white)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 10)
                }
            }
            .background(
                LinearGradient(
                    colors: [AppTheme.accent, AppTheme.accent.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
            .shadow(color: AppTheme.accent.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var secondaryRow: some View {
        let hasRestart = onRestart != nil && restartTitle != nil
        let hasTrailer = trailerURL != nil
        if hasRestart || hasTrailer {
            HStack(spacing: 10) {
                if let onRestart, let restartTitle {
                    DetailSecondaryButton(icon: "arrow.counterclockwise", title: restartTitle, action: onRestart)
                }
                if let trailerURL {
                    Link(destination: trailerURL) {
                        // Round 8 (L-2): was the hardcoded Turkish word
                        // "Fragman" in EVERY language. Now localized
                        // like every other string (en "Trailer", tr
                        // "Fragman").
                        DetailSecondaryLabel(icon: "play.rectangle.on.rectangle", title: L("detail.trailer"))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct DetailSecondaryButton: View {
    let icon: String
    let title: String
    var tinted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DetailSecondaryLabel(icon: icon, title: title, tinted: tinted)
        }
        .buttonStyle(.plain)
    }
}

private struct DetailSecondaryLabel: View {
    let icon: String
    let title: String
    var tinted: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tinted ? AppTheme.ratingGold : Color.primary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Genre chips

struct GenreChipRow: View {
    let genres: [String]
    /// Round 14 (B1/B7): when set, chips are buttons that navigate to
    /// the tab's genre-filtered grid. Nil keeps the passive label row.
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        if !genres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(genres, id: \.self) { g in
                        if let onSelect {
                            Button { onSelect(g) } label: { chipLabel(g) }
                                .buttonStyle(.plain)
                        } else {
                            chipLabel(g)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func chipLabel(_ g: String) -> some View {
        Text(g)
            .font(AppTheme.fontBadge)
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}

// MARK: - Section header (round 10)

/// The detail pages' ONE section-header style (point 20): a short
/// accent bar + headline — used by Story, Cast, Director, More Like
/// This and the series Episodes/About blocks.
struct DetailSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(AppTheme.accent)
                .frame(width: 3, height: 18)
            Text(title)
                .font(AppTheme.fontSectionTitle)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Favorite + download row (round 10)

/// The square favorite button + download action that sit beside
/// the big Play button on the detail pages (point 20). The
/// favorite glyph is the app's star (gold when active) — the same
/// favorite system as everywhere else, not a second one. The
/// download slot is the caller's existing `DownloadButton` (full
/// state machine: progress, pause, delete).
struct DetailFavoriteDownloadRow<Download: View>: View {
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    @ViewBuilder let download: () -> Download

    /// Round 15 (C12): scale pulse on the favorite toggle, paired with
    /// the symbol bounce below.
    @State private var favoritePulse = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                // Round 15 (C12): the favorite toggle's full feedback
                // package — success haptic + the fenced UI sound —
                // alongside the visual bounce/pulse.
                Haptics.success()
                AppSound.play(.favorite)
                withAnimation(Motion.pressSpring) { favoritePulse = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(Motion.pressSpring) { favoritePulse = false }
                }
                onToggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isFavorite ? AppTheme.ratingGold : .primary)
                    .symbolEffect(.bounce, value: isFavorite)
                    .scaleEffect(favoritePulse ? 1.18 : 1.0)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                            .fill(AppTheme.elevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                            .strokeBorder(AppTheme.cardBorderColor, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("favorites.title"))

            download()
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Plot block

struct DetailPlotBlock: View {
    let plot: String
    private static let collapsedLineLimit = 5

    @State private var expanded = false
    @State private var limitedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var isTruncated: Bool {
        fullHeight > limitedHeight + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Round 10: "Story" is the plot block under the shared
            // accent-bar header (the string stays `movie.plot`).
            DetailSectionHeader(title: L("movie.plot"))

            Text(plot)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : Self.collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.2), value: expanded)
                .background(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Text(plot)
                            .font(.subheadline)
                            .lineLimit(Self.collapsedLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newValue in
                                limitedHeight = newValue
                            }
                        Text(plot)
                            .font(.subheadline)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newValue in
                                fullHeight = newValue
                            }
                    }
                    .hidden()
                    .accessibilityHidden(true)
                }

            if isTruncated {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text(expanded ? L("detail.show_less") : L("detail.show_more"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

// MARK: - Info text block (director, cast, etc.)

struct DetailInfoTextBlock: View {
    let label: String
    let value: String
    var lineLimit: Int? = nil
    /// Round 14 (B7): cast text gets the same Show more expander the
    /// summary has, instead of a hard 3-line clip.
    var expandable: Bool = false
    /// Round 15 (C7): when set, the value is a comma-separated people
    /// list rendered as tappable chips (one per real name) that browse
    /// that person's titles. Takes precedence over text rendering.
    var onPersonTap: ((String) -> Void)? = nil

    @State private var expanded = false
    @State private var limitedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var collapsedLimit: Int { lineLimit ?? 3 }

    private var isTruncated: Bool {
        expandable && fullHeight > limitedHeight + 1
    }

    private var people: [String] {
        DetailFormatting.peopleList(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Round 10: Director/Cast use the same accent-bar
            // section header as Story (was a small uppercased label).
            DetailSectionHeader(title: label)
            if let onPersonTap, !people.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(people, id: \.self) { person in
                            Button { onPersonTap(person) } label: {
                                Text(person)
                                    .font(AppTheme.fontBadge)
                                    .foregroundStyle(.primary.opacity(0.9))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(AppTheme.elevated))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(AppTheme.cardBorderColor, lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if expandable {
                expandableText
            } else {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private var expandableText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(expanded ? nil : collapsedLimit)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.2), value: expanded)
                .background(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Text(value)
                            .font(.subheadline)
                            .lineLimit(collapsedLimit)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newValue in
                                limitedHeight = newValue
                            }
                        Text(value)
                            .font(.subheadline)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newValue in
                                fullHeight = newValue
                            }
                    }
                    .hidden()
                    .accessibilityHidden(true)
                }

            if isTruncated {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text(expanded ? L("detail.show_less") : L("detail.show_more"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Season tab bar

struct DetailSeasonTabBar: View {
    let seasons: [DBSeason]
    @Binding var selectedId: String?

    /// Round 15 (C8): season 0's tab sits LAST (after every regular
    /// season) and is labeled "Specials" — the raw season order from
    /// the query puts it first, ahead of Season 1.
    private var orderedSeasons: [DBSeason] {
        SeriesPlaybackOrdering.orderedSeasons(seasons)
    }

    private func tabTitle(_ season: DBSeason) -> String {
        if season.seasonNumber == 0 { return L("series.specials") }
        return season.name ?? L("series.season_format", season.seasonNumber)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(orderedSeasons) { season in
                        let isSelected = selectedId == season.id
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                selectedId = season.id
                            }
                        } label: {
                            Text(tabTitle(season))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? AppTheme.accent : Color.clear)
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            isSelected ? Color.clear : Color.primary.opacity(0.14),
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .id(season.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .onChange(of: selectedId) { _, new in
                guard let new else { return }
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }
}


// MARK: - Movie title normalization (round 15, C7)

/// Title keys for franchise grouping and duplicate-edition detection.
/// Everything derives from the record's own name — no external data.
enum MovieCatalogNaming {
    /// Case/diacritic-folded title with punctuation collapsed —
    /// "Amélie!!" and "amelie" share a key.
    static func normalizedTitle(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let kept = folded.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
        return kept
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static let romanNumerals: Set<String> = [
        "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii"
    ]

    /// The franchise base of a title: the normalized title with a
    /// colon subtitle and trailing part markers (numbers, roman
    /// numerals, "part N") stripped, repeatedly — "Dune Part Two",
    /// "Dune: Part Two" and "Dune 2" all reduce to "dune".
    static func franchiseBase(_ name: String) -> String {
        // Colon subtitle comes off the RAW title first (normalization
        // strips the colon itself): "Dune: Part Two" → "Dune".
        let head = name.split(separator: ":", maxSplits: 1).first.map(String.init) ?? name
        let base = normalizedTitle(head)
        var tokens = base.split(separator: " ").map(String.init)
        while let last = tokens.last {
            if Int(last) != nil || romanNumerals.contains(last) {
                tokens.removeLast()
            } else if last == "part" {
                tokens.removeLast()
            } else if tokens.count >= 2, tokens[tokens.count - 2] == "part",
                      Int(last) != nil || romanNumerals.contains(last) {
                tokens.removeLast(2)
            } else {
                break
            }
        }
        return tokens.joined(separator: " ")
    }

    /// The real category name a movie belongs to, from the loaded
    /// catalog (nil when the category isn't loaded).
    @MainActor
    static func categoryName(for movie: DBVODStream, in store: PlaylistContentStore) -> String? {
        guard let categoryId = movie.categoryId else { return nil }
        return store.vodCategories.first { $0.id == categoryId }?.name
    }
}

// MARK: - Formatting helpers

enum DetailFormatting {
    /// Round 15 (C9): formatters bind to the APP's chosen language,
    /// not the device locale — the canonical `AppTheme.appLocale`
    /// (the one-locale law's single home).
    static var appLocale: Locale { AppTheme.appLocale }

    static func year(from releaseDate: String?) -> String? {
        guard let raw = releaseDate?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let prefix = raw.prefix(4)
        return prefix.count == 4 && prefix.allSatisfy({ $0.isNumber }) ? String(prefix) : raw
    }

    /// The release year as a number, for decade browsing and
    /// year-proximity scoring. Nil when the record carries no
    /// parseable year — never guessed.
    static func releaseYear(from releaseDate: String?) -> Int? {
        guard let raw = releaseDate?.trimmingCharacters(in: .whitespaces), raw.count >= 4 else { return nil }
        let prefix = raw.prefix(4)
        guard prefix.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(prefix)
    }

    static func formatMs(_ ms: Int) -> String {
        let totalSeconds = max(ms, 0) / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", locale: appLocale, h, m, s)
            : String(format: "%d:%02d", locale: appLocale, m, s)
    }

    /// Round 14 (B7): a runtime rendered from the panel's real
    /// `duration_secs` value, through the same localized h/m formats
    /// series runtimes use. Nil for a missing/zero value.
    static func runtimeFromSeconds(_ secs: Int?) -> String? {
        guard let secs, secs > 0 else { return nil }
        let totalMinutes = secs / 60
        if totalMinutes >= 60 {
            let h = totalMinutes / 60
            let m = totalMinutes % 60
            return m > 0 ? L("detail.runtime_hm", h, m) : L("detail.runtime_h", h)
        }
        return L("detail.runtime_m", max(totalMinutes, 1))
    }

    /// A panel people field ("A, B, C") as individual names — the
    /// unit people browsing (C7) navigates by. Empty fields yield [].
    static func peopleList(_ raw: String?) -> [String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Panel `episode_run_time` is a minute count ("120"). Round 5 fix: the
    /// old implementation rendered it with HARDCODED Turkish abbreviations
    /// ("\(h)s \(m)dk" — saat/dakika), so every non-Turkish UI showed a
    /// stray "2s" next to the rating/year for a 120-minute runtime. The
    /// value is a real runtime; it now renders through localized formats
    /// ("2h", "2h 5m", "45m" in English). Pre-formatted panel strings
    /// (already carrying an h/m unit) still pass through untouched.
    static func seriesRuntime(_ raw: String?) -> String? {
        guard let r = raw?.trimmingCharacters(in: .whitespaces), !r.isEmpty, r != "0" else { return nil }
        if r.contains("m") || r.contains("h") { return r }
        if let minutes = Int(r) {
            if minutes >= 60 {
                let h = minutes / 60
                let m = minutes % 60
                return m > 0 ? L("detail.runtime_hm", h, m) : L("detail.runtime_h", h)
            }
            return L("detail.runtime_m", minutes)
        }
        return r
    }

    static func genreList(_ raw: String?) -> [String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return [] }
        return raw
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
