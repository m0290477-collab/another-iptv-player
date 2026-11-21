import SwiftUI

/// M3U favorileri grid görünümü. `M3UFavoriteStore` üstünden reaktif günceller.
///
/// To avoid scanning the full list per body in catalogs of 310K+ channels, the favorite and
/// search results are kept in @State and recomputed with `.task(id:)` (debounced).
struct M3UFavoritesView: View {
    let playlist: Playlist

    @ObservedObject private var store = M3UContentStore.shared
    @ObservedObject private var favorites = M3UFavoriteStore.shared
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var favoriteChannels: [DBM3UChannel] = []
    @State private var filtered: [DBM3UChannel] = []
    /// Build 90: unsanitizable-URL tap alert (build 80, F3) —
    /// the channels surfaces show it; this view used to fail
    /// silently on the same tap.
    @State private var showPlayFailure = false

    /// The recomputation trigger when the favorite set or the catalog changes.
    private var recomputeKey: String {
        "\(favorites.favoriteIds.count)-\(favorites.favoriteIds.hashValue)-\(store.channels.count)-\(debouncedQuery)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Round 10: the shared in-view search field replaces
            // `.searchable` here too — the same double-mount glitch
            // family as Search/Favorites (point 5/8).
            CatalogSearchField(text: $searchText, placeholder: L("favorites.search_placeholder"))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)

            Group {
                if favoriteChannels.isEmpty {
                    // C9: styled surface card empty state with accent icon.
                    VStack(spacing: 14) {
                        Image(systemName: "star")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 72, height: 72)
                            .background(Circle().fill(AppTheme.elevated))
                        Text(L("favorites.empty.title"))
                            .font(AppTheme.fontCardTitle)
                        Text(L("favorites.empty.message"))
                            .font(AppTheme.fontMetadata)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous).fill(AppTheme.surface))
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    ContentUnavailableView(
                        L("favorites.empty.no_result.title"),
                        systemImage: "magnifyingglass",
                        description: Text(L("category_picker.not_found.message"))
                    )
                } else {
                    M3UGroupGridContent(items: filtered, onChannelSelected: { channel in
                        present(channel)
                    }, onRemoveFavorite: { channel in
                        // C1: unfavorite directly from the favorites
                        // grid (existing M3UFavoriteStore toggle).
                        Task { await favorites.toggle(channel: channel) }
                    })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        .task(id: recomputeKey) { await recompute() }
        .onDisappear { debounceTask?.cancel(); debounceTask = nil }
        .navigationTitle(L("favorites.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .cinematicBackground()
        .alert(L("playback.error.failed_to_start"), isPresented: $showPlayFailure) {
            Button(L("common.ok")) { showPlayFailure = false }
        }
    }

    private func recompute() async {
        let channels = store.channels
        let ids = favorites.favoriteIds
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        let result = await Task.detached(priority: .userInitiated) { () -> ([DBM3UChannel], [DBM3UChannel]) in
            // Ordering: the original order in the DB channel list (sortIndex) is preserved.
            let favs = channels.filter { ids.contains($0.id) }
            let filteredList = q.isEmpty
                ? favs
                : favs.filter { CatalogTextSearch.matches(search: q, text: $0.name) }
            return (favs, filteredList)
        }.value
        guard !Task.isCancelled else { return }
        favoriteChannels = result.0
        filtered = result.1
    }

    private func present(_ channel: DBM3UChannel) {
        guard M3UParser.sanitizedURL(from: channel.url) != nil else { showPlayFailure = true; return }
        // When playing from favorites, the queue = the favorites list (prev/next moves between favorites).
        playerOverlay.present {
            M3UPlayerShell(
                playlist: playlist,
                channel: channel,
                queue: filtered
            )
        }
    }
}
