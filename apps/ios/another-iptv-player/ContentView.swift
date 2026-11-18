import SwiftUI
import GRDBQuery
import GRDB

struct ContentView: View {
    @Query<PlaylistRequest> private var playlists: [Playlist]?
    
    init() {
        _playlists = Query(PlaylistRequest(), in: \.appDatabase)
    }
    @State private var selectedPlaylist: Playlist?
    @State private var hasAttemptedAutoLoad = false
    /// Round 11: an explicit sign-out (the dashboards' onDismiss)
    /// suppresses auto-load for the rest of the session, so the user
    /// actually lands on the gate; a fresh launch always auto-enters
    /// when a saved playlist exists.
    @State private var suppressAutoLoad = false
    @State private var showStorageWarning = false
    /// Build 61 (D2, B6): the branded splash covers the cold start
    /// until the playlists query has answered — the moment the gate
    /// or the auto-loaded dashboard underneath is ready. No timer,
    /// no artificial delay.
    @State private var showSplash = true

    private let lastPlaylistKey = "lastPlaylistId"

    var body: some View {
        storageAwareBody
            .overlay {
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
            .onChange(of: playlists != nil) { _, ready in
                if ready { dismissSplash() }
            }
            .onAppear {
                if playlists != nil { dismissSplash() }
                if AppDatabase.isEphemeral || AppDatabase.didResetCorruptStore {
                    showStorageWarning = true
                }
            }
            .alert(
                AppDatabase.isEphemeral ? L("db.error.ephemeral_title") : L("db.error.reset_title"),
                isPresented: $showStorageWarning
            ) {
                Button(L("common.ok"), role: .cancel) {}
            } message: {
                Text(AppDatabase.isEphemeral ? L("db.error.ephemeral_message") : L("db.error.reset_message"))
            }
    }

    private var storageAwareBody: some View {
        ZStack {
            if let playlist = selectedPlaylist {
                Group {
                    if playlist.kind == .m3u {
                        M3UDashboardView(playlist: playlist, onDismiss: {
                            // Round 15 (C13): remember the NAME ONLY
                            // for the gate's "Continue with" row.
                            UserDefaults.standard.set(playlist.name, forKey: "gate.lastPlaylistName")
                            UserDefaults.standard.removeObject(forKey: lastPlaylistKey)
                            suppressAutoLoad = true
                            withAnimation(Motion.animate(.easeInOut(duration: 0.35))) {
                                selectedPlaylist = nil
                            }
                            // Drop the large catalog copies when returning to the picker.
                            M3UContentStore.shared.unload()
                            EPGStore.shared.setActivePlaylist(nil)
                        }, onSwitchPlaylist: { newPlaylist in
                            switchPlaylist(to: newPlaylist)
                        })
                    } else {
                        DashboardView(playlist: playlist, onDismiss: {
                            // Round 15 (C13): NAME ONLY, as above.
                            UserDefaults.standard.set(playlist.name, forKey: "gate.lastPlaylistName")
                            UserDefaults.standard.removeObject(forKey: lastPlaylistKey)
                            suppressAutoLoad = true
                            withAnimation(Motion.animate(.easeInOut(duration: 0.35))) {
                                selectedPlaylist = nil
                            }
                            PlaylistContentStore.shared.unload()
                            EPGStore.shared.setActivePlaylist(nil)
                        }, onSwitchPlaylist: { newPlaylist in
                            switchPlaylist(to: newPlaylist)
                        })
                    }
                }
                // Round 15 (C12): a successful gate entry
                // CROSS-DISSOLVES into the dashboard (opacity both
                // ways; duration 0 when Motion is reduced/off).
                .transition(.opacity)
                .onAppear {
                    // Round 15 (C3, Features): refresh the widget
                    // snapshot when a dashboard is entered (covers
                    // both dashboards; the Xtream dashboard refreshes
                    // again after its catalog load).
                    Task { await WidgetSnapshotStore.refresh(playlist: playlist) }
                    // Reaching a playlist dashboard = a successful session.
                    RatingManager.shared.registerSuccessfulSession()
                    Task {
                        // A short delay so the user is not interrupted at the greeting moment.
                        try? await Task.sleep(for: .seconds(8))
                        RatingManager.shared.requestReviewIfAppropriate()
                    }
                }
            } else if let playlists = playlists {
                // Round 4: the branded gate takes over the playlist
                // picker's role at this exact decision point.
                // Round 11: the gate is a clean sign-in form only —
                // its old saved-playlist list (and the edit/delete
                // flow that hung off it) is gone; selection happens
                // through auto-load below or the gate's own sign-in,
                // and management lives in Settings ▸ My Playlists.
                PlaylistGateView(
                    playlists: playlists,
                    onSelect: selectPlaylist
                )
                .cinematicBackground()
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .opacity
                ))
            } else {
                // Initial check in progress, show app background to prevent flicker
                AppTheme.background
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            if let playlists = playlists {
                attemptAutoLoad(playlists)
            }
        }
        .onChange(of: playlists) { _, newList in
            if let newList = newList {
                attemptAutoLoad(newList)
            }
        }
    }
    
    private func attemptAutoLoad(_ list: [Playlist]) {
        guard !hasAttemptedAutoLoad else { return }

        // If the query has returned (even if empty), we finalize the check
        hasAttemptedAutoLoad = true

        // Round 11 (owner): a returning user with a saved playlist
        // is NEVER blocked by the gate. Only an explicit in-session
        // sign-out (suppressAutoLoad) or an empty library leaves the
        // gate on screen.
        // Round 15 (C13): the pick order is — non-expired first
        // (the shared expiry verdict on the recorded exp_date),
        // then the marked default, then the last-used playlist,
        // then the user's saved order / newest. When EVERY saved
        // subscription is expired the gate stays up with its
        // explicit "All subscriptions expired" state instead of
        // blind-entering a dead playlist.
        guard !suppressAutoLoad, !list.isEmpty else { return }

        let lastId = UserDefaults.standard.string(forKey: lastPlaylistKey)
            .flatMap(UUID.init(uuidString:))
        let ordered = PlaylistLibraryStore.sorted(list)
        let ranked = ordered.sorted { a, b in
            let aExpired = ProviderExpiryStore.isExpired(expiryDate: ProviderExpiryStore.expiryDate(playlistId: a.id))
            let bExpired = ProviderExpiryStore.isExpired(expiryDate: ProviderExpiryStore.expiryDate(playlistId: b.id))
            if aExpired != bExpired { return !aExpired }
            let aDefault = PlaylistLibraryStore.defaultId == a.id
            let bDefault = PlaylistLibraryStore.defaultId == b.id
            if aDefault != bDefault { return aDefault }
            let aLast = lastId == a.id
            let bLast = lastId == b.id
            if aLast != bLast { return aLast }
            return false // stable: keep the saved library order
        }
        guard let pick = ranked.first,
              !ProviderExpiryStore.isExpired(expiryDate: ProviderExpiryStore.expiryDate(playlistId: pick.id)) else {
            return // all expired → the gate's all-expired state
        }
        selectedPlaylist = pick
    }

    /// Build 61 (D2): cross-fade the splash out as soon as content
    /// is ready (Motion-safe: duration collapses when reduced/off).
    private func dismissSplash() {
        guard showSplash else { return }
        withAnimation(Motion.animate(.easeInOut(duration: 0.3))) {
            showSplash = false
        }
    }

    private func selectPlaylist(_ playlist: Playlist) {
        suppressAutoLoad = false
        // Round 15 (C12): cross-dissolve into the dashboard,
        // Motion-safe (duration collapses to 0 when reduced/off).
        withAnimation(Motion.animate(.easeInOut(duration: 0.35))) {
            selectedPlaylist = playlist
            UserDefaults.standard.set(playlist.id.uuidString, forKey: lastPlaylistKey)
        }
    }

    /// Round 10: switch the active playlist from inside a dashboard
    /// (Settings ▸ My Playlists ▸ Activate / Add & Activate). The
    /// outgoing playlist's in-memory catalog is released exactly like
    /// the back-to-gate path; the incoming dashboard's `.task(id:)`
    /// loads the new playlist and rebinds the EPG store.
    private func switchPlaylist(to newPlaylist: Playlist) {
        if let current = selectedPlaylist, current.id != newPlaylist.id {
            if current.kind == .m3u {
                M3UContentStore.shared.unload()
            } else {
                PlaylistContentStore.shared.unload()
            }
            EPGStore.shared.setActivePlaylist(nil)
        }
        selectPlaylist(newPlaylist)
    }
}

#Preview {
    ContentView()
        .environment(\.appDatabase, .empty())
}
