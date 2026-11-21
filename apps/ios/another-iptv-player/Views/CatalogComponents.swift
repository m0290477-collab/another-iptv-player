import SwiftUI

// MARK: - Build 88 shared catalog components (Movies + Series)
//
// The ONE poster-card / shelf / grid language for the Movies and
// Series tabs (build 88, plan Part 2-B/C — the owner's approved
// "max" mockups): posters fill their card frame completely and
// sharply, the FULL title wraps to two lines under the card, a
// gold ★ rating chip sits on the poster's bottom-left when the
// record carries a rating, and a NEW chip sits on the top-left
// for the newest-added slice of the catalog. Items with no usable
// artwork render the designed title card (CachedImage's `title:`
// placeholder) — never an anonymous blank tile.
//
// Both tabs build against these exact types; nothing here knows
// about movies or series specifically — callers pass resolved
// values (artwork URL, title, caption, normalized rating text).

/// One catalog poster card: artwork + optional NEW / ★ chips +
/// full title (2 lines) + caption line under the card.
struct PosterCardView: View {
    /// Primary artwork (the caller resolves its own fallback
    /// chain — e.g. poster, then stored backdrop — into this one
    /// URL, the same resolution `VODStreamCard` always used).
    let imageURL: URL?
    /// The item's full title — rendered under the card, wrapped
    /// to two lines, never truncated to one.
    let title: String
    /// Caption line under the title (the release year, or a
    /// "year • genre" line the caller builds from real fields);
    /// nil hides the line.
    var yearText: String? = nil
    /// Normalized rating text (ContentRating's one normalization
    /// point); nil or empty hides the ★ chip.
    var ratingText: String? = nil
    /// NEW chip (top-left) — the caller decides membership in the
    /// newest-added slice of its catalog.
    var isNew: Bool = false
    /// Section symbol for the designed title-card placeholder.
    var iconName: String = "film"
    let posterWidth: CGFloat
    let posterHeight: CGFloat
    var imageLoadProfile: ImageLoadProfile = .shelf
    /// Watch progress 0...1 (grid/detail callers pass it from the
    /// progress map); nil hides the bar.
    var watchProgress: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedImage(
                url: imageURL,
                width: posterWidth,
                height: posterHeight,
                contentMode: .fill,
                iconName: iconName,
                loadProfile: imageLoadProfile,
                title: title
            )
            .shadow(color: AppTheme.cardShadowColor, radius: AppTheme.cardShadowRadius, x: 0, y: AppTheme.cardShadowY)
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(AppTheme.cardBorderColor, lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if isNew {
                    newChip
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let ratingText, !ratingText.isEmpty {
                    ratingChip(ratingText)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottom) {
                if let watchProgress, watchProgress > 0 {
                    progressBar(watchProgress)
                }
            }

            Text(title)
                .font(AppTheme.fontPosterTitle)
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .minimumScaleFactor(0.9)
                .multilineTextAlignment(.leading)
                .frame(width: posterWidth, alignment: .leading)

            if let yearText, !yearText.isEmpty {
                Text(yearText)
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: posterWidth, alignment: .leading)
            }
        }
    }

    /// Mockup language: a small accent chip, top-left, with a
    /// soft accent glow — accent ONLY from the existing token.
    private var newChip: some View {
        Text(L("newcontent.badge"))
            .font(AppTheme.fontBadge)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.accent)
            )
            .shadow(color: AppTheme.accent.opacity(0.45), radius: 8, x: 0, y: 2)
    }

    /// The on-poster rating chip: gold star (the app's one rating
    /// token) + the normalized value on the shared dark capsule —
    /// the PosterRatingBadge treatment, pinned bottom-left per
    /// the approved mockup.
    private func ratingChip(_ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AppTheme.ratingGold)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    /// The VODStreamCard progress treatment, unchanged: an accent
    /// fill over a dark track at the poster's bottom edge.
    private func progressBar(_ progress: Double) -> some View {
        Rectangle()
            .fill(AppTheme.accent)
            .frame(height: 4)
            .frame(width: posterWidth * progress)
            .frame(maxWidth: posterWidth, alignment: .leading)
            .background(Color.black.opacity(0.3))
            .cornerRadius(2)
            .padding(.bottom, 2)
            .padding(.horizontal, 4)
    }
}

/// Build 88: the Movies tab's poster card for one record — the
/// artwork chain (icon, then the stored backdrop, build 82 item
/// 6), the release-year caption and the normalized rating,
/// resolved in ONE place so every Movies surface (shelves, grids,
/// detail rails) renders the identical card.
func moviePosterCard(
    _ movie: DBVODStream,
    posterWidth: CGFloat,
    posterHeight: CGFloat,
    imageLoadProfile: ImageLoadProfile,
    isNew: Bool,
    watchProgress: Double? = nil
) -> PosterCardView {
    PosterCardView(
        imageURL: ArtworkURL.url(from: movie.streamIcon) ?? ArtworkURL.url(from: movie.backdropPath),
        title: movie.name,
        yearText: DetailFormatting.year(from: movie.releaseDate),
        ratingText: ContentRating.normalizedDisplayText(
            rating: movie.rating,
            rating5Based: movie.rating5Based
        ),
        isNew: isNew,
        iconName: "film",
        posterWidth: posterWidth,
        posterHeight: posterHeight,
        imageLoadProfile: imageLoadProfile,
        watchProgress: watchProgress
    )
}

// MARK: - Shelf row

/// One catalog shelf: the app's ONE section header
/// (CinematicSectionHeader — title, optional count badge, See
/// all) over a lazy horizontal row of caller-built cells.
/// Callers wrap their cell in their own NavigationLink, exactly
/// as the hand-rolled shelves always did.
struct CatalogShelfRow<Item: Identifiable, Destination: View, Cell: View>: View {
    let title: String
    /// Optional real item count for the header badge.
    var count: Int? = nil
    let items: [Item]
    /// Fixed row height when the caller reserves one (the poster
    /// metrics' shelf total); nil sizes the row to its content.
    var rowHeight: CGFloat? = nil
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CinematicSectionHeader(title: title, count: count, destination: destination)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        cell(item)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: rowHeight)
            .shelfEdgeFade()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - See-all grid page

/// The shared "See all" page: a fixed header with the tab's own
/// search field and an honest "N of N" count line, over the
/// catalog grid (adaptive columns — three across on phones, the
/// app's poster-metrics idiom), paginated as the grids always
/// were (90 per page, next page as the end approaches). The
/// search filters the page's OWN items by title with the app's
/// one fuzzy matcher — the same synchronous filter the Recently
/// Added page always ran in its body.
struct CatalogGridView<Item: Identifiable, Cell: View>: View {
    let title: String
    let items: [Item]
    var searchPlaceholder: String
    /// Title accessor for the in-section search.
    let itemTitle: (Item) -> String
    /// SF Symbol for the no-results empty state — a film
    /// strip for Movies; Series pages pass "tv" so the empty
    /// state speaks the section's own language.
    var emptySystemImage: String = "film"
    @ViewBuilder let cell: (Item) -> Cell

    @Environment(\.posterMetrics) private var posterMetrics
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var visibleCount = 90
    private let pageSize = 90

    private var filteredItems: [Item] {
        let q = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { CatalogTextSearch.matchesSectionFuzzy(search: q, text: itemTitle($0)) }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMetrics.categoryGridPosterWidth), spacing: posterMetrics.gridSpacing)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header (build 81 item 7 placement law): the
            // field never sits inside the scroll view.
            VStack(alignment: .leading, spacing: 8) {
                CatalogSearchField(text: $searchText, placeholder: searchPlaceholder)

                Text(L("catalog.count_of_total", filteredItems.count, items.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)

            if filteredItems.isEmpty {
                if debouncedQuery.isEmpty {
                    ContentUnavailableView(L("list.no_result"), systemImage: emptySystemImage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView.search(text: debouncedQuery)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: posterMetrics.gridRowSpacing) {
                        ForEach(Array(filteredItems.prefix(visibleCount).enumerated()), id: \.element.id) { index, item in
                            cell(item)
                                .onAppear {
                                    if index >= visibleCount - 15 {
                                        visibleCount = min(visibleCount + pageSize, filteredItems.count)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    if visibleCount < filteredItems.count {
                        BrandedLoader(size: 28)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                // Build 88 (F3): the floating tab bar never covers
                // the grid's last row.
                .contentMargins(.bottom, 40, for: .scrollContent)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .cinematicBackground()
        // The app pattern: 280 ms debounce, then the filter pass.
        .task(id: searchText) {
            let text = searchText
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, searchText == text else { return }
            debouncedQuery = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .onChange(of: debouncedQuery) { _, _ in visibleCount = pageSize }
    }
}
