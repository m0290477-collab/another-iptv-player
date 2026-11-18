import SwiftUI

/// TabView for M3U playlists. No Live/Movies/Series split — a single "Channels" list.
struct M3UDashboardView: View {
    let playlist: Playlist
    let onDismiss: () -> Void
    /// Round 10: playlist switching from Settings ▸ My Playlists.
    let onSwitchPlaylist: (Playlist) -> Void

    @ObservedObject private var store = M3UContentStore.shared
    @ObservedObject private var favorites = M3UFavoriteStore.shared
    @ObservedObject private var epgStore = EPGStore.shared
    @StateObject private var playerOverlay = PlayerOverlayController()

    /// The last selected tab is not persisted — the dashboard always opens on "Channels".
    @State private var selectedTab: Int = 0

    /// Round 16 (P3): same removal as DashboardView — no tab-change
    /// slide state; selection changes are plain (the system animates
    /// its own bar). The B12 light haptic stays.
    private var tabBinding: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                guard newTab != selectedTab else { return }
                Haptics.selection()
                selectedTab = newTab
            }
        )
    }

    /// Round 14/15 (B9 + C12): same tab-label system as DashboardView —
    /// one semibold filled icon family, selected icon under-glow.
    @ViewBuilder
    private func tabLabel(_ title: String, symbol: String, tab: Int) -> some View {
        let isSelected = selectedTab == tab
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .shadow(color: isSelected ? AppTheme.tabGlow : .clear,
                        radius: isSelected ? 7 : 0, y: isSelected ? 3 : 0)
        }
    }
    // Keep poster sizing tied to the display, not to this view's transient layout.
    // Keyboard/status-bar/player transitions can temporarily shrink GeometryReader.
    private let posterMetrics = PosterMetrics(windowSize: UIScreen.main.bounds.size)

    var body: some View {
        ZStack {
            TabView(selection: tabBinding) {
                Tab(value: 0) {
                    NavigationStack {
                        M3UChannelsView(playlist: playlist)
                            .navigationTitle(L("dashboard.channels"))
                            .navigationBarTitleDisplayMode(.large)
                            .toolbar(.visible, for: .navigationBar)
                            .toolbarBackground(.visible, for: .navigationBar)
                    }
                } label: { tabLabel(L("dashboard.channels"), symbol: "tv.fill", tab: 0) }

                Tab(value: 1) {
                    NavigationStack {
                        M3UPlaylistSettingsView(playlist: playlist, onDismiss: onDismiss, onSwitchPlaylist: onSwitchPlaylist)
                            .navigationTitle(L("dashboard.settings"))
                            .navigationBarTitleDisplayMode(.large)
                    }
                } label: { tabLabel(L("dashboard.settings"), symbol: "gearshape.fill", tab: 1) }
            }
            // Round 16 (P3): no .sidebarAdaptable and no container
            // animation/offset — same fix as DashboardView: the
            // standard tab bar reserves the bottom safe area, is a
            // single instance during transitions, and keeps
            // platform-standard tap targets.
            .environment(\.posterMetrics, posterMetrics)

            ZStack {
                if let item = playerOverlay.presentation {
                    item.root
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.playerOverlayDismiss) {
                            playerOverlay.dismiss(animated: true)
                        }
                        .environment(\.playerOverlayMode, playerOverlay.mode)
                        .environment(\.playerOverlayPresentationID, item.id)
                        .environment(\.playerOverlayMinimize) { playerOverlay.minimize() }
                        .environment(\.playerOverlayExpand) { playerOverlay.expand() }
                        // Keep UIKit-backed video surfaces at a fixed geometry while they attach.
                        // Moving the whole AVPlayer/KSPlayer subtree produced a launch flash.
                        .transition(.opacity)
                }
            }
            // Animate only insertion/removal, never in-place source revisions.
            .animation(.easeOut(duration: 0.14), value: playerOverlay.presentation != nil)
            .zIndex(10_000)
        }
        .environmentObject(playerOverlay)
        .environment(\.epgSnapshot, epgStore.snapshot)
        .task(id: playlist.id) {
            favorites.track(playlistId: playlist.id)
            await store.loadPlaylist(playlist)
            epgStore.setActivePlaylist(playlist)
            await epgStore.refreshIfStale(playlist: playlist)
        }
        .alert(L("loading.error.title"), isPresented: Binding(
            get: {
                store.loadError != nil
                    && store.activePlaylistId == playlist.id
                    && !store.isLoading
            },
            set: { if !$0 { store.loadError = nil } }
        )) {
            Button(L("common.ok")) {
                store.loadError = nil
            }
            Button(L("common.try_again")) {
                store.loadError = nil
                Task { await store.loadPlaylist(playlist) }
            }
        } message: {
            Text(store.loadError ?? "")
        }
        // Round 16 (R8): the round-12 expired-state sheet host that
        // sat here is removed — it could never fire on this
        // dashboard (expiry records exist only for Xtream playlists;
        // ProviderExpiryStore refuses non-Xtream kinds). The live
        // host on DashboardView is unchanged.
    }
}
