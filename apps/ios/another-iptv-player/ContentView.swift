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
    /// Build 66 (W4, item 15a): storage could not be opened at all
    /// at launch — the whole UI is replaced by the recovery screen
    /// until a retry succeeds.
    @State private var storageUnavailable = AppDatabase.isStorageUnavailable
    /// Build 61 (B10, L4): the full-screen expired state for the
    /// playlist auto-load would have entered, plus its Renew
    /// (edit-form) sheet.
    @State private var expiredCandidate: Playlist?
    @State private var playlistToRenew: Playlist?
    /// Build 61 (D2, B6): the branded splash covers the cold start
    /// until the playlists query has answered — the moment the gate
    /// or the auto-loaded dashboard underneath is ready.
    /// Build 88 (A4): dismissal still waits for that answer, but
    /// never lands before the owner's 2.5 s minimum dwell.
    @State private var showSplash = true
    /// Build 88 (A4): the minimum-dwell clock. A static so a
    /// hierarchy rebuild (e.g. a language change re-creating
    /// this view) does not restart it — it measures from the
    /// process's first ContentView, i.e. from launch, once.
    private static let splashLaunchDate = Date()
    /// Build 88 (A4): the pending minimum-dwell dismissal, so
    /// repeated readiness callbacks schedule it at most once.
    @State private var splashDismissTask: Task<Void, Never>?
    /// Build 61 (F4, B13): first-run onboarding completion flag.
    /// First launch only; the T6 erase wipes the whole
    /// UserDefaults domain, which resets it (verified in B13's
    /// report — the erase uses `removePersistentDomain`, not a
    /// key list).
    @AppStorage("onboarding.completed.v1") private var onboardingCompleted = false
    /// Build 61 (N2, B13): observes the reinstall-restore pass so
    /// its ONE small notice can be shown (and acknowledged) here.
    @ObservedObject private var restoreService = PlaylistRestoreService.shared
    /// Build 61 (B15, W1): the app-open lock. While locked, the
    /// body renders ONLY the lock screen — the gate, onboarding
    /// and dashboards below are not in the hierarchy at all.
    @ObservedObject private var appLock = AppLockService.shared

    private let lastPlaylistKey = "lastPlaylistId"

    var body: some View {
        // === B15 (build 61) W1: app-open lock gate ===
        Group {
            if storageUnavailable {
                // Build 66 (W4, item 15a): no usable store exists —
                // nothing below may render (every screen queries the
                // placeholder DB). Only the recovery screen shows.
                StorageUnavailableView(
                    onRetry: { AppDatabase.retryStorageOpen() },
                    onRecovered: { storageUnavailable = false }
                )
            } else if appLock.isLocked {
                AppLockView()
            } else {
                mainBody
            }
        }
        // === End B15 W1 ===
        // Build 61 fixer (ST5 application): IBM Plex Sans Arabic as
        // the ENVIRONMENT DEFAULT font for the whole app — Arabic UI
        // text that does not hard-specify its own font renders in the
        // bundled face. `environmentDefault` is nil for every other
        // language, so Latin is byte-for-byte unaffected. (AppRootView
        // rebuilds this hierarchy on a language change, so the value
        // is re-read then.) Hard-specified system fonts on individual
        // views keep their own font — the documented ST5 limit.
        .font(AppFont.environmentDefault)
    }

    private var mainBody: some View {
        storageAwareBody
            .overlay {
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
            // F4: onboarding sits UNDER the splash and ABOVE the
            // gate/dashboard — on a first launch it is revealed as
            // the splash fades and must be finished or skipped
            // before the gate is reachable. On later launches the
            // flag is already set and this never renders.
            .overlay {
                if !showSplash && !onboardingCompleted {
                    OnboardingView {
                        withAnimation(Motion.animate(.easeInOut(duration: 0.3))) {
                            onboardingCompleted = true
                        }
                    }
                    .transition(.opacity)
                    .zIndex(90)
                }
            }
            // N2: the ONE restored-playlists notice for this launch.
            .alert(L("restored.title"), isPresented: Binding(
                get: { restoreService.restoredCount > 0 },
                set: { if !$0 { restoreService.acknowledgeNotice() } }
            )) {
                Button(L("common.ok"), role: .cancel) {
                    restoreService.acknowledgeNotice()
                }
            } message: {
                Text(restoreService.restoredCount == 1
                     ? L("restored.notice_one")
                     : L("restored.notice_many_format", restoreService.restoredCount))
            }
            .onChange(of: playlists != nil) { _, ready in
                if ready { dismissSplash() }
            }
            .onAppear {
                if playlists != nil { dismissSplash() }
                if AppDatabase.isEphemeral || AppDatabase.didResetCorruptStore
                    || AppDatabase.didRestorePreMigrationBackup {
                    showStorageWarning = true
                }
            }
            .alert(
                storageWarningTitle,
                isPresented: $showStorageWarning
            ) {
                Button(L("common.ok"), role: .cancel) {}
            } message: {
                Text(storageWarningMessage)
            }
    }

    // Build 61 (B9, G1): the restored-backup state gets its own
    // honest wording (data intact, old schema) next to the two
    // pre-existing storage warnings.
    private var storageWarningTitle: String {
        if AppDatabase.didRestorePreMigrationBackup { return L("repair.restored_title") }
        return AppDatabase.isEphemeral ? L("db.error.ephemeral_title") : L("db.error.reset_title")
    }

    private var storageWarningMessage: String {
        if AppDatabase.didRestorePreMigrationBackup { return L("repair.restored_message") }
        return AppDatabase.isEphemeral ? L("db.error.ephemeral_message") : L("db.error.reset_message")
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
                            // Build 61 (B9, E1): no active playlist
                            // at the gate — host pre-warm stands down.
                            PlaybackPrewarmService.shared.setActiveHost(nil)
                            withAnimation(Motion.animate(.easeInOut(duration: 0.35))) {
                                selectedPlaylist = nil
                            }
                            // Drop the large catalog copies when returning to the picker.
                            M3UContentStore.shared.unload()
                        }, onSwitchPlaylist: { newPlaylist in
                            switchPlaylist(to: newPlaylist)
                        })
                    } else {
                        DashboardView(playlist: playlist, onDismiss: {
                            // Round 15 (C13): NAME ONLY, as above.
                            UserDefaults.standard.set(playlist.name, forKey: "gate.lastPlaylistName")
                            UserDefaults.standard.removeObject(forKey: lastPlaylistKey)
                            suppressAutoLoad = true
                            // Build 61 (B9, E1): no active playlist
                            // at the gate — host pre-warm stands down.
                            PlaybackPrewarmService.shared.setActiveHost(nil)
                            withAnimation(Motion.animate(.easeInOut(duration: 0.35))) {
                                selectedPlaylist = nil
                            }
                            PlaylistContentStore.shared.unload()
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
                    // Build 66 (W4): the widget-snapshot writer
                    // call that stood here is removed — the widget
                    // snapshot store itself is deleted in this build
                    // (another builder's scope).
                    // Reaching a playlist dashboard = a successful session.
                    RatingManager.shared.registerSuccessfulSession()
                    Task {
                        // A short delay so the user is not interrupted at the greeting moment.
                        try? await Task.sleep(for: .seconds(8))
                        RatingManager.shared.requestReviewIfAppropriate()
                    }
                }
            } else if let expired = expiredCandidate, let expiredDate = ExpiredPlaylistGuard.blockedState(playlist: expired), let playlists = playlists {
                // Build 61 (B10, L4): the active playlist is
                // expired — the app opens to the full-screen
                // expired state instead of blind-entering it or
                // sitting on the gate. Renew opens the K2 edit
                // form for the SAME record; Switch exists only
                // when another playlist does; Remove runs the
                // shared deletion path.
                ExpiredPlaylistView(
                    playlist: expired,
                    expiryDate: expiredDate,
                    canSwitch: playlists.contains { $0.id != expired.id },
                    onRenew: { playlistToRenew = expired },
                    onSwitch: {
                        if let other = playlists.first(where: {
                            $0.id != expired.id
                                && ExpiredPlaylistGuard.blockedState(playlist: $0) == nil
                        }) ?? playlists.first(where: { $0.id != expired.id }) {
                            expiredCandidate = nil
                            selectPlaylist(other)
                        }
                    },
                    onRemove: {
                        Task {
                            _ = await AccountDataDeletion.deletePlaylistData(expired)
                            expiredCandidate = nil
                        }
                    }
                )
                .sheet(item: $playlistToRenew) { playlist in
                    if playlist.kind == .m3u {
                        AddM3UPlaylistView(editingPlaylist: playlist)
                    } else {
                        AddPlaylistView(editingPlaylist: playlist)
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
        guard let pick = ranked.first else { return }
        if let blockedDate = ExpiredPlaylistGuard.blockedState(playlist: pick) {
            // Build 61 (B10, L4): the would-be active playlist is
            // expired → open to the full-screen expired state
            // (Renew / Switch / Remove), not the gate's passive
            // all-expired card and never the dead dashboard.
            expiredCandidate = pick
            return
        }
        selectedPlaylist = pick
        // Build 61 (B9, E1): keep a warm connection to the active
        // playlist's host while browsing.
        PlaybackPrewarmService.shared.setActiveHost(URL(string: pick.serverURL))
    }

    /// Build 61 (D2): cross-fade the splash out as soon as content
    /// is ready (Motion-safe: duration collapses when reduced/off).
    /// Build 88 (A4, owner): the cinematic entry stays a MINIMUM
    /// of 2.5 s — a warm store answers in well under a second,
    /// which flashed the gate past before it could be seen.
    /// Content readiness still drives dismissal; it simply
    /// cannot land before the minimum dwell has elapsed. (The
    /// dwell is a duration, not a motion effect, so it holds
    /// under Reduce Motion too — only the fade collapses there.)
    private func dismissSplash() {
        guard showSplash, splashDismissTask == nil else { return }
        let remaining = 2.5 - Date().timeIntervalSince(Self.splashLaunchDate)
        guard remaining > 0 else {
            withAnimation(Motion.animate(.easeInOut(duration: 0.3))) {
                showSplash = false
            }
            return
        }
        splashDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.animate(.easeInOut(duration: 0.3))) {
                showSplash = false
            }
        }
    }

    private func selectPlaylist(_ playlist: Playlist) {
        suppressAutoLoad = false
        // Build 61 (B9, E1): warm connection to the newly active
        // playlist's host while browsing.
        PlaybackPrewarmService.shared.setActiveHost(URL(string: playlist.serverURL))
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
        }
        selectPlaylist(newPlaylist)
    }
}

#Preview {
    ContentView()
        .environment(\.appDatabase, .empty())
}
