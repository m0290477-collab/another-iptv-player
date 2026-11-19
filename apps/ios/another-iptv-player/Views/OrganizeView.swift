import SwiftUI
import GRDB

/// Build 68 (W-D): the ONE organization management surface for a
/// single playlist. Before this view, organization state was only
/// reachable scattered: hide/unhide lived in card context menus and
/// the category picker, category order lived inside
/// `CategoryPickerSheet`'s edit mode, channel order in the
/// per-category `ReorderChannelsView` sheet, pins in card menus, and
/// favorite groups in the Library. This view gathers every one of
/// those stores for ONE playlist in one place:
///
/// - Hidden channels (`HiddenChannelStore`) with per-item Unhide.
/// - Hidden categories (`HiddenCategoryStore`) with per-item Unhide.
/// - Category order (`CategoryOrderStore`) via the reorder editor
///   below — the same store `CategoryPickerSheet` writes.
/// - Channel order via the existing `ReorderChannelsView`
///   (Xtream live categories; no M3U equivalent exists in-tree).
/// - Pinned channels (`PinnedChannelStore`) with per-item Unpin.
/// - Favorite groups via the existing `FavoriteGroupsView`.
///
/// Display names are resolved from the playlist's own catalog rows
/// in the database (the same tables the list views render), so the
/// surface works for any playlist, not only the active one. An id
/// that no longer resolves to a catalog row is shown as its raw id —
/// the user's stored organization is never silently dropped.
struct OrganizeView: View {
    let playlist: Playlist

    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var hiddenChannelStore = HiddenChannelStore.shared
    @ObservedObject private var hiddenCategoryStore = HiddenCategoryStore.shared
    @ObservedObject private var pinnedStore = PinnedChannelStore.shared
    @ObservedObject private var groupStore = FavoriteGroupStore.shared

    // Catalog snapshots for name resolution, loaded once on appear.
    @State private var liveNameById: [Int: String] = [:]
    @State private var m3uNameById: [String: String] = [:]
    @State private var categoryNameByKey: [String: String] = [:]
    @State private var liveCategories: [DBCategory] = []
    @State private var vodCategories: [DBCategory] = []
    @State private var seriesCategories: [DBCategory] = []
    @State private var m3uGroups: [String] = []

    private var isM3U: Bool { playlist.kind == .m3u }

    private var categoryTypes: [String] {
        isM3U ? ["m3u"] : ["live", "vod", "series"]
    }

    private var hiddenXtreamChannelIds: [Int] {
        hiddenChannelStore.hiddenIds(playlistId: playlist.id).sorted()
    }

    private var hiddenM3UChannelIds: [String] {
        hiddenChannelStore.hiddenM3UIds(playlistId: playlist.id).sorted()
    }

    private var pinnedXtreamIds: [Int] {
        pinnedStore.pinnedIds(playlistId: playlist.id).sorted()
    }

    private var pinnedM3UIds: [String] {
        pinnedStore.pinnedM3UIds(playlistId: playlist.id).sorted()
    }

    private var hasHiddenChannels: Bool {
        isM3U ? !hiddenM3UChannelIds.isEmpty : !hiddenXtreamChannelIds.isEmpty
    }

    private var hasPinnedChannels: Bool {
        isM3U ? !pinnedM3UIds.isEmpty : !pinnedXtreamIds.isEmpty
    }

    private func hiddenCategoryIds(type: String) -> [String] {
        hiddenCategoryStore.hiddenIds(playlistId: playlist.id, type: type).sorted()
    }

    private var hasHiddenCategories: Bool {
        categoryTypes.contains { !hiddenCategoryIds(type: $0).isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                hiddenChannelsSection
                hiddenCategoriesSection
                categoryOrderSection
                if !isM3U {
                    channelOrderSection
                }
                pinnedChannelsSection
                favoriteGroupsSection
            }
            .listStyle(.insetGrouped)
            .cinematicScrollBackground()
            .navigationTitle(L("organize.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
            .task { await loadCatalog() }
        }
    }

    // MARK: - Hidden channels

    @ViewBuilder
    private var hiddenChannelsSection: some View {
        Section(L("organize.hidden_channels")) {
            if !hasHiddenChannels {
                Text(L("organize.none"))
                    .foregroundStyle(.secondary)
            } else if isM3U {
                ForEach(hiddenM3UChannelIds, id: \.self) { channelId in
                    HStack {
                        Text(m3uNameById[channelId] ?? channelId)
                            .lineLimit(1)
                        Spacer()
                        Button(L("organize.unhide")) {
                            hiddenChannelStore.setHiddenM3U(false, playlistId: playlist.id, channelId: channelId)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(AppTheme.accent)
                    }
                }
            } else {
                ForEach(hiddenXtreamChannelIds, id: \.self) { streamId in
                    HStack {
                        Text(liveNameById[streamId] ?? "#\(streamId)")
                            .lineLimit(1)
                        Spacer()
                        Button(L("organize.unhide")) {
                            hiddenChannelStore.setHidden(false, playlistId: playlist.id, streamId: streamId)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(AppTheme.accent)
                    }
                }
            }
        }
    }

    // MARK: - Hidden categories

    @ViewBuilder
    private var hiddenCategoriesSection: some View {
        Section(L("organize.hidden_categories")) {
            if !hasHiddenCategories {
                Text(L("organize.none"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(categoryTypes, id: \.self) { type in
                    ForEach(hiddenCategoryIds(type: type), id: \.self) { categoryId in
                        HStack {
                            Text(hiddenCategoryName(type: type, categoryId: categoryId))
                                .lineLimit(1)
                            Spacer()
                            Text(categoryTypeLabel(type))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(L("organize.unhide")) {
                                hiddenCategoryStore.setHidden(false, playlistId: playlist.id, type: type, categoryId: categoryId)
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(AppTheme.accent)
                        }
                    }
                }
            }
        }
    }

    private func hiddenCategoryName(type: String, categoryId: String) -> String {
        // M3U hidden-category ids ARE the group names themselves.
        if type == "m3u" { return M3UContentStore.displayName(forGroup: categoryId) }
        return categoryNameByKey["\(type)|\(categoryId)"] ?? categoryId
    }

    private func categoryTypeLabel(_ type: String) -> String {
        switch type {
        case "live": return L("dashboard.live")
        case "vod": return L("dashboard.movies")
        case "series": return L("dashboard.series")
        default: return L("dashboard.channels")
        }
    }

    // MARK: - Category order

    @ViewBuilder
    private var categoryOrderSection: some View {
        Section(L("organize.category_order")) {
            if isM3U {
                if m3uGroups.count > 1 {
                    NavigationLink {
                        OrganizeCategoryOrderView(
                            playlist: playlist,
                            type: "m3u",
                            title: L("dashboard.channels"),
                            entries: m3uGroups.map {
                                OrganizeCategoryEntry(id: $0, name: M3UContentStore.displayName(forGroup: $0))
                            }
                        )
                    } label: {
                        Text(L("dashboard.channels"))
                    }
                } else {
                    Text(L("organize.none"))
                        .foregroundStyle(.secondary)
                }
            } else {
                let orderable: [OrganizeTypeRow] = [
                    OrganizeTypeRow(type: "live", title: L("dashboard.live"), categories: liveCategories),
                    OrganizeTypeRow(type: "vod", title: L("dashboard.movies"), categories: vodCategories),
                    OrganizeTypeRow(type: "series", title: L("dashboard.series"), categories: seriesCategories)
                ].filter { $0.categories.count > 1 }
                if orderable.isEmpty {
                    Text(L("organize.none"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(orderable) { item in
                        NavigationLink {
                            OrganizeCategoryOrderView(
                                playlist: playlist,
                                type: item.type,
                                title: item.title,
                                entries: item.categories.map {
                                    OrganizeCategoryEntry(id: $0.id, name: $0.name)
                                }
                            )
                        } label: {
                            Text(item.title)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Channel order (Xtream live, via the existing reorder sheet)

    @ViewBuilder
    private var channelOrderSection: some View {
        Section(L("organize.reorder_channels")) {
            if liveCategories.isEmpty {
                Text(L("organize.none"))
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    OrganizeChannelReorderPickerView(playlist: playlist, categories: liveCategories)
                } label: {
                    Text(L("organize.choose_category"))
                }
            }
        }
    }

    // MARK: - Pinned channels

    @ViewBuilder
    private var pinnedChannelsSection: some View {
        Section(L("organize.pinned_channels")) {
            if !hasPinnedChannels {
                Text(L("organize.none"))
                    .foregroundStyle(.secondary)
            } else if isM3U {
                ForEach(pinnedM3UIds, id: \.self) { channelId in
                    HStack {
                        Text(m3uNameById[channelId] ?? channelId)
                            .lineLimit(1)
                        Spacer()
                        Button(L("channels.unpin")) {
                            pinnedStore.setPinnedM3U(false, playlistId: playlist.id, channelId: channelId)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(AppTheme.accent)
                    }
                }
            } else {
                ForEach(pinnedXtreamIds, id: \.self) { streamId in
                    HStack {
                        Text(liveNameById[streamId] ?? "#\(streamId)")
                            .lineLimit(1)
                        Spacer()
                        Button(L("channels.unpin")) {
                            pinnedStore.setPinned(false, playlistId: playlist.id, streamId: streamId)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(AppTheme.accent)
                    }
                }
            }
        }
    }

    // MARK: - Favorite groups

    @ViewBuilder
    private var favoriteGroupsSection: some View {
        Section(L("groups.title")) {
            NavigationLink {
                FavoriteGroupsView(playlist: playlist)
            } label: {
                HStack {
                    Text(L("groups.title"))
                    Spacer()
                    Text("\(groupStore.groups(playlistId: playlist.id).count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Catalog loading

    /// Resolves display names from this playlist's own catalog rows —
    /// the same GRDB tables `LiveStreamsView` / `M3UChannelsView`
    /// render — independent of which playlist is currently active.
    private func loadCatalog() async {
        let pid = playlist.id
        if isM3U {
            let channels: [DBM3UChannel] = (try? await AppDatabase.shared.read { db in
                try DBM3UChannel
                    .filter(Column("playlistId") == pid)
                    .order(Column("sortIndex"))
                    .fetchAll(db)
            }) ?? []
            m3uNameById = Dictionary(
                channels.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
            var groups: [String] = []
            var seen = Set<String>()
            for channel in channels {
                let group = channel.groupTitle?.trimmingCharacters(in: .whitespaces) ?? ""
                if !group.isEmpty, seen.insert(group).inserted {
                    groups.append(group)
                }
            }
            m3uGroups = groups
        } else {
            let streams: [DBLiveStream] = (try? await AppDatabase.shared.read { db in
                try DBLiveStream
                    .filter(Column("playlistId") == pid)
                    .fetchAll(db)
            }) ?? []
            liveNameById = Dictionary(
                streams.map { ($0.streamId, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
            let categories: [DBCategory] = (try? await AppDatabase.shared.read { db in
                try DBCategory
                    .filter(Column("playlistId") == pid)
                    .order(Column("sortIndex"))
                    .fetchAll(db)
            }) ?? []
            liveCategories = categories.filter { $0.type == "live" }
            vodCategories = categories.filter { $0.type == "vod" }
            seriesCategories = categories.filter { $0.type == "series" }
            categoryNameByKey = Dictionary(
                categories.map { ("\($0.type)|\($0.id)", $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
}

// MARK: - Category reorder editor

private struct OrganizeTypeRow: Identifiable {
    let type: String
    let title: String
    let categories: [DBCategory]
    var id: String { type }
}

private struct OrganizeCategoryEntry: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Drag-reorder editor for ONE playlist + content type, writing
/// through `CategoryOrderStore`'s existing API — the same store and
/// merged semantics `CategoryPickerSheet`'s edit mode uses (there is
/// no standalone category reorder view in-tree; the picker embeds
/// it). Moves persist immediately; Reset clears the saved order.
private struct OrganizeCategoryOrderView: View {
    let playlist: Playlist
    let type: String
    let title: String
    let entries: [OrganizeCategoryEntry]

    @ObservedObject private var orderStore = CategoryOrderStore.shared
    @State private var rows: [OrganizeCategoryEntry] = []
    @State private var editMode: EditMode = .active
    @State private var loaded = false

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    L("organize.none"),
                    systemImage: "list.bullet"
                )
            } else {
                List {
                    ForEach(rows) { entry in
                        Text(entry.name)
                            .lineLimit(1)
                    }
                    .onMove { offsets, destination in
                        rows.move(fromOffsets: offsets, toOffset: destination)
                        orderStore.setOrder(
                            rows.map(\.id),
                            playlistId: playlist.id, type: type
                        )
                    }
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, $editMode)
            }
        }
        .cinematicScrollBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !orderStore.orderedIds(playlistId: playlist.id, type: type).isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button(L("reorder.reset"), role: .destructive) {
                        orderStore.setOrder([], playlistId: playlist.id, type: type)
                        rows = entries
                    }
                }
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            rows = orderStore.applyOrder(entries, playlistId: playlist.id, type: type) { $0.id }
        }
    }
}

// MARK: - Channel reorder picker

/// Picks the live category whose channels get reordered, then
/// presents the existing `ReorderChannelsView` for it (the same
/// sheet the live card context menu presents).
private struct OrganizeChannelReorderPickerView: View {
    let playlist: Playlist
    let categories: [DBCategory]

    @State private var selectedCategory: DBCategory?

    var body: some View {
        List {
            ForEach(categories) { category in
                Button {
                    selectedCategory = category
                } label: {
                    HStack {
                        Text(category.name)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .cinematicScrollBackground()
        .navigationTitle(L("organize.reorder_channels"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedCategory) { category in
            ReorderChannelsView(
                playlist: playlist,
                categoryId: category.id,
                categoryName: category.name
            )
        }
    }
}
