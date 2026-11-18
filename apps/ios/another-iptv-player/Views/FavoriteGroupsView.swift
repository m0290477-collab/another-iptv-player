import SwiftUI

/// Build 61 (B8, J1 + R6): custom favorite groups surface.
///
/// Lives in the Library area alongside Favorites and Watch Later
/// (reachable from FavoritesView). Groups are created / renamed /
/// deleted here; items are added from each item's own menus (live
/// card menu, movie & series detail pages) and removed here.
///
/// R6: a group item whose catalog entry has vanished STAYS listed,
/// rendered from its add-time snapshot with an "unavailable" mark —
/// user data is never silently deleted. Available items navigate /
/// play through the same paths the Favorites surface uses.
struct FavoriteGroupsView: View {
    let playlist: Playlist

    @ObservedObject private var groupStore = FavoriteGroupStore.shared
    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @Environment(\.posterMetrics) private var posterMetrics

    @State private var showCreateGroup = false
    @State private var newGroupName = ""
    @State private var renamingGroup: FavoriteGroupStore.Group?
    @State private var renameText = ""
    @State private var pendingMovie: DBVODStream?
    @State private var pendingSeries: DBSeries?

    private var groups: [FavoriteGroupStore.Group] {
        groupStore.groups(playlistId: playlist.id)
    }

    var body: some View {
        Group {
            if groups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(L("groups.empty"))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        showCreateGroup = true
                    } label: {
                        Label(L("groups.create"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            if group.items.isEmpty {
                                Text(L("groups.group_empty"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(group.items) { item in
                                    itemRow(group: group, item: item)
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.name)
                                Spacer()
                                Menu {
                                    Button {
                                        renameText = group.name
                                        renamingGroup = group
                                    } label: {
                                        Label(L("groups.rename"), systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        groupStore.deleteGroup(playlistId: playlist.id, groupId: group.id)
                                    } label: {
                                        Label(L("groups.delete"), systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(L("groups.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCreateGroup = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L("groups.create"))
            }
        }
        .alert(L("groups.create"), isPresented: $showCreateGroup) {
            TextField(L("groups.name_placeholder"), text: $newGroupName)
            Button(L("common.cancel"), role: .cancel) { newGroupName = "" }
            Button(L("groups.create")) {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    groupStore.createGroup(playlistId: playlist.id, name: name)
                }
                newGroupName = ""
            }
        }
        .alert(L("groups.rename"), isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField(L("groups.name_placeholder"), text: $renameText)
            Button(L("common.cancel"), role: .cancel) { renamingGroup = nil }
            Button(L("common.save")) {
                if let group = renamingGroup {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        groupStore.renameGroup(playlistId: playlist.id, groupId: group.id, name: name)
                    }
                }
                renamingGroup = nil
            }
        }
        .navigationDestination(item: $pendingMovie) { movie in
            MovieDetailView(playlist: playlist, movie: movie)
        }
        .navigationDestination(item: $pendingSeries) { series in
            SeriesDetailView(playlist: playlist, series: series)
        }
        .cinematicBackground()
    }

    // MARK: - Item rows (R6-aware)

    /// The catalog record for a group item, when it still exists.
    private enum Resolved {
        case live(DBLiveStream)
        case vod(DBVODStream)
        case series(DBSeries)
        case unavailable
    }

    private func resolve(_ item: FavoriteGroupStore.Item) -> Resolved {
        switch item.type {
        case "live":
            guard let streamId = Int(item.itemId),
                  let stream = contentStore.liveStreams.first(where: { $0.stream.streamId == streamId })?.stream
            else { return .unavailable }
            return .live(stream)
        case "vod":
            guard let streamId = Int(item.itemId),
                  let movie = contentStore.vodStreams.first(where: { $0.stream.streamId == streamId })?.stream
            else { return .unavailable }
            return .vod(movie)
        case "series":
            guard let seriesId = Int(item.itemId),
                  let series = contentStore.seriesItems.first(where: { $0.series.seriesId == seriesId })?.series
            else { return .unavailable }
            return .series(series)
        default:
            return .unavailable
        }
    }

    @ViewBuilder
    private func itemRow(group: FavoriteGroupStore.Group, item: FavoriteGroupStore.Item) -> some View {
        let resolved = resolve(item)
        HStack(spacing: 12) {
            CachedImage(
                url: item.imageURL.flatMap { URL(string: $0) },
                width: 44, height: 44,
                cornerRadius: AppTheme.smallCornerRadius,
                iconName: item.type == "live" ? "tv" : (item.type == "vod" ? "film" : "play.tv")
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if case .unavailable = resolved {
                    Label(L("groups.unavailable"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                groupStore.removeItem(playlistId: playlist.id, groupId: group.id, item: item)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("groups.remove_item"))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            switch resolved {
            case .live(let stream):
                let live = LiveChannelCategorySection.xtreamLiveQueue()
                playerOverlay.present(playlistId: playlist.id) {
                    LivePlayerShell(playlist: playlist, queue: live.queue, sections: live.sections,
                                    initialStream: stream, initialHistory: nil, subtitle: nil)
                }
            case .vod(let movie):
                pendingMovie = movie
            case .series(let series):
                pendingSeries = series
            case .unavailable:
                break // R6: stays listed, honestly marked; nothing to open.
            }
        }
    }
}

/// Shared J1 "add to group" menu content for item menus/detail pages:
/// one toggle row per existing group (checkmarked when the item is
/// already a member). Group CREATION lives on FavoriteGroupsView —
/// menus never spawn alert flows.
struct FavoriteGroupMenuItems: View {
    let playlist: Playlist
    let item: FavoriteGroupStore.Item
    /// Context menus cannot host a NavigationLink reliably; callers
    /// inside one pass false and the row simply appears once at least
    /// one group exists (creation lives on FavoriteGroupsView).
    var allowCreateLink: Bool = true

    @ObservedObject private var groupStore = FavoriteGroupStore.shared

    var body: some View {
        let groups = groupStore.groups(playlistId: playlist.id)
        if groups.isEmpty {
            if allowCreateLink {
                NavigationLink {
                    FavoriteGroupsView(playlist: playlist)
                } label: {
                    Label(L("groups.add_to_group"), systemImage: "folder.badge.plus")
                }
            }
        } else {
            Menu {
                ForEach(groups) { group in
                    Button {
                        groupStore.toggle(playlistId: playlist.id, groupId: group.id, item: item)
                    } label: {
                        Label(
                            group.name,
                            systemImage: groupStore.contains(playlistId: playlist.id, groupId: group.id, item: item)
                                ? "checkmark.circle.fill" : "folder"
                        )
                    }
                }
            } label: {
                Label(L("groups.add_to_group"), systemImage: "folder.badge.plus")
            }
        }
    }
}
