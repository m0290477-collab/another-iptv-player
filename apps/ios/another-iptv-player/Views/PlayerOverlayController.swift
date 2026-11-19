import Combine
import SwiftUI
import UIKit

/// It is kept on the Dashboard `ZStack`; while dismissing by dragging, the tab content underneath is visible.
struct PlayerOverlayPresentation: Identifiable {
    let id = UUID()
    let root: AnyView
    let onDismiss: (() -> Void)?
}

/// Whether the active player fills the screen or is shrunk into the floating mini card.
enum PlayerOverlayMode: Equatable {
    case fullscreen
    case mini
}

final class PlayerOverlayController: ObservableObject {
    /// Build 63 (item 12d, owner rule): cross-instance view of
    /// player presentation for alert suppression. While ANY
    /// player presentation is active the in-app goal celebration
    /// is dropped; while one is FULLSCREEN, foreground push
    /// presentation is suppressed entirely (no banner, no sound)
    /// — "while watching, nothing may appear". Maintained from
    /// `presentation`/`mode` below; read by PushNotificationService
    /// and GoalAlertPresenter.
    static private(set) var presentationActiveCount = 0
    static private(set) var fullscreenPresented = false

    @Published var presentation: PlayerOverlayPresentation? {
        didSet {
            if presentation != nil, oldValue == nil {
                Self.presentationActiveCount += 1
            } else if presentation == nil, oldValue != nil {
                Self.presentationActiveCount = max(0, Self.presentationActiveCount - 1)
            }
            Self.fullscreenPresented = presentation != nil && mode == .fullscreen
        }
    }
    /// The pending presentation held for the confirmation alert shown while there is an active download.
    @Published var pendingPresentation: PlayerOverlayPresentation?
    /// Fullscreen vs. floating mini player. Reset to `.fullscreen` on every new presentation.
    @Published var mode: PlayerOverlayMode = .fullscreen {
        didSet {
            // Item 12d: mini ↔ fullscreen transitions update the
            // suppression snapshot too.
            Self.fullscreenPresented = presentation != nil && mode == .fullscreen
        }
    }

    /// If there is an active download on the same playlist, it asks the user for confirmation (so the server connection limits don't collide).
    /// Another playlist's download has no effect.
    /// `skipDownloadCheck = true` → skips the check for local file playback.
    /// If `playlistId` is not given, no warning is shown (for M3U / playlist-independent playback).
    @MainActor
    func present<Content: View>(
        onDismiss: (() -> Void)? = nil,
        skipDownloadCheck: Bool = false,
        playlistId: UUID? = nil,
        @ViewBuilder content: () -> Content
    ) {
        // Build 61 (B10, L4): the expired-playlist guard lives
        // HERE — at the present-player call site, not inside
        // PlayerView. A playback attempt against an expired
        // playlist presents the plain expired message instead of
        // the player (never a spinner over a dead stream). The
        // verdict is ProviderExpiryStore's real provider data.
        if let playlistId, let expiredDate = ExpiredPlaylistGuard.blockedState(playlistId: playlistId) {
            let notice = PlayerOverlayPresentation(
                root: AnyView(
                    ExpiredPlaybackNoticeView(expiryDate: expiredDate) { [weak self] in
                        self?.dismiss()
                    }
                    .preferredColorScheme(nil)
                ),
                onDismiss: onDismiss
            )
            mode = .fullscreen
            presentation = notice
            return
        }
        // Build 60: build 33 had no forced appearance anywhere — the
        // player followed the system color scheme. The app root now
        // forces dark for the rest of the app (AppRootView), so this
        // presentation resets the preference to nil (system) for the
        // player subtree only, restoring the build-33 player appearance
        // — including the sheets PlayerView presents (track settings,
        // subtitle appearance), which inherit this environment.
        let pkg = PlayerOverlayPresentation(root: AnyView(content().preferredColorScheme(nil)), onDismiss: onDismiss)
        let shouldWarn: Bool = {
            if skipDownloadCheck { return false }
            guard let playlistId else { return false }
            return DownloadManager.shared.hasActiveDownload(playlistId: playlistId)
        }()
        if shouldWarn {
            pendingPresentation = pkg
        } else {
            // A new stream always opens fullscreen, even if a mini player was showing.
            // Overlay hosts pass pkg.id as an environment revision while preserving the
            // PlayerView/VideoPlayerController identity (required for AirPlay continuity).
            mode = .fullscreen
            presentation = pkg
        }
    }

    func confirmPending() {
        guard let pending = pendingPresentation else { return }
        pendingPresentation = nil
        mode = .fullscreen
        presentation = pending
    }

    func cancelPending() {
        pendingPresentation = nil
    }

    func dismiss(animated _: Bool = true) {
        let callback = presentation?.onDismiss
        // Keep `mode` as-is through removal so the exit transition matches the current mode
        // (a mini card fades, a fullscreen player slides down). `mode` is reset by the next
        // `present()` / `confirmPending()`, before any new content is shown.
        presentation = nil
        callback?()
    }

    /// Shrink the active player into the floating mini card (no teardown).
    @MainActor
    func minimize() {
        guard presentation != nil else { return }
        mode = .mini
    }

    /// Grow the mini card back to fullscreen.
    @MainActor
    func expand() {
        guard presentation != nil else { return }
        mode = .fullscreen
    }
}

/// Build 64 (A3-i): presents the download-warning choice for a
/// PARKED presentation (`pendingPresentation`) on the TOPMOST
/// view controller, whatever currently covers the dashboard.
///
/// Why UIKit: the SwiftUI `.alert` that used to release a parked
/// presentation was hosted in DashboardView — UNDER any sheet.
/// The owner's route to the build-63 episode failure was Home →
/// Search SHEET → episode tap: the presentation parked, the
/// alert existed but was invisible beneath the sheet, and the
/// tap did literally nothing. A UIKit alert presented from the
/// topmost controller always lands in the visible hierarchy —
/// episodes, movies and live alike.
@MainActor
enum DownloadWarningPresenter {
    private static weak var presentedAlert: UIAlertController?

    /// Shows the warning when a presentation is parked. Safe to
    /// call repeatedly (e.g. from `onChange`): it no-ops while an
    /// alert is already up or nothing is parked.
    static func presentIfNeeded(
        controller: PlayerOverlayController,
        onGoToDownloads: (() -> Void)? = nil
    ) {
        guard controller.pendingPresentation != nil else { return }
        guard presentedAlert == nil else { return }
        guard let host = topmostViewController() else { return }

        let alert = UIAlertController(
            title: L("download.player_warning.title"),
            message: L("download.player_warning.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel) { _ in
            controller.cancelPending()
        })
        if let onGoToDownloads {
            alert.addAction(UIAlertAction(title: L("download.player_warning.go_to_downloads"), style: .default) { _ in
                controller.cancelPending()
                // Let the alert finish dismissing, then close the
                // covering sheet (if the host was itself presented)
                // so the dashboard's downloads sheet can present.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if host.presentingViewController != nil {
                        host.dismiss(animated: true) { onGoToDownloads() }
                    } else {
                        onGoToDownloads()
                    }
                }
            })
        }
        alert.addAction(UIAlertAction(title: L("download.player_warning.continue"), style: .default) { _ in
            controller.confirmPending()
        })
        presentedAlert = alert
        host.present(alert, animated: true)
    }

    private static func topmostViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

private struct PlayerOverlayDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct PlayerOverlayModeKey: EnvironmentKey {
    static let defaultValue: PlayerOverlayMode = .fullscreen
}

private struct PlayerOverlayPresentationIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

private struct PlayerOverlayMinimizeKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct PlayerOverlayExpandKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// In overlay mode, `PlayerView` closing; otherwise `dismiss()` is used.
    var playerOverlayDismiss: (() -> Void)? {
        get { self[PlayerOverlayDismissKey.self] }
        set { self[PlayerOverlayDismissKey.self] = newValue }
    }

    /// Current fullscreen/mini mode of the overlay-hosted player.
    var playerOverlayMode: PlayerOverlayMode {
        get { self[PlayerOverlayModeKey.self] }
        set { self[PlayerOverlayModeKey.self] = newValue }
    }

    /// Changes whenever the overlay receives a newly selected playback item.
    /// PlayerView observes this explicit revision while keeping its StateObject
    /// (and therefore an active AirPlay AVPlayer) alive across content changes.
    var playerOverlayPresentationID: UUID? {
        get { self[PlayerOverlayPresentationIDKey.self] }
        set { self[PlayerOverlayPresentationIDKey.self] = newValue }
    }

    /// Request shrinking the player to the mini card. `nil` when not overlay-hosted.
    var playerOverlayMinimize: (() -> Void)? {
        get { self[PlayerOverlayMinimizeKey.self] }
        set { self[PlayerOverlayMinimizeKey.self] = newValue }
    }

    /// Request growing the mini card back to fullscreen. `nil` when not overlay-hosted.
    var playerOverlayExpand: (() -> Void)? {
        get { self[PlayerOverlayExpandKey.self] }
        set { self[PlayerOverlayExpandKey.self] = newValue }
    }
}
