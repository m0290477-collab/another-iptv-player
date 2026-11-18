import SwiftUI

/// Build 61 (B8, R3/R4): Recently Added surfaces.
///
/// - `RecentlyAddedRow`: the Home row COMPONENT (badged items only —
///   the same set `FirstSeenStore.newItemKeys` reports; B7 wires it
///   into Home assembly after the Series row, before Today's Matches
///   per the amended O1; hidden when empty).
/// - `RecentlyAddedView`: the full screen, grouped by type
///   (Channels / Movies / Series; new episodes roll up to their
///   series, R5).
/// - `WhatsNewBanner`: the R4 one-shot Home banner — real added
///   counts per type from `FirstSeenStore.pendingCounts`, shown once
///   per refresh batch, never stacked; tapping opens the Recently
///   Added screen, dismissing clears the pending counts.
///
/// Resolution rule: a badged key whose catalog record no longer
/// exists is skipped here (this is a discovery surface, not a user
/// list — R6's keep-and-mark rule governs favorites/watch-later/
/// groups, whose stores carry snapshots).
struct RecentlyAddedEntry: Identifiable {
    enum Kind { case live, vod, series }
    let kind: Kind
    let key: String
    let title: String
    let imageURL: URL?
    let firstSeen: Date
    var id: String { key }
}

@MainActor
enum RecentlyAddedResolver {
    /// Resolves the playlist's currently-badged items against the
    /// loaded catalog, grouped-ready (newest first overall; the
    /// screen re-groups by kind). A series with new episodes appears
    /// once, keyed by the series.
    static func entries(playlist: Playlist, contentStore: PlaylistContentStore) -> [RecentlyAddedEntry] {
        let badged = FirstSeenStore.shared.newItemKeys(playlistId: playlist.id)
        var result: [RecentlyAddedEntry] = []
        var seenSeries = Set<Int>()
        for (key, date) in badged {
            let parts = key.split(separator: ":").map(String.init)
            guard let type = parts.first else { continue }
            switch type {
            case "live":
                guard parts.count > 1, let streamId = Int(parts[1]),
                      let stream = contentStore.liveStreams.first(where: { $0.stream.streamId == streamId })?.stream
                else { continue }
                result.append(RecentlyAddedEntry(
                    kind: .live, key: key, title: stream.name,
                    imageURL: stream.streamIcon.flatMap { URL(string: $0) }, firstSeen: date))
            case "vod":
                guard parts.count > 1, let streamId = Int(parts[1]),
                      let movie = contentStore.vodStreams.first(where: { $0.stream.streamId == streamId })?.stream
                else { continue }
                result.append(RecentlyAddedEntry(
                    kind: .vod, key: key, title: movie.name,
                    imageURL: movie.streamIcon.flatMap { URL(string: $0) }, firstSeen: date))
            case "series", "episode":
                // "episode:<seriesId>:<episodeId>" rolls up to the series (R5).
                guard parts.count > 1, let seriesId = Int(parts[1]),
                      seenSeries.insert(seriesId).inserted,
                      let series = contentStore.seriesItems.first(where: { $0.series.seriesId == seriesId })?.series
                else { continue }
                result.append(RecentlyAddedEntry(
                    kind: .series, key: "series:\(seriesId)", title: series.name,
                    imageURL: series.cover.flatMap { URL(string: $0) }, firstSeen: date))
            default:
                continue
            }
        }
        return result
    }
}

// MARK: - R3 Home row component

struct RecentlyAddedRow: View {
    let playlist: Playlist
    /// Build 61 fixer (F-3, O1 dedupe): resolver keys ("vod:<id>" /
    /// "series:<id>" / "live:<id>") the earlier Home rows already
    /// show — this row (O1 position 6) drops them. Default empty:
    /// every other call site keeps the full set.
    var excludingKeys: Set<String> = []
    /// Tapping a card hands the resolved entry's catalog identity to
    /// the parent, which routes it through its existing detail/play
    /// paths (Home assembly is B7's job).
    var onSelect: (RecentlyAddedEntry) -> Void

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var firstSeenStore = FirstSeenStore.shared
    @Environment(\.posterMetrics) private var posterMetrics

    private var entries: [RecentlyAddedEntry] {
        RecentlyAddedResolver.entries(playlist: playlist, contentStore: contentStore)
            .filter { !excludingKeys.contains($0.key) }
    }

    var body: some View {
        let items = entries
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CinematicSectionHeader(title: L("newcontent.recently_added")) {
                    RecentlyAddedView(playlist: playlist)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items.prefix(20)) { entry in
                            Button {
                                onSelect(entry)
                            } label: {
                                VStack(spacing: 8) {
                                    ZStack(alignment: .topLeading) {
                                        CachedImage(
                                            url: entry.imageURL,
                                            width: posterMetrics.liveShelfIcon,
                                            height: posterMetrics.liveShelfIcon,
                                            cornerRadius: AppTheme.cornerRadius,
                                            iconName: entry.kind == .live ? "tv" : (entry.kind == .vod ? "film" : "play.tv"),
                                            loadProfile: .shelf
                                        )
                                        NewContentBadge()
                                            .padding(6)
                                    }
                                    Text(entry.title)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(width: posterMetrics.liveShelfLabelWidth)
                                        .foregroundColor(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - R3 full screen

struct RecentlyAddedView: View {
    let playlist: Playlist

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var firstSeenStore = FirstSeenStore.shared
    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @State private var pendingMovie: DBVODStream?
    @State private var pendingSeries: DBSeries?

    private var entries: [RecentlyAddedEntry] {
        RecentlyAddedResolver.entries(playlist: playlist, contentStore: contentStore)
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                // O10 (B7): shared empty-state component, same
                // icon + localized text as before.
                EmptyStateView(iconName: "sparkles", message: L("newcontent.empty"))
            } else {
                List {
                    section(kind: .live, title: L("newcontent.group.channels"))
                    section(kind: .vod, title: L("newcontent.group.movies"))
                    section(kind: .series, title: L("newcontent.group.series"))
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(L("newcontent.recently_added"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $pendingMovie) { movie in
            MovieDetailView(playlist: playlist, movie: movie)
        }
        .navigationDestination(item: $pendingSeries) { series in
            SeriesDetailView(playlist: playlist, series: series)
        }
        .cinematicBackground()
    }

    @ViewBuilder
    private func section(kind: RecentlyAddedEntry.Kind, title: String) -> some View {
        let items = entries.filter { $0.kind == kind }
        if !items.isEmpty {
            Section(header: Text(title)) {
                ForEach(items) { entry in
                    Button {
                        select(entry)
                    } label: {
                        HStack(spacing: 12) {
                            CachedImage(
                                url: entry.imageURL, width: 44, height: 44,
                                cornerRadius: AppTheme.smallCornerRadius,
                                iconName: kind == .live ? "tv" : (kind == .vod ? "film" : "play.tv")
                            )
                            Text(entry.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            NewContentBadge()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func select(_ entry: RecentlyAddedEntry) {
        FirstSeenStore.shared.markOpened(playlistId: playlist.id, itemKey: entry.key)
        switch entry.kind {
        case .live:
            guard let streamId = Int(entry.key.split(separator: ":").last ?? ""),
                  let stream = contentStore.liveStreams.first(where: { $0.stream.streamId == streamId })?.stream
            else { return }
            let live = LiveChannelCategorySection.xtreamLiveQueue()
            playerOverlay.present(playlistId: playlist.id) {
                LivePlayerShell(playlist: playlist, queue: live.queue, sections: live.sections,
                                initialStream: stream, initialHistory: nil, subtitle: nil)
            }
        case .vod:
            guard let streamId = Int(entry.key.split(separator: ":").last ?? "") else { return }
            pendingMovie = contentStore.vodStreams.first(where: { $0.stream.streamId == streamId })?.stream
        case .series:
            guard let seriesId = Int(entry.key.split(separator: ":").last ?? "") else { return }
            pendingSeries = contentStore.seriesItems.first(where: { $0.series.seriesId == seriesId })?.series
        }
    }
}

// MARK: - R4 what's-new banner

/// One dismissible banner per refresh batch (pending counts are
/// cleared on dismiss AND on tap, so it can never stack or repeat).
/// B7/coordinator wires this into Home above the content rows.
struct WhatsNewBanner: View {
    let playlist: Playlist

    @ObservedObject private var firstSeenStore = FirstSeenStore.shared
    @State private var showRecentlyAdded = false

    private var counts: [String: Int] {
        firstSeenStore.pendingCounts(playlistId: playlist.id)
    }

    private var summaryText: String {
        var parts: [String] = []
        if let n = counts["live"], n > 0 { parts.append(L("newcontent.count.channels_format", n)) }
        if let n = counts["vod"], n > 0 { parts.append(L("newcontent.count.movies_format", n)) }
        if let n = counts["series"], n > 0 { parts.append(L("newcontent.count.series_format", n)) }
        if let n = counts["episode"], n > 0 { parts.append(L("newcontent.count.episodes_format", n)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if !counts.isEmpty && !summaryText.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("newcontent.banner.title"))
                        .font(.subheadline.weight(.bold))
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button {
                    FirstSeenStore.shared.clearPending(playlistId: playlist.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("common.close"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(AppTheme.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.cardBorderColor, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                FirstSeenStore.shared.clearPending(playlistId: playlist.id)
                showRecentlyAdded = true
            }
            .padding(.horizontal, 16)
            .sheet(isPresented: $showRecentlyAdded) {
                NavigationStack {
                    RecentlyAddedView(playlist: playlist)
                }
            }
        }
    }
}
