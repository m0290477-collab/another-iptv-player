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

/// Round 12 (point 9): set when the expiry gate blocks a playback
/// presentation; the dashboard hosts present the expired state.
struct ExpiredPlaybackNotice: Identifiable {
    let id = UUID()
    let playlistId: UUID
    let expiryDate: Date
}

final class PlayerOverlayController: ObservableObject {
    @Published var presentation: PlayerOverlayPresentation?
    /// The pending presentation held for the confirmation alert shown while there is an active download.
    @Published var pendingPresentation: PlayerOverlayPresentation?
    /// Fullscreen vs. floating mini player. Reset to `.fullscreen` on every new presentation.
    @Published var mode: PlayerOverlayMode = .fullscreen
    /// Round 12 (point 9): the provider-expiry gate's blocked notice.
    /// EVERY playback presentation in the app routes through
    /// `present(...)` below, so this single check covers all entry
    /// points (Home, Live, Movies, Series, EPG, favorites, history,
    /// downloads). Browsing is never gated — only playback.
    @Published var expiredNotice: ExpiredPlaybackNotice?

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
        // Round 12 (point 9): provider-expiry gate — checked FIRST,
        // before the download warning, and independent of
        // `skipDownloadCheck` (local downloads of an expired
        // playlist's content are blocked too, per the owner's
        // "ALL content playback stops" order). The expiry day
        // itself still plays; blocking starts the next day
        // (see ProviderExpiryStore). No recorded expiry = no block.
        // M3U presentations carry no playlistId (or no expiry
        // record) and are never blocked.
        if let playlistId,
           let expired = ProviderExpiryStore.blockedExpiry(playlistId: playlistId) {
            expiredNotice = ExpiredPlaybackNotice(playlistId: playlistId, expiryDate: expired)
            return
        }
        let pkg = PlayerOverlayPresentation(root: AnyView(content()), onDismiss: onDismiss)
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
