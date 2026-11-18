import SwiftUI
import GRDB
import GRDBQuery

/// Round 20 (R20-5): combined trigger for the Live tab's catalog
/// recompute — the live row count rides along so the pass re-runs
/// the moment the live fetch publishes (the store publishes live →
/// vod → series progressively) instead of waiting for
/// `streamsLoaded`, which only flips after the LAST type lands.
private struct LiveRecomputeToken: Equatable {
    let loaded: Bool
    let liveCount: Int
}

struct LiveStreamsView: View {
    let playlist: Playlist
    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @ObservedObject private var orderStore = CategoryOrderStore.shared
    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @Environment(\.epgSnapshot) private var epgSnapshot
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.posterMetrics) private var posterMetrics
    @State private var heroScrollVisible = false
    @Query<RecentWatchHistoryRequest> private var recentLiveHistory: [DBWatchHistory]

    @State private var showSearchSheet = false
    @State private var homeSearchText = ""
    // === B5 (build 61) Item 11: Multiview entry state — wave-2 (B8) preserve ===
    @State private var showMultiview = false
    // === End B5 Item 11 state ===
    // B3 (Round 14): Live tab Favorites filter chip — when on, the
    // shelves/queue below contain favorite channels only (real
    // DBFavorite rows via FavoriteLiveRequest).
    @State private var favoritesOnly = false
    @Query<FavoriteLiveRequest> private var favoriteLiveChannels: [LiveStreamWithCategory]

    // Round 8 (D-4/D-5): Live's round-5 filter chips are GONE. The
    // Favorites chip duplicated the nav-bar star's FavoritesView and
    // the History chip duplicated the Continue Watching row — the
    // no-duplication rule keeps ONE entry each (star + row), and Live
    // never had a Newest data path (DBLiveStream carries no added
    // date), so no chips remain on this tab. The favorites/history chip
    // grids and their queries went with the chips.
    init(playlist: Playlist) {
        self.playlist = playlist
        _recentLiveHistory = Query(
            RecentWatchHistoryRequest(playlistId: playlist.id, limit: 1, type: "live"),
            in: \.appDatabase
        )
        _favoriteLiveChannels = Query(
            FavoriteLiveRequest(playlistId: playlist.id),
            in: \.appDatabase
        )
    }

    @State private var displayCategories: [DBCategory] = []
    @State private var displayItemsByCategory: [String: [LiveStreamWithCategory]] = [:]
    /// Round 8 (audit A3): the derived channel sections, cached by
    /// `recomputeFilter()` — the only place their two inputs change.
    /// They used to be a computed property that re-mapped every channel
    /// wrapper on each body pass (count line, hero, trending and the
    /// playback queue each re-ran the mapping).
    @State private var liveChannelSections: [LiveChannelCategorySection] = []

    private var liveHiddenIds: Set<String> { hiddenStore.hiddenIds(playlistId: playlist.id, type: "live") }
    @State private var showingCategoryPicker = false
    @State private var pendingScrollTarget: String? = nil
    // Build 61 (B3, item 5): parental lock guard for direct channel
    // playback — a selection whose category is PIN-locked waits
    // here until the PIN sheet verifies. (B8: preserve this guard
    // when editing this file; the store/API is ParentalControlStore.)
    @State private var parentalPendingSelection: LivePlayerSelection?
    @State private var showParentalPIN = false

    private var livePlaybackQueue: [DBLiveStream] {
        // Round 8 (audit A3): flattened from the cached sections. The
        // sections are the non-empty visible categories in shelf order,
        // so this is content- and order-identical to the old per-category
        // flatMap (empty categories contributed nothing).
        liveChannelSections.flatMap(\.streams)
    }

    private var pickerEntries: [CategoryPickerSheet.Entry] {
        // B1 (Round 14): hidden categories are NOT jump targets —
        // the picker only lists visible categories (the picker sheet
        // itself stays the place where hiding is managed).
        orderStore.applyOrder(
            contentStore.liveCategories.filter { !liveHiddenIds.contains($0.id) },
            playlistId: playlist.id, type: "live"
        ) { $0.id }.map { cat in
            CategoryPickerSheet.Entry(
                id: cat.id,
                name: cat.name,
                count: contentStore.liveStreamsByCategoryId[cat.id]?.count ?? 0
            )
        }
    }

    private func liveQueueIndex(for stream: DBLiveStream) -> Int? {
        livePlaybackQueue.firstIndex(where: { $0.streamId == stream.streamId })
    }

    /// Hero channel rule (deterministic): the most recently watched live
    /// channel when watch history holds one that still exists in the
    /// catalog; otherwise the first channel of the first category (the
    /// head of the playback queue).
    private var heroStream: DBLiveStream? {
        if let item = recentLiveHistory.first, let match = liveStream(for: item) {
            return match
        }
        return livePlaybackQueue.first
    }

    private func heroHistory(for stream: DBLiveStream) -> DBWatchHistory? {
        guard let item = recentLiveHistory.first, Int(item.streamId) == stream.streamId else { return nil }
        return item
    }

    /// The hero subtitle is the channel's REAL current EPG programme title;
    /// nil when the guide has nothing for the channel (subtitle omitted).
    private func heroNowTitle(for stream: DBLiveStream) -> String? {
        guard let snapshot = epgSnapshot else { return nil }
        return snapshot[EPGChannelKey.forXtream(stream)]?.now?.title
    }

    /// The hero's live preview may run only while the hero is actually on
    /// screen and nothing covers the tab: hero inside the scroll viewport,
    /// app in the foreground (also pre-empts any automatic PiP hand-off of
    /// the preview surface), no player overlay (fullscreen or mini), and no
    /// sheet up (global search, category picker).
    private var heroPreviewActive: Bool {
        heroScrollVisible
            && scenePhase == .active
            && playerOverlay.presentation == nil
            && playerOverlay.pendingPresentation == nil
            && !showSearchSheet
            && !showingCategoryPicker
    }

    /// Trending rule (round 3): the FIRST channel of each visible category,
    /// in category order, capped at 15. Round 2 took the first 15 queue
    /// entries, which on real playlists is one category's near-identical
    /// logos repeated; one-per-category keeps the row diverse. Sections are
    /// the visible (non-hidden, non-empty) categories in shelf order.
    private var trendingStreams: [DBLiveStream] {
        var result: [DBLiveStream] = []
        for section in liveChannelSections {
            guard let first = section.streams.first else { continue }
            result.append(first)
            if result.count == 15 { break }
        }
        return result
    }

    var body: some View {
        Group {
            if displayCategories.isEmpty {
                // Round 20 (R20-5): the Home tab's round-12 guard,
                // which this tab never got. Phase 1 of the catalog
                // load sets isLoading=false with categories only,
                // while streamsLoaded stays false until ALL of phase
                // 2 lands — the old condition fell through to
                // "No category found" for that whole window on every
                // cold open (owner recording, build 54). Until the
                // streams have actually loaded (and there is no error
                // to show instead), an empty display set means
                // LOADING, not empty.
                if contentStore.isLoading || playlist.id != contentStore.activePlaylistId
                    || (!contentStore.streamsLoaded && contentStore.loadError == nil) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text(contentStore.loadingMessage ?? L("live.empty.preparing"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError = contentStore.loadError {
                    CatalogLoadErrorView(message: loadError) {
                        Task { await contentStore.loadPlaylist(playlist) }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "tv.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(L("live.empty.no_category"))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                contentList
            }
        }
        // Round 3: the tab's native `.searchable` bar is GONE — the Live tab
        // has exactly ONE search entry, the HomeSearchBar in the home header
        // (mockup position), which presents the global SearchView. In-tab
        // shelf filtering went with it; AllLiveView and the category
        // detail screens keep their own search fields.
        .task(id: LiveRecomputeToken(loaded: contentStore.streamsLoaded, liveCount: contentStore.liveStreams.count)) { await recomputeFilter() }
        .task(id: hiddenStore.hiddenIds(playlistId: playlist.id, type: "live")) { await recomputeFilter() }
        .task(id: orderStore.orderedIds(playlistId: playlist.id, type: "live")) { await recomputeFilter() }
        .task(id: favoritesOnly) { await recomputeFilter() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    EPGGuideView(source: .xtream(playlist))
                } label: {
                    Image(systemName: "calendar.day.timeline.left")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel(L("epg.guide.title"))
            }
            // === B5 (build 61) Item 11: Multiview entry — wave-2 (B8) preserve this item ===
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showMultiview = true
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.body.weight(.semibold))
                }
                .disabled(contentStore.liveCategories.isEmpty)
                .accessibilityLabel(L("multiview.title"))
            }
            // === End B5 Item 11 entry ===
            // Round 8 (D-2): NO toolbar grid icon — AllLiveView was
            // reachable twice from this tab (here + the Trending
            // shelf's "See all"). The shelf entry stays as the ONE
            // path, matching the Movies/Series treatment.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingCategoryPicker = true
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(.body.weight(.semibold))
                }
                .disabled(contentStore.liveCategories.isEmpty)
                .accessibilityLabel(L("list.jump_to_category"))
            }
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerSheet(
                title: L("category_picker.title"),
                entries: pickerEntries,
                playlistId: playlist.id,
                type: "live"
            ) { id in
                showingCategoryPicker = false
                pendingScrollTarget = id
            }
        }
        // Build 61 (B3, item 5): PIN sheet for the playback guard
        // in presentLiveSelection — success session-unlocks the
        // category and plays the pending selection.
        .sheet(isPresented: $showParentalPIN) {
            PINEntrySheet(message: L("parental.locked.enter_pin")) {
                if let pending = parentalPendingSelection {
                    if let categoryId = pending.stream.categoryId {
                        ParentalControlStore.shared.unlockForSession(
                            playlistId: playlist.id, type: "live", categoryId: categoryId
                        )
                    }
                    parentalPendingSelection = nil
                    presentLiveSelection(pending)
                }
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            NavigationStack {
                // Round 10: SearchView owns its big title — the
                // wrapper's inline title was removed.
                SearchView(playlist: playlist, searchText: $homeSearchText)
            }
        }
        // === B5 (build 61) Item 11: Multiview sheet — wave-2 (B8) preserve ===
        .fullScreenCover(isPresented: $showMultiview) {
            MultiviewView(playlist: playlist)
        }
        // === End B5 Item 11 sheet ===
        .cinematicBackground()
    }

    private func presentLiveSelection(_ selection: LivePlayerSelection) {
        // Build 61 (B3, item 5): a channel in a PIN-locked category
        // does not start playing until the PIN is entered (the PIN
        // sheet's success re-enters this function with the category
        // session-unlocked).
        if ParentalControlStore.shared.isBlocked(
            playlistId: playlist.id, type: "live", categoryId: selection.stream.categoryId
        ) {
            parentalPendingSelection = selection
            showParentalPIN = true
            return
        }
        playerOverlay.present(playlistId: playlist.id) {
            LivePlayerShell(
                playlist: playlist,
                queue: livePlaybackQueue,
                sections: liveChannelSections,
                initialStream: selection.stream,
                initialHistory: selection.history,
                subtitle: nil
            )
        }
    }

    private func presentHistoryItem(_ item: DBWatchHistory) {
        guard let url = historyURL(for: item) else { return }
        if item.type == "series" {
            playerOverlay.present(playlistId: playlist.id) {
                HistorySeriesPlayerShell(playlist: playlist, history: item, url: url)
            }
        } else if item.type == "live" {
            let stream = liveStream(for: item) ?? DBLiveStream(
                streamId: Int(item.streamId) ?? 0,
                name: item.title,
                streamIcon: item.imageURL,
                categoryId: nil,
                sortIndex: 0,
                playlistId: item.playlistId
            )
            playerOverlay.present(playlistId: playlist.id) {
                LivePlayerShell(
                    playlist: playlist,
                    queue: livePlaybackQueue,
                    sections: liveChannelSections,
                    initialStream: stream,
                    initialHistory: item,
                    subtitle: nil
                )
            }
        } else {
            playerOverlay.present(playlistId: playlist.id) {
                PlayerView(
                    url: url,
                    title: item.title,
                    subtitle: item.secondaryTitle,
                    artworkURL: item.imageURL.flatMap { URL(string: $0) },
                    isLiveStream: false,
                    playlistId: playlist.id,
                    streamId: item.streamId,
                    type: item.type,
                    seriesId: item.seriesId,
                    resumeTimeMs: item.lastTimeMs
                )
            }
        }
    }

    /// Home header. Round 5 order was count → search → chips → hero.
    /// Round 7 (owner's direct order: "search must be at the top"): the
    /// search bar is the FIRST element under the title, above the count
    /// line and the hero. The tab still has exactly ONE search entry.
    /// Round 8 removed the chips row (see the init note), so the hero
    /// and Trending shelf render unconditionally.
    @ViewBuilder
    private var homeHeader: some View {
        HomeSearchBar(placeholder: L("home.search_placeholder")) {
            showSearchSheet = true
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)

        // B3: Favorites filter chip (the tab's one filter chip).
        HStack(spacing: 8) {
            PillChipButton(title: L("favorites.title"), isSelected: favoritesOnly) {
                favoritesOnly.toggle()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)

        Text(L("home.count_channels", CatalogCountFormatter.string(liveChannelSections.reduce(0) { $0 + $1.streams.count })))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 10)

        Group {
            if let hero = heroStream {
                LiveHeroCard(
                    stream: hero,
                    nowProgramTitle: heroNowTitle(for: hero),
                    previewURL: PlaybackURLBuilder(playlist: playlist).liveURL(streamId: hero.streamId),
                    previewActive: heroPreviewActive
                ) {
                    presentLiveSelection(LivePlayerSelection(stream: hero, history: heroHistory(for: hero)))
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                // Round 7 (landscape): the hero is 16:9 over the full
                // content width — in landscape that is ~820 pt wide ×
                // ~461 pt tall, taller than the whole viewport. Cap the
                // card at 560 pt wide (≈315 pt tall) and center it;
                // portrait widths (~361 pt) never reach the cap.
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .onScrollVisibilityChange(threshold: 0.25) { visible in
                    heroScrollVisible = visible
                }
            }

            if trendingStreams.count >= 4 {
                TrendingChannelsShelf(
                    playlist: playlist,
                    items: trendingStreams,
                    onStreamSelected: { stream, history in
                        presentLiveSelection(LivePlayerSelection(stream: stream, history: history))
                    }
                )
                .padding(.top, 18)
            }
        }
    }

    private var contentList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                homeHeader

                // Round 8: no chip switch anymore (see the init note) —
                // the shelves are the tab's only content arrangement,
                // with the Continue Watching row as its one History
                // surface.
                ContinueWatchingRow(
                    playlist: playlist,
                    typeFilter: "live",
                    destination: {
                        WatchHistoryListView(playlist: playlist, typeFilter: "live") { item in
                            presentHistoryItem(item)
                        }
                    },
                    onPlay: { item in
                        presentHistoryItem(item)
                    }
                )

                LazyVStack(spacing: 0) {
                    ForEach(displayCategories) { category in
                        LiveCategoryShelfRow(
                            playlist: playlist,
                            category: category,
                            items: displayItemsByCategory[category.id] ?? [],
                            onStreamSelected: { stream, history in
                                presentLiveSelection(LivePlayerSelection(stream: stream, history: history))
                            },
                            isStreamsLoading: !contentStore.streamsLoaded
                        )
                        .equatable()
                        .id(category.id)
                    }
                }
            }
            .refreshable {
                // SwiftUI can cancel the refreshable task when the ScrollView redraws;
                // the cancellation propagated to the child URLSession requests and produced a "cancelled"
                // error. An independent Task is not affected by cancellation; await task.value
                // keeps the spinner until the work finishes.
                let work = Task { await contentStore.refreshFromNetwork(playlist: playlist, only: .live) }
                await work.value
                // C12: success haptic + UI sound on real completion.
                if contentStore.loadError == nil {
                    Haptics.success()
                    AppSound.play(.refreshSuccess)
                }
            }
            .onChange(of: pendingScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    pendingScrollTarget = nil
                }
            }
        }
    }

    private func historyURL(for item: DBWatchHistory) -> URL? {
        let builder = PlaybackURLBuilder(playlist: playlist)
        switch item.type {
        case "live":
            return builder.liveURL(streamId: Int(item.streamId) ?? 0)
        case "vod":
            // MovieDetailView stores streamId as string, builder needs int
            return builder.movieURL(streamId: Int(item.streamId) ?? 0, containerExtension: nil)
        case "series":
            // EpisodeId might be an integer or string in different IPTV setups
            return builder.seriesURL(streamId: item.streamId, containerExtension: nil)
        default:
            return nil
        }
    }

    /// Round 3: with the native search bar removed there is no in-tab
    /// query anymore — the display set is simply every visible category
    /// with its streams, exactly what the old empty-query path produced.
    private func recomputeFilter() async {
        guard playlist.id == contentStore.activePlaylistId else {
            displayCategories = []; displayItemsByCategory = [:]; liveChannelSections = []; return
        }
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "live")
        displayCategories = orderStore.applyOrder(
            contentStore.liveCategories.filter { !hidden.contains($0.id) },
            playlistId: playlist.id, type: "live"
        ) { $0.id }
        displayItemsByCategory = contentStore.liveStreamsByCategoryId
        if favoritesOnly {
            // B3: keep only favorite channels (and categories that
            // still hold one) — hero, trending and the play queue all
            // derive from these same display values.
            let favoriteIds = Set(favoriteLiveChannels.map(\.stream.streamId))
            displayItemsByCategory = displayItemsByCategory.mapValues { items in
                items.filter { favoriteIds.contains($0.stream.streamId) }
            }
            displayCategories = displayCategories.filter { !(displayItemsByCategory[$0.id]?.isEmpty ?? true) }
        }
        // Round 8 (audit A3): cache the sections here — the old computed
        // property's mapping, verbatim — so body, hero, trending and the
        // count line read this instead of re-mapping per render.
        liveChannelSections = displayCategories.compactMap { cat in
            let streams = displayItemsByCategory[cat.id]?.map(\.stream) ?? []
            guard !streams.isEmpty else { return nil }
            return LiveChannelCategorySection(id: cat.id, title: cat.name, streams: streams)
        }
    }

    private func liveStream(for item: DBWatchHistory) -> DBLiveStream? {
        let streamId = Int(item.streamId) ?? 0
        if let match = livePlaybackQueue.first(where: { $0.streamId == streamId }) {
            return match
        }
        // Lazy search: the eager flatMap+map was copying the whole catalog twice and adding
        // tens of ms to the tap latency; .lazy.joined() builds no intermediate array and stops at the .first match.
        return contentStore.liveStreamsByCategoryId.values
            .lazy
            .joined()
            .first(where: { $0.stream.streamId == streamId })?
            .stream
    }
}

// MARK: - Category shelf (horizontal preview)
private enum CategoryShelf {
    static let prefetchHeadCount = 16 // Round 7: 32 → 16 (see ListImagePrefetch — bounds speculative decode work per shelf)
}

struct LiveCategoryShelfRow: View, Equatable {
    let playlist: Playlist
    let category: DBCategory
    let items: [LiveStreamWithCategory]
    var onStreamSelected: ((DBLiveStream, DBWatchHistory?) -> Void)? = nil
    var isStreamsLoading: Bool = false

    static func == (lhs: LiveCategoryShelfRow, rhs: LiveCategoryShelfRow) -> Bool {
        lhs.playlist.id == rhs.playlist.id &&
        lhs.category == rhs.category &&
        lhs.items == rhs.items &&
        lhs.isStreamsLoading == rhs.isStreamsLoading
    }

    @Environment(\.posterMetrics) private var posterMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Round 8: the ONE shelf-header style — was a headline +
            // chevron NavigationLink with a trailing count badge; now
            // CinematicSectionHeader carries the same destination and
            // the same real per-category count badge (elite pattern).
            CinematicSectionHeader(title: category.name, count: items.isEmpty ? nil : items.count) {
                LiveCategoryDetailView(playlist: playlist, category: category)
            }

            if items.isEmpty {
                if isStreamsLoading {
                    Color.clear.frame(height: posterMetrics.liveShelfIcon + 30)
                } else {
                    Text(L("live.empty.no_channel_in_category"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            LiveStreamCard(
                                playlistId: playlist.id,
                                stream: item.stream,
                                width: posterMetrics.liveShelfLabelWidth,
                                iconSize: posterMetrics.liveShelfIcon,
                                imageLoadProfile: .shelf
                            ) { stream, history in
                                onStreamSelected?(stream, history)
                            }
                            .liveCardContextMenu(
                                playlist: playlist,
                                stream: item.stream,
                                categoryId: category.id,
                                categoryName: category.name
                            )
                            // Round 20 (R20-5): as each cell appears,
                            // warm the logos just ahead of it — the
                            // old head-only prefetch left every logo
                            // past the first 16 a cold request during
                            // fast horizontal scrolls.
                            .onAppear {
                                prefetchWindow(from: items, after: index)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onAppear {
                    prefetchIcons(from: items)
                }
                .onDisappear {
                    // Round 20 (R20-5): retract this shelf's
                    // not-yet-started head batch so a fast vertical
                    // fling doesn't leave the shared prefetch queue
                    // full of shelves the user already passed.
                    stopPrefetchIcons(from: items)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func prefetchIcons(from list: [LiveStreamWithCategory]) {
        let urls = list.prefix(CategoryShelf.prefetchHeadCount)
            .compactMap { $0.stream.streamIcon }
            .compactMap { URL(string: $0) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.liveShelfIcon,
            height: posterMetrics.liveShelfIcon,
            loadProfile: .shelf
        )
    }

    /// Round 20 (R20-5): the scroll window ahead of the cell at
    /// `index` (see ListImagePrefetch.scrollWindow).
    private func prefetchWindow(from list: [LiveStreamWithCategory], after index: Int) {
        let start = index + 1
        guard start < list.count else { return }
        let urls = list[start..<min(start + ListImagePrefetch.scrollWindow, list.count)]
            .compactMap { $0.stream.streamIcon }
            .compactMap { URL(string: $0) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.liveShelfIcon,
            height: posterMetrics.liveShelfIcon,
            loadProfile: .shelf
        )
    }

    private func stopPrefetchIcons(from list: [LiveStreamWithCategory]) {
        let urls = list.prefix(CategoryShelf.prefetchHeadCount)
            .compactMap { $0.stream.streamIcon }
            .compactMap { URL(string: $0) }
        ListImagePrefetch.stop(
            urls: urls,
            width: posterMetrics.liveShelfIcon,
            height: posterMetrics.liveShelfIcon,
            loadProfile: .shelf
        )
    }
}

struct LiveStreamCard: View {
    let playlistId: UUID
    let stream: DBLiveStream
    var width: CGFloat = 120
    var iconSize: CGFloat = 120
    var imageLoadProfile: ImageLoadProfile = .standard
    var onStreamSelected: ((DBLiveStream, DBWatchHistory?) -> Void)? = nil

    @Environment(\.epgSnapshot) private var epgSnapshot

    var body: some View {
        Button(action: {
            onStreamSelected?(stream, nil)
        }) {
            VStack(alignment: .center, spacing: 10) {
                CachedImage(
                    url: stream.streamIcon.flatMap { URL(string: $0) },
                    width: iconSize,
                    height: iconSize,
                    cornerRadius: AppTheme.cornerRadius,
                    iconName: "tv",
                    loadProfile: imageLoadProfile
                )

                Text(stream.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: width)
                    .foregroundColor(.primary)

                if let snapshot = epgSnapshot {
                    EPGNowNextLine(nowNext: snapshot[EPGChannelKey.forXtream(stream)],
                                   width: width, reserveSpace: true)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Trending Channels shelf (home header)

/// "Trending Channels" row on the Live home header. There is no popularity
/// signal in the catalog, so the row is deterministic: the FIRST channel of
/// each visible category, in category order (round 3 — one per category
/// keeps the tiles diverse instead of repeating one category's logos).
/// Tiles are the existing `LiveStreamCard` (real logo, name, and real EPG
/// now-line). "See all" opens the existing All Channels grid — the tab's
/// ONE all-grid entry (round 8 dedupe removed the toolbar grid button
/// that duplicated it).
struct TrendingChannelsShelf: View {
    let playlist: Playlist
    let items: [DBLiveStream]
    var onStreamSelected: ((DBLiveStream, DBWatchHistory?) -> Void)? = nil

    @Environment(\.posterMetrics) private var posterMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // B1 (Round 14): renamed — the row is the first channel
            // of each category, i.e. a categories browse, not trending.
            CinematicSectionHeader(title: L("home.browse_categories")) {
                AllLiveView(playlist: playlist)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items.indices, id: \.self) { index in
                        LiveStreamCard(
                            playlistId: playlist.id,
                            stream: items[index],
                            width: posterMetrics.liveShelfLabelWidth,
                            iconSize: posterMetrics.liveShelfIcon,
                            imageLoadProfile: .shelf
                        ) { stream, history in
                            onStreamSelected?(stream, history)
                        }
                        .liveCardContextMenu(
                            playlist: playlist,
                            stream: items[index],
                            categoryId: items[index].categoryId,
                            categoryName: PlaylistContentStore.shared.liveCategories
                                .first(where: { $0.id == items[index].categoryId })?.name
                        )
                        .shelfCardAppear(index: index)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear {
                prefetchIcons(from: items)
            }
        }
        .padding(.bottom, 6)
    }

    /// Round 9 (owner recording, build 45): the trending tiles and the
    /// category-shelf tiles are the SAME `LiveStreamCard` with the same
    /// URL field (`streamIcon`), size and profile — but the category
    /// shelves prefetch their head icons with the exact render request
    /// (see `LiveCategoryShelfRow.prefetchIcons`) while this shelf never
    /// did. Its 15 tiles therefore fired cold in the open-time request
    /// storm (hero logo + live preview + EPG over 4 connections/host),
    /// and a first attempt that timed out left the placeholder up for
    /// the whole session while the same channel's prefetched logo
    /// rendered fine in its category row. Same fix as the rows: warm
    /// the identical requests on appear.
    private func prefetchIcons(from list: [DBLiveStream]) {
        let urls = list.prefix(CategoryShelf.prefetchHeadCount)
            .compactMap { $0.streamIcon }
            .compactMap { URL(string: $0) }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.liveShelfIcon,
            height: posterMetrics.liveShelfIcon,
            loadProfile: .shelf
        )
    }
}

// MARK: - Category Detail View
struct LiveCategoryDetailView: View {
    let playlist: Playlist
    let category: DBCategory

    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var displayItems: [LiveStreamWithCategory] = []

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    private var currentStreams: [DBLiveStream] { displayItems.map(\.stream) }

    var body: some View {
        LiveCategoryContent(
            playlist: playlist,
            items: displayItems,
            onStreamSelected: { stream, history in
                let selection = LivePlayerSelection(stream: stream, history: history)
                playerOverlay.present(playlistId: playlist.id) {
                    LivePlayerShell(
                        playlist: playlist,
                        queue: currentStreams,
                        sections: [LiveChannelCategorySection(id: category.id, title: category.name, streams: currentStreams)],
                        initialStream: selection.stream,
                        initialHistory: selection.history,
                        subtitle: category.name
                    )
                }
            }
        )
        .equatable()
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: L("live.search_placeholder"))
        .onChange(of: searchText) { _, new in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { debouncedQuery = new }
            }
        }
        .onDisappear { debounceTask?.cancel(); debounceTask = nil }
        .task(id: debouncedQuery) { await recomputeItems() }
        .task(id: contentStore.streamsLoaded) { await recomputeItems() }
    }

    private func recomputeItems() async {
        guard playlist.id == contentStore.activePlaylistId else { displayItems = []; return }
        let base = contentStore.liveStreamsByCategoryId[category.id] ?? []
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { displayItems = base; return }
        let result = await Task.detached(priority: .userInitiated) {
            let filtered = base.filter { CatalogTextSearch.matches(search: q, text: $0.stream.name) }
            return CatalogTextSearch.sortLiveByRelevance(filtered, search: q)
        }.value
        guard !Task.isCancelled else { return }
        displayItems = result
    }
}

struct LiveCategoryContent: View, Equatable {
    let playlist: Playlist
    let items: [LiveStreamWithCategory]
    var onStreamSelected: ((DBLiveStream, DBWatchHistory?) -> Void)? = nil

    /// Cheap signature compare (ignores the selection closure) so a parent @Published
    /// re-render doesn't force SwiftUI to re-process a huge channel list. Internal
    /// @State updates still invalidate normally.
    static func == (lhs: LiveCategoryContent, rhs: LiveCategoryContent) -> Bool {
        lhs.playlist.id == rhs.playlist.id
            && lhs.items.count == rhs.items.count
            && lhs.items.first?.stream.streamId == rhs.items.first?.stream.streamId
            && lhs.items.last?.stream.streamId == rhs.items.last?.stream.streamId
    }

    @Environment(\.posterMetrics) private var posterMetrics

    @AppStorage(LiveSortOption.storageKey) private var sortOption: LiveSortOption = .defaultOrder
    @State private var showSortSheet = false
    /// Screen-local toggle filters (catch-up / EPG).
    @State private var filter: LiveStreamFilter = []
    /// Sort/filter output, recomputed off the main thread on input changes.
    @State private var displayItems: [LiveStreamWithCategory] = []
    /// Paginated render count so a huge catalog doesn't build one giant ForEach.
    @State private var visibleCount = Self.pageSize

    private static let pageSize = 90

    /// Cheap O(1) change signal for `items`; avoids O(n) array equality in `.task(id:)`
    /// on every update pass, which froze navigation on huge lists ("All Channels").
    private var itemsToken: Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        hasher.combine(items.first?.stream.streamId)
        hasher.combine(items.last?.stream.streamId)
        return hasher.finalize()
    }

    private var isFilterActive: Bool {
        sortOption != .defaultOrder || !filter.isEmpty
    }

    private func recompute() async {
        let source = items
        let sort = sortOption
        let activeFilter = filter
        let result = await Task.detached(priority: .userInitiated) {
            sort.apply(to: LiveStreamFilter.apply(source, activeFilter))
        }.value
        displayItems = result
        visibleCount = min(Self.pageSize, result.count)
        prefetch(result)
    }

    private func loadMore() {
        guard visibleCount < displayItems.count else { return }
        let pageStart = visibleCount
        visibleCount = min(visibleCount + Self.pageSize, displayItems.count)
        // Round 20 (R20-5): warm the page that is about to be
        // revealed — the old flow only ever prefetched the grid's
        // first 24 logos (at recompute), so every paged-in page
        // painted cold during fast scrolling.
        prefetch(displayItems, startingAt: pageStart)
    }

    var body: some View {
        Group {
            if displayItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(L("list.no_channel"))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                let columns = [
                    GridItem(.adaptive(minimum: posterMetrics.liveGridIconSize), spacing: posterMetrics.gridSpacing)
                ]
                ScrollView {
                    LazyVGrid(columns: columns, spacing: posterMetrics.gridRowSpacing) {
                        ForEach(Array(displayItems.prefix(visibleCount).enumerated()), id: \.element.stream.streamId) { index, item in
                            LiveStreamCard(
                                playlistId: playlist.id,
                                stream: item.stream,
                                width: posterMetrics.liveGridIconSize,
                                iconSize: posterMetrics.liveGridIconSize,
                                imageLoadProfile: .grid,
                                onStreamSelected: onStreamSelected
                            )
                            .liveCardContextMenu(
                                playlist: playlist,
                                stream: item.stream,
                                categoryId: item.stream.categoryId,
                                categoryName: item.categoryName
                            )
                            .onAppear { if index >= visibleCount - 15 { loadMore() } }
                        }
                    }
                    .padding()

                    if visibleCount < displayItems.count {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                sortFilterMenu
            }
        }
        .task(id: itemsToken) { await recompute() }
        .task(id: sortOption) { await recompute() }
        .task(id: filter.rawValue) { await recompute() }
    }

    /// Round 10 (point 13): the raw popover `Menu` is now the
    /// styled `SortFilterSheet` bottom sheet — same state, same
    /// options, same toggle/clear behavior.
    private var sortFilterMenu: some View {
        Button {
            showSortSheet = true
        } label: {
            Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.body.weight(.semibold))
        }
        .accessibilityLabel(L("sort.title"))
        .sheet(isPresented: $showSortSheet) {
            SortFilterSheet(
                sortRows: LiveSortOption.allCases.map { option in
                    SortFilterSheet.Row(
                        id: option.rawValue,
                        title: L(option.titleKey),
                        systemImage: option.systemImage,
                        isSelected: sortOption == option
                    ) { sortOption = option }
                },
                filterTitle: L("filter.title"),
                filterRows: [
                    SortFilterSheet.Row(
                        id: "catchup",
                        title: L("filter.catchup"),
                        isSelected: filter.contains(.catchup)
                    ) { filter.formSymmetricDifference(.catchup) },
                    SortFilterSheet.Row(
                        id: "hasEPG",
                        title: L("filter.has_epg"),
                        isSelected: filter.contains(.hasEPG)
                    ) { filter.formSymmetricDifference(.hasEPG) }
                ],
                // B1 (Round 14): Clear resets the FILTERS and the
                // SORT together — the old clear left a non-default
                // sort silently in force.
                onClearFilters: { filter = []; sortOption = .defaultOrder }
            )
        }
    }

    private func prefetch(_ list: [LiveStreamWithCategory], startingAt: Int = 0) {
        let urls = list.dropFirst(startingAt).prefix(ListImagePrefetch.maxBatch)
            .compactMap { $0.stream.streamIcon }
            .compactMap { URL(string: $0) }
        ListImagePrefetch.start(urls: urls, width: posterMetrics.liveGridIconSize, height: posterMetrics.liveGridIconSize, loadProfile: .grid)
    }
}

// MARK: - All Live (flat, sortable/filterable browse)

/// Flat grid of every channel across categories. Reuses `LiveCategoryContent`, so
/// it inherits the sort menu and catch-up/EPG filters for free.
struct AllLiveView: View {
    let playlist: Playlist

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var displayItems: [LiveStreamWithCategory] = []

    private var currentStreams: [DBLiveStream] { displayItems.map(\.stream) }

    var body: some View {
        LiveCategoryContent(
            playlist: playlist,
            items: displayItems,
            onStreamSelected: { stream, history in
                let all = currentStreams
                playerOverlay.present(playlistId: playlist.id) {
                    LivePlayerShell(
                        playlist: playlist,
                        queue: all,
                        sections: [LiveChannelCategorySection(id: "all", title: L("browse.all_live"), streams: all)],
                        initialStream: stream,
                        initialHistory: history,
                        subtitle: L("browse.all_live")
                    )
                }
            }
        )
        .equatable()
        .navigationTitle(L("browse.all_live"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: L("live.search_placeholder"))
        .onChange(of: searchText) { _, new in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { debouncedQuery = new }
            }
        }
        .onDisappear { debounceTask?.cancel(); debounceTask = nil }
        .task(id: debouncedQuery) { await recompute() }
        .task(id: contentStore.streamsLoaded) { await recompute() }
        .task(id: hiddenStore.hiddenIds(playlistId: playlist.id, type: "live")) { await recompute() }
        .cinematicBackground()
    }

    private func recompute() async {
        guard playlist.id == contentStore.activePlaylistId else { displayItems = []; return }
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "live")
        let source = contentStore.liveStreams
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        // All work off the main thread; the catalog can be very large.
        let result = await Task.detached(priority: .userInitiated) {
            let base = source.filter { !hidden.contains($0.stream.categoryId ?? "") }
            if q.isEmpty { return base }
            let filtered = base.filter { CatalogTextSearch.matches(search: q, text: $0.stream.name) }
            return CatalogTextSearch.sortLiveByRelevance(filtered, search: q)
        }.value
        guard !Task.isCancelled else { return }
        displayItems = result
    }
}

struct LivePlayerSelection: Identifiable {
    let id = UUID()
    let stream: DBLiveStream
    let history: DBWatchHistory?
}

struct LivePlayerShell: View {
    let playlist: Playlist
    let queue: [DBLiveStream]
    let sections: [LiveChannelCategorySection]
    let subtitle: String?
    private let initialStream: DBLiveStream
    private let initialHistory: DBWatchHistory?

    @State private var session: LivePlaybackSession
    @State private var showChannelSidePanel: Bool = false
    @State private var isFavorite = false
    @Environment(\.playerOverlayPresentationID) private var overlayPresentationID

    init(
        playlist: Playlist,
        queue: [DBLiveStream],
        sections: [LiveChannelCategorySection],
        initialStream: DBLiveStream,
        initialHistory: DBWatchHistory?,
        subtitle: String?
    ) {
        self.playlist = playlist
        self.queue = queue
        self.sections = sections
        self.subtitle = subtitle
        self.initialStream = initialStream
        self.initialHistory = initialHistory
        // The sections do not change for the shell's lifetime; build them once instead of re-mapping tens of thousands of channels on every body evaluation (channel zap,
        // panel open/close).
        self.panelSections = sections.map { section in
            ChannelPanelSection(
                id: section.id,
                title: section.title,
                items: section.streams.map { stream in
                    ChannelPanelItem(
                        id: String(stream.streamId),
                        name: stream.name,
                        iconURL: stream.streamIcon.flatMap { URL(string: $0) }
                    )
                }
            )
        }
        let initialURL = PlaybackURLBuilder(playlist: playlist).liveURL(streamId: initialStream.streamId)
        _session = State(initialValue: LivePlaybackSession(
            stream: initialStream,
            url: initialURL,
            resumeTimeMs: initialHistory?.lastTimeMs
        ))
    }

    private var currentIndex: Int? {
        queue.firstIndex(where: { $0.streamId == session.stream.streamId })
    }

    /// Category name of the channel on screen, shown under the title. Derived from the
    /// current stream so it updates on zap, and never echoes the channel name itself.
    private var liveSubtitle: String? {
        if let categoryId = session.stream.categoryId,
           let name = PlaylistContentStore.shared.liveCategories.first(where: { $0.id == categoryId })?.name,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if let subtitle, subtitle != session.stream.name { return subtitle }
        return nil
    }

    private let panelSections: [ChannelPanelSection]

    var body: some View {
        if let url = session.url {
            ZStack(alignment: .bottom) {
                PlayerView(
                    url: url,
                    title: session.stream.name,
                    subtitle: liveSubtitle,
                    artworkURL: session.stream.streamIcon.flatMap { URL(string: $0) },
                    isLiveStream: true,
                    playlistId: playlist.id,
                    streamId: String(session.stream.streamId),
                    type: "live",
                    resumeTimeMs: session.resumeTimeMs,
                    // Build 61 (B10, G2): the playlist's custom
                    // User-Agent reaches the engine's existing
                    // load path through the shell.
                    userAgent: playlist.playbackUserAgent(channelUserAgent: nil),
                    epgChannelKey: EPGChannelKey.forXtream(session.stream),
                    canGoToPreviousChannel: (currentIndex ?? 0) > 0,
                    canGoToNextChannel: {
                        guard let index = currentIndex else { return false }
                        return index < queue.count - 1
                    }(),
                    onPreviousChannel: { jump(offset: -1) },
                    onNextChannel: { jump(offset: 1) },
                    channelPanelSections: panelSections,
                    currentChannelPanelItemId: String(session.stream.streamId),
                    onSelectChannelPanelItem: { id in selectPanelItem(id: id) },
                    isLiveChannelSidePanelVisible: showChannelSidePanel,
                    onToggleLiveChannelSidePanel: {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showChannelSidePanel.toggle()
                        }
                    },
                    onVideoSurfaceTap: {
                        guard showChannelSidePanel else { return }
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showChannelSidePanel = false
                        }
                    },
                    isFavorite: isFavorite,
                    onToggleFavorite: toggleFavorite
                )

                if showChannelSidePanel, !sections.isEmpty {
                    LiveChannelSidePanel(
                        sections: panelSections,
                        currentItemId: String(session.stream.streamId),
                        onSelectChannel: { id in selectPanelItem(id: id) }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .task(id: "\(playlist.id.uuidString)-\(session.stream.streamId)") {
                await refreshFavorite()
            }
            .onChange(of: overlayPresentationID) { _, _ in
                applyInitialSelectionIfNeeded()
            }
        }
    }

    private func applyInitialSelectionIfNeeded() {
        let targetURL = PlaybackURLBuilder(playlist: playlist).liveURL(streamId: initialStream.streamId)
        let targetResume = initialHistory?.lastTimeMs
        guard session.stream.streamId != initialStream.streamId
                || session.url != targetURL
                || session.resumeTimeMs != targetResume else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            showChannelSidePanel = false
            session = LivePlaybackSession(
                stream: initialStream,
                url: targetURL,
                resumeTimeMs: targetResume
            )
        }
    }

    private func selectPanelItem(id: String) {
        guard let streamId = Int(id) else { return }
        guard let stream = queue.first(where: { $0.streamId == streamId })
            ?? sections.flatMap(\.streams).first(where: { $0.streamId == streamId }) else { return }
        switchTo(stream: stream, resumeTimeMs: nil)
    }

    private func jump(offset: Int) {
        guard let index = currentIndex else { return }
        let target = index + offset
        guard target >= 0, target < queue.count else { return }
        let targetStream = queue[target]
        switchTo(stream: targetStream, resumeTimeMs: nil)
    }

    private func switchTo(stream: DBLiveStream, resumeTimeMs: Int?) {
        let targetURL = PlaybackURLBuilder(playlist: playlist).liveURL(streamId: stream.streamId)
        if session.stream.streamId == stream.streamId, session.url == targetURL {
            return
        }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            session = LivePlaybackSession(
                stream: stream,
                url: targetURL,
                resumeTimeMs: resumeTimeMs
            )
        }
    }

    private func refreshFavorite() async {
        let streamId = session.stream.streamId
        let value = (try? await AppDatabase.shared.read { db in
            try DBFavorite
                .filter(Column("streamId") == streamId
                    && Column("playlistId") == playlist.id
                    && Column("type") == "live")
                .fetchCount(db) > 0
        }) ?? false
        guard !Task.isCancelled, session.stream.streamId == streamId else { return }
        isFavorite = value
    }

    private func toggleFavorite() {
        let streamId = session.stream.streamId
        let nextValue = !isFavorite
        isFavorite = nextValue
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    if nextValue {
                        try DBFavorite(
                            streamId: streamId, playlistId: playlist.id, type: "live"
                        ).insert(db)
                    } else {
                        try DBFavorite
                            .filter(Column("streamId") == streamId
                                && Column("playlistId") == playlist.id
                                && Column("type") == "live")
                            .deleteAll(db)
                    }
                }
            } catch {
                if session.stream.streamId == streamId { isFavorite.toggle() }
            }
        }
    }
}

struct LivePlaybackSession: Equatable {
    var stream: DBLiveStream
    var url: URL?
    var resumeTimeMs: Int?
}
