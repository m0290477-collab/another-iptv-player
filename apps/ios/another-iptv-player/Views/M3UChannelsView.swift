import SwiftUI

/// Horizontal shelves with group (group-title) headings. The same pattern as the Xtream Live TV view.
struct M3UChannelsView: View {
    static let hiddenCategoryType = "m3u"

    let playlist: Playlist
    @ObservedObject private var store = M3UContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @ObservedObject private var pinnedStore = PinnedChannelStore.shared
    @ObservedObject private var hiddenChannelStore = HiddenChannelStore.shared
    @ObservedObject private var orderStore = CategoryOrderStore.shared
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var isSearchActive = false
    /// Build 67 (W6, S8): the Categories-First group tile selection —
    /// nil shows every group shelf; a group name narrows the shelves
    /// to that group only (the M3U analog of the Xtream sections'
    /// category filter). Ignored while a search query is active.
    @State private var selectedGroup: String? = nil

    /// The groups filtered after a search.
    @State private var displayGroups: [String] = []
    @State private var displayChannelsByGroup: [String: [DBM3UChannel]] = [:]

    /// Category jump: whether the picker sheet is open, and the most recently requested group (for scrollTo).
    @State private var showingCategoryPicker = false
    @State private var pendingScrollTarget: String? = nil

    /// The groups to show in the shelf list (hidden ones removed). The picker sees all groups.
    private var visibleShelfGroups: [String] {
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: Self.hiddenCategoryType)
        let ordered = orderStore.applyOrder(
            displayGroups.filter { !hidden.contains($0) },
            playlistId: playlist.id, type: Self.hiddenCategoryType
        ) { $0 }
        // Build 67 (W6, S8): a selected group tile narrows the
        // shelves to that group (only outside search, where the
        // query already defines the visible set).
        if debouncedQuery.isEmpty, let selectedGroup, ordered.contains(selectedGroup) {
            return [selectedGroup]
        }
        return ordered
    }

    /// Build 67 (W6, S8): the group tiles' data — every group the
    /// shelves can show (hidden ones removed, saved order applied)
    /// with its REAL channel count.
    private var groupTileItems: [SectionCategoryTileItem] {
        let hidden = hiddenStore.hiddenIds(playlistId: playlist.id, type: Self.hiddenCategoryType)
        return orderStore.applyOrder(
            displayGroups.filter { !hidden.contains($0) },
            playlistId: playlist.id, type: Self.hiddenCategoryType
        ) { $0 }.map { group in
            SectionCategoryTileItem(
                id: group,
                name: M3UContentStore.displayName(forGroup: group),
                count: displayChannelsByGroup[group]?.count ?? 0
            )
        }
    }

    var body: some View {
        Group {
            if store.isLoading && store.channels.isEmpty {
                VStack(spacing: 16) {
                    BrandedLoader()
                    Text(L("m3u.loading"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.channels.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tv.slash")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(L("m3u.empty.no_channel"))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleShelfGroups.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(L("list.no_result"))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                shelvesList
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    EPGGuideView(source: .m3u(playlist))
                } label: {
                    Image(systemName: "calendar.day.timeline.left")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel(L("epg.guide.title"))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    M3UFavoritesView(playlist: playlist)
                } label: {
                    Image(systemName: "star.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .accessibilityLabel(L("favorites.title"))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingCategoryPicker = true
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(.body.weight(.semibold))
                }
                .disabled(displayGroups.isEmpty)
                .accessibilityLabel(L("list.jump_to_category"))
            }
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerSheet(
                title: L("category_picker.title"),
                // B1 (Round 14): hidden groups are NOT jump targets —
                // the picker lists visible groups only.
                entries: visibleShelfGroups.map { g in
                    CategoryPickerSheet.Entry(
                        id: g,
                        name: M3UContentStore.displayName(forGroup: g),
                        count: displayChannelsByGroup[g]?.count ?? 0
                    )
                },
                playlistId: playlist.id,
                type: Self.hiddenCategoryType
            ) { id in
                showingCategoryPicker = false
                pendingScrollTarget = id
            }
        }
        .searchable(text: $searchText, isPresented: $isSearchActive, prompt: L("m3u.search_placeholder"))
        .onChange(of: searchText) { _, new in
            debounceTask?.cancel()
            // On switching to an empty search there is no debounce wait — show the full list instantly.
            let trimmed = new.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                debouncedQuery = ""
                applyFull()
                return
            }
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { debouncedQuery = new }
            }
        }
        .onChange(of: isSearchActive) { _, active in
            if !active {
                debounceTask?.cancel()
                searchText = ""
                debouncedQuery = ""
                applyFull()
            }
        }
        .task(id: debouncedQuery) { await recomputeFilter() }
        .onChange(of: store.channels) { _, _ in
            // As the store updates, re-apply the current search (if empty, the full list).
            Task { await recomputeFilter() }
        }
        // Build 61 (B8, C10/H2): pin/hide changes re-run the filter.
        .onChange(of: pinnedStore.version) { _, _ in Task { await recomputeFilter() } }
        .onChange(of: hiddenChannelStore.version) { _, _ in Task { await recomputeFilter() } }
        .onAppear { applyFull() }
        .cinematicBackground()
    }

    /// Return to the full-list view instantly (skip the debounce).
    /// Build 61 (B8): still applies the pin/hide transform.
    private func applyFull() {
        guard playlist.id == store.activePlaylistId else { return }
        displayGroups = store.groupNames
        displayChannelsByGroup = Self.processedByGroup(
            store.channelsByGroup, playlistId: playlist.id
        )
    }

    /// Build 61 (B8, C10/H2): hidden channels drop out, pins lead
    /// each group (O7) — shared by the instant and filtered paths.
    nonisolated static func processedByGroup(
        _ raw: [String: [DBM3UChannel]], playlistId: UUID
    ) -> [String: [DBM3UChannel]] {
        let hidden = HiddenChannelStore.hiddenM3UIds(playlistId: playlistId)
        let pinned = PinnedChannelStore.pinnedM3UIds(playlistId: playlistId)
        var out: [String: [DBM3UChannel]] = [:]
        for (g, items) in raw {
            let visible = items.filter { !hidden.contains($0.id) }
            out[g] = ChannelOrdering.pinnedFirstM3U(visible, pinned: pinned)
        }
        return out
    }

    private var shelvesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Build 67 (W6, S8 — Categories First): group
                    // TILES first when browsing (hidden during
                    // search) — the REAL groups with their REAL
                    // channel counts; tapping one narrows the
                    // shelves to that group, "All" restores them.
                    if debouncedQuery.isEmpty && groupTileItems.count > 1 {
                        SectionCategoryTilesRow(
                            items: groupTileItems,
                            selectedCategoryId: $selectedGroup
                        )
                        .padding(.vertical, 8)
                    }

                    // Continue watching: at the top when there is no search.
                    if debouncedQuery.isEmpty {
                        ContinueWatchingRow(
                            playlist: playlist,
                            destination: {
                                WatchHistoryListView(playlist: playlist, typeFilter: nil) { item in
                                    presentHistoryItem(item)
                                }
                            },
                            onPlay: { item in
                                presentHistoryItem(item)
                            }
                        )
                    }

                    ForEach(visibleShelfGroups, id: \.self) { group in
                        M3UGroupShelfRow(
                            playlist: playlist,
                            group: group,
                            items: displayChannelsByGroup[group] ?? [],
                            onChannelSelected: { channel in
                                present(channel)
                            }
                        )
                        .equatable()
                        .id(group)
                    }
                }
            }
            .refreshable {
                // Independent Task: so the refreshable cancellation doesn't propagate to the requests (see LiveStreamsView).
                let work = Task { await refreshCatalog() }
                await work.value
                // C12: success haptic + UI sound on real completion.
                if store.loadError == nil {
                    Haptics.success()
                    AppSound.play(.refreshSuccess)
                }
            }
            .onChange(of: pendingScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                // Reset; so onChange fires again if the same group is selected again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    pendingScrollTarget = nil
                }
            }
        }
    }

    /// Pull-to-refresh: on a URL-based playlist, a full re-download + import (the same path as the refresh in Settings);
    /// on a local-file playlist, only a reload from the DB
    /// (the content cannot change without the file being re-selected).
    private func refreshCatalog() async {
        let url = playlist.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            await store.reloadIfActive(playlist: playlist)
            return
        }
        do {
            let content = try await M3UService().fetchRemote(urlString: url, playlist: playlist)
            let parsed = try await M3UParser.parseAsync(content)
            try await M3UImporter.replace(
                playlist: playlist,
                channels: parsed.channels,
                epgURL: parsed.epgURL
            )
            await store.reloadIfActive(playlist: playlist)
        } catch {
            // Write it to the store's error field; a failed refresh does not corrupt the existing content.
            store.loadError = error.localizedDescription
        }
    }

    // MARK: - Filter

    private func recomputeFilter() async {
        guard playlist.id == store.activePlaylistId else {
            displayGroups = []; displayChannelsByGroup = [:]; return
        }
        let groups = store.groupNames
        let rawByGroup = store.channelsByGroup
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        // Build 61 (B9, Q10): dead-channel set for the hide-dead
        // toggle (empty = filter off). M3U live identity uses the
        // same content-key triple as playback (type "live",
        // streamId = the channel's UUID string).
        let dead: Set<String> = ChannelHealthStore.hideDeadEnabled
            ? ChannelHealthStore.shared.deadKeys() : []
        let playlistId = playlist.id
        func alive(_ channels: [DBM3UChannel]) -> [DBM3UChannel] {
            guard !dead.isEmpty else { return channels }
            return channels.filter {
                !dead.contains(ImportedSubtitleStore.contentKey(
                    playlistId: playlistId, type: "live", streamId: $0.id
                ))
            }
        }
        // Build 61 (B8, C10/H2): per-channel hides drop out and pins
        // lead each group (O7) — same stores as the card menus.
        let byGroup = Self.processedByGroup(rawByGroup, playlistId: playlist.id)

        if q.isEmpty {
            displayGroups = groups
            displayChannelsByGroup = byGroup.mapValues { alive($0) }
            if !dead.isEmpty {
                displayGroups = groups.filter { !(displayChannelsByGroup[$0]?.isEmpty ?? true) }
            }
            return
        }

        let result = await Task.detached(priority: .userInitiated) {
            var outGroups: [String] = []
            var outBy: [String: [DBM3UChannel]] = [:]
            for g in groups {
                let groupMatch = CatalogTextSearch.matches(search: q, text: g)
                var items = byGroup[g] ?? []
                if !dead.isEmpty {
                    items = items.filter {
                        !dead.contains(ImportedSubtitleStore.contentKey(
                            playlistId: playlistId, type: "live", streamId: $0.id
                        ))
                    }
                }
                // Build 61 (B8, C11/H5): name OR provider number.
                let filtered = groupMatch ? items : items.filter {
                    CatalogTextSearch.matches(search: q, text: $0.name)
                        || ($0.tvgChno.map { $0 == q } ?? false)
                }
                if groupMatch || !filtered.isEmpty {
                    outGroups.append(g)
                    outBy[g] = filtered
                }
            }
            return (outGroups, outBy)
        }.value

        guard !Task.isCancelled else { return }
        displayGroups = result.0
        displayChannelsByGroup = result.1
    }

    // MARK: - Playback

    private func present(_ channel: DBM3UChannel) {
        guard M3UParser.sanitizedURL(from: channel.url) != nil else { return }
        let queue = queueForChannel(channel)
        playerOverlay.present {
            M3UPlayerShell(
                playlist: playlist,
                channel: channel,
                queue: queue
            )
        }
    }

    /// For prev/next, use the channel list of the same group as the queue.
    /// The key must be the CANONICAL label the store grouped by — a label localized with L()
    /// does not match the store key and the queue falls to a single channel (prev/next dies).
    private func queueForChannel(_ channel: DBM3UChannel) -> [DBM3UChannel] {
        let key = channel.groupTitle?.trimmingCharacters(in: .whitespaces).nonEmptyOrNil
            ?? M3UContentStore.ungroupedLabel
        return displayChannelsByGroup[key] ?? [channel]
    }

    /// Plays the record coming from the Continue Watching row. If the channel has disappeared after a reimport, an alert.
    private func presentHistoryItem(_ item: DBWatchHistory) {
        guard let channel = store.channels.first(where: { $0.id == item.streamId }) else {
            // The channel may have been deleted (removed from the playlist). Swallow it silently, the Continue row
            // will be updated on the next refresh.
            return
        }
        guard M3UParser.sanitizedURL(from: channel.url) != nil else { return }
        let queue = queueForChannel(channel)
        playerOverlay.present {
            M3UPlayerShell(
                playlist: playlist,
                channel: channel,
                queue: queue,
                resumeTimeMs: item.type == "live" ? nil : item.lastTimeMs
            )
        }
    }
}

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}

// MARK: - Group shelf (horizontal preview)

private enum M3UShelf {
    /// How many subsequent logos to preload when a card appears.
    static let lookAhead = 10
    /// Preparation for the visible window before the user scrolls, on first open.
    static let initialWarmup = 6
}

struct M3UGroupShelfRow: View, Equatable {
    let playlist: Playlist
    let group: String
    let items: [DBM3UChannel]
    var onChannelSelected: ((DBM3UChannel) -> Void)? = nil

    static func == (lhs: M3UGroupShelfRow, rhs: M3UGroupShelfRow) -> Bool {
        lhs.playlist.id == rhs.playlist.id &&
        lhs.group == rhs.group &&
        lhs.items == rhs.items
    }

    @Environment(\.posterMetrics) private var posterMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                NavigationLink {
                    M3UGroupDetailView(playlist: playlist, group: group)
                } label: {
                    HStack(spacing: 6) {
                        Text(M3UContentStore.displayName(forGroup: group))
                            .font(.headline)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                }
                Spacer()
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)

            if items.isEmpty {
                Text(L("live.empty.no_channel_in_category"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, channel in
                            M3UChannelCard(
                                channel: channel,
                                width: posterMetrics.liveShelfLabelWidth,
                                iconSize: posterMetrics.liveShelfIcon,
                                imageLoadProfile: .shelf,
                                onChannelSelected: onChannelSelected
                            )
                            .onAppear { prefetchAhead(from: index) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onAppear {
                    // Only warm the initially visible window; the rest loads on scroll.
                    prefetchAhead(from: -1, count: M3UShelf.initialWarmup)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// When the `index` card becomes visible, it prefetches the `index+1 ..< index+1+count` range.
    /// Because the Nuke memory cache already dedupes, overlapping calls are cheap.
    private func prefetchAhead(from index: Int, count: Int = M3UShelf.lookAhead) {
        let start = max(0, index + 1)
        let end = min(items.count, start + count)
        guard start < end else { return }
        let urls = items[start..<end]
            .compactMap { $0.tvgLogo }
            .compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }
        ListImagePrefetch.start(
            urls: urls,
            width: posterMetrics.liveShelfIcon,
            height: posterMetrics.liveShelfIcon,
            loadProfile: .shelf
        )
    }
}

// MARK: - Channel card

struct M3UChannelCard: View {
    let channel: DBM3UChannel
    var width: CGFloat = 120
    var iconSize: CGFloat = 120
    var imageLoadProfile: ImageLoadProfile = .standard
    var onChannelSelected: ((DBM3UChannel) -> Void)? = nil

    @Environment(\.epgSnapshot) private var epgSnapshot

    var body: some View {
        Button {
            onChannelSelected?(channel)
        } label: {
            VStack(alignment: .center, spacing: 10) {
                CachedImage(
                    url: channel.tvgLogo.flatMap { URL(string: $0) },
                    width: iconSize,
                    height: iconSize,
                    cornerRadius: 12,
                    iconName: "tv",
                    loadProfile: imageLoadProfile
                )

                Text(channel.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: width)
                    .foregroundColor(.primary)

                // Build 61 (B8, H5): provider channel number
                // (tvg-chno) — shown only when the playlist
                // carries one.
                if let number = channel.tvgChno, !number.isEmpty {
                    Text(L("channels.number_format", number))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let snapshot = epgSnapshot {
                    EPGNowNextLine(nowNext: snapshot[EPGChannelKey.forM3U(channel)],
                                   width: width, reserveSpace: true)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Observing the store with @ObservedObject was re-rendering the THOUSANDS of cards the lazy
            // stack kept alive on a single favorite change. The favorite state is
            // only needed here; because the menu is rebuilt on every open, an instantaneous
            // okumak yeterli.
            let isFavorite = M3UFavoriteStore.shared.isFavorite(channelId: channel.id)
            Button {
                Task { await M3UFavoriteStore.shared.toggle(channel: channel) }
            } label: {
                Label(isFavorite ? L("favorites.remove") : L("favorites.add"),
                      systemImage: isFavorite ? "star.slash" : "star")
            }
            // Build 61 (B8, C10/H2): pin + per-channel hide — the
            // same stores the Xtream surfaces use.
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
            // Sadece VOD-tipi kanallar (mp4/mkv/... veya /vod/, /movie/ path'i) indirilebilir.
            // Live HLS/TS streams are not suitable for single-file download.
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

// MARK: - Group detail (grid)

struct M3UGroupDetailView: View {
    let playlist: Playlist
    let group: String

    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var displayItems: [DBM3UChannel] = []

    @ObservedObject private var store = M3UContentStore.shared
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    var body: some View {
        M3UGroupGridContent(
            items: displayItems,
            onChannelSelected: { channel in
                present(channel)
            }
        )
        .navigationTitle(M3UContentStore.displayName(forGroup: group))
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
        .onChange(of: store.channels) { _, _ in Task { await recomputeItems() } }
    }

    private func recomputeItems() async {
        guard playlist.id == store.activePlaylistId else { displayItems = []; return }
        var base = store.channelsByGroup[group] ?? []
        // Build 61 (B9, Q10): hide dead channels when the toggle is on.
        if ChannelHealthStore.hideDeadEnabled {
            let dead = ChannelHealthStore.shared.deadKeys()
            if !dead.isEmpty {
                base = base.filter {
                    !dead.contains(ImportedSubtitleStore.contentKey(
                        playlistId: playlist.id, type: "live", streamId: $0.id
                    ))
                }
            }
        }
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { displayItems = base; return }
        let result = await Task.detached(priority: .userInitiated) {
            base.filter {
                CatalogTextSearch.matches(search: q, text: $0.name)
                    || ($0.tvgChno.map { $0 == q } ?? false)
            }
        }.value
        guard !Task.isCancelled else { return }
        displayItems = result
    }

    private func present(_ channel: DBM3UChannel) {
        guard M3UParser.sanitizedURL(from: channel.url) != nil else { return }
        // In this detail screen, the queue = all channels of this group (filtered if there is a search).
        playerOverlay.present {
            M3UPlayerShell(
                playlist: playlist,
                channel: channel,
                queue: displayItems
            )
        }
    }
}

struct M3UGroupGridContent: View {
    let items: [DBM3UChannel]
    var onChannelSelected: ((DBM3UChannel) -> Void)? = nil
    /// C1 (Round 15): when set (the Favorites grid sets it), each card
    /// gains a long-press "Remove from favorites" context menu entry.
    var onRemoveFavorite: ((DBM3UChannel) -> Void)? = nil

    @Environment(\.posterMetrics) private var posterMetrics

    /// As grid cards appear, download the next row/window ahead.
    private func prefetchAhead(from index: Int, count: Int = 16) {
        let start = max(0, index + 1)
        let end = min(items.count, start + count)
        guard start < end else { return }
        let urls = items[start..<end]
            .compactMap { $0.tvgLogo }
            .compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }
        ListImagePrefetch.start(urls: urls, width: posterMetrics.liveGridIconSize, height: posterMetrics.liveGridIconSize, loadProfile: .grid)
    }

    var body: some View {
        Group {
            if items.isEmpty {
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
                    GridItem(.adaptive(minimum: posterMetrics.liveGridIconSize),
                             spacing: posterMetrics.gridSpacing)
                ]
                ScrollView {
                    LazyVGrid(columns: columns, spacing: posterMetrics.gridRowSpacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, channel in
                            M3UChannelCard(
                                channel: channel,
                                width: posterMetrics.liveGridIconSize,
                                iconSize: posterMetrics.liveGridIconSize,
                                imageLoadProfile: .grid,
                                onChannelSelected: onChannelSelected
                            )
                            // Round 12 (point 7): the same one-shot
                            // card entrance every other grid has
                            // (Xtream live/VOD/series grids all use
                            // it); one-shot + index-capped, so
                            // scrolling cost is unchanged.
                            .shelfCardAppear(index: index)
                            .contextMenu {
                                if let onRemoveFavorite {
                                    Button(role: .destructive) {
                                        onRemoveFavorite(channel)
                                    } label: {
                                        Label(L("favorites.remove"), systemImage: "star.slash")
                                    }
                                }
                            }
                            .onAppear { prefetchAhead(from: index) }
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

// MARK: - Player shell

/// M3U playback — prev/next channel on a live channel, single playback on VOD (prev/next hidden).
/// The queue is usually the current group's channel list; if left empty, navigation is passive.
/// `resumeTimeMs` is only used when the first channel opens (for Continue Watching entries).
struct M3UPlayerShell: View {
    let playlist: Playlist
    let initialResumeMs: Int?
    private let initialChannel: DBM3UChannel
    private let initialQueue: [DBM3UChannel]
    /// `@State` because when switching to another category from the panel, the queue is regenerated.
    @State private var queue: [DBM3UChannel]
    /// The panel model derived from all live channels of the playlist (if the store is loaded) or from the queue (fallback).
    /// Calculated off-main and cached inside `.task(id:)` — it is not regenerated on every body render.
    @State private var livePanelSections: [ChannelPanelSection] = []
    @State private var currentIndex: Int
    @State private var resumeTimeMs: Int?
    @State private var showChannelSidePanel: Bool = false
    @Environment(\.playerOverlayPresentationID) private var overlayPresentationID
    @ObservedObject private var favorites = M3UFavoriteStore.shared
    @ObservedObject private var m3uStore = M3UContentStore.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared

    init(
        playlist: Playlist,
        channel: DBM3UChannel,
        queue: [DBM3UChannel] = [],
        resumeTimeMs: Int? = nil
    ) {
        self.playlist = playlist
        self.initialResumeMs = resumeTimeMs
        self.initialChannel = channel
        let resolvedQueue: [DBM3UChannel]
        let resolvedIndex: Int
        if let idx = queue.firstIndex(where: { $0.id == channel.id }) {
            resolvedQueue = queue
            resolvedIndex = idx
        } else {
            resolvedQueue = [channel]
            resolvedIndex = 0
        }
        self.initialQueue = resolvedQueue
        _queue = State(initialValue: resolvedQueue)
        _currentIndex = State(initialValue: resolvedIndex)
        _resumeTimeMs = State(initialValue: resumeTimeMs)
    }

    private var channel: DBM3UChannel { queue[currentIndex] }

    var body: some View {
        if let url = M3UParser.sanitizedURL(from: channel.url) {
            let classification = M3UStreamClassifier.classify(url: url, groupTitle: channel.groupTitle)
            let activeChannel = channel
            // If the queue has a single element, prev/next is meaningless; otherwise both callbacks are left open for live (showLiveChannelSkip) and
            // VOD (showVODQueueSkip). PlayerView
            // decides which UI to show from the `type` + `isLive` combination.
            let hasQueueNav = queue.count > 1
            let panelSections = classification.isLive ? livePanelSections : []
            ZStack(alignment: .bottom) {
                PlayerView(
                    url: url,
                    title: activeChannel.name,
                    subtitle: activeChannel.groupTitle,
                    artworkURL: activeChannel.tvgLogo.flatMap { URL(string: $0) },
                    isLiveStream: classification.isLive,
                    playlistId: playlist.id,
                    streamId: activeChannel.id,
                    type: classification.playbackType,
                    resumeTimeMs: resumeTimeMs,
                    containerExtension: classification.containerExtension,
                    // Build 61 (B10, G2): the playlist's own
                    // User-Agent wins over the per-channel one.
                    userAgent: playlist.playbackUserAgent(channelUserAgent: activeChannel.userAgent),
                    // Build 61 (FA, F-2/G2): custom headers alongside the UA.
                    customHeaders: playlist.customHeaders,
                    epgChannelKey: classification.isLive ? EPGChannelKey.forM3U(activeChannel) : nil,
                    canGoToPreviousChannel: hasQueueNav && currentIndex > 0,
                    canGoToNextChannel: hasQueueNav && currentIndex < queue.count - 1,
                    onPreviousChannel: hasQueueNav ? { jump(offset: -1) } : nil,
                    onNextChannel: hasQueueNav ? { jump(offset: 1) } : nil,
                    channelPanelSections: panelSections,
                    currentChannelPanelItemId: activeChannel.id,
                    onSelectChannelPanelItem: { id in selectPanelItem(id: id) },
                    isLiveChannelSidePanelVisible: showChannelSidePanel,
                    onToggleLiveChannelSidePanel: panelSections.isEmpty ? nil : {
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
                    isFavorite: favorites.isFavorite(channelId: activeChannel.id),
                    onToggleFavorite: {
                        Task { await favorites.toggle(channel: activeChannel) }
                    }
                )

                if showChannelSidePanel, !panelSections.isEmpty {
                    LiveChannelSidePanel(
                        sections: panelSections,
                        currentItemId: activeChannel.id,
                        onSelectChannel: { id in selectPanelItem(id: id) }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .task(id: panelSectionsCacheKey) { await recomputeLivePanelSections() }
            // Build 61 (B9, P1): warm the PREVIOUS + NEXT channel
            // connections on every zap (live queues only;
            // connection level only — see PlaybackPrewarmService).
            .task(id: channel.id) {
                if classification.isLive {
                    PlaybackPrewarmService.shared.updateNeighbors(
                        previous: currentIndex > 0 ? M3UParser.sanitizedURL(from: queue[currentIndex - 1].url) : nil,
                        next: currentIndex < queue.count - 1 ? M3UParser.sanitizedURL(from: queue[currentIndex + 1].url) : nil
                    )
                }
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
        guard channel.id != initialChannel.id
                || queue.map(\.id) != initialQueue.map(\.id)
                || resumeTimeMs != initialResumeMs else { return }
        guard let targetIndex = initialQueue.firstIndex(where: { $0.id == initialChannel.id }) else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            showChannelSidePanel = false
            queue = initialQueue
            currentIndex = targetIndex
            resumeTimeMs = initialResumeMs
        }
    }

    /// When the playlist id, the group count and the hidden-category version in the store change, `.task(id:)`
    /// a combined key so it re-fires.
    private var panelSectionsCacheKey: String {
        "\(m3uStore.activePlaylistId?.uuidString ?? "none")-\(m3uStore.groupNames.count)-\(playlist.id.uuidString)-\(hiddenStore.version)"
    }

    private func recomputeLivePanelSections() async {
        let useStore = m3uStore.activePlaylistId == playlist.id && !m3uStore.groupNames.isEmpty
        let snapshotNames = useStore ? m3uStore.groupNames : []
        let snapshotByGroup = useStore ? m3uStore.channelsByGroup : [:]
        let snapshotQueue = useStore ? [] : queue
        // To stay consistent with the store keys and the hidden-category ids,
        // the canonical label; headings are localized with displayName at render time.
        let ungroupedLabel = M3UContentStore.ungroupedLabel
        let hiddenIds = hiddenStore.hiddenIds(playlistId: playlist.id, type: M3UChannelsView.hiddenCategoryType)

        let result = await Task.detached(priority: .userInitiated) { () -> [ChannelPanelSection] in
            let raw: [ChannelPanelSection]
            if !snapshotNames.isEmpty {
                raw = Self.buildLivePanelSectionsFromStore(names: snapshotNames, byGroup: snapshotByGroup)
            } else {
                raw = Self.buildLivePanelSections(queue: snapshotQueue, ungroupedLabel: ungroupedLabel)
            }
            return raw.filter { !hiddenIds.contains($0.id) }
        }.value

        guard !Task.isCancelled else { return }
        livePanelSections = result
    }

    private func jump(offset: Int) {
        let target = currentIndex + offset
        guard target >= 0, target < queue.count else { return }
        currentIndex = target
        resumeTimeMs = nil
    }

    private func selectPanelItem(id: String) {
        if let idx = queue.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
            resumeTimeMs = nil
            return
        }
        // A selection was made from a different category — regenerate the queue from that category's channels.
        guard let section = livePanelSections.first(where: { section in
            section.items.contains(where: { $0.id == id })
        }) else { return }
        let channelsById = Dictionary(uniqueKeysWithValues: m3uStore.channels.map { ($0.id, $0) })
        let newQueue = section.items.compactMap { channelsById[$0.id] }
        guard let newIdx = newQueue.firstIndex(where: { $0.id == id }) else { return }
        queue = newQueue
        currentIndex = newIdx
        resumeTimeMs = nil
    }

    nonisolated private static func buildLivePanelSections(queue: [DBM3UChannel], ungroupedLabel: String) -> [ChannelPanelSection] {
        var groupOrder: [String] = []
        var groups: [String: [DBM3UChannel]] = [:]
        for channel in queue {
            guard let url = M3UParser.sanitizedURL(from: channel.url) else { continue }
            let classification = M3UStreamClassifier.classify(url: url, groupTitle: channel.groupTitle)
            guard classification.isLive else { continue }
            let raw = channel.groupTitle?.trimmingCharacters(in: .whitespaces)
            let key = (raw?.isEmpty == false ? raw! : ungroupedLabel)
            if groups[key] == nil {
                groupOrder.append(key)
                groups[key] = []
            }
            groups[key]?.append(channel)
        }
        return groupOrder.map { key in
            ChannelPanelSection(
                id: key,
                title: M3UContentStore.displayName(forGroup: key),
                items: (groups[key] ?? []).map { ch in
                    ChannelPanelItem(
                        id: ch.id,
                        name: ch.name,
                        iconURL: ch.tvgLogo.flatMap { URL(string: $0) }
                    )
                }
            )
        }
    }

    /// The store has already grouped the playlist; for each category it is enough to filter only the live channels.
    nonisolated private static func buildLivePanelSectionsFromStore(
        names: [String],
        byGroup: [String: [DBM3UChannel]]
    ) -> [ChannelPanelSection] {
        var result: [ChannelPanelSection] = []
        result.reserveCapacity(names.count)
        for name in names {
            let groupChannels = byGroup[name] ?? []
            var items: [ChannelPanelItem] = []
            items.reserveCapacity(groupChannels.count)
            for ch in groupChannels {
                guard let url = M3UParser.sanitizedURL(from: ch.url) else { continue }
                let classification = M3UStreamClassifier.classify(url: url, groupTitle: ch.groupTitle)
                guard classification.isLive else { continue }
                items.append(
                    ChannelPanelItem(
                        id: ch.id,
                        name: ch.name,
                        iconURL: ch.tvgLogo.flatMap { URL(string: $0) }
                    )
                )
            }
            if !items.isEmpty {
                result.append(ChannelPanelSection(id: name, title: M3UContentStore.displayName(forGroup: name), items: items))
            }
        }
        return result
    }
}

/// Detects whether M3U channels are live broadcasts or VOD (movie/series).
/// The seek bar, resume and control-center behaviors depend on this.
enum M3UStreamClassifier {
    struct Classification {
        /// Given to `PlayerView.isLiveStream` — if false, the seek bar appears and resume works.
        let isLive: Bool
        /// `PlayerView.type` — for watch history ("live" | "vod").
        let playbackType: String
        /// If the URL has an obvious file extension (mp4/mkv/...), it is passed to the player as info.
        let containerExtension: String?
    }

    /// VOD indicators: file extensions and Xtream-style paths.
    nonisolated private static let vodExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "webm", "flv", "m4v", "wmv", "3gp"]
    nonisolated private static let vodPathHints: [String] = ["/movie/", "/movies/", "/series/", "/vod/", "/films/", "/film/"]

    nonisolated static func classify(url: URL, groupTitle: String?) -> Classification {
        let path = url.path.lowercased()
        let ext = url.pathExtension.lowercased()

        if vodPathHints.contains(where: path.contains) {
            return Classification(isLive: false, playbackType: "vod", containerExtension: ext.isEmpty ? nil : ext)
        }
        if vodExtensions.contains(ext) {
            return Classification(isLive: false, playbackType: "vod", containerExtension: ext)
        }
        // Known live indicators or extensionless Xtream-style: assume live.
        return Classification(isLive: true, playbackType: "live", containerExtension: ext.isEmpty ? nil : ext)
    }
}
