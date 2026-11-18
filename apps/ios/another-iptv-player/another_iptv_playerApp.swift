import SwiftUI
import Nuke

class AppDelegate: NSObject, UIApplicationDelegate {
    /// Round 9 (owner recording, build 45): the browse/tab interface is
    /// PORTRAIT-ONLY on iPhone — in landscape the Live tab's sections
    /// overlapped, the hero/logo cards stretched and a leftover player
    /// pane clung to the edge, because those screens were never laid
    /// out for landscape. Landscape now exists ONLY inside the video
    /// player: `PlayerView` raises the lock to `.allButUpsideDown`
    /// while fullscreen and restores this browse mask when it exits
    /// or docks to the mini player. (`LiveChannelBrowserScreen` —
    /// defined in PlayerView.swift, currently unreferenced — assigns
    /// this same lock directly to force `.landscape` while open and
    /// restore the player's mask on the way out, so it stays
    /// compatible if it is ever re-wired.) iPad keeps free rotation
    /// everywhere (its layouts are width-driven).
    static var orientationLock: UIInterfaceOrientationMask = AppDelegate.browseOrientationLock

    /// The mask every non-player surface lives under.
    static var browseOrientationLock: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .allButUpsideDown : .portrait
    }

    /// Sets the lock and makes the system re-evaluate it NOW (a static
    /// change alone only applies at the next presentation). When
    /// `forceOrientation` is given (locking back to portrait), a
    /// geometry update is also requested so a phone still physically
    /// held in landscape rotates its UI back immediately.
    static func setOrientationLock(
        _ mask: UIInterfaceOrientationMask,
        forceOrientation: UIInterfaceOrientationMask? = nil
    ) {
        orientationLock = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        // Round 10: poke EVERY window's root controller, not just the
        // key window's — with the player overlay up, the key window is
        // not guaranteed to be the one hosting the interface, and a
        // missed poke leaves the system consulting the stale mask.
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        if let forceOrientation {
            let request = {
                scene.requestGeometryUpdate(
                    UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: forceOrientation)
                ) { _ in }
            }
            request()
            // Round 10 (owner video, build 46): exiting the player
            // while the phone is still physically sideways left the
            // browse UI stuck in landscape. A geometry request issued
            // mid-rotation (the exit swipe usually starts while the
            // interface is still turning) can be dropped by the
            // system with the error swallowed above. Re-issue ONCE,
            // shortly after, if the interface orientation still isn't
            // inside the forced mask.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let current = scene.interfaceOrientation
                guard current != .unknown else { return }
                let currentMask = UIInterfaceOrientationMask(rawValue: 1 << UInt(current.rawValue))
                if !forceOrientation.contains(currentMask) {
                    request()
                }
            }
        }
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Cinematic Dark chrome for UIKit-backed bars (tab bar / nav bar).
        AppChrome.apply()
        // Build 61 (B1, S3): BGAppRefreshTask registration must
        // happen before launch finishes; the service schedules its
        // first run itself.
        BackgroundRefreshService.register()
        // C2 (Round 15): memory-warning response — trim the IMAGE
        // memory cache only; the catalog and all DB state stay. (The
        // pipeline itself lives in CachedImage.swift, which is not the
        // app file's to edit; the hookup lives here.)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            ImagePipeline.shared.cache.removeAll()
        }
        return true
    }

    /// The system calls it for background URLSession events. We forward the completion handler to DownloadManager;
    /// when all delegate calls are delivered, it triggers `urlSessionDidFinishEvents`.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        Task { @MainActor in
            DownloadManager.shared.backgroundCompletionHandler = completionHandler
        }
    }
}

@main
struct another_iptv_playerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        IPTVRemoteImagePipeline.installAsShared()
        // C10 (Round 15): cold start — DB touch and fixture seeding are
        // DEFERRED until after the first frame (see the `.task` on
        // AppRootView). The old init synchronously opened/migrated the
        // DB and seeded fixtures before the window existed, adding
        // that whole cost to time-to-first-frame.
        UserDefaults.standard.register(defaults: [
            "player.pipEnabled": true,
            "player.continuePlayingInBackground": true,
            "player.speedUpOnLongPress": true,
            "player.autoPlayNextEpisode": true
        ])
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}

/// The app root observes the language choice: on a change, `.id` rebuilds the whole hierarchy,
/// so every text resolved via L() immediately switches to the new language (trusting only 3-4 views' observing
/// the manager was leaving most screens in the old language). `.locale` and
/// `.layoutDirection` are also set according to the choice — in Arabic, number/date formats and
/// the RTL layout follow the chosen language, not the device language.
private struct AppRootView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    // Build 61 (B3, item 7a): the user's appearance choice
    // (Settings ▸ Playback & Appearance; key "app.appearance",
    // values "system" / "light" / "dark"). Default is "dark" —
    // the app's established look — until the user picks otherwise.
    @AppStorage("app.appearance") private var appearanceChoice = "dark"

    /// The stored choice as a color scheme; nil = follow system.
    private var preferredScheme: ColorScheme? {
        switch appearanceChoice {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
    // Round 7: observing the accent store re-renders the hierarchy on a
    // picker change; the environment accent below routes every
    // `Color.accentColor` / control tint in the app to the chosen color
    // (the AccentColor asset remains only as the pre-root fallback).
    @ObservedObject private var accentTheme = AccentThemeStore.shared

    var body: some View {
        let code = localization.effectiveLanguageCode
        let isRTL = Locale.Language(identifier: code).characterDirection == .rightToLeft
        ContentView()
            // C10: runs after the first frame is committed — first DB
            // touch, fixture seed, and the ~500-per-playlist history
            // prune all happen here, off the launch path.
            .task {
                _ = AppDatabase.shared
                MockFixture.seedIfNeeded()
                await AppDatabase.shared.pruneWatchHistory()
                // === B5 (build 61) Item 3: iCloud sync start (one line;
                // the service degrades silently when iCloud is off) ===
                ICloudSyncService.shared.startIfNeeded()
                // === End B5 Item 3 ===
                // Build 61 (B3, T2): queue the last watched live
                // channel for launch resume when the user enabled
                // it (consumed by the dashboard's existing
                // pending-playback path; a no-op when off).
                await LaunchResumeService.scheduleIfEnabled()
            }
            // Build 61 (B3, item 7a): the stored appearance choice
            // replaces the hard-forced dark scheme (default stays
            // dark). The player subtree keeps its own nil reset in
            // PlayerOverlayController, exactly as before.
            .preferredColorScheme(preferredScheme)
            .accentColor(accentTheme.color)
            .tint(accentTheme.color)
            .environment(\.appDatabase, .shared)
            .environment(\.locale, Locale(identifier: code))
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
            .id(localization.selectedLanguage)
    }
}
