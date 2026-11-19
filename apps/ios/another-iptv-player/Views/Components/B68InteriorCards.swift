import SwiftUI
import GRDB
import GRDBQuery

// MARK: - Build 68 (W-B): section interiors — owner picks
//
// Movies "Cinema Rows", Series "Progress Grid" (Continue Watching
// wide cards) and Live TV "Channel Tiles". Every value rendered
// here comes from a real model field: ratings/years render only
// when the record carries them, and resume bars only from real
// resume state. Build 68 owner order: the TV Guide / EPG feature
// is REMOVED from the app entirely — the Live TV tiles below are
// logo + channel name only, with no programme lines at all.

// MARK: - Movies: Cinema Rows

/// One wide (16:9) movie card for the Cinema Rows rails: artwork
/// (the record's real backdrop when it carries one, else its poster
/// filled/cropped wide through the existing `CachedImage` path),
/// a bottom-gradient scrim carrying the title and a meta line built
/// ONLY from real fields — "year • ★rating", each part omitted when
/// the record has no parseable year / no valid normalized rating.
struct MovieCinemaWideCard: View {
    let movie: DBVODStream
    var cardWidth: CGFloat = 272
    var cardHeight: CGFloat = 153

    private var artworkURL: URL? {
        if let backdrop = movie.backdropPath?.trimmingCharacters(in: .whitespaces), !backdrop.isEmpty {
            return URL(string: backdrop)
        }
        return movie.streamIcon.flatMap { URL(string: $0) }
    }

    /// "2026 • ★8.4" — year from the record's real release date,
    /// rating from the ONE normalized rating value; nil when the
    /// record carries neither (the line is then omitted entirely).
    private var metaLine: String? {
        var parts: [String] = []
        if let year = DetailFormatting.year(from: movie.releaseDate) {
            parts.append(year)
        }
        if let rating = ContentRating.normalizedDisplayText(
            rating: movie.rating, rating5Based: movie.rating5Based
        ) {
            parts.append("★\(rating)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedImage(
                url: artworkURL,
                width: cardWidth,
                height: cardHeight,
                cornerRadius: AppTheme.cornerRadius,
                contentMode: .fill,
                iconName: "film",
                loadProfile: .shelf
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: Color.black.opacity(0.82), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 3) {
                Text(movie.name)
                    .font(AppTheme.fontCardTitle)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let metaLine {
                    Text(metaLine)
                        .font(AppTheme.fontMetadata.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(width: cardWidth, alignment: .leading)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(AppTheme.cardBorderColor, lineWidth: 0.5)
        )
    }
}

/// One Cinema Row: a heading row (category name left, "See all ›"
/// in the accent right — a NavigationLink to that category's
/// EXISTING full grid, `VODCategoryDetailView`) over a horizontal
/// rail of wide cards. Tapping a card opens the same movie detail
/// (with the same queue) the poster shelf opened.
struct VODCinemaCategoryRow: View, Equatable {
    let playlist: Playlist
    let category: DBCategory
    let items: [VODWithCategory]
    var isStreamsLoading: Bool = false

    static func == (lhs: VODCinemaCategoryRow, rhs: VODCinemaCategoryRow) -> Bool {
        lhs.playlist.id == rhs.playlist.id &&
        lhs.category == rhs.category &&
        lhs.items == rhs.items &&
        lhs.isStreamsLoading == rhs.isStreamsLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(category.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !items.isEmpty {
                    Text(CatalogCountFormatter.string(items.count))
                        .font(AppTheme.fontBadge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.accent))
                }
                Spacer()
                NavigationLink {
                    VODCategoryDetailView(playlist: playlist, category: category)
                } label: {
                    HStack(spacing: 3) {
                        Text(L("category.see_all"))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .font(AppFont.font(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(PressScaleButtonStyle())
            }
            .padding(.horizontal, 16)

            if items.isEmpty {
                if isStreamsLoading {
                    Color.clear.frame(height: 153)
                } else {
                    Text(L("vod.empty.no_in_category"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            } else {
                let queue = items.map(\.stream)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            NavigationLink {
                                MovieDetailView(playlist: playlist, movie: item.stream, queue: queue)
                            } label: {
                                MovieCinemaWideCard(movie: item.stream)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .shelfEdgeFade()
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Series: Progress Grid — Continue Watching wide cards

/// The Series landing's Continue Watching rail (owner pick:
/// "Progress Grid" top row): wide cards fed by the SAME watch
/// history data behind `ContinueSeriesRow` (`RecentWatchHistory
/// Request`, type "series" — one card per series, its latest
/// in-progress episode). Each card shows the series' real artwork
/// (backdrop, else cover, else the history image), its title, the
/// "S# • E#" badge from the parent's real per-series progress pass
/// (`SeriesProgressInfo`, derived from watch history joined to the
/// episode record) and a progress bar from the real resume state.
/// The row renders NOTHING when no series is in progress.
struct SeriesProgressContinueRow: View {
    let playlist: Playlist
    var progressBySeriesId: [String: SeriesProgressInfo] = [:]
    var onPlay: (DBWatchHistory) -> Void

    @Query<RecentWatchHistoryRequest> private var historyItems: [DBWatchHistory]
    @ObservedObject private var contentStore = PlaylistContentStore.shared

    init(playlist: Playlist, progressBySeriesId: [String: SeriesProgressInfo], onPlay: @escaping (DBWatchHistory) -> Void) {
        self.playlist = playlist
        self.progressBySeriesId = progressBySeriesId
        self.onPlay = onPlay
        _historyItems = Query(
            RecentWatchHistoryRequest(playlistId: playlist.id, limit: 30, type: "series"),
            in: \.appDatabase
        )
    }

    /// One card per series (latest episode record first), kept only
    /// while that episode is genuinely in progress — the same
    /// dedupe/finished rule `ContinueWatchingRow` applies.
    private var displayItems: [DBWatchHistory] {
        var seenSeries = Set<String>()
        var result: [DBWatchHistory] = []
        for item in historyItems {
            guard let seriesId = item.seriesId, !seriesId.isEmpty else { continue }
            guard seenSeries.insert(seriesId).inserted else { continue }
            if item.durationMs > 0,
               Double(item.lastTimeMs) / Double(item.durationMs) >= 0.98 {
                continue
            }
            result.append(item)
            if result.count >= 10 { break }
        }
        return result
    }

    var body: some View {
        if !displayItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CinematicSectionHeader(title: L("series.continue.title")) {
                    WatchHistoryListView(playlist: playlist, typeFilter: "series") { item in
                        onPlay(item)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(displayItems) { item in
                            SeriesContinueWideCard(
                                item: item,
                                series: seriesRecord(for: item),
                                positionText: item.seriesId.flatMap { progressBySeriesId[$0]?.positionText }
                            )
                            .onTapGesture { onPlay(item) }
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
                }
                .shelfEdgeFade()
            }
            .padding(.vertical, 6)
        }
    }

    private func seriesRecord(for item: DBWatchHistory) -> DBSeries? {
        guard let seriesId = item.seriesId else { return nil }
        return contentStore.seriesItems.first(where: { "\($0.series.seriesId)" == seriesId })?.series
    }

    /// The same real history-row deletion `ContinueWatchingRow`'s
    /// long-press performs (the row's only data source).
    private func removeHistoryItem(_ item: DBWatchHistory) {
        let id = item.id
        Task {
            try? await AppDatabase.shared.write { db in
                try DBWatchHistory.filter(Column("id") == id).deleteAll(db)
            }
        }
    }
}

/// One wide Continue Watching card for a series in progress.
private struct SeriesContinueWideCard: View {
    let item: DBWatchHistory
    let series: DBSeries?
    var positionText: String? = nil
    var cardWidth: CGFloat = 272
    var cardHeight: CGFloat = 153

    private var artworkURL: URL? {
        if let backdrop = series?.backdropPath?.trimmingCharacters(in: .whitespaces), !backdrop.isEmpty {
            return URL(string: backdrop)
        }
        if let cover = series?.cover?.trimmingCharacters(in: .whitespaces), !cover.isEmpty {
            return URL(string: cover)
        }
        return item.imageURL.flatMap { URL(string: $0) }
    }

    private var title: String {
        series?.name ?? item.secondaryTitle ?? item.title
    }

    /// Real resume fraction from the history row itself; nil when
    /// the row carries no duration (no bar is drawn then).
    private var progress: Double? {
        guard item.durationMs > 0 else { return nil }
        return min(max(Double(item.lastTimeMs) / Double(item.durationMs), 0), 1)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedImage(
                url: artworkURL,
                width: cardWidth,
                height: cardHeight,
                cornerRadius: AppTheme.cornerRadius,
                contentMode: .fill,
                iconName: "play.tv",
                loadProfile: .shelf
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: Color.black.opacity(0.82), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(AppTheme.fontCardTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if let positionText {
                        Text(positionText)
                            .font(AppTheme.fontBadge)
                            .foregroundStyle(AppTheme.onAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(AppTheme.accent))
                            .lineLimit(1)
                    }
                }
                if let progress {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25)).frame(height: 3)
                        Capsule().fill(AppTheme.accent).frame(width: max(0, (cardWidth - 24) * progress), height: 3)
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(width: cardWidth, alignment: .leading)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(AppTheme.cardBorderColor, lineWidth: 0.5)
        )
    }
}

// MARK: - Live TV: Channel Tiles — Xtream tile

/// The grid form of a live channel (owner pick: "Channel Tiles"):
/// a card surface with the channel's big centered logo and its
/// name — ONLY (build 68 owner order: the TV Guide / EPG is
/// removed, so tiles carry no programme lines, no progress bar).
/// The NEW / pin / audio-only overlays on the logo are the same
/// real store states `LiveStreamCard` renders.
struct ChannelTileCard: View {
    let playlistId: UUID
    let stream: DBLiveStream
    var width: CGFloat = 120
    var iconSize: CGFloat = 120
    var imageLoadProfile: ImageLoadProfile = .standard
    var onStreamSelected: ((DBLiveStream, DBWatchHistory?) -> Void)? = nil

    @ObservedObject private var firstSeenStore = FirstSeenStore.shared
    @ObservedObject private var pinnedStore = PinnedChannelStore.shared
    @ObservedObject private var audioOnlyStore = AudioOnlyStore.shared

    var body: some View {
        Button(action: {
            onStreamSelected?(stream, nil)
        }) {
            VStack(alignment: .center, spacing: 6) {
                CachedImage(
                    url: stream.streamIcon.flatMap { URL(string: $0) },
                    width: max(iconSize - 28, 40),
                    height: max(iconSize - 28, 40),
                    cornerRadius: AppTheme.cornerRadius,
                    iconName: "tv",
                    loadProfile: imageLoadProfile
                )
                .overlay(alignment: .topLeading) {
                    if firstSeenStore.isNewLive(playlistId: playlistId, streamId: stream.streamId) {
                        NewContentBadge()
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if pinnedStore.isPinned(playlistId: playlistId, streamId: stream.streamId) {
                        Image(systemName: "pin.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if audioOnlyStore.isEnabled(playlistId: playlistId, streamId: stream.streamId) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(AppTheme.accent, in: Circle())
                            .padding(6)
                            .accessibilityLabel(L("audioonly.badge"))
                    }
                }

                Text(stream.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: max(width - 12, 40))
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(width: width)
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
    }
}

// MARK: - Live TV: Channel Tiles — M3U tile

/// The M3U grid's channel tile — the `ChannelTileCard` treatment
/// over an M3U channel: big centered logo (`tvgLogo`) and name
/// ONLY (build 68 owner order: no guide/programme lines — the TV
/// Guide / EPG feature is removed). Its context menu is the SAME
/// menu `M3UChannelCard` carries (favorite / pin / hide / VOD
/// download), unchanged.
struct M3UChannelTileCard: View {
    let channel: DBM3UChannel
    var width: CGFloat = 120
    var iconSize: CGFloat = 120
    var imageLoadProfile: ImageLoadProfile = .standard
    var onChannelSelected: ((DBM3UChannel) -> Void)? = nil

    var body: some View {
        Button {
            onChannelSelected?(channel)
        } label: {
            VStack(alignment: .center, spacing: 6) {
                CachedImage(
                    url: channel.tvgLogo.flatMap { URL(string: $0) },
                    width: max(iconSize - 28, 40),
                    height: max(iconSize - 28, 40),
                    cornerRadius: AppTheme.cornerRadius,
                    iconName: "tv",
                    loadProfile: imageLoadProfile
                )

                Text(channel.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: max(width - 12, 40))
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(width: width)
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
        .contextMenu {
            let isFavorite = M3UFavoriteStore.shared.isFavorite(channelId: channel.id)
            Button {
                Task { await M3UFavoriteStore.shared.toggle(channel: channel) }
            } label: {
                Label(isFavorite ? L("favorites.remove") : L("favorites.add"),
                      systemImage: isFavorite ? "star.slash" : "star")
            }
            let isPinned = PinnedChannelStore.shared.isPinnedM3U(playlistId: channel.playlistId, channelId: channel.id)
            Button {
                PinnedChannelStore.shared.toggleM3U(playlistId: channel.playlistId, channelId: channel.id)
            } label: {
                Label(isPinned ? L("channels.unpin") : L("channels.pin"),
                      systemImage: isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                HiddenChannelStore.shared.setHiddenM3U(true, playlistId: channel.playlistId, channelId: channel.id)
            } label: {
                Label(L("channels.hide"), systemImage: "eye.slash")
            }
            if let url = M3UParser.sanitizedURL(from: channel.url) {
                let cls = M3UStreamClassifier.classify(url: url, groupTitle: channel.groupTitle)
                if !cls.isLive {
                    M3UDownloadMenuItems(
                        id: DownloadManager.idFor(m3uChannel: channel.playlistId, channelId: channel.id),
                        playlistId: channel.playlistId,
                        streamId: channel.id,
                        title: channel.name,
                        secondaryTitle: channel.groupTitle,
                        imageURL: channel.tvgLogo,
                        remoteURL: url,
                        containerExtension: cls.containerExtension
                    )
                }
            }
        }
    }
}
