import SwiftUI
import GRDBQuery
import GRDB

/// The full watch history grid screen.
/// - Parameters:
///   - `playlist`: whose history it is
///   - `typeFilter`: `"live"` / `"vod"` / `"series"` / nil (M3U: tümü)
///   - `onPlay`: called when an item is tapped; every screen applies its own playback logic.
struct WatchHistoryListView: View {
    let playlist: Playlist
    let typeFilter: String?
    let onPlay: (DBWatchHistory) -> Void

    @Query<RecentWatchHistoryRequest> private var items: [DBWatchHistory]
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var showClearConfirm = false
    @Environment(\.appDatabase) private var appDatabase

    init(playlist: Playlist, typeFilter: String?, onPlay: @escaping (DBWatchHistory) -> Void) {
        self.playlist = playlist
        self.typeFilter = typeFilter
        self.onPlay = onPlay
        _items = Query(
            RecentWatchHistoryRequest(playlistId: playlist.id, limit: 500, type: typeFilter),
            in: \.appDatabase
        )
    }

    private var filtered: [DBWatchHistory] {
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { CatalogTextSearch.matches(search: q, text: $0.title) }
    }

    private var navTitle: String {
        switch typeFilter {
        case "live":   return L("history.title.live")
        case "vod":    return L("history.title.vod")
        case "series": return L("history.title.series")
        default:       return L("history.title")
        }
    }

    var body: some View {
        // Single pass: reading the `filtered` computed property separately for both isEmpty and ForEach
        // was normalizing and scanning 500 rows twice on every render.
        let results = filtered
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    L("history.empty.title"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(L("history.empty.message"))
                )
            } else if results.isEmpty {
                ContentUnavailableView(
                    L("favorites.empty.no_result.title"),
                    systemImage: "magnifyingglass",
                    description: Text(L("category_picker.not_found.message"))
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160), spacing: 16)],
                        spacing: 20
                    ) {
                        ForEach(results) { item in
                            HistoryCardGridItem(item: item) {
                                onPlay(item)
                            }
                            // B3: remove this single history entry.
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task { await removeItem(item) }
                                } label: {
                                    Label(L("continue_watching.remove"), systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .searchable(text: $searchText, prompt: L("history.search_placeholder"))
        .onChange(of: searchText) { _, new in
            debounceTask?.cancel()
            let trimmed = new.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                debouncedQuery = ""
                return
            }
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { debouncedQuery = new }
            }
        }
        .onDisappear { debounceTask?.cancel(); debounceTask = nil }
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(L("history.clear.label"))
                }
            }
        }
        .alert(L("history.clear.title"), isPresented: $showClearConfirm) {
            Button(L("common.cancel"), role: .cancel) { }
            Button(L("common.confirm_delete_yes"), role: .destructive) {
                Task { await clearHistory() }
            }
        } message: {
            Text(clearAlertMessage)
        }
        .cinematicBackground()
    }

    private var clearAlertMessage: String {
        switch typeFilter {
        case "live":   return L("history.clear.message.live")
        case "vod":    return L("history.clear.message.vod")
        case "series": return L("history.clear.message.series")
        default:       return L("history.clear.message.all")
        }
    }

    private func removeItem(_ item: DBWatchHistory) async {
        let id = item.id
        try? await appDatabase.write { db in
            try DBWatchHistory.filter(Column("id") == id).deleteAll(db)
        }
    }

    private func clearHistory() async {
        let pid = playlist.id
        let type = typeFilter
        do {
            try await appDatabase.write { db in
                if let type {
                    try db.execute(
                        sql: "DELETE FROM watchHistory WHERE playlistId = ? AND type = ?",
                        arguments: [pid, type]
                    )
                } else {
                    try db.execute(
                        sql: "DELETE FROM watchHistory WHERE playlistId = ?",
                        arguments: [pid]
                    )
                }
            }
        } catch {
            Log.error("WatchHistory", "clear error: \(error.localizedDescription)")
        }
    }
}

/// The grid equivalent of the `HistoryCard` in ContinueWatchingRow — the
/// same 160×90 art card (one shared decode variant across both history
/// surfaces), progress at the bottom left; title + subtitle below.
private struct HistoryCardGridItem: View {
    let item: DBWatchHistory
    let onTap: () -> Void
    @State private var fillFraction: CGFloat = 0

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    // Round 11: live logos get the same fitted-logo
                    // treatment as the Home row (`LiveLogoArt`) —
                    // this grid used `.fill` for every type, which
                    // cropped channel logos at the card edges.
                    if item.type == "live" {
                        LiveLogoArt(
                            url: item.imageURL.flatMap { ArtworkURL.url(from: $0) },
                            width: 160,
                            height: 90,
                            cornerRadius: AppTheme.smallCornerRadius
                        )
                    } else {
                        CachedImage(
                            url: item.imageURL.flatMap { ArtworkURL.url(from: $0) },
                            width: 160,
                            height: 90,
                            cornerRadius: 10,
                            contentMode: .fill,
                            iconName: "film",
                            title: item.title
                        )
                    }

                    if item.type != "live" && item.durationMs > 0 {
                        let progress = Double(item.lastTimeMs) / Double(item.durationMs)
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(.black.opacity(0.55))
                                .frame(height: 3)
                            Rectangle()
                                .fill(AppTheme.accent)
                                .frame(width: 160 * min(max(progress, 0), 1) * fillFraction, height: 3)
                        }
                        .onAppear {
                            withAnimation(Motion.animate(.easeOut(duration: 0.7))) { fillFraction = 1 }
                        }
                    }
                }
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius))

                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let subtitle = item.secondaryTitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 160, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
