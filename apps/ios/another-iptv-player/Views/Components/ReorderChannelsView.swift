import SwiftUI
import GRDB

/// B2 (build 61, item 12 — channel half): drag-reorder sheet for the
/// channels of ONE Xtream live category. The list is a real SwiftUI
/// `List` in edit mode (`.onMove`); the chosen order is persisted
/// via `ChannelOrderStore` and applied by `LiveStreamsView` as
/// tier 3 of the O7 in-category order. "Reset" removes the custom
/// order and returns the category to its provider order.
struct ReorderChannelsView: View {
    let playlist: Playlist
    let categoryId: String
    let categoryName: String?

    @Environment(\.dismiss) private var dismiss
    @State private var channels: [DBLiveStream] = []
    @State private var editMode: EditMode = .active
    @State private var loaded = false

    private var store: ChannelOrderStore { ChannelOrderStore.shared }

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView()
                } else if channels.isEmpty {
                    ContentUnavailableView(
                        L("list.no_channel"),
                        systemImage: "tv.slash"
                    )
                } else {
                    List {
                        ForEach(channels) { channel in
                            HStack(spacing: 12) {
                                CachedImage(
                                    url: channel.streamIcon.flatMap { URL(string: $0) },
                                    width: 40, height: 40,
                                    iconName: "tv",
                                    loadProfile: .grid
                                )
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius))
                                Text(channel.name)
                                    .lineLimit(1)
                            }
                        }
                        .onMove { offsets, destination in
                            channels.move(fromOffsets: offsets, toOffset: destination)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .environment(\.editMode, $editMode)
                }
            }
            .navigationTitle(categoryName ?? L("reorder.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) {
                        store.setOrder(
                            channels.map { String($0.streamId) },
                            playlistId: playlist.id, categoryId: categoryId
                        )
                        dismiss()
                    }
                }
                if store.hasCustomOrder(playlistId: playlist.id, categoryId: categoryId) {
                    ToolbarItem(placement: .bottomBar) {
                        Button(L("reorder.reset"), role: .destructive) {
                            store.setOrder([], playlistId: playlist.id, categoryId: categoryId)
                            dismiss()
                        }
                    }
                }
            }
            .task { await load() }
        }
    }

    /// Loads the category's channels in their CURRENT display order:
    /// the saved custom order (if any) over the provider's sortIndex
    /// order — the same composition `LiveStreamsView` renders.
    private func load() async {
        let pid = playlist.id
        let catId = categoryId
        let rows: [DBLiveStream] = (try? await AppDatabase.shared.read { db in
            try DBLiveStream
                .filter(Column("playlistId") == pid && Column("categoryId") == catId)
                .order(Column("sortIndex"))
                .fetchAll(db)
        }) ?? []
        channels = store.applyOrder(rows, playlistId: pid, categoryId: catId) { String($0.streamId) }
        loaded = true
    }
}
