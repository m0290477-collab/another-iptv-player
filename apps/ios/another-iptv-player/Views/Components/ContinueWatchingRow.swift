import SwiftUI
import GRDB
import GRDBQuery

struct ContinueWatchingRow<Destination: View>: View {
    let playlist: Playlist
    let typeFilter: String?
    @Query<RecentWatchHistoryRequest> private var historyItems: [DBWatchHistory]
    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ViewBuilder let destination: () -> Destination
    var onPlay: (DBWatchHistory) -> Void

    init(
        playlist: Playlist,
        typeFilter: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination,
        onPlay: @escaping (DBWatchHistory) -> Void
    ) {
        self.playlist = playlist
        self.typeFilter = typeFilter
        self.destination = destination
        self.onPlay = onPlay
        _historyItems = Query(
            // Finisher (C8): fetch more than the row shows — the
            // series dedupe below collapses several episode records
            // into one card, so a limit of 10 could starve the row.
            RecentWatchHistoryRequest(playlistId: playlist.id, limit: 30, type: typeFilter),
            in: \.appDatabase
        )
    }

    /// C8 Continue Watching cleanup (finisher): ONE card per series.
    /// `historyItems` arrives ordered by `lastWatchedAt` descending,
    /// one record per EPISODE for series. For each series only its
    /// LATEST episode record is considered:
    /// - if that latest episode is finished (≥98% watched), the
    ///   series exits the row entirely — a finished episode also
    ///   drops off automatically whenever a newer episode has
    ///   started, because the newer record is then the latest one;
    /// - otherwise the latest (in-progress) episode is the series'
    ///   single card.
    /// Non-series items pass through unchanged. The row shows at
    /// most 10 cards, as before.
    private var displayItems: [DBWatchHistory] {
        var seenSeries = Set<String>()
        var result: [DBWatchHistory] = []
        for item in historyItems {
            if item.type == "series", let seriesId = item.seriesId, !seriesId.isEmpty {
                guard seenSeries.insert(seriesId).inserted else { continue }
                if item.durationMs > 0,
                   Double(item.lastTimeMs) / Double(item.durationMs) >= 0.98 {
                    continue
                }
            }
            result.append(item)
            if result.count >= 10 { break }
        }
        return result
    }

    var body: some View {
        if !displayItems.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                // Round 8: the ONE shelf-header style (CinematicSection
                // Header) — this row used its own title+chevron header
                // at 20 pt padding while every other shelf sits at 16.
                // The header's link still opens the same full history
                // list; the row is now also the tabs' ONE History
                // surface (the duplicate History chip grid was removed).
                CinematicSectionHeader(title: L("continue_watching.title"), destination: destination)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(displayItems) { item in
                            HistoryCard(
                                item: item,
                                backdropURL: backdropURL(for: item),
                                metaText: metaText(for: item)
                            )
                            .onTapGesture {
                                onPlay(item)
                            }
                            // B3 (Round 14): long-press Remove from
                            // Continue Watching — a REAL deletion of
                            // that watch-history entry (the row's only
                            // data source), not a visual hide.
                            .contextMenu {
                                Button(role: .destructive) {
                                    removeHistoryItem(item)
                                } label: {
                                    Label(L("continue_watching.remove"), systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .padding(.vertical, 12)
        }
    }

    /// B3: deletes the history row backing a Continue Watching card.
    private func removeHistoryItem(_ item: DBWatchHistory) {
        let id = item.id
        Task {
            try? await AppDatabase.shared.write { db in
                try DBWatchHistory.filter(Column("id") == id).deleteAll(db)
            }
        }
    }

    // MARK: - Real catalog lookups (round 10)
    //
    // The history row itself stores only one image URL (usually the
    // poster/cover or channel logo). The card's backdrop and year
    // come from the SAME catalog records the shelves use — looked up
    // in the loaded content store by id. A record the catalog doesn't
    // have (or whose metadata was never loaded) yields nil, and the
    // card falls back to the history image alone. Nothing is derived
    // or invented.

    private func vodRecord(for item: DBWatchHistory) -> DBVODStream? {
        contentStore.vodStreams.first(where: { "\($0.stream.streamId)" == item.streamId })?.stream
    }

    private func seriesRecord(for item: DBWatchHistory) -> DBSeries? {
        guard let seriesId = item.seriesId else { return nil }
        return contentStore.seriesItems.first(where: { "\($0.series.seriesId)" == seriesId })?.series
    }

    /// The item's real 16:9 backdrop when its catalog record carries
    /// one (backdrops arrive with detail loads, so this is nil for a
    /// fresh catalog — the card then uses the blurred-fill poster
    /// treatment instead of a hard crop).
    private func backdropURL(for item: DBWatchHistory) -> URL? {
        let backdrop: String?
        switch item.type {
        case "vod": backdrop = vodRecord(for: item)?.backdropPath
        case "series": backdrop = seriesRecord(for: item)?.backdropPath
        default: backdrop = nil
        }
        guard let raw = backdrop?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// "2026 • Drama" from the record's own fields (point 15).
    private func metaText(for item: DBWatchHistory) -> String? {
        let releaseDate: String?
        let genre: String?
        switch item.type {
        case "vod":
            releaseDate = vodRecord(for: item)?.releaseDate
            genre = vodRecord(for: item)?.genre
        case "series":
            releaseDate = seriesRecord(for: item)?.releaseDate
            genre = seriesRecord(for: item)?.genre
        default:
            return nil
        }
        var parts: [String] = []
        if let year = DetailFormatting.year(from: releaseDate) { parts.append(year) }
        if let first = DetailFormatting.genreList(genre).first { parts.append(first) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

struct HistoryCard: View {
    @State private var fillFraction: CGFloat = 0
    let item: DBWatchHistory
    /// Round 10: the catalog record's real backdrop, when known.
    var backdropURL: URL? = nil
    /// Round 10: "year • genre" from the record's own fields.
    var metaText: String? = nil

    private var historyImageURL: URL? {
        item.imageURL.flatMap { URL(string: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                artLayer

                if item.type != "live" && item.durationMs > 0 {
                    let progress = Double(item.lastTimeMs) / Double(item.durationMs)
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(.black.opacity(0.5))
                            .frame(height: 3)

                        // B12: the bar animates filling on appear
                        // (width from 0 to the real progress).
                        Rectangle()
                            .fill(AppTheme.accent)
                            .frame(width: 160 * min(max(progress, 0), 1) * fillFraction, height: 3)
                    }
                    .cornerRadius(1.5)
                    .onAppear {
                        withAnimation(Motion.animate(.easeOut(duration: 0.7))) { fillFraction = 1 }
                    }
                }
            }
            .frame(width: 160, height: 90)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)

                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 160, alignment: .leading)
        }
    }

    /// Round 10 (owner, build 46): the old card fill-cropped every
    /// image into 160×90 — channel logos came out stretched and
    /// blurry, series posters were center-cropped through faces and
    /// titles. Now, per type:
    /// - live: the dedicated `LiveLogoArt` (round 11 — see below);
    /// - movie/series with a real backdrop: the backdrop fills the
    ///   card (it is 16:9 art — filling is its native shape);
    /// - movie/series with only a poster: the Home-hero treatment —
    ///   a blurred, darkened enlargement of the SAME poster fills
    ///   the card behind the sharp poster shown whole in front.
    @ViewBuilder
    private var artLayer: some View {
        if item.type == "live" {
            LiveLogoArt(url: historyImageURL, width: 160, height: 90)
        } else if let backdropURL {
            CachedImage(
                url: backdropURL,
                width: 160,
                height: 90,
                cornerRadius: AppTheme.cornerRadius,
                contentMode: .fill,
                iconName: item.type == "series" ? "play.tv" : "film"
            )
        } else {
            ZStack {
                CachedImage(
                    url: historyImageURL,
                    width: 160,
                    height: 90,
                    cornerRadius: AppTheme.cornerRadius,
                    contentMode: .fill,
                    iconName: item.type == "series" ? "play.tv" : "film"
                )
                .scaleEffect(1.15)
                .blur(radius: 18)
                .overlay(Color.black.opacity(0.45))

                CachedImage(
                    url: historyImageURL,
                    width: 160,
                    height: 90,
                    cornerRadius: AppTheme.cornerRadius,
                    contentMode: .fit,
                    iconName: item.type == "series" ? "play.tv" : "film"
                )
            }
        }
    }

    /// Secondary line: the stored subtitle (episode/series name)
    /// plus the record's own year • genre when the catalog has them.
    private var subtitleText: String? {
        let parts = [item.secondaryTitle, metaText]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

/// Round 11 (owner, build 47): Continue Watching's live channel
/// logos STILL rendered zoomed/cropped and off-center — the beIN
/// logos were cut at the edges, overflowing their cards — despite
/// round 10's aspect-fit pass on this row, and the See All grid
/// still used `.fill` for every type. The logo now gets ONE
/// dedicated treatment on every Continue Watching surface (this
/// row and `WatchHistoryListView`'s grid):
/// - the WHOLE logo, aspect-fit and centered, inset by a real
///   margin on every side (rendered at card size minus 28×22 pt),
///   so no part of it can touch — let alone cross — the card edge;
/// - behind it, a blurred, darkened enlargement of the SAME logo
///   fills the card (the backdrop may fill; the logo never does),
///   or the neutral surface while no logo is available;
/// - the whole composition is clipped to the card's rounded rect,
///   so nothing can spill outside the card bounds.
struct LiveLogoArt: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    var cornerRadius: CGFloat = AppTheme.cornerRadius

    var body: some View {
        ZStack {
            if let url {
                CachedImage(
                    url: url,
                    width: width,
                    height: height,
                    cornerRadius: cornerRadius,
                    contentMode: .fill,
                    iconName: "tv"
                )
                .scaleEffect(1.15)
                .blur(radius: 18)
                .overlay(Color.black.opacity(0.45))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.surface)
            }

            CachedImage(
                url: url,
                width: max(width - 28, 1),
                height: max(height - 22, 1),
                cornerRadius: 0,
                contentMode: .fit,
                iconName: "tv"
            )
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
