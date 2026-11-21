import Combine
import SwiftUI
import GRDB
import GRDBQuery

/// Round 20 (R20-5): combined trigger for the Live tab's catalog
/// recompute — the live row count rides along so the pass re-runs
/// the moment the live fetch publishes (the store publishes live →
/// vod → series progressively) instead of waiting for
/// `streamsLoaded`, which only flips after the LAST type lands.
/// Build 75 (performance): EVERY recompute input now rides in
/// this one token (health revision, hidden categories/channels,
/// empty-category toggle, category + channel order, favorites
/// toggle, grid search + chip) — the tab used to carry eight
/// separate `.task(id:)` modifiers plus the grid's own, so one
/// appearance could fire the full catalog pass up to nine times.
private struct LiveRecomputeToken: Equatable {
    let loaded: Bool
    let liveCount: Int
    let healthRevision: Int
    let hiddenCategories: Set<String>
    let hiddenChannelsVersion: Int
    let showEmptyCategories: Bool
    let categoryOrder: [String]
    let channelOrderVersion: Int
    let favoritesOnly: Bool
    let gridQuery: String
    let gridCategory: String?
}

/// Build 80: one category group for a channel grid's "All" browse —
/// the category's REAL name from the playlist data plus its channels
/// in display order. Built inside the same detached recompute pass
/// that produces the flat grid list (never in a view body), so the
/// grouped presentation costs no extra catalog walk.
struct LiveChannelGridSection: Identifiable {
    let id: String
    let title: String
    let items: [LiveStreamWithCategory]
}

struct LiveStreamsView: View {
    let playlist: Playlist
    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @ObservedObject private var orderStore = CategoryOrderStore.shared
    // B2 (build 61, item 12): per-category channel order store.
    @ObservedObject private var channelOrderStore = ChannelOrderStore.shared
    // Build 61 (B9, Q10): dead-channel markings (hide-dead filter).
    @ObservedObject private var channelHealth = ChannelHealthStore.shared
    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.posterMetrics) private var posterMetrics
    @State private var heroScrollVisible = false
    @Query<RecentWatchHistoryRequest> private var recentLiveHistory: [DBWatchHistory]

    @State private var showSearchSheet = false
    @State private var homeSearchText = ""
    // Build 61 (B8, Z13): the Live tab's browsing mode — "grid"
    // (large logo grid) is the DEFAULT; "list" is the shelf layout.
    // The choice persists in AppStorage.
    @AppStorage("live.viewMode") private var liveViewMode = "grid"
    @State private var gridSearchText = ""
    @State private var gridDebouncedQuery = ""
    @State private var gridDebounceTask: Task<Void, Never>?
    /// Build 89 (item 3): the grid's sort/filter toggle state,
    /// owned here because the sort/filter entry now lives in the
    /// in-scroll header pill (the navigation bar is hidden on
    /// this tab); it is passed into `LiveCategoryContent` as a
    /// binding, which keeps the grid's processing unchanged.
    @State private var gridFilter: LiveStreamFilter = []
    @State private var gridItems: [LiveStreamWithCategory] = []
    /// Build 80: the grid's "All" browse grouped by category —
    /// the SAME display set as `gridItems` before search/chip
    /// filtering, split per category in catalog category order,
    /// computed inside `recomputeFilter`'s detached pass and
    /// published once with the other display values.
    @State private var gridSections: [LiveChannelGridSection] = []
    /// Build 65 (inside-sections): the grid mode's category chip
    /// selection — nil = every visible channel; a category id
    /// filters the SAME grid (cards already carry their real EPG
    /// programme lines — build 80 removed them with the TV Guide).
    @State private var selectedCategoryId: String? = nil

    // Build 75 (performance): the grid's category-chip filter used
    // to run here as a computed property — a full walk over the
    // grid list on EVERY body pass. It is folded into
    // `recomputeFilter`'s detached pass now (the chip rides in the
    // recompute token), and the grid reads `gridItems` directly.
    // Build 61 (B8, Z6): recompute when the empty-category toggle flips.
    @AppStorage(EmptyCategoryVisibility.defaultsKey) private var showEmptyCategories = false
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
    // Build 61 fixer (O9): scroll restoration for the shelves list —
    // the category shelf at the top anchor, persisted per playlist
    // via ScrollAnchorStore. Shelves ("list") mode only; the Z13
    // grid mode keeps its own behaviour.
    @State private var scrollAnchorID: String? = nil
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
        // Build 61 (B8, Z6): empty categories are not jump targets
        // either, unless the user shows empty categories.
        let visible = EmptyCategoryVisibility.visible(
            contentStore.liveCategories.filter { !liveHiddenIds.contains($0.id) }
        ) { contentStore.liveStreamsByCategoryId[$0.id]?.count ?? 0 }
        return orderStore.applyOrder(
            visible,
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
        // Build 75 (performance): the head of the playback queue
        // without building the flattened queue array — the first
        // stream of the first non-empty section (sections are
        // non-empty by construction) is the same value.
        for section in liveChannelSections {
            if let first = section.streams.first { return first }
        }
        return nil
    }

    private func heroHistory(for stream: DBLiveStream) -> DBWatchHistory? {
        guard let item = recentLiveHistory.first, Int(item.streamId) == stream.streamId else { return nil }
        return item
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

    /// Build 75 (performance): the ONE recompute trigger — every
    /// input that used to carry its own `.task(id:)` modifier
    /// (catalog load state, health revision, hidden categories,
    /// channel hides (B8, H2), the empty-category toggle (B8, Z6),
    /// category order, channel-order version (B2), the favorites
    /// toggle, the grid's debounced search and its category chip)
    /// is a field of this token, so the pass runs once per actual
    /// change set instead of once per modifier.
    private var liveRecomputeToken: LiveRecomputeToken {
        LiveRecomputeToken(
            loaded: contentStore.streamsLoaded,
            liveCount: contentStore.liveStreams.count,
            healthRevision: channelHealth.revision,
            hiddenCategories: hiddenStore.hiddenIds(playlistId: playlist.id, type: "live"),
            hiddenChannelsVersion: HiddenChannelStore.shared.version,
            showEmptyCategories: showEmptyCategories,
            categoryOrder: orderStore.orderedIds(playlistId: playlist.id, type: "live"),
            channelOrderVersion: channelOrderStore.version,
            favoritesOnly: favoritesOnly,
            gridQuery: gridDebouncedQuery,
            gridCategory: selectedCategoryId
        )
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
                        BrandedLoader()
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
        // Build 75 (performance): ONE `.task(id:)` for the whole
        // recompute — the eight modifiers that used to sit here
        // (one per input) each re-fired the full pass on a tab
        // switch; their inputs all ride in `liveRecomputeToken`.
        .task(id: liveRecomputeToken) { await recomputeFilter() }
        // Build 89 (item 3): the navigation bar is HIDDEN on this
        // tab — the owner's order is that the whole top block
        // (title, toolbar pill, search, chips) scrolls WITH the
        // content instead of staying pinned. The bar's actions
        // (Favorites star, Multiview, grid/list toggle, category
        // jump, and the grid's sort/filter) live in the in-scroll
        // header pill now (`liveTabHeaderRow`), rendered as the
        // first element of each mode's scroll flow; the scroll
        // views keep the top safe area, so at rest the header
        // sits below the status bar / Dynamic Island and slides
        // away only when the user scrolls. Pushed screens (group
        // pages, All Channels, Favorites) declare their own
        // titles and get the bar back.
        // === B5 (build 61) Item 11: Multiview entry — wave-2 (B8):
        // the entry moved into the header pill (same action, same
        // disabled state, same accessibility label) — see
        // `liveTabHeaderRow`. ===
        // Round 8 (D-2): still NO second AllLiveView entry — the
        // Trending shelf's "See all" stays the ONE path.
        .toolbar(.hidden, for: .navigationBar)
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
                SearchView(playlist: playlist, searchText: $homeSearchText, initialFilter: .live)
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
        // Build 61 (B8, R2): opening the channel clears its NEW badge.
        FirstSeenStore.shared.markOpened(playlistId: playlist.id, itemKey: "live:\(selection.stream.streamId)")
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
                    artworkURL: item.imageURL.flatMap { ArtworkURL.url(from: $0) },
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

    /// Build 89 (item 3): the tab's title + toolbar pill, built
    /// to sit INSIDE the scroll flow (the navigation bar is
    /// hidden on this tab — see the body note). The pill carries
    /// the exact actions the nav toolbar carried: the Favorites
    /// star (the same `FavoritesView` destination the dashboard
    /// chrome linked to), Multiview, the grid/list view toggle
    /// and the category jump; the grid header additionally
    /// carries the grid's sort/filter entry. One pill, one place
    /// — no action exists twice on this tab.
    @ViewBuilder
    private func liveTabHeaderRow(includeSortFilter: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(L("dashboard.live"))
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                NavigationLink {
                    FavoritesView(playlist: playlist, initialType: "live")
                } label: {
                    Image(systemName: "star.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("favorites.title"))

                // === B5 (build 61) Item 11: Multiview entry ===
                Button {
                    showMultiview = true
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(contentStore.liveCategories.isEmpty)
                .accessibilityLabel(L("multiview.title"))

                // Build 61 (B8, Z13): grid/list view toggle — one
                // tap switches the main browsing surface; the
                // choice persists in AppStorage.
                Button {
                    liveViewMode = liveViewMode == "grid" ? "list" : "grid"
                } label: {
                    Image(systemName: liveViewMode == "grid" ? "list.bullet" : "square.grid.2x2")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L(liveViewMode == "grid" ? "channels.view.list" : "channels.view.grid"))

                Button {
                    showingCategoryPicker = true
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(contentStore.liveCategories.isEmpty)
                .accessibilityLabel(L("list.jump_to_category"))

                if includeSortFilter {
                    LiveSortFilterButton(filter: $gridFilter)
                }
            }
            .padding(.horizontal, 6)
            .background(Capsule().fill(AppTheme.elevated))
            .overlay(Capsule().stroke(AppTheme.cardBorderColor, lineWidth: 1))
        }
        .padding(.horizontal, 16)
    }

    /// Build 89 (item 3): the grid mode's scroll header — title
    /// row, the in-grid search field and the category chips, in
    /// the order the pinned block had them, passed into
    /// `LiveCategoryContent` to render as the first element of
    /// its scroll flow. The search field keeps its build-63
    /// wiring verbatim (same binding, same debounce below) — it
    /// only changed position, from a pinned VStack above the
    /// grid into the grid's own scroll content.
    private var gridScrollHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            liveTabHeaderRow(includeSortFilter: true)
                .padding(.top, 8)
            CatalogSearchField(text: $gridSearchText, placeholder: L("live.search_placeholder"))
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            // Build 65 (inside-sections design): category chips
            // above the channel grid — the REAL provider
            // categories, filtering the grid in place (the
            // in-grid search above keeps its build-63 behavior
            // across the full catalog).
            if displayCategories.count > 1 {
                SectionCategoryChips(
                    categories: displayCategories,
                    selectedCategoryId: $selectedCategoryId
                )
                .padding(.vertical, 6)
            }
        }
    }

    /// Home header. Round 5 order was count → search → chips → hero.
    /// Round 7 (owner's direct order: "search must be at the top"): the
    /// search bar is the FIRST element under the title, above the count
    /// line and the hero. The tab still has exactly ONE search entry.
    /// Round 8 removed the chips row (see the init note), so the hero
    /// and Trending shelf render unconditionally.
    /// Build 89 (item 3): the title + toolbar pill row now leads
    /// the header (it scrolls with the shelves — it is inside the
    /// same ScrollView).
    @ViewBuilder
    private var homeHeader: some View {
        liveTabHeaderRow(includeSortFilter: false)
            .padding(.top, 8)

        HomeSearchBar(placeholder: L("home.search_placeholder")) {
            showSearchSheet = true
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)

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
                    nowProgramTitle: nil,
                    previewURL: PlaybackURLBuilder(playlist: playlist).liveURL(streamId: hero.streamId),
                    previewActive: heroPreviewActive,
                    userAgent: playlist.trimmedUserAgent
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

    // @ViewBuilder: the two modes return different opaque view types;
    // a plain `some View` body cannot branch between them.
    @ViewBuilder
    private var contentList: some View {
        // Build 61 (B8, Z13): grid is the default browsing surface;
        // the shelf ("list") layout is one toolbar tap away.
        if liveViewMode == "grid" {
            gridContent
        } else {
            shelvesContent
        }
    }

    /// Z13 grid mode: in-list search field (C11 — name + provider
    /// number, as-you-type) atop the large logo grid. The grid itself
    /// is the SAME `LiveCategoryContent` the category screens use
    /// (one card system, O3), fed every visible channel.
    /// Build 89 (item 3): the search field + chips are no longer
    /// pinned in a VStack above the grid — the whole top block
    /// (title row, search, chips) is passed in as the grid's
    /// `scrollHeader` and renders as the first element of the
    /// grid's own scroll flow.
    private var gridContent: some View {
        // Build 80: browsing "All" (no category chip, no
        // active search) renders the grid GROUPED by category
        // with a section header per group; a chip selection or
        // an active search keeps the flat presentation exactly
        // as before (nil sections).
        LiveCategoryContent(
            playlist: playlist,
            items: gridItems,
            groupedSections: (selectedCategoryId == nil
                && gridDebouncedQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                ? gridSections : nil,
            filter: $gridFilter,
            scrollHeader: AnyView(gridScrollHeader),
            onStreamSelected: { stream, history in
                presentLiveSelection(LivePlayerSelection(stream: stream, history: history))
            }
        )
        .equatable()
        // Build 88 (F3): the floating tab bar pill overlays
        // this tab's content — reserve its height at the
        // bottom of the scroll surface so the last shelf/row
        // never rests under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: LiveTabBarClearance.height)
        }
        .onChange(of: gridSearchText) { _, new in
            gridDebounceTask?.cancel()
            gridDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { gridDebouncedQuery = new }
            }
        }
        .onDisappear { gridDebounceTask?.cancel(); gridDebounceTask = nil }
        // Build 75: no `.task` here — the debounced query rides in
        // the root's single `liveRecomputeToken`.
    }

    private var shelvesContent: some View {
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
            // Build 88 (F3): same floating-bar clearance as the
            // grid surface — the last category shelf must clear
            // the tab bar pill.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: LiveTabBarClearance.height)
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
            // Build 61 fixer (O9): bind the shelves list to the
            // persisted anchor — the system tracks the first-visible
            // category shelf; the store write keeps it for the next
            // appearance, and the restore below re-applies it (a
            // jump — setting the binding never animates).
            .scrollPosition(id: $scrollAnchorID, anchor: .top)
            .onChange(of: scrollAnchorID) { _, newValue in
                if let newValue {
                    ScrollAnchorStore.save(newValue, surface: "live", playlistId: playlist.id)
                }
            }
            .onAppear { restoreScrollAnchor() }
            .onChange(of: displayCategories.map(\.id)) { _, _ in restoreScrollAnchor() }
        }
    }

    /// O9 restore: once the shelves exist, jump back to the
    /// persisted first-visible shelf (only when it is still in the
    /// list and the position is not already there).
    private func restoreScrollAnchor() {
        guard !displayCategories.isEmpty,
              let saved = ScrollAnchorStore.anchor(surface: "live", playlistId: playlist.id),
              saved != scrollAnchorID,
              displayCategories.contains(where: { $0.id == saved })
        else { return }
        scrollAnchorID = saved
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
    ///
    /// Build 75 (performance): the heavy middle of this pass — the
    /// per-category channel order over every bucket, the
    /// hidden-channel / favorites / dead filters, the grid flatten
    /// + search + chip filter and the sections build — used to run
    /// entirely on the main actor, and eight separate `.task(id:)`
    /// modifiers could each re-fire it, so a single tab switch
    /// queued several full walks over the whole live catalog
    /// (~6.8k channels) ahead of the first frame. Now the main
    /// actor only snapshots the inputs (store reads + the saved
    /// channel orders), ONE combined token triggers the pass (see
    /// `liveRecomputeToken`), the value work runs in a detached
    /// task, and the four display values publish once at the end.
    /// Filter order and published results are unchanged.
    private func recomputeFilter() async {
        guard playlist.id == contentStore.activePlaylistId else {
            displayCategories = []; displayItemsByCategory = [:]; liveChannelSections = []; gridSections = []; return
        }
        let pid = playlist.id
        // Main-actor snapshots (cheap reads only).
        let hidden = hiddenStore.hiddenIds(playlistId: pid, type: "live")
        let orderedCategories = orderStore.applyOrder(
            contentStore.liveCategories.filter { !hidden.contains($0.id) },
            playlistId: pid, type: "live"
        ) { $0.id }
        let byCategory = contentStore.liveStreamsByCategoryId
        // B2 (build 61, item 12): the saved per-category channel
        // orders, snapshotted per bucket (the detached pass applies
        // them via `ChannelOrderStore.applySavedOrder`). Buckets
        // with no saved order are absent here and pass through as
        // the identity in the detached pass, exactly as
        // `applyOrder` treats them.
        var savedOrders: [String: [String]] = [:]
        for bucketId in byCategory.keys {
            let saved = channelOrderStore.orderedIds(playlistId: pid, categoryId: bucketId)
            if !saved.isEmpty { savedOrders[bucketId] = saved }
        }
        let hiddenChannels = HiddenChannelStore.shared.hiddenIds(playlistId: pid)
        let favoriteIds: Set<Int>? = favoritesOnly ? Set(favoriteLiveChannels.map(\.stream.streamId)) : nil
        let hideDead = ChannelHealthStore.hideDeadEnabled
        let deadKeys: Set<String> = hideDead ? channelHealth.deadKeys() : []
        let streamsLoaded = contentStore.streamsLoaded
        let query = gridDebouncedQuery
        let chipCategory = selectedCategoryId

        let result = await Task.detached(priority: .userInitiated) { () -> (
            categories: [DBCategory],
            itemsByCategory: [String: [LiveStreamWithCategory]],
            grid: [LiveStreamWithCategory],
            gridSections: [LiveChannelGridSection],
            sections: [LiveChannelCategorySection]
        ) in
            // B2 (build 61, item 12): apply the user's persisted
            // per-category channel order (tier 3 of the O7
            // in-category order). With no saved order this is the
            // identity, so the provider order stands; explicit
            // name sorts in the category screens still override it
            // there, as they do the provider order today.
            var itemsByCategory: [String: [LiveStreamWithCategory]] = [:]
            itemsByCategory.reserveCapacity(byCategory.count)
            for (bucketId, items) in byCategory {
                if let saved = savedOrders[bucketId] {
                    itemsByCategory[bucketId] = ChannelOrderStore.applySavedOrder(items, saved: saved) {
                        String($0.stream.streamId)
                    }
                } else {
                    itemsByCategory[bucketId] = items
                }
            }
            // Build 61 (B8, H2): per-channel hides apply to the
            // shelves as well as the category grids (same
            // HiddenChannelStore).
            if !hiddenChannels.isEmpty {
                itemsByCategory = itemsByCategory.mapValues { items in
                    items.filter { !hiddenChannels.contains($0.stream.streamId) }
                }
            }
            var categories = orderedCategories
            if let favoriteIds {
                // B3: keep only favorite channels (and categories
                // that still hold one) — hero, trending and the
                // play queue all derive from these same display
                // values.
                itemsByCategory = itemsByCategory.mapValues { items in
                    items.filter { favoriteIds.contains($0.stream.streamId) }
                }
                categories = categories.filter { !(itemsByCategory[$0.id]?.isEmpty ?? true) }
            }
            if hideDead {
                // Build 61 (B9, Q10): hide channels marked dead
                // (≥3 consecutive playback failures) from the
                // shelves, the hero/trending derivation and the
                // play queue.
                if !deadKeys.isEmpty {
                    itemsByCategory = itemsByCategory.mapValues { items in
                        items.filter {
                            !deadKeys.contains(ImportedSubtitleStore.contentKey(
                                playlistId: pid, type: "live", streamId: String($0.stream.streamId)
                            ))
                        }
                    }
                    categories = categories.filter { !(itemsByCategory[$0.id]?.isEmpty ?? true) }
                }
            }
            // Build 61 (B8, Z6): once the catalog is actually
            // loaded, empty categories leave the shelf list by
            // default (the Appearance toggle brings them back).
            // Applied AFTER the hidden-category and favorites
            // filters, so an empty locked/hidden category stays
            // hidden regardless.
            if streamsLoaded {
                categories = EmptyCategoryVisibility.visible(categories) {
                    itemsByCategory[$0.id]?.count ?? 0
                }
            }
            // Build 61 (B8, Z13): the grid surface's flat item
            // list — the same display set as the shelves, flattened
            // in category order, with the grid's in-list search
            // applied (name + provider number, C11/H5). Build 75:
            // the build-65 category chip's filter applies at the
            // end of the same pass — it used to re-run as a
            // computed property on every body pass.
            let flat = categories.flatMap { itemsByCategory[$0.id] ?? [] }
            // Build 80: the "All" browse groups — the SAME display
            // set as `flat`, split per category BEFORE the search
            // and chip filters narrow the flat list. Group order is
            // `categories` order (the catalog's category order, the
            // same order the filter chips use); channel order
            // inside a group is the bucket order verbatim (saved
            // custom channel order already applied above), so
            // flattening the groups reproduces `flat` exactly.
            let gridSections = categories.compactMap { cat -> LiveChannelGridSection? in
                let items = itemsByCategory[cat.id] ?? []
                guard !items.isEmpty else { return nil }
                return LiveChannelGridSection(id: cat.id, title: cat.name, items: items)
            }
            let q = query.trimmingCharacters(in: .whitespaces)
            var grid = q.isEmpty ? flat : flat.filter {
                CatalogTextSearch.matchesSectionFuzzy(search: q, text: $0.stream.name)
                    || ($0.stream.channelNumber.map { String($0) == q } ?? false)
            }
            if let chipCategory {
                grid = grid.filter { $0.stream.categoryId == chipCategory }
            }
            // Round 8 (audit A3): cache the sections here — the
            // old computed property's mapping, verbatim — so body,
            // hero, trending and the count line read this instead
            // of re-mapping per render.
            let sections = categories.compactMap { cat -> LiveChannelCategorySection? in
                let streams = itemsByCategory[cat.id]?.map(\.stream) ?? []
                guard !streams.isEmpty else { return nil }
                return LiveChannelCategorySection(id: cat.id, title: cat.name, streams: streams)
            }
            return (categories, itemsByCategory, grid, gridSections, sections)
        }.value
        guard !Task.isCancelled else { return }
        displayCategories = result.categories
        displayItemsByCategory = result.itemsByCategory
        gridItems = result.grid
        gridSections = result.gridSections
        liveChannelSections = result.sections
    }

    private func liveStream(for item: DBWatchHistory) -> DBLiveStream? {
        let streamId = Int(item.streamId) ?? 0
        // Build 75 (performance): scan the cached sections lazily
        // in queue order — the same first match the flattened
        // `livePlaybackQueue` scan produced, without building the
        // whole queue array per call.
        if let match = liveChannelSections.lazy.flatMap(\.streams).first(where: { $0.streamId == streamId }) {
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
                    Color.clear.frame(height: LiveChannelTileMetrics.height + 52)
                } else {
                    Text(L("live.empty.no_channel_in_category"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            // Build 88 (Part 2-A): the wide glass
                            // logo tile replaces the small square
                            // card on the category shelves.
                            LiveChannelTile(
                                playlistId: playlist.id,
                                stream: item.stream,
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
                            // Build 83 (item 5): the category
                            // shelves get the same one-shot card
                            // entrance the trending shelf already
                            // had (`shelfCardAppear` — gated by
                            // the EffectsGate, indices ≥ 12
                            // pre-shown, transform/opacity only).
                            .shelfCardAppear(index: index)
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
            .compactMap { ArtworkURL.url(from: $0) }
        ListImagePrefetch.start(
            urls: urls,
            width: LiveChannelTileMetrics.logoWidth,
            height: LiveChannelTileMetrics.logoHeight,
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
            .compactMap { ArtworkURL.url(from: $0) }
        ListImagePrefetch.start(
            urls: urls,
            width: LiveChannelTileMetrics.logoWidth,
            height: LiveChannelTileMetrics.logoHeight,
            loadProfile: .shelf
        )
    }

    private func stopPrefetchIcons(from list: [LiveStreamWithCategory]) {
        let urls = list.prefix(CategoryShelf.prefetchHeadCount)
            .compactMap { $0.stream.streamIcon }
            .compactMap { ArtworkURL.url(from: $0) }
        ListImagePrefetch.stop(
            urls: urls,
            width: LiveChannelTileMetrics.logoWidth,
            height: LiveChannelTileMetrics.logoHeight,
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

    // Build 61 (B8): R2 NEW badge + C10 pin indicator, read from the
    // stores at render (cards are cheap; the stores bump `version`).
    @ObservedObject private var firstSeenStore = FirstSeenStore.shared
    @ObservedObject private var pinnedStore = PinnedChannelStore.shared
    // Build 61 (FA, H1): audio-only active indicator, read from the
    // same store the long-press toggle writes and the player reads.
    @ObservedObject private var audioOnlyStore = AudioOnlyStore.shared

    var body: some View {
        Button(action: {
            onStreamSelected?(stream, nil)
        }) {
            VStack(alignment: .center, spacing: 10) {
                CachedImage(
                    url: stream.streamIcon.flatMap { ArtworkURL.url(from: $0) },
                    width: iconSize,
                    height: iconSize,
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
                // Build 61 (FA, H1): audio-only indicator — shown
                // only while the store says this channel plays
                // audio-only (explicit choice or Settings default).
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
                    .frame(width: width)
                    .foregroundColor(.primary)

                // Build 61 (B8, H5): the provider's channel number,
                // only when the provider supplied one.
                if let number = stream.channelNumber {
                    Text(L("channels.number_format", String(number)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

            }
        }
        // Build 81 (item 8): press feedback on the channel tile
        // (was .plain — a tap gave no visible response).
        .buttonStyle(PressScaleButtonStyle())
    }
}

/// Build 88 (F3): bottom clearance for the Live tab's scroll
/// surfaces. On iOS 26 the system tab bar renders as a floating
/// glass pill OVER the content, and the last shelf/row rested
/// half-hidden under it (owner's build-87 recording). The inset
/// reserves the pill's height plus its breathing margin.
enum LiveTabBarClearance {
    static let height: CGFloat = 84
}

/// Shared geometry for the wide Live TV tile (build 88) — the
/// shelf rows, the grouped browse and the prefetch requests all
/// size from here, so a logo is decoded once at the size every
/// surface renders. Build 89 (item 4): the owner liked the wide
/// tiles but found them a bit too big — the fixed shelf size
/// shrinks modestly (216×122 → 192×108, the same 16:9 family);
/// the grid surfaces use the tile's flexible-width form, whose
/// card follows its grid cell at the same 16:9 ratio.
enum LiveChannelTileMetrics {
    static let width: CGFloat = 192
    static let height: CGFloat = 108
    static let logoWidth: CGFloat = 132
    static let logoHeight: CGFloat = 74
}

/// Build 88: the approved mockup's press treatment for the wide
/// channel tile — the card lifts (scale), an accent border lights
/// around the tile, and a soft accent glow with an expanding ring
/// reads as the ripple. The border/ring overlays are anchored to
/// the tile's exact size at the label's top, so the name under the
/// tile stays outside the lit frame. Transform and opacity only,
/// routed through `Motion.animate`, so Reduce Motion / motion-off
/// still the whole state change.
private struct LiveTileButtonStyle: ButtonStyle {
    // Fix round 1 (build 88): the configuration type is spelled
    // out — this file imports GRDB, whose own top-level
    // `Configuration` type shadows the style's in the bare name,
    // which broke the conformance (and made `configuration.label`
    // resolve to GRDB's String label).
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                    .stroke(AppTheme.accent, lineWidth: 1.6)
                    .frame(width: LiveChannelTileMetrics.width, height: LiveChannelTileMetrics.height)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                    .stroke(AppTheme.accent.opacity(0.45), lineWidth: 1)
                    .frame(width: LiveChannelTileMetrics.width, height: LiveChannelTileMetrics.height)
                    .scaleEffect(configuration.isPressed ? 1.045 : 1.0)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .shadow(
                color: AppTheme.accent.opacity(configuration.isPressed ? 0.40 : 0),
                radius: configuration.isPressed ? 16 : 0,
                y: 6
            )
            .animation(Motion.animate(Motion.pressSpring), value: configuration.isPressed)
    }
}

/// Build 88 (Part 2-A — the owner's Playra pick, built exactly
/// from the approved livetv-max mockup): the wide glass channel
/// tile. The channel logo sits LARGE and centered on the shared
/// card gradient, aspect-fit — never stretched, never cropped —
/// and the FULL channel name stands under the tile. One tile
/// system for the Live TV category shelves and the grouped "All"
/// browse; the small square `LiveStreamCard` remains only where
/// it was already the surface (the trending strip).
struct LiveChannelTile: View {
    let playlistId: UUID
    let stream: DBLiveStream
    var imageLoadProfile: ImageLoadProfile = .shelf
    /// Build 89 (item 4): the grid form of the same tile — the
    /// card fills its grid cell's width at the family's 16:9
    /// ratio instead of the fixed shelf size, so every channel
    /// surface (shelves, grouped browse, flat grids) renders ONE
    /// tile system at any screen width. The logo request size is
    /// the shared metrics size in both forms, so a channel's logo
    /// is decoded once and reused across surfaces.
    var flexibleWidth: Bool = false
    var onStreamSelected: ((DBLiveStream, DBWatchHistory?) -> Void)? = nil

    // The same badge stores the square card reads (NEW / pin /
    // audio-only) — one badge system for every channel tile.
    @ObservedObject private var firstSeenStore = FirstSeenStore.shared
    @ObservedObject private var pinnedStore = PinnedChannelStore.shared
    @ObservedObject private var audioOnlyStore = AudioOnlyStore.shared

    var body: some View {
        if flexibleWidth {
            Button {
                onStreamSelected?(stream, nil)
            } label: {
                tileLabel
            }
            .buttonStyle(PressScaleButtonStyle())
        } else {
            Button {
                onStreamSelected?(stream, nil)
            } label: {
                tileLabel
            }
            .buttonStyle(LiveTileButtonStyle())
        }
    }

    private var tileLabel: some View {
            VStack(alignment: .center, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                        .fill(AppTheme.cardGradient)
                    RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                        .stroke(AppTheme.cardBorderColor, lineWidth: 1)
                    CachedImage(
                        url: stream.streamIcon.flatMap { ArtworkURL.url(from: $0) },
                        width: LiveChannelTileMetrics.logoWidth,
                        height: LiveChannelTileMetrics.logoHeight,
                        cornerRadius: AppTheme.smallCornerRadius,
                        iconName: "tv",
                        loadProfile: imageLoadProfile
                    )
                }
                .frame(width: flexibleWidth ? nil : LiveChannelTileMetrics.width,
                       height: flexibleWidth ? nil : LiveChannelTileMetrics.height)
                .frame(maxWidth: flexibleWidth ? .infinity : nil)
                .aspectRatio(flexibleWidth ? 16.0 / 9.0 : nil, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    if firstSeenStore.isNewLive(playlistId: playlistId, streamId: stream.streamId) {
                        NewContentBadge()
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if pinnedStore.isPinned(playlistId: playlistId, streamId: stream.streamId) {
                        Image(systemName: "pin.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if audioOnlyStore.isEnabled(playlistId: playlistId, streamId: stream.streamId) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(AppTheme.accent, in: Circle())
                            .padding(8)
                            .accessibilityLabel(L("audioonly.badge"))
                    }
                }

                Text(stream.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: flexibleWidth ? nil : LiveChannelTileMetrics.width)
                    .frame(maxWidth: flexibleWidth ? .infinity : nil)
                    .foregroundColor(.primary)

                // The provider's own channel number, only when the
                // provider supplied one (same rule as the square
                // card — nothing is faked).
                if let number = stream.channelNumber {
                    Text(L("channels.number_format", String(number)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
    }
}

// MARK: - Trending Channels shelf (home header)

/// "Trending Channels" row on the Live home header. There is no popularity
/// signal in the catalog, so the row is deterministic: the FIRST channel of
/// each visible category, in category order (round 3 — one per category
/// keeps the tiles diverse instead of repeating one category's logos).
/// Tiles are the shared wide `LiveChannelTile` (real logo, name) — the
/// same tile every other Live TV shelf uses (build 89 unification; this
/// shelf previously rendered the small square `LiveStreamCard`). "See
/// all" opens the existing All Channels grid — the tab's ONE all-grid
/// entry (round 8 dedupe removed the toolbar grid button that
/// duplicated it).
struct TrendingChannelsShelf: View {
    let playlist: Playlist
    let items: [DBLiveStream]
    var onStreamSelected: ((DBLiveStream, DBWatchHistory?) -> Void)? = nil

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
                        // Build 89 (item 4 unification): the wide
                        // glass logo tile replaces the small square
                        // card here too — same tile as the category
                        // shelves (see LiveCategoryShelfRow).
                        LiveChannelTile(
                            playlistId: playlist.id,
                            stream: items[index],
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
    /// category-shelf tiles are the SAME tile with the same
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
            .compactMap { ArtworkURL.url(from: $0) }
        ListImagePrefetch.start(
            urls: urls,
            width: LiveChannelTileMetrics.logoWidth,
            height: LiveChannelTileMetrics.logoHeight,
            loadProfile: .shelf
        )
    }
}

// MARK: - Category Detail View

/// Build 88 (Part 2-A — the owner's Playra pick): the group page
/// is a SEQUENTIAL LIST — logo thumb, FULL channel name, favorite
/// star — with a search field scoped to THIS group and an
/// "N of N" count header. (Builds ≤87 rendered the shared channel
/// grid here; the grid remains on the tab's flat browse states
/// and All Channels. The build-63 full-catalog search on this
/// page is superseded by the plan's in-group search — the global
/// search entry on the tab is unchanged.)
struct LiveCategoryDetailView: View {
    let playlist: Playlist
    let category: DBCategory

    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    /// The group's full display list: the saved per-category
    /// channel order, per-channel hides and dead-channel hiding
    /// applied — the same processing the tab's shelves publish, so
    /// this page matches the shelf it was opened from.
    @State private var groupItems: [LiveStreamWithCategory] = []
    /// `groupItems` narrowed by the in-group search.
    @State private var displayItems: [LiveStreamWithCategory] = []

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var channelOrderStore = ChannelOrderStore.shared
    @ObservedObject private var hiddenChannelStore = HiddenChannelStore.shared
    @ObservedObject private var channelHealth = ChannelHealthStore.shared
    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @Query<FavoriteLiveRequest> private var favoriteLiveChannels: [LiveStreamWithCategory]

    init(playlist: Playlist, category: DBCategory) {
        self.playlist = playlist
        self.category = category
        _favoriteLiveChannels = Query(
            FavoriteLiveRequest(playlistId: playlist.id),
            in: \.appDatabase
        )
    }

    private var favoriteIds: Set<Int> {
        Set(favoriteLiveChannels.map(\.stream.streamId))
    }

    var body: some View {
        VStack(spacing: 0) {
            CatalogSearchField(text: $searchText, placeholder: L("live.search_placeholder"))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

            // The "N of N" header: visible rows over the group's
            // full count (identical while no search is active).
            HStack {
                Spacer()
                Text(L("live.group.count_format", displayItems.count, groupItems.count))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            if groupItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tv.slash")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(L("live.empty.no_channel_in_category"))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if displayItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(L("list.no_result"))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayItems) { item in
                            channelRow(item)
                            if item.stream.streamId != displayItems.last?.stream.streamId {
                                Rectangle()
                                    .fill(AppTheme.cardBorderColor)
                                    .frame(height: 0.5)
                                    .padding(.leading, 104)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.hidden, for: .tabBar)
        .cinematicBackground()
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
        .task(id: hiddenChannelStore.version) { await recomputeItems() }
        .task(id: channelOrderStore.version) { await recomputeItems() }
        .task(id: channelHealth.revision) { await recomputeItems() }
    }

    private func channelRow(_ item: LiveStreamWithCategory) -> some View {
        let isFavorite = favoriteIds.contains(item.stream.streamId)
        return HStack(spacing: 12) {
            Button {
                play(item.stream)
            } label: {
                HStack(spacing: 12) {
                    CachedImage(
                        url: item.stream.streamIcon.flatMap { ArtworkURL.url(from: $0) },
                        width: 76,
                        height: 46,
                        cornerRadius: AppTheme.smallCornerRadius,
                        iconName: "tv",
                        loadProfile: .shelf
                    )
                    Text(item.stream.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressOpacityButtonStyle())

            Button {
                toggleFavorite(item.stream)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isFavorite ? AppTheme.ratingGold : Color.secondary)
                    .symbolEffect(.bounce, value: isFavorite)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(isFavorite ? "favorites.remove" : "favorites.add"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .liveCardContextMenu(
            playlist: playlist,
            stream: item.stream,
            categoryId: category.id,
            categoryName: category.name
        )
    }

    /// Playback keeps the pre-build-88 semantics: the shell's
    /// queue is the whole group in display order, opened at the
    /// tapped channel.
    private func play(_ stream: DBLiveStream) {
        let queue = groupItems.map(\.stream)
        playerOverlay.present(playlistId: playlist.id) {
            LivePlayerShell(
                playlist: playlist,
                queue: queue,
                sections: [LiveChannelCategorySection(id: category.id, title: category.name, streams: queue)],
                initialStream: stream,
                initialHistory: nil,
                subtitle: category.name
            )
        }
    }

    /// The same DBFavorite write the channel context menu and the
    /// in-player star perform: the CURRENT state is read fresh at
    /// tap time and the insert/delete follows it (the composite
    /// primary key makes a blind insert throw and a blind delete
    /// must stay a no-op). The star itself renders from the
    /// `FavoriteLiveRequest` query, so it always shows the stored
    /// truth once the write lands.
    private func toggleFavorite(_ stream: DBLiveStream) {
        let streamId = stream.streamId
        let playlistId = playlist.id
        Task {
            let fresh = try? await AppDatabase.shared.read { db in
                try DBFavorite
                    .filter(Column("streamId") == streamId
                        && Column("playlistId") == playlistId
                        && Column("type") == "live")
                    .fetchCount(db) > 0
            }
            let currentValue = fresh ?? favoriteIds.contains(streamId)
            let nextValue = !currentValue
            if nextValue {
                FavoriteSnapshotStore.shared.record(playlistId: playlistId, type: "live", streamId: streamId, title: stream.name, imageURL: stream.streamIcon)
            } else {
                FavoriteSnapshotStore.shared.remove(playlistId: playlistId, type: "live", streamId: streamId)
            }
            do {
                try await AppDatabase.shared.write { db in
                    if nextValue {
                        try DBFavorite(
                            streamId: streamId, playlistId: playlistId, type: "live"
                        ).insert(db)
                    } else {
                        try DBFavorite
                            .filter(Column("streamId") == streamId
                                && Column("playlistId") == playlistId
                                && Column("type") == "live")
                            .deleteAll(db)
                    }
                }
            } catch {
                // The query keeps the star on the stored truth.
            }
        }
    }

    private func recomputeItems() async {
        guard playlist.id == contentStore.activePlaylistId else {
            groupItems = []; displayItems = []; return
        }
        let pid = playlist.id
        let rawBase = contentStore.liveStreamsByCategoryId[category.id] ?? []
        let savedOrder = channelOrderStore.orderedIds(playlistId: pid, categoryId: category.id)
        let hiddenChannels = hiddenChannelStore.hiddenIds(playlistId: pid)
        let deadKeys: Set<String> = ChannelHealthStore.hideDeadEnabled
            ? channelHealth.deadKeys() : []
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        let result = await Task.detached(priority: .userInitiated) { () -> (
            group: [LiveStreamWithCategory],
            display: [LiveStreamWithCategory]
        ) in
            var base = rawBase
            if !savedOrder.isEmpty {
                base = ChannelOrderStore.applySavedOrder(base, saved: savedOrder) {
                    String($0.stream.streamId)
                }
            }
            if !hiddenChannels.isEmpty {
                base = base.filter { !hiddenChannels.contains($0.stream.streamId) }
            }
            if !deadKeys.isEmpty {
                base = base.filter {
                    !deadKeys.contains(ImportedSubtitleStore.contentKey(
                        playlistId: pid, type: "live", streamId: String($0.stream.streamId)
                    ))
                }
            }
            if q.isEmpty { return (base, base) }
            // In-group search (build 88 plan): name OR the
            // provider channel number (C11/H5), relevance-sorted.
            let filtered = base.filter {
                CatalogTextSearch.matchesSectionFuzzy(search: q, text: $0.stream.name)
                    || ($0.stream.channelNumber.map { String($0) == q } ?? false)
            }
            return (base, CatalogTextSearch.sortLiveByRelevance(filtered, search: q))
        }.value
        guard !Task.isCancelled else { return }
        groupItems = result.group
        displayItems = result.display
    }
}

/// Build 89 (item 5): ONE recompute trigger for `LiveCategoryContent`
/// — the same build-75 pattern the tab root uses. The grid used to
/// carry six separate `.task(id:)` modifiers (items signature, sort,
/// health revision, filter, pinned version, hidden version), so one
/// appearance or one store bump could queue several full-catalog
/// passes, each republishing the display model and resetting the
/// pagination budget — a core part of why the "All" browse staggered
/// in shelf by shelf. Every input rides in this token; the pass runs
/// once per actual change set.
private struct LiveGridRecomputeToken: Equatable {
    let items: Int
    let sort: String
    let filterRaw: Int
    let healthRevision: Int
    let pinnedVersion: Int
    let hiddenVersion: Int
}

struct LiveCategoryContent: View, Equatable {
    let playlist: Playlist
    let items: [LiveStreamWithCategory]
    /// Build 80: optional category groups for the "All" browse.
    /// When non-nil (and no sort/filter is active — see
    /// `recompute()`), the grid renders one headed section per
    /// group instead of one flat grid. Callers that pass nil (the
    /// category detail screen, a chip-filtered or searched grid)
    /// keep the flat presentation unchanged.
    let groupedSections: [LiveChannelGridSection]?
    /// Build 89 (item 3): the toggle filters are owned by the
    /// caller now — the tab's sort/filter entry lives in its
    /// in-scroll header pill, which writes the same binding this
    /// view's processing reads. All Channels passes its own
    /// state binding; the processing itself is unchanged.
    @Binding var filter: LiveStreamFilter
    /// Build 89 (item 3): an optional header rendered as the
    /// FIRST element of this view's scroll flow (the tab passes
    /// its title row + search field + category chips; pushed
    /// surfaces like All Channels pass nil and keep their
    /// navigation-bar chrome). Ignored by the `==` signature,
    /// like the selection closure.
    let scrollHeader: AnyView?
    var onStreamSelected: ((DBLiveStream, DBWatchHistory?) -> Void)? = nil

    /// Cheap signature compare (ignores the selection closure) so a parent @Published
    /// re-render doesn't force SwiftUI to re-process a huge channel list. Internal
    /// @State updates still invalidate normally.
    static func == (lhs: LiveCategoryContent, rhs: LiveCategoryContent) -> Bool {
        lhs.playlist.id == rhs.playlist.id
            // Build 89 (item 3): the filter binding is compared by
            // value — the view's output depends on it, and the tab
            // wraps this view in `.equatable()`, so a filter change
            // must read as a change here (its own recompute token
            // carries it too; this is the guaranteed parent path).
            && lhs.filter.rawValue == rhs.filter.rawValue
            && lhs.items.count == rhs.items.count
            && lhs.items.first?.stream.streamId == rhs.items.first?.stream.streamId
            && lhs.items.last?.stream.streamId == rhs.items.last?.stream.streamId
            && lhs.groupedSections?.count == rhs.groupedSections?.count
            && lhs.groupedSections?.first?.id == rhs.groupedSections?.first?.id
            && lhs.groupedSections?.last?.id == rhs.groupedSections?.last?.id
    }

    @AppStorage(LiveSortOption.storageKey) private var sortOption: LiveSortOption = .defaultOrder
    // Build 61 (B9, Q10): dead-channel markings (hide-dead filter).
    @ObservedObject private var channelHealth = ChannelHealthStore.shared
    /// Sort/filter output, recomputed off the main thread on input changes.
    @State private var displayItems: [LiveStreamWithCategory] = []
    /// Build 80: grouped render output — the per-category sections
    /// after this view's own processing, plus the flag that the
    /// grouped presentation is in force for the current inputs.
    @State private var displaySections: [LiveChannelGridSection] = []
    @State private var displayGrouped = false
    /// Paginated render count so a huge catalog doesn't build one giant ForEach.
    @State private var visibleCount = Self.pageSize
    // Build 61 (B8): C10 pins / H2 hidden channels / O7 favorite tier.
    @ObservedObject private var pinnedStore = PinnedChannelStore.shared
    @ObservedObject private var hiddenChannelStore = HiddenChannelStore.shared
    @Query<FavoriteLiveRequest> private var favoriteLiveChannels: [LiveStreamWithCategory]

    init(playlist: Playlist, items: [LiveStreamWithCategory], groupedSections: [LiveChannelGridSection]? = nil, filter: Binding<LiveStreamFilter>, scrollHeader: AnyView? = nil, onStreamSelected: ((DBLiveStream, DBWatchHistory?) -> Void)? = nil) {
        self.playlist = playlist
        self.items = items
        self.groupedSections = groupedSections
        self._filter = filter
        self.scrollHeader = scrollHeader
        self.onStreamSelected = onStreamSelected
        _favoriteLiveChannels = Query(FavoriteLiveRequest(playlistId: playlist.id), in: \.appDatabase)
    }

    private static let pageSize = 90

    /// Cheap O(1) change signal for `items`; avoids O(n) array equality in `.task(id:)`
    /// on every update pass, which froze navigation on huge lists ("All Channels").
    private var itemsToken: Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        hasher.combine(items.first?.stream.streamId)
        hasher.combine(items.last?.stream.streamId)
        // Build 80: the grouping signature rides along so a
        // sections change re-runs the same recompute.
        hasher.combine(groupedSections?.count ?? -1)
        hasher.combine(groupedSections?.first?.id)
        hasher.combine(groupedSections?.last?.id)
        return hasher.finalize()
    }

    /// Build 89 (item 5): the single recompute trigger (see
    /// `LiveGridRecomputeToken`).
    private var gridRecomputeToken: LiveGridRecomputeToken {
        LiveGridRecomputeToken(
            items: itemsToken,
            sort: sortOption.rawValue,
            filterRaw: filter.rawValue,
            healthRevision: channelHealth.revision,
            pinnedVersion: pinnedStore.version,
            hiddenVersion: hiddenChannelStore.version
        )
    }

    private func recompute() async {
        let source = items
        let sort = sortOption
        let activeFilter = filter
        // Build 80: grouping is the DEFAULT presentation of the
        // "All" browse. An explicit sort or toggle filter is a
        // global re-ordering/filtering of the whole catalog, so
        // while one is active the grid falls back to the flat
        // presentation (the pre-build-80 behavior); clearing back
        // to the default order with no filters restores grouping.
        let sectionsInput = groupedSections
        let grouping = sectionsInput != nil && sort == .defaultOrder && activeFilter.isEmpty
        // Build 61 (B9, Q10): the dead set is computed once here
        // (not per row) and applied inside the same detached pass.
        let dead: Set<String> = ChannelHealthStore.hideDeadEnabled
            ? ChannelHealthStore.shared.deadKeys() : []
        let playlistId = playlist.id
        // Build 61 (B8): hidden channels drop out; O7 tiers
        // (pinned → favorites) hold in front of the chosen sort,
        // which supplies tier 3 (custom order / alphabetical).
        let hidden = hiddenChannelStore.hiddenIds(playlistId: playlist.id)
        let pinned = pinnedStore.pinnedIds(playlistId: playlist.id)
        let favorites = Set(favoriteLiveChannels.map(\.stream.streamId))
        // Build 89 (item 5): the common case — default order, no
        // toggle filter, nothing hidden/dead/pinned and no
        // favorites — makes every processing step the identity
        // (the filter and the default sort return their input;
        // the tier sort with two empty sets preserves order), so
        // the pass can return each list untouched instead of
        // running five filter/sort/partition walks per section
        // over the whole catalog.
        let isIdentity = sort == .defaultOrder && activeFilter.isEmpty
            && hidden.isEmpty && dead.isEmpty && pinned.isEmpty && favorites.isEmpty
        let result = await Task.detached(priority: .userInitiated) { () -> (
            flat: [LiveStreamWithCategory],
            sections: [LiveChannelGridSection]
        ) in
            // The per-list processing, shared verbatim by both
            // presentations: toggle filter → hidden channels →
            // dead channels → sort → pinned/favorites tier.
            func process(_ list: [LiveStreamWithCategory]) -> [LiveStreamWithCategory] {
                if isIdentity { return list }
                var base = LiveStreamFilter.apply(list, activeFilter)
                base = base.filter { !hidden.contains($0.stream.streamId) }
                if !dead.isEmpty {
                    base = base.filter {
                        !dead.contains(ImportedSubtitleStore.contentKey(
                            playlistId: playlistId, type: "live", streamId: String($0.stream.streamId)
                        ))
                    }
                }
                let sorted = sort.apply(to: base)
                return ChannelOrdering.pinnedFavoritesFirst(sorted, pinned: pinned, favorites: favorites) { $0.stream.streamId }
            }
            if grouping, let sectionsInput {
                // Grouped: the same processing per section (the
                // pinned/favorites tier then holds at the front of
                // the channel's OWN category instead of jumping
                // across categories); sections that process to
                // empty drop out. The flat publish value is the
                // groups flattened in order — identical membership
                // and order to the sections.
                var sections: [LiveChannelGridSection] = []
                sections.reserveCapacity(sectionsInput.count)
                for section in sectionsInput {
                    let processed = process(section.items)
                    if !processed.isEmpty {
                        sections.append(LiveChannelGridSection(id: section.id, title: section.title, items: processed))
                    }
                }
                return (sections.flatMap(\.items), sections)
            }
            return (process(source), [])
        }.value
        guard !Task.isCancelled else { return }
        let newGrouped = grouping && !result.sections.isEmpty
        // Build 89 (item 5): publish only on a real change. The
        // parent republishes the grid model on catalog events
        // whose signature is unchanged for this surface (same
        // counts, same first/last channels, same sections) —
        // reassigning the @State values anyway invalidated the
        // body and re-diffed the whole shelf stack for nothing.
        // The signature follows this file's existing cheap
        // compare convention (counts + boundary ids).
        // Build 89 fix round 1: the signature staged into separate
        // statements — the single chained expression timed out the
        // Swift type-checker on Codemagic #86 (LiveStreamsView.swift
        // "unable to type-check this expression in reasonable time").
        // Same comparisons, same result.
        let sameMode = displayGrouped == newGrouped
        let sameCount = displayItems.count == result.flat.count
        let sameFirst = displayItems.first?.stream.streamId == result.flat.first?.stream.streamId
        let sameLast = displayItems.last?.stream.streamId == result.flat.last?.stream.streamId
        let sameSectionCount = displaySections.count == result.sections.count
        let sameSectionEdges = displaySections.first?.id == result.sections.first?.id
            && displaySections.last?.id == result.sections.last?.id
        let oldSectionTotal = displaySections.reduce(0) { $0 + $1.items.count }
        let newSectionTotal = result.sections.reduce(0) { $0 + $1.items.count }
        let unchanged = sameMode && sameCount && sameFirst && sameLast
            && sameSectionCount && sameSectionEdges && oldSectionTotal == newSectionTotal
        if unchanged { return }
        displayItems = result.flat
        displaySections = result.sections
        displayGrouped = newGrouped
        // Build 89 (item 5): the flat pagination budget is
        // PRESERVED across recomputes (clamped to the new total)
        // instead of resetting to one page — a reset after the
        // user had paged deep restarted the reveal cascade and
        // collapsed the scroll content under them. The grouped
        // presentation no longer paginates at all (see the body).
        visibleCount = min(max(visibleCount, min(Self.pageSize, result.flat.count)), result.flat.count)
        prefetch(result.flat)
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

    /// The flat grid's channel cell. Build 89 (item 4): the
    /// wide-tile system now covers the flat browse too — the
    /// old small square `LiveStreamCard` grid is gone from every
    /// Live TV surface. The tile renders in its flexible-width
    /// form (the card follows the grid cell at 16:9); the
    /// context menu is the same one the shelves use.
    @ViewBuilder
    private func channelCell(_ item: LiveStreamWithCategory) -> some View {
        LiveChannelTile(
            playlistId: playlist.id,
            stream: item.stream,
            imageLoadProfile: .grid,
            flexibleWidth: true,
            onStreamSelected: onStreamSelected
        )
        .liveCardContextMenu(
            playlist: playlist,
            stream: item.stream,
            categoryId: item.stream.categoryId,
            categoryName: item.categoryName
        )
    }

    /// The flat grid's cells (paginated — a flat grid of
    /// thousands of channels genuinely needs the budget; the
    /// grouped shelves do not, see the body).
    @ViewBuilder
    private var flatCells: some View {
        ForEach(Array(displayItems.prefix(visibleCount).enumerated()), id: \.element.stream.streamId) { index, item in
            channelCell(item)
                .onAppear { if index >= visibleCount - 15 { loadMore() } }
        }
    }

    /// Warm a grouped section's head logos as the section
    /// materializes — the same head-prefetch the category shelf
    /// rows run (bounded, exact tile request, so the logos are
    /// decoded before the shelf's tiles ask for them).
    private func prefetchSectionHead(_ items: [LiveStreamWithCategory]) {
        let urls = items.prefix(CategoryShelf.prefetchHeadCount)
            .compactMap { $0.stream.streamIcon }
            .compactMap { ArtworkURL.url(from: $0) }
        ListImagePrefetch.start(
            urls: urls,
            width: LiveChannelTileMetrics.logoWidth,
            height: LiveChannelTileMetrics.logoHeight,
            loadProfile: .grid
        )
    }

    var body: some View {
        Group {
            if displayItems.isEmpty {
                // Build 89 (item 3): with a scroll header in play
                // (the tab), the header stays reachable above the
                // empty state — a search with no results must keep
                // its field so the user can edit or clear it.
                VStack(spacing: 0) {
                    if let scrollHeader {
                        scrollHeader
                    }
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(L("list.no_channel"))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            } else {
                ScrollView {
                    if displayGrouped {
                        // Build 80: one headed section per category
                        // group, sections stacked lazily so off-screen
                        // groups are never built. Build 88 (Part
                        // 2-A): each group renders as a SHELF of the
                        // wide glass logo tiles (the approved
                        // livetv-max mockup).
                        // Build 89 (item 5): the grouped browse no
                        // longer paginates. The 90-item budget was
                        // the stagger: the LazyVStack materialized
                        // newly-budgeted sections, their tiles'
                        // onAppear fired the next load-more, and
                        // the cascade chained ~76 rounds for a
                        // ~6.8k catalog — shelves popping in one by
                        // one for ~16 s with the pagination spinner
                        // up throughout. Laziness here is already
                        // structural (the LazyVStack builds only
                        // near-viewport sections; each shelf's
                        // LazyHStack builds only near-viewport
                        // tiles), so ALL sections render at once,
                        // settled — the same instant-complete
                        // behaviour the single-category page has.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if let scrollHeader {
                                scrollHeader
                            }
                            ForEach(displaySections) { section in
                                VStack(alignment: .leading, spacing: 10) {
                                    LiveGridSectionHeader(playlist: playlist, section: section)
                                        .padding(.top, section.id == displaySections.first?.id ? 6 : 22)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        LazyHStack(alignment: .top, spacing: 14) {
                                            ForEach(Array(section.items.enumerated()), id: \.element.stream.streamId) { index, item in
                                                LiveChannelTile(
                                                    playlistId: playlist.id,
                                                    stream: item.stream,
                                                    imageLoadProfile: .grid
                                                ) { stream, history in
                                                    onStreamSelected?(stream, history)
                                                }
                                                .liveCardContextMenu(
                                                    playlist: playlist,
                                                    stream: item.stream,
                                                    categoryId: item.stream.categoryId,
                                                    categoryName: item.categoryName
                                                )
                                                .shelfCardAppear(index: index)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                }
                                .onAppear { prefetchSectionHead(section.items) }
                            }
                        }
                        .padding(.bottom)
                    } else {
                        // Build 89 (item 4): the flat browse uses
                        // the same wide tile, in flexible-width
                        // form, on adaptive columns (two across on
                        // a phone, more on wider screens — the
                        // layout follows the width automatically).
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 168), spacing: 14)
                        ], spacing: 18) {
                            if let scrollHeader {
                                Section {
                                    flatCells
                                } header: {
                                    // The grid's horizontal
                                    // padding wraps the header
                                    // too — cancel it so the
                                    // header's rows (which carry
                                    // the standard 16 pt inset
                                    // themselves) align with the
                                    // tiles below.
                                    scrollHeader
                                        .padding(.horizontal, -16)
                                }
                            } else {
                                flatCells
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom)
                        .padding(.top, scrollHeader == nil ? 16 : 0)
                    }

                    // The pagination spinner belongs to the FLAT
                    // browse only — the grouped browse renders its
                    // full model at once (item 5).
                    if !displayGrouped, visibleCount < displayItems.count {
                        BrandedLoader(size: 28)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                LiveSortFilterButton(filter: $filter)
            }
        }
        // Build 89 (item 5): ONE recompute task for the whole
        // input set (see `LiveGridRecomputeToken`) — replaces the
        // six per-input `.task(id:)` modifiers.
        .task(id: gridRecomputeToken) { await recompute() }
    }

    private func prefetch(_ list: [LiveStreamWithCategory], startingAt: Int = 0) {
        let urls = list.dropFirst(startingAt).prefix(ListImagePrefetch.maxBatch)
            .compactMap { $0.stream.streamIcon }
            .compactMap { ArtworkURL.url(from: $0) }
        // Build 89 (item 4): the flat grid renders the wide tile
        // now — warm its exact logo request (metrics size, grid
        // profile), not the retired square card's.
        ListImagePrefetch.start(urls: urls, width: LiveChannelTileMetrics.logoWidth, height: LiveChannelTileMetrics.logoHeight, loadProfile: .grid)
    }
}

/// Build 89 (item 3): the Live grid's sort/filter entry — ONE
/// component carrying the button + its `SortFilterSheet` (round
/// 10: the styled bottom sheet that replaced the raw popover
/// menu — same options, same toggle/clear behavior). It is used
/// by the tab's in-scroll header pill (the navigation bar is
/// hidden there) and by All Channels' navigation toolbar alike;
/// both instances drive the same AppStorage sort key and the
/// caller's filter binding, so the two surfaces can never
/// disagree about the grid's state.
private struct LiveSortFilterButton: View {
    @AppStorage(LiveSortOption.storageKey) private var sortOption: LiveSortOption = .defaultOrder
    @Binding var filter: LiveStreamFilter
    @State private var showSortSheet = false

    private var isFilterActive: Bool {
        sortOption != .defaultOrder || !filter.isEmpty
    }

    var body: some View {
        Button {
            showSortSheet = true
        } label: {
            Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
}

/// Build 80: the in-grid category header for the grouped "All"
/// browse. It reuses the app's ONE shelf-header treatment from
/// `CinematicSectionHeader` — the accent small-caps title and the
/// real-count accent badge. Build 88 (Part 2-A): the header now
/// also carries that component's "See all" link into the group's
/// sequential-list page, exactly as the category shelves do; when
/// the section's category cannot be resolved from the content
/// store (defensive — sections are built from those categories),
/// it falls back to the plain title + count treatment.
private struct LiveGridSectionHeader: View {
    let playlist: Playlist
    let section: LiveChannelGridSection

    var body: some View {
        if let category = PlaylistContentStore.shared.liveCategories.first(where: { $0.id == section.id }) {
            CinematicSectionHeader(title: section.title, count: section.items.count) {
                LiveCategoryDetailView(playlist: playlist, category: category)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("• \(section.title.uppercased()) •")
                    .font(AppFont.font(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .lineLimit(1)
                Spacer()
                if section.items.count > 0 {
                    Text(CatalogCountFormatter.string(section.items.count))
                        .font(AppTheme.fontBadge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.accent))
                }
            }
            .padding(.horizontal, 16)
        }
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
    /// Build 89 (item 3): this page's sort/filter toggle state,
    /// passed into `LiveCategoryContent` as a binding (the state
    /// used to live inside that view; its toolbar entry renders
    /// the shared `LiveSortFilterButton` against this binding).
    @State private var contentFilter: LiveStreamFilter = []
    /// Build 80: the browsed (unsearched) list grouped by
    /// category, built in this view's own detached recompute;
    /// empty while a search is active (search stays flat).
    @State private var allSections: [LiveChannelGridSection] = []

    private var currentStreams: [DBLiveStream] { displayItems.map(\.stream) }

    var body: some View {
        LiveCategoryContent(
            playlist: playlist,
            items: displayItems,
            groupedSections: allSections.isEmpty ? nil : allSections,
            filter: $contentFilter,
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
        guard playlist.id == contentStore.activePlaylistId else { displayItems = []; allSections = []; return }
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: "live")
        let source = contentStore.liveStreams
        let categories = contentStore.liveCategories
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        // All work off the main thread; the catalog can be very large.
        let result = await Task.detached(priority: .userInitiated) { () -> (
            items: [LiveStreamWithCategory],
            sections: [LiveChannelGridSection]
        ) in
            let base = source.filter { !hidden.contains($0.stream.categoryId ?? "") }
            if q.isEmpty {
                // Build 80: group the browsed list by category in
                // catalog category order (bucket order inside a
                // group = the base order verbatim). Grouping is
                // only published when EVERY base item lands in a
                // group — a stream whose category is missing from
                // the category list keeps the flat presentation
                // rather than silently vanishing from the grid.
                let buckets = Dictionary(grouping: base) { $0.stream.categoryId ?? "" }
                var sections: [LiveChannelGridSection] = []
                for cat in categories where !hidden.contains(cat.id) {
                    let items = buckets[cat.id] ?? []
                    if !items.isEmpty {
                        sections.append(LiveChannelGridSection(id: cat.id, title: cat.name, items: items))
                    }
                }
                if sections.reduce(0, { $0 + $1.items.count }) != base.count {
                    sections = []
                }
                return (base, sections)
            }
            // Build 61 (B8, C11 + H5): name OR provider channel number.
            let filtered = base.filter {
                CatalogTextSearch.matchesSectionFuzzy(search: q, text: $0.stream.name)
                    || ($0.stream.channelNumber.map { String($0) == q } ?? false)
            }
            return (CatalogTextSearch.sortLiveByRelevance(filtered, search: q), [])
        }.value
        guard !Task.isCancelled else { return }
        displayItems = result.items
        allSections = result.sections
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
                        iconURL: stream.streamIcon.flatMap { ArtworkURL.url(from: $0) }
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

    /// Build 88 (Part 2-A): the current group for the in-player channel
    /// list — the section containing the playing channel, falling back
    /// to the playback queue when no section contains it.
    private var currentGroupChannels: [DBLiveStream] {
        if let section = sections.first(where: { section in
            section.streams.contains(where: { $0.streamId == session.stream.streamId })
        }) {
            return section.streams
        }
        return queue
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
                    artworkURL: session.stream.streamIcon.flatMap { ArtworkURL.url(from: $0) },
                    isLiveStream: true,
                    playlistId: playlist.id,
                    streamId: String(session.stream.streamId),
                    type: "live",
                    resumeTimeMs: session.resumeTimeMs,
                    // Build 61 (B10, G2): the playlist's custom
                    // User-Agent reaches the engine's existing
                    // load path through the shell.
                    userAgent: playlist.playbackUserAgent(channelUserAgent: nil),
                    // Build 61 (FA, F-2/G2): the playlist's custom
                    // headers reach playback alongside the UA.
                    customHeaders: playlist.customHeaders,
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

                if showChannelSidePanel, !currentGroupChannels.isEmpty {
                    // Build 88 (Part 2-A): the owner's Playra pick — the
                    // current group's channels as one sequential list
                    // under the video (positional numbers, up/down zap).
                    PlayerChannelList(
                        channels: currentGroupChannels,
                        currentChannelId: session.stream.streamId,
                        onSelect: { stream in switchTo(stream: stream, resumeTimeMs: nil) }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .task(id: "\(playlist.id.uuidString)-\(session.stream.streamId)") {
                await refreshFavorite()
            }
            // Build 61 (B9, P1): warm the PREVIOUS + NEXT channel
            // connections on every zap (connection level only —
            // see PlaybackPrewarmService for the exact level and
            // its bounds).
            .task(id: session.stream.streamId) {
                let builder = PlaybackURLBuilder(playlist: playlist)
                PlaybackPrewarmService.shared.updateNeighbors(
                    previous: currentIndex.flatMap { $0 > 0 ? builder.liveURL(streamId: queue[$0 - 1].streamId) : nil },
                    next: currentIndex.flatMap { $0 < queue.count - 1 ? builder.liveURL(streamId: queue[$0 + 1].streamId) : nil }
                )
            }
            .onDisappear {
                PlaybackPrewarmService.shared.cancelNeighbors()
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
