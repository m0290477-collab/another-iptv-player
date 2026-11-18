import Combine
import SwiftUI

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
    @Published var presentation: PlayerOverlayPresentation?
    /// The pending presentation held for the confirmation alert shown while there is an active download.
    @Published var pendingPresentation: PlayerOverlayPresentation?
    /// Fullscreen vs. floating mini player. Reset to `.fullscreen` on every new presentation.
    @Published var mode: PlayerOverlayMode = .fullscreen

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
