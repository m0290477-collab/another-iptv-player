import AVKit
import Combine
import SwiftUI
import GRDB
import UIKit
import os

struct LiveChannelCategorySection: Identifiable, Equatable {
    let id: String
    let title: String
    let streams: [DBLiveStream]
}

extension LiveChannelCategorySection {
    /// Full live queue + per-category sections for the current Xtream playlist.
    /// Players opened outside the main channel list (EPG guide, programme sheet)
    /// use this so prev/next channel and the channel side panel keep working instead
    /// of being disabled by a single-item queue.
    @MainActor
    static func xtreamLiveQueue() -> (queue: [DBLiveStream], sections: [LiveChannelCategorySection]) {
        let store = PlaylistContentStore.shared
        let sections = store.liveCategories.compactMap { cat -> LiveChannelCategorySection? in
            let streams = store.liveStreamsByCategoryId[cat.id]?.map(\.stream) ?? []
            guard !streams.isEmpty else { return nil }
            return LiveChannelCategorySection(id: cat.id, title: cat.name, streams: streams)
        }
        return (sections.flatMap(\.streams), sections)
    }
}

/// It is a lightweight display model so the channel panel can work with different sources such as an Xtream `DBLiveStream` or an M3U `DBM3UChannel`.
/// Taps give the item's `id` to the callback; looking it up / selecting the stream
/// is the caller's responsibility.
struct ChannelPanelItem: Identifiable, Equatable {
    let id: String
    let name: String
    let iconURL: URL?
}

struct ChannelPanelSection: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [ChannelPanelItem]
}

/// After the channel browser closes, it recreates the inner body with `.id` to refresh the main mpv/UIKit bridge.
struct PlayerView: View {
    let url: URL
    let title: String
    var subtitle: String? = nil
    var artworkURL: URL? = nil
    var isLiveStream: Bool = false

    let playlistId: UUID
    let streamId: String
    let type: String
    var seriesId: String? = nil
    var resumeTimeMs: Int? = nil
    var containerExtension: String? = nil
    /// M3U per-channel User-Agent (#EXTVLCOPT / #KODIPROP); passed to the engine at load.
    var userAgent: String? = nil
    /// EPG lookup key for the live channel; drives the in-player now-playing strip.
    var epgChannelKey: String? = nil
    /// Catch-up playback must not write watch history (would overwrite the live row).
    var suppressWatchHistory: Bool = false

    var canGoToPreviousEpisode: Bool = false
    var canGoToNextEpisode: Bool = false
    var onPreviousEpisode: (() -> Void)? = nil
    var onNextEpisode: (() -> Void)? = nil
    /// Round 15 (C8): the NEXT episode's season/episode numbers,
    /// shown on the T-50 next-episode card when the caller knows
    /// them (nil = the line is omitted, never invented).
    var nextEpisodeSeason: Int? = nil
    var nextEpisodeEpisode: Int? = nil
    var canGoToPreviousChannel: Bool = false
    var canGoToNextChannel: Bool = false
    var onPreviousChannel: (() -> Void)? = nil
    var onNextChannel: (() -> Void)? = nil
    var channelPanelSections: [ChannelPanelSection] = []
    var currentChannelPanelItemId: String? = nil
    var onSelectChannelPanelItem: ((String) -> Void)? = nil
    var isLiveChannelSidePanelVisible: Bool = false
    var onToggleLiveChannelSidePanel: (() -> Void)? = nil
    var onVideoSurfaceTap: (() -> Void)? = nil
    var onNavigateToDetail: ((String, String) -> Void)? = nil

    /// Favorite UI — shells may supply the state + toggle (the
    /// Live/M3U shells do). When both are nil, PlayerViewImpl
    /// derives the star from the same DBFavorite rows the detail
    /// screens write (round 16, F1) — the button is hidden only
    /// when no favorite identity can be derived either.
    var isFavorite: Bool? = nil
    var onToggleFavorite: (() -> Void)? = nil

    @State private var channelBrowserVolumeBackup: Double?

    var body: some View {
        PlayerViewImpl(
            url: url,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            isLiveStream: isLiveStream,
            playlistId: playlistId,
            streamId: streamId,
            type: type,
            seriesId: seriesId,
            resumeTimeMs: resumeTimeMs,
            containerExtension: containerExtension,
            userAgent: userAgent,
            epgChannelKey: epgChannelKey,
            suppressWatchHistory: suppressWatchHistory,
            isFavorite: isFavorite,
            onToggleFavorite: onToggleFavorite,
            canGoToPreviousEpisode: canGoToPreviousEpisode,
            canGoToNextEpisode: canGoToNextEpisode,
            onPreviousEpisode: onPreviousEpisode,
            onNextEpisode: onNextEpisode,
            nextEpisodeSeason: nextEpisodeSeason,
            nextEpisodeEpisode: nextEpisodeEpisode,
            canGoToPreviousChannel: canGoToPreviousChannel,
            canGoToNextChannel: canGoToNextChannel,
            onPreviousChannel: onPreviousChannel,
            onNextChannel: onNextChannel,
            channelPanelSections: channelPanelSections,
            currentChannelPanelItemId: currentChannelPanelItemId,
            onSelectChannelPanelItem: onSelectChannelPanelItem,
            isLiveChannelSidePanelVisible: isLiveChannelSidePanelVisible,
            onToggleLiveChannelSidePanel: onToggleLiveChannelSidePanel,
            onVideoSurfaceTap: onVideoSurfaceTap,
            onNavigateToDetail: onNavigateToDetail,
            volumeBackupDuringChannelBrowser: $channelBrowserVolumeBackup,
            onLiveChannelBrowserClosed: {}
        )
    }
}

private struct PlayerViewImpl: View {
    let url: URL
    let title: String
    var subtitle: String? = nil
    var artworkURL: URL? = nil
    var isLiveStream: Bool = false

    let playlistId: UUID
    let streamId: String
    let type: String
    var seriesId: String? = nil
    var resumeTimeMs: Int? = nil
    var containerExtension: String? = nil
    var userAgent: String? = nil
    var epgChannelKey: String? = nil
    var suppressWatchHistory: Bool = false
    /// Optional favorite button — shown in the quick-actions row
    /// when the shell sets both, or when a favorite identity can be
    /// derived from the playback itself (round 16, F1, below).
    var isFavorite: Bool? = nil
    var onToggleFavorite: (() -> Void)? = nil

    /// Round 16 (F1): state for the derived favorite path.
    @State private var derivedFavorite = false

    /// Previous / next episode in playlist order while playing a series (UI + Control Center).
    var canGoToPreviousEpisode: Bool = false
    var canGoToNextEpisode: Bool = false
    var onPreviousEpisode: (() -> Void)? = nil
    var onNextEpisode: (() -> Void)? = nil
    /// Round 15 (C8): next episode's season/episode numbers for
    /// the T-50 card's "Season N • Episode M" line.
    var nextEpisodeSeason: Int? = nil
    var nextEpisodeEpisode: Int? = nil
    var canGoToPreviousChannel: Bool = false
    var canGoToNextChannel: Bool = false
    var onPreviousChannel: (() -> Void)? = nil
    var onNextChannel: (() -> Void)? = nil
    var channelPanelSections: [ChannelPanelSection] = []
    var currentChannelPanelItemId: String? = nil
    var onSelectChannelPanelItem: ((String) -> Void)? = nil
    var isLiveChannelSidePanelVisible: Bool = false
    var onToggleLiveChannelSidePanel: (() -> Void)? = nil
    var onVideoSurfaceTap: (() -> Void)? = nil
    var onNavigateToDetail: ((String, String) -> Void)? = nil

    @Binding var volumeBackupDuringChannelBrowser: Double?
    var onLiveChannelBrowserClosed: () -> Void

    @StateObject private var player = VideoPlayerController()
    @StateObject private var systemVolumeBridge = SystemVolumeBridge()

    @Environment(\.dismiss) private var dismiss
    @Environment(\.playerOverlayDismiss) private var playerOverlayDismiss
    @Environment(\.playerOverlayMode) private var overlayMode
    @Environment(\.playerOverlayPresentationID) private var overlayPresentationID
    @Environment(\.playerOverlayMinimize) private var playerOverlayMinimize
    @Environment(\.playerOverlayExpand) private var playerOverlayExpand
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.epgSnapshot) private var epgSnapshot

    /// Current programme for the live channel, if EPG data is available.
    private var currentNowNext: EPGNowNext? {
        guard isLiveStream, let key = epgChannelKey else { return nil }
        return epgSnapshot?[key]
    }

    @State private var showControls = true
    /// Round 19 (R19-1a): controls lock (STRONG top-bar lock icon) —
    /// while locked every chrome control is hidden and inert; only
    /// the standalone unlock button remains on screen.
    @State private var controlsLocked = false
    @State private var timer: Timer?
    @State private var saveHistoryTimer: Timer?
    @State private var hasInitialSeeked = false
    @AppStorage("player.videoAspectMode") private var videoAspectModeRaw = VideoAspectMode.fit.rawValue
    @AppStorage("player.pipEnabled") private var pipEnabled = true
    @AppStorage("player.continuePlayingInBackground") private var continuePlayingInBackground = true
    @AppStorage("player.speedUpOnLongPress") private var speedUpOnLongPress = true
    @AppStorage("player.autoPlayNextEpisode") private var autoPlayNextEpisode = true
    // Round 11: the Player settings group is wired for real here —
    // the Skip Intro visibility + jump length, and the default
    // sleep timer armed on open. Round 14 (A4): the old post-end
    // "Next-episode timer" AppStorage is GONE from the player —
    // the T-50 card (below) replaces that behavior entirely; the
    // Auto-Play Next Episode toggle above remains the master switch.
    @AppStorage("player.showSkipIntro") private var showSkipIntro = true
    @AppStorage("player.skipIntroLengthSeconds") private var skipIntroLengthSeconds = 85
    @AppStorage("player.defaultSleepTimerMinutes") private var defaultSleepTimerMinutes = 0
    @State private var didApplyDefaultSleepTimer = false

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var lockedSliderValue: Double?
    @State private var sliderUnlockGeneration = 0
    @State private var showTrackSettings = false
    /// Round 8: which section the track sheet opens scrolled to
    /// (Audio / Subtitles quick-action buttons deep-link into it).
    @State private var trackSheetFocus: PlaybackTrackSettingsSheet.SectionFocus = .all
    /// Round 8: REAL sleep timer — the chosen minutes while armed, and
    /// the one-shot Timer that pauses playback when they elapse.
    /// Nothing is persisted: leaving the player disarms it, and the
    /// only effect it ever has is pausing this playback.
    @State private var sleepTimerMinutes: Int?
    /// Round 14 (B1): when the armed sleep timer fires — the Sleep
    /// button's caption shows the REMAINING minutes, computed from
    /// this date (refreshed by a TimelineView in the button).
    @State private var sleepTimerEndsAt: Date?
    @State private var sleepCountdownTimer: Timer?
    @State private var isFastForwarding = false
    /// The surface's manual-PiP trigger input. Round 9 removed the
    /// capsule's PiP button; round 14 (B1) restores manual PiP as a
    /// button in the ONE quick-actions row, which increments this.
    @State private var pipManualSignal = 0
    /// Original AirPlay flow state (restored round 18): the remux
    /// preparation spinner and the hidden route-picker trigger the
    /// pre-restyle top capsule used.
    @State private var isPreparingAirPlay = false
    @State private var airPlayPickerSignal = 0
    @State private var aspectToastText: String?
    @State private var aspectToastToken: UInt64 = 0

    /// Round 14 (A4): the T-50 next-episode card state. The card is
    /// COMPUTED from the live position (see
    /// `nextEpisodeRemainingSeconds`); these flags carry only what
    /// the position can't say: Cancel was pressed for this ending
    /// (re-arms when the user seeks back out of the 50 s zone), and
    /// an auto-advance is in flight (so the identity change it
    /// causes isn't mistaken for a manual episode switch).
    @State private var nextEpisodeCardDismissed = false
    @State private var autoAdvanceInFlight = false
    /// Round 15 (C8): "Still watching?" — consecutive auto-advances
    /// with zero user interaction. At 3, the next card shows but
    /// does NOT auto-play at 0; it waits for an explicit tap. Any
    /// user interaction (everything funnels through `resetTimer`)
    /// resets the counter. Local state only, never persisted.
    @State private var consecutiveAutoAdvances = 0
    @State private var stillWatchingHold = false
    /// Round 14 (A2): the failure message the user already closed
    /// the failure card for — a NEW failure (different message)
    /// re-shows the card.
    @State private var dismissedFailureMessage: String?
    /// Round 14 (B12): the ±10 s double-tap seek indicator
    /// (direction + token so a stale clear can't hide a fresh one).
    @State private var skipIndicatorDirection: Int?
    @State private var skipIndicatorToken: UInt64 = 0
    /// Round 14 (B3): last channel-zap time — the pull-down
    /// dismiss gesture stays out of a zap swipe's way briefly.
    @State private var lastZapAt: Date?
    // NOTE (round 15, owner phone-first order 2026-11-16 04:28 PT):
    // iPad keyboard shortcuts from C1 are DEFERRED to the later
    // iPad round — not implemented in this build.
    /// Round 15 (C10): last EPG fullscreen-stamp heartbeat write.
    @State private var lastEPGStampAt: Date = .distantPast

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fullscreen cover: back from the edge (pop) and pull-down-to-close.
    private enum InteractiveDismissAxis {
        case edgeBack
        case pullDown
    }

    @State private var interactiveDismissAxis: InteractiveDismissAxis?
    @State private var interactiveDismissOffset: CGSize = .zero

    /// Mini player morph state. `miniProgress` drives the whole full↔mini transform
    /// (0 = fullscreen, 1 = docked mini card). `miniCorner` is the docked corner; the live
    /// drag translation lives in `cardDrag` (isolated so it doesn't re-render the body).
    @State private var miniProgress: CGFloat = 0
    @State private var miniCorner: MiniPlayerCorner = .bottomTrailing
    /// Live docked-card drag translation. Held via `@State` so the body does NOT observe it —
    /// only `MiniCardDragLayer` does — keeping the drag from re-rendering the video subtree.
    @State private var cardDrag = MiniCardDragModel()
    /// Invalidates a pending "reveal chrome after expand" if the mode changes again first.
    @State private var expandControlsGeneration = 0

    private var isMiniCommitted: Bool { overlayMode == .mini }

    /// Two-finger pinch: 1x–4x; when zoomed in, the frame can be shifted by dragging with one finger.
    /// Pinch & pan are on the UIKit side (`PlayerMediaKitTouchContainerView`); because the coordinate system
    /// is not bound to the scaled view, dragging is reliable. For the pinch midpoint anchor, the
    /// `pinchAnchorState` below is used.
    @State private var videoPinchBase: CGFloat = 1
    /// Live-only pinch/pan values, isolated in an ObservableObject like `cardDrag` so
    /// per-frame gesture updates re-render only `VideoZoomPanLayer`, not this whole body.
    @State private var videoZoomPan = VideoZoomPanModel()
    @State private var videoPanCommitted: CGSize = .zero
    /// The fitted (aspect-ratio) layout size of the surface — its rendered size is this
    /// times `effectiveVideoScale`.
    @State private var videoViewportSize: CGSize = .zero
    /// The full container (screen) size the surface is centered in. Pan bounds are the
    /// overflow of the rendered surface past this, so panning never exposes the background.
    @State private var videoContainerSize: CGSize = .zero
    @State private var videoAspectFillScale: CGFloat = 1
    @State private var pinchAnchorState: PinchAnchorState?

    /// Per-window pixel density; used for the 1:1 (`.center`) mapping. `UIScreen.main.scale`
    /// is wrong on external displays / multi-window and can collapse the surface to 1×1.
    @Environment(\.displayScale) private var displayScale

    /// The snapshot taken when the pinch starts: all the constant values needed for the offset calculation
    /// to do the zoom from the pinch midpoint.
    private struct PinchAnchorState: Equatable {
        let screenMidpoint: CGPoint  // UIKit container (= playerChrome) coordinates
        let containerCenter: CGPoint
        let startScale: CGFloat
        let startPanCommitted: CGSize
    }

    /// Live pinch/pan values only; mutating `@Published` here does not re-render
    /// `PlayerViewImpl.body` (held via plain `@State`, not `@StateObject`) — only
    /// `VideoZoomPanLayer` below, which observes it via `@ObservedObject`, does. Mirrors
    /// `MiniCardDragModel` in MiniPlayerSupport.swift for the same reason.
    private final class VideoZoomPanModel: ObservableObject {
        @Published var pinchLive: CGFloat = 1
        @Published var panLive: CGSize = .zero
    }

    /// Applies the live pinch/pan transform to the video surface. Observing `model`
    /// directly keeps per-frame gesture updates from re-rendering the whole chrome —
    /// only this layer re-evaluates while zooming/panning.
    private struct VideoZoomPanLayer<Content: View>: View {
        @ObservedObject var model: VideoZoomPanModel
        let pinchBase: CGFloat
        let zoomMax: CGFloat
        let panCommitted: CGSize
        let aspectFillScale: CGFloat
        let viewportSize: CGSize
        let containerSize: CGSize
        let pinchAnchor: PinchAnchorState?
        @ViewBuilder var content: Content

        private var zoomScale: CGFloat {
            min(max(pinchBase * model.pinchLive, 1), zoomMax)
        }

        // Round 18 (R18-2): the original arrangement — the `.fill`
        // cover factor is a transform on the fitted-size layer, as
        // in the pre-restyle player (round 10's render-size layout
        // is reverted with the rest of the display restore).
        private var effectiveScale: CGFloat {
            aspectFillScale * zoomScale
        }

        private var panBounds: CGSize {
            CGSize(
                width: max(0, (viewportSize.width * effectiveScale - containerSize.width) / 2),
                height: max(0, (viewportSize.height * effectiveScale - containerSize.height) / 2)
            )
        }

        private var pinchZoomOffset: CGSize {
            guard let s = pinchAnchor else { return .zero }
            let M = s.screenMidpoint
            let C = s.containerCenter
            let S0 = s.startScale
            let O0 = s.startPanCommitted
            let Px = (M.x - C.x - O0.width) / S0
            let Py = (M.y - C.y - O0.height) / S0
            let S = effectiveScale
            let Ox = M.x - C.x - S * Px
            let Oy = M.y - C.y - S * Py
            return CGSize(width: Ox - O0.width, height: Oy - O0.height)
        }

        private var effectiveOffset: CGSize {
            let rawX = panCommitted.width + model.panLive.width + pinchZoomOffset.width
            let rawY = panCommitted.height + model.panLive.height + pinchZoomOffset.height
            let maxX = panBounds.width
            let maxY = panBounds.height
            return CGSize(
                width: min(max(rawX, -maxX), maxX),
                height: min(max(rawY, -maxY), maxY)
            )
        }

        var body: some View {
            content
                .scaleEffect(effectiveScale, anchor: .center)
                .offset(effectiveOffset)
        }
    }

    /// The last loaded content; when `streamId`/URL changes, history is first saved with this (the new struct's fields may not have updated yet).
    @State private var historySaveTags: WatchHistoryTags?
    @State private var appliedPlaybackIdentity: String?
    /// The subtitle `update()` does a binary search + equality check, but still, every 120ms
    /// triggering it is a load as small as an onChange closure. The 200ms window is imperceptible.

    // Round 16 (R9): logger fallback names this app's own bundle id
    // (was the upstream project's name; never executes in the
    // shipped app, where the bundle identifier is always present).
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.irqus.superx", category: "Playback")

    private let videoZoomMax: CGFloat = 4

    private var videoZoomScale: CGFloat {
        min(max(videoPinchBase * videoZoomPan.pinchLive, 1), videoZoomMax)
    }

    /// The true on-screen render scale of the video: the user pinch-zoom multiplied by the
    /// `.fill` cover scale. All pan-clamp / pinch-anchor math uses this so bounds are correct
    /// whether the extra scale came from a pinch or from fill-mode cropping.
    /// (Build-33 form, restored in round 20: round 10's render-frame
    /// semantics — zoom only — were an incomplete round-18 revert
    /// remnant and disagreed with the zoom layer's transform.)
    private var effectiveVideoScale: CGFloat {
        videoAspectFillScale * videoZoomScale
    }

    /// Max pan offset on each axis: half the amount the rendered surface (fitted × effective
    /// scale) overflows the container. Zero when the content fits, so panning never reveals
    /// the black background — correct for both pinch-zoom and `.fill` cropping. Using the
    /// container (not the fitted size) as the reference is what keeps Fill from over-panning.
    private var videoPanBounds: CGSize {
        CGSize(
            width: max(0, (videoViewportSize.width * effectiveVideoScale - videoContainerSize.width) / 2),
            height: max(0, (videoViewportSize.height * effectiveVideoScale - videoContainerSize.height) / 2)
        )
    }

    /// It only clamps the committed + live pan to the valid range. `VideoZoomPanLayer.effectiveOffset` [clamps] all
    /// components clamp in a unified way, it is not used during the gesture; at pinch end,
    /// it uses `commitVideoPanClamp` to clamp the committed pan again.
    private var videoPanClamped: CGSize {
        let maxX = videoPanBounds.width
        let maxY = videoPanBounds.height
        let raw = CGSize(
            width: videoPanCommitted.width + videoZoomPan.panLive.width,
            height: videoPanCommitted.height + videoZoomPan.panLive.height
        )
        return CGSize(
            width: min(max(raw.width, -maxX), maxX),
            height: min(max(raw.height, -maxY), maxY)
        )
    }

    /// Pinch anchor compensating offset (to zoom from the pinch midpoint).
    /// Because the scale is from the center, it returns the delta to fix the point that should stay
    /// under the finger. At pinch end, the value is baked into `videoPanCommitted` and this function returns zero.
    private var videoPinchZoomOffset: CGSize {
        guard let s = pinchAnchorState else { return .zero }
        let M = s.screenMidpoint
        let C = s.containerCenter
        let S0 = s.startScale
        let O0 = s.startPanCommitted
        // The content point at the start of the pinch (relative to the center, unscaled):
        let Px = (M.x - C.x - O0.width) / S0
        let Py = (M.y - C.y - O0.height) / S0
        // The absolute offset needed to keep the point at the same screen position at the new scale:
        let S = effectiveVideoScale
        let Ox = M.x - C.x - S * Px
        let Oy = M.y - C.y - S * Py
        // The delta relative to the `videoPanCommitted` start value:
        return CGSize(width: Ox - O0.width, height: Oy - O0.height)
    }

    private var playbackPresentationKey: String {
        [title, subtitle ?? "", artworkURL?.absoluteString ?? "", isLiveStream ? "1" : "0"]
            .joined(separator: "\u{1e}")
    }

    private var showSeriesEpisodeSkip: Bool {
        type == "series" && (onPreviousEpisode != nil || onNextEpisode != nil)
    }

    private var showLiveChannelSkip: Bool {
        isLiveStream && (onPreviousChannel != nil || onNextChannel != nil)
    }

    private var showLiveChannelListButton: Bool {
        isLiveStream && !channelPanelSections.isEmpty && onToggleLiveChannelSidePanel != nil
    }

    private var showVODQueueSkip: Bool {
        !isLiveStream && type == "vod" && (onPreviousChannel != nil || onNextChannel != nil)
    }

    /// Round 17 (R17-3): channel (live) / queue-item (VOD) prev/
    private var hasPlaybackFailure: Bool {
        !(player.playbackFailureMessage ?? "").isEmpty
    }

    /// Waiting indicator on the center button: even if mpv is `pause=no`, until the real pipeline (`FILE_LOADED` / `PLAYBACK_RESTART`) arrives.
    /// At the end, `END_FILE` resets the setup flag; in that case it shows play-again, not loading.
    private var isCenterTransportLoading: Bool {
        if hasPlaybackFailure { return false }
        if player.state == .ended { return false }
        if player.isCastPresenting {
            // The phone engine is intentionally stopped throughout a remux cast;
            // consulting it would leave the spinner visible forever even while
            // the TV is playing. CastController is the active presentation source.
            if player.state == .buffering { return true }
            return player.castController?.isPlaybackEstablished != true
        }
        // Native AVPlayer external playback can report its phone-side layer as
        // buffering/not-established even though the Apple TV is already playing.
        // Once video external playback is active, that local layer must not drive
        // an endless spinner on the handset.
        if player.isAirPlayPlaybackActive { return false }
        if !player.engine.isReady { return true }
        if !player.engine.isPlaybackEstablished {
            // Round 18 (R18-1): before establishment, the loading
            // state ends the moment frames actually render
            // (`hasRenderedFirstFrame`) — `isSecondOpen` puts
            // picture on screen before `readyToPlay`, and keying
            // on establishment alone left the spinner drawn over
            // playing video. After establishment the buffering
            // state below drives the stall spinner as before.
            return !player.engine.hasRenderedFirstFrame
        }
        if player.state == .buffering { return true }
        return false
    }

    private var seriesRemoteCommandsKey: String {
        "\(streamId)|\(type)|\(canGoToPreviousEpisode ? "1" : "0")|\(canGoToNextEpisode ? "1" : "0")|\(onPreviousEpisode != nil)|\(onNextEpisode != nil)|\(canGoToPreviousChannel ? "1" : "0")|\(canGoToNextChannel ? "1" : "0")"
    }

    private var selectedAspectMode: VideoAspectMode {
        VideoAspectMode(rawValue: videoAspectModeRaw) ?? .fit
    }

    private var nextAspectMode: VideoAspectMode {
        let all = VideoAspectMode.allCases
        guard let idx = all.firstIndex(of: selectedAspectMode) else { return .fit }
        return all[(idx + 1) % all.count]
    }

    private var sourceVideoAspectRatio: CGFloat {
        let w = CGFloat(player.videoWidth)
        let h = CGFloat(player.videoHeight)
        guard w > 0, h > 0 else { return 16.0 / 9.0 }
        return w / h
    }

    /// The layout frame the video surface is given, at the source's natural aspect ratio.
    /// `.fit` and `.fill` both use this; `.fill` additionally applies `aspectFillScale` to
    /// the surface transform to cover the screen and crops the overflow.
    private func fittedVideoSize(in viewport: CGSize) -> CGSize {
        let vw = max(viewport.width, 0)
        let vh = max(viewport.height, 0)
        guard vw > 0, vh > 0 else { return .zero }
        if selectedAspectMode == .center, player.videoWidth > 0, player.videoHeight > 0 {
            // 1:1 pixel mapping; downscale only if the native size doesn't fit.
            let scale = max(displayScale, 1)
            let sourceWPoints = max(CGFloat(player.videoWidth) / scale, 1)
            let sourceHPoints = max(CGFloat(player.videoHeight) / scale, 1)
            let fit = min(vw / sourceWPoints, vh / sourceHPoints, 1)
            return CGSize(width: sourceWPoints * fit, height: sourceHPoints * fit)
        }
        // fit / fill (and center before real dimensions arrive): aspect-fit the source ratio.
        return aspectFittedSize(ratio: sourceVideoAspectRatio, in: CGSize(width: vw, height: vh))
    }

    /// Largest box of `ratio` that fits inside `viewport` (letterbox/pillarbox).
    private func aspectFittedSize(ratio: CGFloat, in viewport: CGSize) -> CGSize {
        let r = max(ratio, 0.01)
        if viewport.width / viewport.height > r {
            return CGSize(width: viewport.height * r, height: viewport.height)
        }
        return CGSize(width: viewport.width, height: viewport.width / r)
    }

    /// Cover scale for `.fill`: multiplies the fitted frame up until it covers the whole
    /// viewport (one axis matches, the other overflows and is clipped). 1 in fit/center.
    private func aspectFillScale(viewport: CGSize, fitted: CGSize) -> CGFloat {
        guard selectedAspectMode == .fill, fitted.width > 0, fitted.height > 0 else { return 1 }
        return max(viewport.width / fitted.width, viewport.height / fitted.height)
    }

    /// Recognizes a switch to another video in the same `PlayerView` instance (`onAppear` only runs on first open).
    private var playbackIdentity: String {
        "\(streamId)\u{1e}\(url.absoluteString)"
    }

    private var displayedSliderPosition: Double {
        if isScrubbing { return scrubValue }
        if let locked = lockedSliderValue { return locked }
        let p = player.position
        guard p.isFinite else { return 0 }
        return Double(min(max(p, 0), 1))
    }

    private var effectiveSeekable: Bool {
        !isLiveStream && player.isSeekable
    }

    // Round 16 (R6): the nine playbackDebug*Text properties that
    // fed the dead debug overlay are removed with it, along with
    // the bitrate sampler that only the overlay read.

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { displayedSliderPosition },
            set: { newVal in if isScrubbing { scrubValue = newVal } }
        )
    }

    // MARK: - Round 16 (F1): derived favorite state

    /// The DBFavorite key for the derived path; nil when this
    /// playback has no DBFavorite identity. Series favorites key on
    /// the SERIES id (the same row SeriesView's own favorite button
    /// writes), movies/live on the stream id + type. M3U playback
    /// never lands here — its shell supplies M3UFavoriteStore state.
    private var derivedFavoriteKey: (streamId: Int, type: String)? {
        if type == "series" {
            guard let seriesId, let id = Int(seriesId) else { return nil }
            return (id, "series")
        }
        if type == "vod" || type == "live" {
            guard let id = Int(streamId) else { return nil }
            return (id, type)
        }
        return nil
    }

    private var usesDerivedFavorite: Bool {
        isFavorite == nil && onToggleFavorite == nil && derivedFavoriteKey != nil
    }

    private var effectiveIsFavorite: Bool? {
        isFavorite ?? (usesDerivedFavorite ? derivedFavorite : nil)
    }

    private var effectiveOnToggleFavorite: (() -> Void)? {
        onToggleFavorite ?? (usesDerivedFavorite ? { toggleDerivedFavorite() } : nil)
    }

    private var derivedFavoriteTaskID: String {
        guard usesDerivedFavorite, let key = derivedFavoriteKey else { return "none" }
        return "\(playlistId.uuidString)-\(key.streamId)-\(key.type)"
    }

    private func refreshDerivedFavorite() async {
        guard usesDerivedFavorite, let key = derivedFavoriteKey else { return }
        let value = (try? await AppDatabase.shared.read { db in
            try DBFavorite
                .filter(Column("streamId") == key.streamId
                    && Column("playlistId") == playlistId
                    && Column("type") == key.type)
                .fetchCount(db) > 0
        }) ?? false
        // A zap / episode hop may have replaced the item mid-read.
        if derivedFavoriteKey?.streamId == key.streamId, derivedFavoriteKey?.type == key.type {
            derivedFavorite = value
        }
    }

    private func toggleDerivedFavorite() {
        guard let key = derivedFavoriteKey else { return }
        let nextValue = !derivedFavorite
        derivedFavorite = nextValue
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    if nextValue {
                        try DBFavorite(
                            streamId: key.streamId, playlistId: playlistId, type: key.type
                        ).insert(db)
                    } else {
                        try DBFavorite
                            .filter(Column("streamId") == key.streamId
                                && Column("playlistId") == playlistId
                                && Column("type") == key.type)
                            .deleteAll(db)
                    }
                }
            } catch {
                derivedFavorite = !nextValue
            }
        }
    }

    private func performPlayerDismiss() {
        if let overlayDismiss = playerOverlayDismiss {
            overlayDismiss()
        } else {
            dismiss()
        }
    }

    var body: some View {
        GeometryReader { geo in
            let containerSize = geo.size
            let outerSafeAreaInsets = geo.safeAreaInsets
            let clampedProgress = min(max(miniProgress, 0), 1)
            let card = miniCardRect(container: containerSize, safeArea: outerSafeAreaInsets)
            let t = miniTransform(progress: clampedProgress, card: card, container: containerSize)
            ZStack {
                // The whole mini-card group is repositioned by the live drag inside
                // `MiniCardDragLayer`, which is the ONLY view that re-renders while dragging —
                // the masked/scaled video below is evaluated once and merely re-offset, so the
                // picture is never re-processed (which used to glitch the video mid-drag).
                MiniCardDragLayer(model: cardDrag) {
                    ZStack {
                        // Card shadow, a cheap standalone rounded rect tracking the visible video
                        // card through the whole morph. The masked video layer never carries a
                        // shadow itself — re-shadowing that full-screen layer each frame as the
                        // mask animates caused judder/tremble. The opaque video lands on top of
                        // this fill; only the shadow spills out.
                        if clampedProgress > 0.01 {
                            let visibleCard = CGSize(width: t.maskSize.width * t.scale, height: t.maskSize.height * t.scale)
                            RoundedRectangle(
                                cornerRadius: MiniPlayerMetrics.cornerRadius * min(clampedProgress * 2.5, 1),
                                style: .continuous
                            )
                            .fill(Color.black)
                            .frame(width: visibleCard.width, height: visibleCard.height)
                            .shadow(color: .black.opacity(0.38 * Double(clampedProgress)),
                                    radius: 22 * clampedProgress, x: 0, y: 8 * clampedProgress)
                            .position(
                                x: containerSize.width / 2 + t.offset.width + interactiveDismissOffset.width,
                                y: containerSize.height / 2 + t.offset.height + interactiveDismissOffset.height
                            )
                            .allowsHitTesting(false)
                        }

                        // Player content, transformed toward the floating mini card as
                        // `miniProgress` grows. The mask crops the letterbox down to the card;
                        // scale/offset land the video on the card center. View identity is stable
                        // so playback never restarts.
                        ZStack {
                            Color.black
                                .ignoresSafeArea()

                            playerChromeAndVideo(outerSafeAreaInsets: outerSafeAreaInsets)
                        }
                        .background(Color.black)
                        .frame(width: containerSize.width, height: containerSize.height)
                        .mask(
                            RoundedRectangle(cornerRadius: t.cornerRadius, style: .continuous)
                                .frame(width: t.maskSize.width, height: t.maskSize.height)
                        )
                        .scaleEffect(t.scale)
                        .offset(
                            x: t.offset.width + interactiveDismissOffset.width,
                            y: t.offset.height + interactiveDismissOffset.height
                        )
                        .opacity(edgeBackOpacity(containerSize: containerSize))
                        .simultaneousGesture(
                            interactiveDismissDragGesture(
                                containerSize: containerSize,
                                safeAreaTop: geo.safeAreaInsets.top,
                                safeAreaBottom: geo.safeAreaInsets.bottom
                            )
                        )
                        // Once docked, stop the (visually card-sized but layout-full-screen)
                        // content from swallowing touches: SwiftUI `.mask` crops rendering only,
                        // not the hit region. `isMiniCommitted` only flips at commit, so the
                        // interactive pull-down morph is unaffected; card taps go to the chrome.
                        .allowsHitTesting(!isMiniCommitted)

                        // Floating mini card chrome (unscaled), tappable only once docked.
                        if clampedProgress > 0.01 {
                            MiniPlayerChrome(
                                player: player,
                                cornerRadius: MiniPlayerMetrics.cornerRadius,
                                isLoading: isCenterTransportLoading,
                                onExpand: { playerOverlayExpand?() },
                                onClose: { performPlayerDismiss() },
                                onDragChanged: { translation in
                                    handleMiniCardDragChanged(
                                        translation: translation,
                                        card: card, container: containerSize
                                    )
                                },
                                onDragEnded: { translation, velocity in
                                    handleMiniCardDragEnded(
                                        translation: translation, velocity: velocity,
                                        container: containerSize, safeArea: outerSafeAreaInsets
                                    )
                                }
                            )
                            .frame(width: card.width, height: card.height)
                            .position(x: card.midX, y: card.midY)
                            .opacity(miniChromeOpacity)
                            .allowsHitTesting(isMiniCommitted)
                        }
                    }
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
            // Round 15 (C12): exit parallax — during the edge-back
            // dismiss drag the whole player surface scales down a
            // touch (≤5%) as it fades, so the exit feels layered
            // instead of a flat slide. Transform only; Reduce
            // Motion pins it to 1.
            .scaleEffect(exitParallaxScale)
            // On iPad / wide landscape layouts, toggling the status bar with the controls changes the top safe area;
            // the GeometryReader height jumps. On the phone (compact) the old behavior is preserved.
            // On the mini card, the status bar is always visible.
            .statusBarHidden(statusBarHiddenInCurrentMode)
        // Round 16 (F1): keep the derived favorite star in sync
        // with the current playback identity — channel zaps and
        // episode hops re-read the DBFavorite row for the new item.
        .task(id: derivedFavoriteTaskID) {
            await refreshDerivedFavorite()
        }
        .onAppear {
            log.info("Opening player: \(title, privacy: .public)")
            // Round 9: landscape is allowed ONLY inside the fullscreen
            // player (see AppDelegate.browseOrientationLock).
            syncOrientationLockForPlayerMode()
            // Round 15 (C10): opening fullscreen starts the EPG
            // tick-lengthening stamp (heartbeat in the timeMs
            // handler keeps it fresh; mini/disappear clear it).
            if overlayMode == .fullscreen {
                lastEPGStampAt = Date()
                UserDefaults.standard.set(
                    Date().timeIntervalSince1970,
                    forKey: EPGStore.fullscreenPlaybackStampKey
                )
            }
            resetTimer()
            player.setupAudioHandler()
            // Defer to the next run loop: the KSPlayer surface's view setup and
            // `play` can race within the same tick. First layout also relieves the main queue.
            DispatchQueue.main.async {
                applyPlaybackTransitionIfNeeded()
                applySelectedAspectMode(force: true)
                applyDefaultSleepTimerIfNeeded()
                applySeriesEpisodeRemoteCommands()
                if let v = volumeBackupDuringChannelBrowser {
                    player.setVolume(v)
                    volumeBackupDuringChannelBrowser = nil
                }
            }
        }
        .onChange(of: playbackIdentity) { _, _ in
            handlePlaybackIdentityChange()
            applyPlaybackTransitionIfNeeded()
        }
        .onChange(of: overlayPresentationID) { _, _ in
            // The overlay deliberately preserves PlayerView identity so an active
            // AirPlay AVPlayer survives a source switch. Observe the host's explicit
            // presentation revision as a reliable handoff trigger; the identity guard
            // inside applyPlaybackTransitionIfNeeded prevents duplicate loads.
            applyPlaybackTransitionIfNeeded()
        }
        .onChange(of: videoAspectModeRaw) { _, _ in
            applySelectedAspectMode()
            showAspectToast()
        }
        .onReceive(player.$position.removeDuplicates()) { newPos in
            guard newPos.isFinite else { return }
            if isScrubbing { return }
            if let locked = lockedSliderValue {
                if abs(Double(newPos) - locked) < 0.035 {
                    DispatchQueue.main.async {
                        lockedSliderValue = nil
                    }
                }
                return
            }
        }
        .onChange(of: playbackPresentationKey) { _, _ in
            player.setPlaybackPresentation(makePresentation())
        }
        .onChange(of: currentNowNext?.now?.id) { _, _ in
            player.setPlaybackPresentation(makePresentation())
        }
        .onDisappear {
            // Round 9: leaving the player restores the portrait browse
            // lock (with a forced rotation back when the phone is still
            // physically held in landscape — no leftover landscape UI).
            restoreBrowseOrientationLock()
            // Round 15 (C10): fullscreen playback is over — the EPG
            // tick returns to its normal minute cadence.
            UserDefaults.standard.set(0, forKey: EPGStore.fullscreenPlaybackStampKey)
            timer?.invalidate()
            saveHistoryTimer?.invalidate()
            sleepCountdownTimer?.invalidate()
            sleepCountdownTimer = nil
            // Save under the applied playback identity, not the (possibly newer)
            // incoming props — mirrors the timer path above.
            saveWatchHistory(tags: historySaveTags)
            player.teardown()
        }
        // Round 12 (point 2): the tracks panel is NO LONGER a
        // sheet — it renders as a compact floating overlay inside
        // `playerChromeAndVideo` (see `trackSettingsOverlay`), so
        // the video stays visible around it and a tap outside
        // dismisses it. The state + focus plumbing is unchanged.
        .onChange(of: showTrackSettings) { _, isOpen in
            if isOpen { resetInteractiveDismissTracking() }
        }
        // Round 19 (R19-1a): the subtitle-appearance sheet has NO
        // entry in the reference chrome (round 9 removed its "AA"
        // button; round 18's capsule presenter is superseded). The
        // sheet type and the saved appearance values remain in the
        // tree and still apply to subtitle rendering.
        .onChange(of: player.isSeekable) { _, _ in checkAndPerformResume() }
        .onChange(of: player.durationMs) { _, _ in checkAndPerformResume() }
        .onAppear { startSaveHistoryTimer(); migratePersistedAspectModeIfNeeded() }
        .onChange(of: seriesRemoteCommandsKey) { _, _ in
            applySeriesEpisodeRemoteCommands()
        }
        .onChange(of: player.state) { _, newState in
            // Round 14 (A4): the post-end countdown timer is GONE.
            // Reaching the end with the T-50 flow armed (card not
            // cancelled, no still-watching hold) advances at once —
            // the card's countdown WAS the last 50 seconds.
            if newState == .ended {
                handlePlaybackEnded()
            }
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            // Round 15 (C10): pause is a progress-save safety net
            // (with close + transition saves), which is what makes
            // the relaxed 30 s periodic interval safe.
            if !isPlaying { saveWatchHistory() }
        }
        .onChange(of: player.timeMs) { _, _ in
            // Round 15 (C10): EPG fullscreen-stamp heartbeat
            // (throttled to ~20 s) while playback runs fullscreen.
            if overlayMode == .fullscreen,
               Date().timeIntervalSince(lastEPGStampAt) > 20 {
                lastEPGStampAt = Date()
                UserDefaults.standard.set(
                    Date().timeIntervalSince1970,
                    forKey: EPGStore.fullscreenPlaybackStampKey
                )
            }
            updateNextEpisodeCardForPosition()
        }
        .onChange(of: overlayMode) { _, newMode in
            expandControlsGeneration &+= 1
            let gen = expandControlsGeneration
            switch newMode {
            case .mini:
                // Round 9: docked to the mini card the user is back in
                // the browse interface — portrait lock returns.
                restoreBrowseOrientationLock()
                // Round 15 (C10): mini playback no longer lengthens
                // the EPG tick.
                UserDefaults.standard.set(0, forKey: EPGStore.fullscreenPlaybackStampKey)
                // The gesture path already animated `miniProgress`; here only settle chrome.
                // Covers any external minimize too.
                timer?.invalidate()
                if showControls { showControls = false }
                if miniProgress < 0.999 {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { miniProgress = 1 }
                }
            case .fullscreen:
                // Round 9: growing back to fullscreen re-opens rotation.
                AppDelegate.setOrientationLock(.allButUpsideDown)
                // Round 15 (C10): fullscreen again — restamp the EPG
                // flag (the timeMs heartbeat keeps it fresh).
                lastEPGStampAt = Date()
                UserDefaults.standard.set(
                    Date().timeIntervalSince1970,
                    forKey: EPGStore.fullscreenPlaybackStampKey
                )
                cardDrag.offset = .zero
                cardDrag.dismissOpacity = 1
                // Keep the (heavy) fullscreen chrome hidden during the grow so its layout doesn't
                // run every animation frame and make the expand judder. Near-critical damping
                // (0.96) also avoids a scale overshoot at the end. Reveal chrome once settled.
                timer?.invalidate()
                showControls = false
                withAnimation(.spring(response: 0.42, dampingFraction: 0.96)) { miniProgress = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.44) {
                    guard gen == expandControlsGeneration else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
                    resetTimer()
                }
            }
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Automatic transition only for series and only when there really is a next episode to go to.
    private var isAutoAdvanceEligible: Bool {
        autoPlayNextEpisode && type == "series" && !isLiveStream
            && canGoToNextEpisode && onNextEpisode != nil
    }

    // MARK: - Round 14 (A4): next-episode card at T-50 s

    /// Seconds left in the current episode, when the T-50 card's
    /// conditions hold (series + Auto-Play toggle ON + a next
    /// episode exists + a real duration). The card shows while
    /// this is ≤ 50; the pill's N is this value, live.
    private var nextEpisodeRemainingSeconds: Double? {
        guard isAutoAdvanceEligible, player.durationMs > 0 else { return nil }
        return Double(player.durationMs - player.timeMs) / 1000.0
    }

    private var nextEpisodeCardVisible: Bool {
        guard let remaining = nextEpisodeRemainingSeconds else { return false }
        return remaining <= 50 && !nextEpisodeCardDismissed && !hasPlaybackFailure
    }

    /// Whole seconds shown on the pill (ceil so it reads 50…1 and
    /// reaches 0 only at the true end).
    private var nextEpisodeCountdownSeconds: Int {
        guard let remaining = nextEpisodeRemainingSeconds else { return 0 }
        return max(0, Int(remaining.rounded(.up)))
    }

    /// Runs on every position tick: re-arms a cancelled card when
    /// the user seeks back OUT of the 50 s zone, and fires the
    /// advance the moment the countdown reaches ~0 while playing
    /// (the `.ended` state change is the backstop). Round 15
    /// (C8): with the still-watching hold, 0 does NOT auto-play —
    /// the card stays up waiting for an explicit tap.
    private func updateNextEpisodeCardForPosition() {
        guard let remaining = nextEpisodeRemainingSeconds else { return }
        if remaining > 50 {
            if nextEpisodeCardDismissed { nextEpisodeCardDismissed = false }
            return
        }
        guard remaining <= 0.3, player.isPlaying, nextEpisodeCardVisible,
              !stillWatchingHold else { return }
        fireNextEpisode(auto: true)
    }

    private func handlePlaybackEnded() {
        saveWatchHistory()
        guard isAutoAdvanceEligible, !nextEpisodeCardDismissed,
              !stillWatchingHold else { return }
        fireNextEpisode(auto: true)
    }

    private func fireNextEpisode(auto: Bool) {
        // Settings contract (round 14/15): "player.nextEpisode
        // CardMode" — "auto" (default) lets the T-50 countdown
        // auto-play at 0; "ask" means the countdown NEVER
        // auto-plays and only the pill's explicit tap (auto ==
        // false) may start the next episode. Read fresh here, at
        // trigger time — this is the single choke point both
        // auto paths (position tick + `.ended` backstop) pass
        // through.
        if auto,
           UserDefaults.standard.string(forKey: "player.nextEpisodeCardMode") == "ask" {
            return
        }
        // Position ticks keep arriving until the identity actually
        // changes — an advance already in flight must not re-fire.
        if auto, autoAdvanceInFlight { return }
        autoAdvanceInFlight = auto
        if !auto { noteUserInteraction() }
        onNextEpisode?()
    }

    /// The card's Cancel pill: hides the card for THIS ending. It
    /// re-arms only if the user seeks back before the 50 s zone
    /// (see `updateNextEpisodeCardForPosition`).
    private func dismissNextEpisodeCard() {
        noteUserInteraction()
        nextEpisodeCardDismissed = true
    }

    /// A new playback identity (episode/channel switch): the card
    /// re-arms for the new ending, and the still-watching counter
    /// advances ONLY when the switch was an auto-advance — a
    /// manual switch is itself user interaction.
    private func handlePlaybackIdentityChange() {
        nextEpisodeCardDismissed = false
        if autoAdvanceInFlight {
            autoAdvanceInFlight = false
            consecutiveAutoAdvances += 1
            if consecutiveAutoAdvances >= 3 { stillWatchingHold = true }
        } else {
            consecutiveAutoAdvances = 0
            stillWatchingHold = false
        }
    }

    /// Round 15 (C8): any real user interaction resets the
    /// still-watching counter. Interaction funnels through
    /// `resetTimer()` (every control calls it), which invokes
    /// this; gesture-only paths (zap, double-tap seek) call it
    /// directly.
    private func noteUserInteraction() {
        if consecutiveAutoAdvances != 0 { consecutiveAutoAdvances = 0 }
        if stillWatchingHold { stillWatchingHold = false }
    }

    private func applySeriesEpisodeRemoteCommands() {
        switch type {
        case "series":
            player.configureSeriesEpisodeSkipping(
                canPrevious: canGoToPreviousEpisode,
                canNext: canGoToNextEpisode,
                onPrevious: onPreviousEpisode,
                onNext: onNextEpisode
            )
        default:
            // Live TV: turn skip off for channel hopping, show prev/next.
            // Round 20 (R20-2): a movie opened WITH a queue mirrors
            // series exactly — its prev/next queue navigation also
            // replaces skip in Control Center. A movie with no
            // queue (and catch-up, which passes no channel
            // callbacks) keeps skip, exactly like a series playback
            // with no episode callbacks.
            player.configureSeriesEpisodeSkipping(
                canPrevious: canGoToPreviousChannel,
                canNext: canGoToNextChannel,
                onPrevious: onPreviousChannel,
                onNext: onNextChannel,
                swapSkipForNav: isLiveStream || showVODQueueSkip
            )
        }
    }

    private func applyPlaybackTransitionIfNeeded() {
        guard appliedPlaybackIdentity != playbackIdentity else { return }
        if let tags = historySaveTags {
            saveWatchHistory(tags: tags)
        }
        appliedPlaybackIdentity = playbackIdentity
        historySaveTags = WatchHistoryTags(
            playlistId: playlistId,
            streamId: streamId,
            type: type,
            seriesId: seriesId,
            title: title,
            secondaryTitle: subtitle,
            imageURL: artworkURL?.absoluteString,
            containerExtension: containerExtension
        )

        // KSOptions.startPlayTime (the `startSeconds` we pass) is honored ONLY by the
        // FFmpeg engine — the AVPlayer path (mp4/m4v/mov/HLS) ignores it, which used to
        // restart VOD resume at 0:00. For AVPlayer-native containers, leave
        // hasInitialSeeked false so checkAndPerformResume() seeks once the item is seekable.
        let usesFFmpegStartTime = KSPlayerEngine.prefersFFmpegFirst(for: url)
        let shouldStartFromResume = !isLiveStream && (resumeTimeMs ?? 0) > 5000
        hasInitialSeeked = shouldStartFromResume && usesFFmpegStartTime
        isScrubbing = false
        scrubValue = 0
        lockedSliderValue = nil
        sliderUnlockGeneration += 1
        isFastForwarding = false
        player.setRate(1.0)
        videoPinchBase = 1
        videoZoomPan.pinchLive = 1
        videoPanCommitted = .zero

        log.info("Load playback: \(self.playbackIdentity, privacy: .public)")
        player.setImportedSubtitleContext(
            contentKey: ImportedSubtitleStore.contentKey(
                playlistId: playlistId, type: type, streamId: streamId
            )
        )
        let initialStartSeconds: TimeInterval? =
            (shouldStartFromResume && usesFFmpegStartTime) ? Double(resumeTimeMs ?? 0) / 1000.0 : nil
        if let initialStartSeconds {
            log.info("Starting playback with mpv start option: \(initialStartSeconds, privacy: .public)s")
        }
        player.play(
            url: url, startSeconds: initialStartSeconds, isLiveStream: isLiveStream,
            userAgent: userAgent
        )
        applySelectedAspectMode(force: true)
        player.setPlaybackPresentation(makePresentation())
        applySeriesEpisodeRemoteCommands()
    }

    private func checkAndPerformResume() {
        guard !isLiveStream else { return }
        guard !hasInitialSeeked, player.isSeekable, player.durationMs > 0,
              let resumeTime = resumeTimeMs, resumeTime > 5000 else { return }
        let pos = Float(Double(resumeTime) / Double(player.durationMs))
        log.info("Seeking to resumeTimeMs: \(resumeTime) (pos: \(pos))")
        player.seek(to: min(max(pos, 0), 1))
        hasInitialSeeked = true
    }

    private func startSaveHistoryTimer() {
        saveHistoryTimer?.invalidate()
        // Round 15 (C10): periodic progress saves relax from 5 s to
        // 30 s — a DB write every 5 s for hours of playback was
        // pure churn. The safety nets make the gap harmless: saves
        // also happen on pause, on episode/content transition, at
        // playback end, and on player close (all verified in this
        // file), so at most ~30 s of progress can ever be lost.
        saveHistoryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            // The closure captures the view struct from onAppear, freezing plain props
            // (streamId, title, …) at first render. historySaveTags is @State, so it
            // stays live across in-place episode switches — without it, episode 2's
            // position would be written into episode 1's history row.
            if player.isPlaying, let tags = historySaveTags {
                saveWatchHistory(tags: tags)
            }
        }
    }

    private func applySpeedHoldBegan() {
        guard speedUpOnLongPress else { return }
        guard player.isPlaying, videoZoomScale <= 1.02, !isScrubbing,
              interactiveDismissAxis == nil else { return }
        resetTimer()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            isFastForwarding = true
        }
        player.setRate(2.0)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func applySpeedHoldEnded() {
        guard isFastForwarding else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            isFastForwarding = false
        }
        // Round 20 (R20-4): build-33 speed-hold semantics restored —
        // releasing the hold returns to 1.0 (round 8's
        // restore-previous-rate behavior is removed).
        player.setRate(1.0)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func cancelSpeedHoldBecauseDismissDragRecognized() {
        if isFastForwarding {
            applySpeedHoldEnded()
        }
    }

    private func resetInteractiveDismissTracking() {
        interactiveDismissAxis = nil
        interactiveDismissOffset = .zero
    }

    private func resetInteractiveDismissTrackingWithAnimation() {
        interactiveDismissAxis = nil
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            interactiveDismissOffset = .zero
        }
    }

    private func startsInteractiveEdgeBack(start: CGPoint, containerWidth: CGFloat) -> Bool {
        let margin: CGFloat = 36
        switch layoutDirection {
        case .rightToLeft:
            return start.x > containerWidth - margin
        default:
            return start.x < margin
        }
    }

    /// Suppress pull-down-to-close only if the point where the gesture started is in a "chrome" region (side brightness/volume,
    /// top/bottom buttons and the time bar). A downward swipe from the middle works even while the controls are open.
    private func interactiveDismissShouldSuppressPullDown(
        start: CGPoint,
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        safeAreaBottom: CGFloat
    ) -> Bool {
        // Only the on-screen controls (edge sliders / top & bottom chrome) need protecting
        // from an accidental pull-down. With the chrome hidden — the normal viewing state —
        // pull-down works from anywhere, so it never feels like a restricted zone.
        guard showControls else { return false }
        let w = max(containerWidth, 1)
        let h = max(containerHeight, 1)

        let sideMargin: CGFloat = 110
        if start.x <= sideMargin || start.x >= w - sideMargin {
            return true
        }

        let topChrome: CGFloat = 96
        if start.y <= topChrome {
            return true
        }

        let bottomChrome = safeAreaBottom + 168
        if start.y >= h - bottomChrome {
            return true
        }

        return false
    }

    /// Top edge: Control Center / Notifications / status-area gestures; they must not trigger the player closing.
    private func interactiveDismissTopSystemGestureBandHeight(
        safeAreaTop: CGFloat,
        containerHeight: CGFloat
    ) -> CGFloat {
        let h = max(containerHeight, 1)
        let minBand: CGFloat = 72
        let fromSafe = safeAreaTop + 40
        return min(max(fromSafe, minBand), h * 0.28)
    }

    private func interactiveDismissStartedInTopSystemGestureBand(
        start: CGPoint,
        containerHeight: CGFloat,
        safeAreaTop: CGFloat
    ) -> Bool {
        start.y <= interactiveDismissTopSystemGestureBandHeight(
            safeAreaTop: safeAreaTop,
            containerHeight: containerHeight
        )
    }

    /// Round 15 (C12): exit-parallax scale for the edge-back
    /// drag (see the body). The pull-down axis has its own morph
    /// (the mini-card transform), which already parallaxes.
    private var exitParallaxScale: CGFloat {
        guard !reduceMotion else { return 1 }
        let progress = min(abs(interactiveDismissOffset.width) / 400, 1)
        return 1 - 0.05 * progress
    }

    /// Fade only for the horizontal edge-back swipe. The pull-down axis no longer fades;
    /// it morphs into the mini card instead.
    private func edgeBackOpacity(containerSize: CGSize) -> Double {
        let w = max(containerSize.width, 1)
        let vx = Double(abs(interactiveDismissOffset.width)) / Double(w)
        let combined = min(0.55, vx * 0.32)
        return max(0.38, 1.0 - combined)
    }

    // MARK: - Mini player geometry & morph

    /// Fullscreen chrome fades out over the first quarter of the minimize morph so the
    /// controls don't ride the shrinking card.
    private var fullChromeOpacity: Double {
        Double(1 - min(max(miniProgress, 0) / 0.25, 1))
    }

    /// Mini card chrome fades in over the last third of the morph.
    private var miniChromeOpacity: Double {
        Double(max(0, min(1, (miniProgress - 0.65) / 0.35)))
    }

    private var statusBarHiddenInCurrentMode: Bool {
        if isMiniCommitted { return false }
        return horizontalSizeClass == .compact ? !showControls : true
    }

    /// Vertical finger travel that maps to a full minimize (before velocity projection).
    private func pullDownDragDistance(container: CGSize) -> CGFloat {
        max(container.height * 0.32, 180)
    }

    /// Rest frame of the mini card in the GeometryReader's coordinate space, for the
    /// currently docked corner.
    private func miniCardRect(container: CGSize, safeArea: EdgeInsets) -> CGRect {
        let fitted = fittedVideoSize(in: container)
        let aspect = fitted.height > 0 ? fitted.width / fitted.height : 16.0 / 9.0
        // Reserve only the tab-bar height on compact widths. The home-indicator safe area is
        // already contained within the tab bar's region here, so adding `safeArea.bottom` on top
        // lifted the card well above the bar instead of resting it directly on top.
        let bottomInset = isCompactWidth ? MiniPlayerMetrics.tabBarAllowance : 0
        // Bound the card height to the free vertical space so it always floats fully on-screen
        // above the tab bar (matters for portrait video in a short/landscape container).
        let maxHeight = max(
            80,
            min(container.height * 0.42,
                container.height - safeArea.top - bottomInset - MiniPlayerMetrics.margin * 2)
        )
        let size = MiniPlayerMetrics.cardSize(container: container, videoAspect: aspect, maxHeight: maxHeight)
        let origin = MiniPlayerMetrics.cardOrigin(
            corner: miniCorner, size: size, container: container,
            safeArea: safeArea, bottomInset: bottomInset
        )
        return CGRect(origin: origin, size: size)
    }

    /// Scale / offset / mask / corner radius for the player content at morph progress `p`.
    /// The transform lands the *video* (not the letterboxed screen) onto the card. The mask
    /// starts generously oversized so the fullscreen state never clips the safe-area bleed.
    private func miniTransform(
        progress p: CGFloat, card: CGRect, container: CGSize
    ) -> (scale: CGFloat, offset: CGSize, maskSize: CGSize, cornerRadius: CGFloat) {
        let fitted = fittedVideoSize(in: container)
        let fh = max(fitted.height, 1)
        // Minimize must never scale content UP. Clamping guards the degenerate window where
        // .center aspect mode reports a 1×1 fitted size before the stream dimensions arrive.
        let targetScale = min(card.height / fh, 1)
        let scale = miniLerp(1, targetScale, p)

        // Oversized at p=0 (no clip); shrinks to the card slot (in pre-scale points) at p=1.
        let bleed: CGFloat = 160
        let maskSize = CGSize(
            width: miniLerp(container.width + bleed * 2, card.width / max(targetScale, 0.01), p),
            height: miniLerp(container.height + bleed * 2, card.height / max(targetScale, 0.01), p)
        )

        let containerCenter = CGPoint(x: container.width / 2, y: container.height / 2)
        let offset = CGSize(
            width: miniLerp(0, card.midX - containerCenter.x, p),
            height: miniLerp(0, card.midY - containerCenter.y, p)
        )
        // Corner radius is applied pre-scale, so divide by scale to keep it visually constant.
        let cornerRadius = MiniPlayerMetrics.cornerRadius * min(p * 2.5, 1) / max(scale, 0.01)
        return (scale, offset, maskSize, cornerRadius)
    }

    private func nearestCorner(toCenter c: CGPoint, container: CGSize) -> MiniPlayerCorner {
        let left = c.x < container.width / 2
        let top = c.y < container.height / 2
        switch (top, left) {
        case (true, true): return .topLeading
        case (true, false): return .topTrailing
        case (false, true): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    /// Commit the pull-down gesture into the mini card, seeding the spring with the
    /// gesture's exit velocity so a flick feels continuous. Falls back to the old
    /// slide-off dismiss when there is no overlay host to minimize into.
    private func commitMinimize(velocity: CGFloat, distance: CGFloat, containerHeight: CGFloat) {
        guard let minimize = playerOverlayMinimize else {
            withAnimation(.easeIn(duration: 0.18)) {
                interactiveDismissOffset = CGSize(width: 0, height: containerHeight + 60)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                performPlayerDismiss()
            }
            return
        }
        timer?.invalidate()
        showControls = false
        let remaining = max(1, (1 - miniProgress) * distance)
        // Seed the spring with the gesture's normalized velocity (clamped so a release near
        // the end doesn't produce an absurd initial velocity).
        let springV = min(max(Double(velocity) / Double(remaining), -25), 25)
        withAnimation(.interpolatingSpring(stiffness: 320, damping: 30, initialVelocity: springV)) {
            miniProgress = 1
        }
        minimize()
    }

    private func handleMiniCardDragChanged(
        translation: CGSize, card: CGRect, container: CGSize
    ) {
        // Mutate the isolated model directly — the body does not observe it, so only
        // `MiniCardDragLayer` re-renders and the video is left untouched. Offset and fade are set
        // together so the whole card group moves and dims in the same tick (no lockstep drift).
        cardDrag.offset = translation
        let center = CGPoint(x: card.midX + translation.width, y: card.midY + translation.height)
        let frac = MiniPlayerDismissPolicy.offscreenFraction(
            center: center, card: card.size, container: container
        )
        cardDrag.dismissOpacity = MiniPlayerDismissPolicy.liveOpacity(offscreenFraction: frac)
    }

    private func handleMiniCardDragEnded(
        translation: CGSize, velocity: CGSize, container: CGSize, safeArea: EdgeInsets
    ) {
        let card = miniCardRect(container: container, safeArea: safeArea)
        let draggedCenter = CGPoint(
            x: card.midX + translation.width,
            y: card.midY + translation.height
        )

        // Dismiss ONLY when the card has actually been dragged out of the app — half of it past a
        // left, right, or bottom edge at the moment of release. This is position-only on purpose:
        // a quick flick that doesn't physically leave the screen must re-dock, not close (a fast
        // horizontal swipe from a top corner used to close via velocity projection). The top edge
        // is excluded by `offscreenFraction`, so an upward drag always re-docks.
        let liveFrac = MiniPlayerDismissPolicy.offscreenFraction(
            center: draggedCenter, card: card.size, container: container
        )
        if liveFrac >= MiniPlayerDismissPolicy.releaseFraction {
            dismissMiniCardOffscreen(
                draggedCenter: draggedCenter, card: card, container: container
            )
            return
        }

        // Not dismissed → settle to the nearest corner. Velocity still projects the *corner*
        // choice so a flick toward a corner snaps there, but it can no longer trigger a close.
        let projected = CGPoint(
            x: draggedCenter.x + velocity.width * 0.12,
            y: draggedCenter.y + velocity.height * 0.12
        )
        let target = nearestCorner(toCenter: projected, container: container)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            miniCorner = target
            cardDrag.offset = .zero
            cardDrag.dismissOpacity = 1
        }
    }

    /// Slide the card the rest of the way off whichever edge it has cleared most, fade it out,
    /// then tear the player down. The exit direction continues the user's own drag rather than
    /// snapping to a fixed side.
    private func dismissMiniCardOffscreen(
        draggedCenter: CGPoint, card: CGRect, container: CGSize
    ) {
        let halfW = card.width / 2
        let offLeft = halfW - draggedCenter.x
        let offRight = draggedCenter.x + halfW - container.width
        let offBottom = draggedCenter.y + card.height / 2 - container.height

        var exit = cardDrag.offset
        // Continue off whichever edge the card has already left the most.
        if offBottom >= max(offLeft, offRight) {
            exit.height += container.height - draggedCenter.y + card.height
        } else if offLeft >= offRight {
            exit.width -= draggedCenter.x + card.width
        } else {
            exit.width += container.width - draggedCenter.x + card.width
        }

        withAnimation(.easeIn(duration: 0.2)) {
            cardDrag.offset = exit
            cardDrag.dismissOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            performPlayerDismiss()
        }
    }

    private func interactiveDismissDragGesture(
        containerSize: CGSize,
        safeAreaTop: CGFloat,
        safeAreaBottom: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 22, coordinateSpace: .local)
            .onChanged { value in
                if isMiniCommitted { return }  // mini card handles its own gestures
                if showTrackSettings { return }
                if videoZoomScale > 1.02 || isScrubbing { return }
                // While a 2x speed-hold is active it owns the touch until finger-up; the
                // dismiss drag must not fight it (was the "drag-down vs long-press" conflict).
                if isFastForwarding { return }

                let start = value.startLocation
                let t = value.translation
                let w = max(containerSize.width, 1)
                let h = max(containerSize.height, 1)
                let startedInTopSystemBand = interactiveDismissStartedInTopSystemGestureBand(
                    start: start,
                    containerHeight: h,
                    safeAreaTop: safeAreaTop
                )

                if interactiveDismissAxis == nil {
                    if startsInteractiveEdgeBack(start: start, containerWidth: w) {
                        if !startedInTopSystemBand {
                            let correctDirection =
                                (layoutDirection == .leftToRight && t.width > 12)
                                || (layoutDirection == .rightToLeft && t.width < -12)
                            if correctDirection, abs(t.width) + 8 >= abs(t.height) {
                                interactiveDismissAxis = .edgeBack
                            }
                        }
                    }
                    if interactiveDismissAxis == nil,
                       // Round 14 (B3): a downward channel-zap swipe
                       // must not ALSO start the pull-down minimize —
                       // the zap handler stamps `lastZapAt`, and the
                       // pull-down stays out of its way for 0.5 s.
                       Date().timeIntervalSince(lastZapAt ?? .distantPast) > 0.5,
                       FullscreenPlayerPullDownPolicy.shouldActivate(translation: t),
                       !interactiveDismissShouldSuppressPullDown(
                        start: start,
                        containerWidth: w,
                        containerHeight: h,
                        safeAreaBottom: safeAreaBottom
                       ),
                       !startedInTopSystemBand
                    {
                        interactiveDismissAxis = .pullDown
                    }
                }

                switch interactiveDismissAxis {
                case .edgeBack:
                    if layoutDirection == .leftToRight {
                        interactiveDismissOffset = CGSize(width: max(0, t.width), height: 0)
                    } else {
                        interactiveDismissOffset = CGSize(width: min(0, t.width), height: 0)
                    }
                case .pullDown:
                    // Drive the mini-player morph directly with the finger.
                    let dist = pullDownDragDistance(container: containerSize)
                    miniProgress = FullscreenPlayerPullDownPolicy.progress(
                        translationHeight: t.height,
                        fullDistance: dist
                    )
                case .none:
                    break
                }

                if interactiveDismissAxis != nil {
                    cancelSpeedHoldBecauseDismissDragRecognized()
                }
            }
            .onEnded { value in
                if isMiniCommitted { return }
                if showTrackSettings {
                    resetInteractiveDismissTracking()
                    return
                }

                let axis = interactiveDismissAxis
                guard videoZoomScale <= 1.02, !isScrubbing else {
                    resetInteractiveDismissTrackingWithAnimation()
                    if miniProgress > 0 {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { miniProgress = 0 }
                    }
                    return
                }

                guard let axis else {
                    if interactiveDismissOffset != .zero {
                        resetInteractiveDismissTrackingWithAnimation()
                    }
                    return
                }

                let t = value.translation
                let pred = value.predictedEndTranslation
                let cw = max(containerSize.width, 1)
                let ch = max(containerSize.height, 1)

                interactiveDismissAxis = nil
                switch axis {
                case .edgeBack:
                    let progressed = layoutDirection == .leftToRight ? t.width : -t.width
                    let predProg = layoutDirection == .leftToRight ? pred.width : -pred.width
                    if progressed > min(cw * 0.28, 130) || predProg > 200 {
                        let targetX: CGFloat = layoutDirection == .leftToRight ? cw + 60 : -(cw + 60)
                        withAnimation(.easeIn(duration: 0.18)) {
                            interactiveDismissOffset = CGSize(width: targetX, height: 0)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            performPlayerDismiss()
                        }
                    } else {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                            interactiveDismissOffset = .zero
                        }
                    }
                case .pullDown:
                    // A flick can commit only after meaningful travel; tiny fast touch
                    // drift must never throw the player into the mini card.
                    let dist = pullDownDragDistance(container: containerSize)
                    let vy = value.velocity.height
                    let projected = FullscreenPlayerPullDownPolicy.progress(
                        translationHeight: value.predictedEndTranslation.height,
                        fullDistance: dist
                    )
                    let commitMini = FullscreenPlayerPullDownPolicy.shouldCommit(
                        progress: miniProgress,
                        projectedProgress: projected,
                        velocityY: vy
                    )
                    if commitMini {
                        commitMinimize(
                            velocity: vy,
                            distance: FullscreenPlayerPullDownPolicy.activeDistance(
                                fullDistance: dist
                            ),
                            containerHeight: ch
                        )
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            miniProgress = 0
                        }
                    }
                }
            }
    }

    // MARK: - Player surface

    private func playerChromeAndVideo(outerSafeAreaInsets: EdgeInsets) -> some View {
        GeometryReader { geo in
            // Round 16 (P1): the chrome's insets are read from THIS
            // reader, not from the body-level reader passed in. The
            // outer insets travel through the mini-morph container
            // (drag layer + mask/scale/offset transforms); on the
            // owner's phone in build 50 they no longer matched the
            // visible screen, so every edge-anchored control (close
            // button, edge sliders, scrubber labels) rendered
            // partially off-screen in portrait while the video —
            // sized by this same local reader — stayed correct.
            // Sourcing the insets locally restores the build-49
            // behavior: all chrome inside the real safe area, in
            // portrait and landscape, VOD and live.
            let outerSafeAreaInsets = geo.safeAreaInsets
            // Round 18 (R18-2): the surface is laid out at the
            // aspect-FITTED size, as in the original player; `.fill`
            // covers via the zoom layer's transform scale.
            let fittedSize = fittedVideoSize(in: geo.size)
            ZStack {
                MPVolumeViewHost(bridge: systemVolumeBridge)
                    .frame(width: 120, height: 48)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(-10)

                HiddenAirPlayRoutePicker(trigger: airPlayPickerSignal)
                    .frame(width: 44, height: 44)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(-10)

                ZStack {
                    VideoZoomPanLayer(
                        model: videoZoomPan,
                        pinchBase: videoPinchBase,
                        zoomMax: videoZoomMax,
                        panCommitted: videoPanCommitted,
                        aspectFillScale: videoAspectFillScale,
                        viewportSize: videoViewportSize,
                        containerSize: videoContainerSize,
                        pinchAnchor: pinchAnchorState
                    ) {
                        ZStack {
                            if let cast = player.castController {
                                KSPlayerVideoSurface(
                                    engine: player.engine,
                                    cast: cast,
                                    manualPiPTrigger: pipManualSignal,
                                    pipEnabled: pipEnabled,
                                    continuePlayingInBackground: continuePlayingInBackground
                                )
                                .id("KSPlaybackSurface")
                            }
                        }
                        .frame(width: fittedSize.width, height: fittedSize.height)
                    }
                }
                // Clip to the screen so the `.fill` crop never bleeds past the viewport into
                // the chrome. Only Fill overflows, so the clip (an offscreen compositing pass
                // that was adding jank on open / pull-down) is skipped in fit/center.
                .frame(width: geo.size.width, height: geo.size.height)
                .modifier(ConditionalClip(active: selectedAspectMode == .fill))
                .allowsHitTesting(false)  // all touch is in the UIKit overlay; the video layer receives no hit-testing
                .zIndex(0)

                // Tap/pinch/pan UIKit overlay'inde. Pinch midpoint callback ile zoom anchor
                // the offset is calculated; pan is enabled only while zoomed.
                PlayerMediaKitStyleTouchOverlay(
                    showControls: $showControls,
                    isSeekDisabled: isCenterTransportLoading,
                    videoZoomScale: videoZoomScale,
                    isSpeedHoldActive: isFastForwarding,
                    isSpeedHoldEnabled: speedUpOnLongPress
                        && player.isPlaying
                        && interactiveDismissAxis == nil,
                    // Round 14 (B12): double-tap ±10 s seek on
                    // seekable content; (B3): vertical-swipe channel
                    // zap on fullscreen live with a channel queue.
                    seekEnabled: effectiveSeekable && !hasPlaybackFailure,
                    onDoubleTapSeek: { forward in handleDoubleTapSeek(forward: forward) },
                    channelZapEnabled: isLiveStream
                        && (onNextChannel != nil || onPreviousChannel != nil),
                    onChannelZap: { direction in handleChannelZap(direction: direction) },
                    // Round 9: ONE source for the capsule size — the
                    // rendered sliders read the same helper, so the
                    // exclusion rect can never drift from the visual.
                    edgeSliderTrackSize: PlayerControlCenterStyleEdgeSliders.trackSize(isCompactWidth: isCompactWidth),
                    edgeSliderLeadingInset: 16 + outerSafeAreaInsets.leading,
                    edgeSliderTrailingInset: 16 + outerSafeAreaInsets.trailing,
                    interactionEnabled: miniProgress < 0.02,
                    onResetTimer: { resetTimer() },
                    onInvalidateTimer: { timer?.invalidate() },
                    onSpeedHoldBegan: { applySpeedHoldBegan() },
                    onSpeedHoldEnded: { applySpeedHoldEnded() },
                    onVideoPinchBegan: { location, containerBounds in
                        handleVideoPinchBegan(at: location, containerSize: containerBounds)
                    },
                    onVideoPinchChanged: { videoZoomPan.pinchLive = $0 },
                    onVideoPinchEnded: { handleVideoPinchGestureEnded() },
                    onVideoPanChanged: { translation in
                        videoZoomPan.panLive = translation
                    },
                    onVideoPanEnded: { translation in
                        handleVideoPanEnded(translation: translation)
                    },
                    onVideoSurfaceTap: { onVideoSurfaceTap?() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(1)

                if controlsLocked {
                    // Round 19: while the controls lock is on, this
                    // unlock button is the ONLY chrome on screen —
                    // rendered outside the showControls stack so it
                    // survives the chrome being hidden.
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            glassIconButton(systemName: "lock.fill", size: 44) {
                                toggleControlsLock()
                            }
                            .accessibilityLabel(L("player.controls_unlock"))
                        }
                        .padding(.top, 16)
                        Spacer()
                    }
                    .padding(.leading, 12 + outerSafeAreaInsets.leading)
                    .padding(.trailing, 12 + outerSafeAreaInsets.trailing)
                    .padding(.top, outerSafeAreaInsets.top)
                    .zIndex(31)
                }

                if showControls {
                    // top/bottom dark gradient for readability, like the iOS native player.
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.55),
                                Color.black.opacity(0.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 160)
                        Spacer(minLength: 0)
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.0),
                                Color.black.opacity(0.65)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 220)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .opacity(fullChromeOpacity)
                    .zIndex(29)

                    VStack(spacing: 0) {
                        topChrome
                        Spacer()
                        centerTransport
                        Spacer()
                        bottomTransportChrome
                    }
                    .padding(.leading, 12 + outerSafeAreaInsets.leading)
                    .padding(.trailing, 12 + outerSafeAreaInsets.trailing)
                    .padding(.top, outerSafeAreaInsets.top)
                    .padding(.bottom, 12 + outerSafeAreaInsets.bottom)
                    // The controls must not leave the safe area — the bottom safe area is preserved so the scrub bar
                    // doesn't accidentally trigger a seek in the home indicator / app switcher gesture region.
                    .opacity(controlsLocked ? 0 : fullChromeOpacity)
                    // Invisible (opacity ~0) but still-hittable fullscreen chrome must not
                    // intercept taps during the minimize/expand morph — otherwise a stray tap
                    // on the scaled-down invisible close/play button could tear down or pause.
                    // Only interactive when essentially fullscreen — and never while the
                    // controls lock is on (round 19).
                    .allowsHitTesting(!controlsLocked && miniProgress < 0.02)
                    .zIndex(30)

                    if isLiveStream, let programme = currentNowNext?.now {
                        PlayerProgrammeStrip(programme: programme)
                            .frame(maxWidth: 240, alignment: .leading)
                            .clipped()
                            .padding(.leading, 20 + outerSafeAreaInsets.leading)
                            .padding(.bottom, 20 + outerSafeAreaInsets.bottom)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .bottomLeading
                            )
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .opacity(fullChromeOpacity)
                            .zIndex(31)
                    }

                    PlayerControlCenterStyleEdgeSliders(
                        player: player,
                        systemVolume: systemVolumeBridge,
                        safeAreaInsets: outerSafeAreaInsets,
                        isCompactWidth: isCompactWidth
                    ) {
                        resetTimer()
                    }
                    .opacity(fullChromeOpacity)
                    .allowsHitTesting(miniProgress < 0.02)
                    .zIndex(32)
                }

                // Loading/buffering feedback even while the controls are hidden: on a slow panel
                // opening, after the controls disappeared after 5 sec, the user was left alone
                // with a pitch-black screen. While the controls are open, the center button already shows a spinner,
                // so here it is drawn only in the !showControls state.
                if isCenterTransportLoading && !showControls {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.4)
                        .padding(18)
                        .background(.black.opacity(0.35), in: Circle())
                        .allowsHitTesting(false)
                        .opacity(fullChromeOpacity)
                        .zIndex(25)
                }

                // Round 14 (B12): ±10 s double-tap seek indicator —
                // a big arrow + seconds glyph on the tapped side,
                // shown briefly alongside the rigid haptic the seek
                // fires (see `handleDoubleTapSeek`).
                if let direction = skipIndicatorDirection {
                    HStack {
                        if direction < 0 {
                            skipSeekIndicator(forward: false)
                            Spacer()
                        } else {
                            Spacer()
                            skipSeekIndicator(forward: true)
                        }
                    }
                    .padding(.horizontal, 96)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .zIndex(38)
                }

                // Round 16 (R6): the dead debug overlay render block is
                // removed — its toggle was deleted in round 14, the
                // @AppStorage flag could never be set true again, and
                // the panel could never appear. The Playback Tracks
                // panel Stats section (real engine values) replaces it.

                if let aspectToastText {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: selectedAspectMode.iconName)
                                .font(.footnote.weight(.semibold))
                            Text(aspectToastText)
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
                        .padding(.top, 64)
                        Spacer()
                    }
                    .transition(
                        .opacity
                            .combined(with: .scale(scale: 0.92, anchor: .top))
                            .combined(with: .move(edge: .top))
                    )
                    .opacity(fullChromeOpacity)
                    .zIndex(40)
                    .allowsHitTesting(false)
                }

                // Round 12 (point 2): Playback Tracks as a compact
                // floating panel over the video (was a full sheet).
                // Topmost layer; its backdrop tap dismisses, and it
                // fades/scales in (point 7) without touching the
                // video surface or the chrome underneath.
                if showTrackSettings {
                    trackSettingsOverlay(containerSize: geo.size)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        .zIndex(60)
                }

                // Round 14 (A4): the next-episode card at T-50 s —
                // the SAME Netflix-style pills the post-end countdown
                // used, now driven by the live position: they appear
                // when 50 s remain, N counts the seconds left to the
                // episode's end, and at 0 the next episode starts
                // (see `updateNextEpisodeCardForPosition`). Cancel
                // hides the card for this ending. Round 15 (C8):
                // with the still-watching hold the countdown still
                // shows, but at 0 the pill switches to a plain
                // "Next episode" and waits for a tap; the season /
                // episode line renders only when the caller supplied
                // the next episode's real numbers.
                Group {
                if nextEpisodeCardVisible {
                    VStack(alignment: .trailing, spacing: 8) {
                        if let season = nextEpisodeSeason, let episode = nextEpisodeEpisode {
                            Text(L("player.autonext.season_episode", season, episode))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        }
                        HStack(spacing: 10) {
                            Button {
                                dismissNextEpisodeCard()
                            } label: {
                                Text(L("common.cancel"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                            }
                            .buttonStyle(PressScaleButtonStyle())

                            Button {
                                fireNextEpisode(auto: false)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.fill")
                                        .font(.footnote.weight(.bold))
                                    if stillWatchingHold || nextEpisodeCountdownSeconds <= 0 {
                                        Text(L("player.autonext.play_next"))
                                    } else {
                                        Text(L("player.autonext.countdown", nextEpisodeCountdownSeconds))
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.white, in: Capsule())
                            }
                            .buttonStyle(PressScaleButtonStyle())
                        }
                    }
                    .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
                    // Round 10: the padding now comes BEFORE the
                    // full-size frame (see the Skip Intro note below) —
                    // the round-9 order halved the effective inset and
                    // left both pills sitting on the volume capsule.
                    .padding(.trailing, pillTrailingPadding(outerSafeAreaInsets))
                    .padding(.bottom, (showControls ? 92 : 16) + outerSafeAreaInsets.bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    // Because the chrome visibility can change without animation (Transaction.disablesAnimations),
                    // drive the padding with its own animation — while the user was reaching for
                    // "Cancel", the buttons were teleporting 76pt.
                    .animation(.easeInOut(duration: 0.2), value: showControls)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .opacity(fullChromeOpacity)
                }
                }
                // Value-scoped animation drives the card's
                // slide+fade entrance; nothing else animates on
                // this change.
                .animation(
                    reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                    value: nextEpisodeCardVisible
                )
                .zIndex(41)

                // Round 8: Skip Intro — STRONG's fixed model, exactly.
                // The app has NO intro metadata (no intro field exists
                // in the Xtream/M3U models or the DB), so the pill does
                // NOT detect anything: while a seekable VOD stream is
                // inside its intro window, the pill offers ONE jump of
                // the configured length through the same relative seek
                // the ±10 s buttons use. An earlier draft gated this
                // on a metadata parameter no caller could ever supply,
                // which made the pill dead UI; the fixed skip is the
                // feature.
                //
                // Round 11 (owner, build 47): three changes. (1) The
                // pill moves to the BOTTOM-LEFT — rounds 9–10 kept it
                // bottom-right clear of the volume capsule by inset
                // math alone and it still crowded on the owner's
                // phone; the left side's only capsule is the
                // brightness one, and the pill now starts a full
                // 20 pt right of IT, so no gesture bar can touch it
                // in any orientation (the auto-advance pill below
                // stays bottom-right — series only, and it already
                // clears via pillTrailingPadding). (2) Settings ▸
                // Player ▸ "Show Skip Intro" gates the pill. (3) The
                // window and the jump use Settings ▸ Player ▸
                // "Skip-intro length" (default 85 s, as before).
                // Round 14 (B12): the pill now SLIDES in from the
                // leading edge (it used to pop in instantly when its
                // time-window condition flipped) — it stays in the
                // hierarchy for VOD and its visibility is driven by
                // offset + opacity with a spring. Round 15 (C8):
                // the window and the jump use the PER-SERIES LEARNED
                // landing position when one exists for this series
                // (stored when the user last pressed Skip Intro in
                // it), else the generic Settings length exactly as
                // before.
                if showSkipIntro, !isLiveStream {
                    Button {
                        resetTimer()
                        performSkipIntro()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "forward.end.fill")
                                .font(.footnote.weight(.bold))
                            Text(L("player.skip_intro"))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.white, in: Capsule())
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
                    // Padding FIRST, framing second (round 10's
                    // modifier-order fix) — the inset is exact.
                    .padding(.leading, pillLeadingPadding(outerSafeAreaInsets))
                    .padding(.bottom, (showControls ? 168 : 72) + outerSafeAreaInsets.bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .animation(.easeInOut(duration: 0.2), value: showControls)
                    .offset(x: skipIntroVisible || reduceMotion ? 0 : -180)
                    .opacity(skipIntroVisible ? fullChromeOpacity : 0)
                    .allowsHitTesting(skipIntroVisible)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                        value: skipIntroVisible
                    )
                    .zIndex(42)
                }

                // Note: the PiP placeholder UI was removed — the system `AVPictureInPictureController`
                // automatically shows its own "playing in picture in picture" message.

                if isFastForwarding {
                    VStack {
                        HStack(spacing: 6) {
                            Text("2x")
                            Image(systemName: "forward.fill")
                        }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial.opacity(0.8), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                        .padding(.top, 64)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .opacity(fullChromeOpacity)
                    .zIndex(10)
                }

                // Round 14 (A2): the failure surface — a CENTERED,
                // dismissible card with the real cause and a Close
                // button, replacing both the endless spinner and
                // the old bottom-left banner (whose hard-coded red
                // is gone with it; the card's accent is
                // AppTheme.live — round 15, B9). If the account is
                // expired, the EXPIRED state is presented instead of
                // the generic failure. An error haptic fires when
                // the surface appears (round 14, B12), and the
                // entrance is slide + fade (round 15, C12).
                Group {
                    if showFailureCard, let msg = player.playbackFailureMessage {
                        Group {
                            if let expired = ProviderExpiryStore.blockedExpiry(playlistId: playlistId) {
                                SubscriptionExpiredView(
                                    expiryDate: expired,
                                    onOpenSettings: { performPlayerDismiss() },
                                    onClose: { performPlayerDismiss() }
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                                .padding(.horizontal, 28)
                            } else {
                                playbackFailureCard(message: msg)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.45))
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity)
                        )
                        .onAppear {
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                        }
                    }
                }
                // Value-scoped animation drives the slide+fade
                // entrance (round 15, C12) and nothing else.
                .animation(
                    reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86),
                    value: showFailureCard
                )
                .zIndex(45)

                // Round 15 (B8): end-of-series state — the LAST
                // episode ended (no next episode exists): instead
                // of a frozen frame, a clear finished state with
                // Back / Watch again.
                Group {
                    if player.state == .ended, type == "series",
                       !canGoToNextEpisode, onNextEpisode == nil,
                       !hasPlaybackFailure {
                        endOfSeriesCard
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.opacity(0.45))
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: player.state)
                .zIndex(44)

            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { syncVideoLayout(container: geo.size) }
            .onChange(of: geo.size) { _, new in syncVideoLayout(container: new) }
            .onChange(of: sourceVideoAspectRatio) { _, _ in syncVideoLayout(container: geo.size) }
            .onChange(of: videoAspectModeRaw) { _, _ in syncVideoLayout(container: geo.size) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Let the video surface extend to the edges of the screen. The controls separately use `outerSafeAreaInsets`
        // to respect the safe area (the controls VStack padding below).
        .ignoresSafeArea()
    }

    private func handleVideoPinchBegan(at location: CGPoint, containerSize: CGSize) {
        pinchAnchorState = PinchAnchorState(
            screenMidpoint: location,
            containerCenter: CGPoint(x: containerSize.width / 2, y: containerSize.height / 2),
            startScale: effectiveVideoScale,
            startPanCommitted: videoPanCommitted
        )
    }

    private func handleVideoPinchGestureEnded() {
        // Pinch end: first bake the compensating zoom offset into the committed pan, then clear the state.
        let zoomDelta = videoPinchZoomOffset
        pinchAnchorState = nil
        videoPanCommitted = CGSize(
            width: videoPanCommitted.width + zoomDelta.width,
            height: videoPanCommitted.height + zoomDelta.height
        )
        // Scale'i komite et.
        videoPinchBase = min(max(videoPinchBase * videoZoomPan.pinchLive, 1), videoZoomMax)
        videoZoomPan.pinchLive = 1
        if videoPinchBase < 1.02 {
            videoPinchBase = 1
            videoPanCommitted = .zero
        } else {
            commitVideoPanClamp()
        }
    }

    private func handleVideoPanEnded(translation: CGSize) {
        let maxX = videoPanBounds.width
        let maxY = videoPanBounds.height
        let combined = CGSize(
            width: videoPanCommitted.width + translation.width,
            height: videoPanCommitted.height + translation.height
        )
        videoPanCommitted = CGSize(
            width: min(max(combined.width, -maxX), maxX),
            height: min(max(combined.height, -maxY), maxY)
        )
        videoZoomPan.panLive = .zero
    }

    private func commitVideoPanClamp() {
        let maxX = videoPanBounds.width
        let maxY = videoPanBounds.height
        videoPanCommitted = CGSize(
            width: min(max(videoPanCommitted.width, -maxX), maxX),
            height: min(max(videoPanCommitted.height, -maxY), maxY)
        )
    }

    /// Recomputes the fitted frame + `.fill` cover scale for a container size and re-clamps
    /// the pan. Called on appear, container resize, source-ratio change, and mode change.
    private func syncVideoLayout(container: CGSize) {
        // Round 20 (R20-4): build-33 body restored — round 10's
        // orientation-flip transform reset is removed; the surface
        // is laid out at the aspect-FITTED size and `.fill` covers
        // via the zoom layer's `aspectFillScale` transform.
        let fitted = fittedVideoSize(in: container)
        videoViewportSize = fitted
        videoContainerSize = container
        videoAspectFillScale = aspectFillScale(viewport: container, fitted: fitted)
        commitVideoPanClamp()
    }

    /// Builds the Now Playing presentation, folding in the current EPG programme
    /// (used as the Now Playing title on live channels).
    private func makePresentation() -> PlaybackPresentation {
        let programme = currentNowNext?.now
        return PlaybackPresentation(
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            isLive: isLiveStream,
            programmeTitle: programme?.title,
            programmeInterval: programme.map { DateInterval(start: $0.start, end: max($0.start, $0.stop)) }
        )
    }

    private func saveWatchHistory(tags: WatchHistoryTags? = nil) {
        // Catch-up (timeshift) sessions must not persist history: the key would
        // collide with the channel's live row and its resume time is meaningless
        // once the archive window rolls past.
        if suppressWatchHistory { return }
        let resolvedTags = tags ?? WatchHistoryTags(
            playlistId: playlistId,
            streamId: streamId,
            type: type,
            seriesId: seriesId,
            title: title,
            secondaryTitle: subtitle,
            imageURL: artworkURL?.absoluteString,
            containerExtension: containerExtension
        )
        let currentTime = Int(player.timeMs)
        let duration = Int(player.durationMs)
        // On live broadcasts, the mpv duration mostly stays 0; if we don't skip the guard on live,
        // the "recently watched channels" never fills. On VOD/series, the valid-duration requirement continues.
        guard duration > 0 || resolvedTags.type == "live" else { return }

        let history = DBWatchHistory(
            id: "\(resolvedTags.playlistId)_\(resolvedTags.type)_\(resolvedTags.streamId)",
            playlistId: resolvedTags.playlistId,
            streamId: resolvedTags.streamId,
            type: resolvedTags.type,
            lastTimeMs: currentTime,
            durationMs: duration,
            lastWatchedAt: Date(),
            seriesId: resolvedTags.seriesId,
            title: resolvedTags.title,
            secondaryTitle: resolvedTags.secondaryTitle,
            imageURL: resolvedTags.imageURL,
            containerExtension: resolvedTags.containerExtension
        )

        Task {
            do {
                try await AppDatabase.shared.write { db in
                    try history.save(db)
                }
            } catch {
                log.error("Failed to save watch history: \(error)")
            }
        }
    }

    // MARK: - Chrome

    // Round 19 (R19-1a): the top bar follows the arrangement of the
    // owner's STRONG reference photos, realized with Super X styling
    // (his Super X photo): ONE close button + title on the left —
    // live streams show a red-dot "Live" line under the title
    // instead of the subtitle — and on the right, in order: AirPlay,
    // controls lock, dock-to-mini (exit fullscreen; only where a
    // mini-player host exists). Nothing else. The grouped capsule
    // (round 18) is gone, as in round 9: no favorite star, no aspect
    // button, no PiP button, no "AA", no gear up here — aspect,
    // tracks, speed and sleep live in the ONE bottom row below.
    private var topChrome: some View {
        HStack(alignment: .center, spacing: 12) {
            glassIconButton(systemName: "xmark", size: 44) { performPlayerDismiss() }
                .accessibilityLabel(L("common.close"))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                if isLiveStream {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                        Text(L("player.live_badge"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    }
                } else if let subtitle, !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            // Long channel metadata must never push trailing controls off-screen.
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                if let onNavigate = onNavigateToDetail {
                    let targetId = (type == "series" ? seriesId : streamId) ?? streamId
                    onNavigate(type, targetId)
                    performPlayerDismiss()
                }
            }

            topBarActions
        }
        .padding(.horizontal, isCompactWidth ? 0 : 20)
        .padding(.top, 16)
    }

    private var topBarActions: some View {
        HStack(spacing: 10) {
            airPlayTopBarAction

            glassIconButton(systemName: controlsLocked ? "lock.fill" : "lock.open.fill", size: 44) {
                toggleControlsLock()
            }
            .accessibilityLabel(L(controlsLocked ? "player.controls_unlock" : "player.controls_lock"))

            if playerOverlayMinimize != nil {
                glassIconButton(systemName: "arrow.down.right.and.arrow.up.left", size: 44) {
                    requestDockToMini()
                }
                .accessibilityLabel(L("player.dock_to_mini"))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var airPlayTopBarAction: some View {
        if player.isAirPlayVideoCapable {
            if player.needsAirPlayPreparation {
                // UHF akışı: önce remux hazırlanır (loading), sonra seçici açılır.
                if isPreparingAirPlay {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 44, height: 44)
                } else {
                    glassIconButton(systemName: "airplay.video", size: 44) {
                        prepareAndPresentAirPlay()
                    }
                    .accessibilityLabel("AirPlay")
                }
            } else {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                    AirPlayRoutePickerButton()
                        .frame(width: 44, height: 44)
                }
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .accessibilityLabel("AirPlay")
            }
        }
    }

    private func toggleControlsLock() {
        controlsLocked.toggle()
        if controlsLocked {
            timer?.invalidate()
            showControls = false
        } else {
            showControls = true
            resetTimer()
        }
    }

    /// The STRONG top-bar fullscreen icon, realized as our real
    /// "exit fullscreen": dock into the mini player through the same
    /// host closure the pull-down gesture commits to.
    private func requestDockToMini() {
        guard let minimize = playerOverlayMinimize else { return }
        timer?.invalidate()
        showControls = false
        withAnimation(.interpolatingSpring(stiffness: 320, damping: 30)) {
            miniProgress = 1
        }
        minimize()
    }

    private func cycleVideoAspectMode() {
        resetVideoTransformForAspectSwitch()
        videoAspectModeRaw = nextAspectMode.rawValue
    }

    private func prepareAndPresentAirPlay() {
        isPreparingAirPlay = true
        player.prepareAirPlay { success in
            isPreparingAirPlay = false
            if success { airPlayPickerSignal += 1 }
        }
    }

    // MARK: - Round 19 quick-actions row (Audio / Audio Track / Subtitles / Guide / Speed / Fill / Sleep)

    /// One circular quick-action visual: 48pt glass circle (Super X
    /// blue accent fill when active) with a caption under it — the
    /// button row of the owner's reference photos.
    private func quickActionVisual(systemName: String, caption: String, isActive: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
                .frame(width: 48, height: 48)
                .background {
                    if isActive {
                        Circle().fill(AppTheme.accent)
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 5, y: 1)
            Text(caption)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isActive ? AppTheme.accent : .white.opacity(0.88))
                .shadow(color: .black.opacity(0.4), radius: 2, y: 0.5)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    /// The ONE bottom row, evenly spaced across the full width
    /// (STRONG measurements). Content adapts by type, arrangement
    /// and sizing never do (R19-1b):
    /// - Movies / Series (VOD): Audio, Audio Track, Subtitles,
    ///   Speed, Fill, Sleep.
    /// - Live: Audio, Audio Track, Guide, Fit, Sleep (no subtitle
    ///   or speed controls on a broadcast; Guide opens the channel
    ///   side panel and renders only where that panel exists).
    /// "Audio" opens the track sheet on its audio section (audio
    /// settings incl. delay); "Audio Track" is the quick menu of the
    /// stream's real audio tracks; "Subtitles" is the quick menu of
    /// the real subtitle tracks (with Off) — both menus end in
    /// "More Options" into the same sheet, so nothing is duplicated.
    private var quickActionsRow: some View {
        HStack(spacing: 10) {
            Button {
                resetTimer()
                openTrackSettings(focus: .audio)
            } label: {
                quickActionVisual(systemName: "speaker.wave.2.fill", caption: L("player.tracks.audio"), isActive: false)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel(L("player.tracks.audio"))
            .frame(maxWidth: .infinity)

            Menu {
                audioTrackMenuItems
            } label: {
                quickActionVisual(systemName: "waveform", caption: L("player.tracks.audio_track"), isActive: false)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel(L("player.tracks.audio_track"))
            .frame(maxWidth: .infinity)

            if isLiveStream {
                if showLiveChannelListButton, let toggle = onToggleLiveChannelSidePanel {
                    Button {
                        resetTimer()
                        toggle()
                    } label: {
                        quickActionVisual(systemName: "rectangle.grid.1x2", caption: L("player.guide"), isActive: isLiveChannelSidePanelVisible)
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityLabel(L("player.guide"))
                    .frame(maxWidth: .infinity)
                }
            } else {
                Menu {
                    subtitleMenuItems
                } label: {
                    quickActionVisual(systemName: "captions.bubble.fill", caption: L("player.tracks.subtitle"), isActive: player.currentSubtitleTrackId >= 0)
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel(L("player.tracks.subtitle"))
                .frame(maxWidth: .infinity)

                Menu {
                    ForEach(Self.playbackRates, id: \.self) { rate in
                        Button {
                            resetTimer()
                            player.setRate(rate)
                        } label: {
                            if abs(player.rate - rate) < 0.001 {
                                Label(Self.rateCaption(rate), systemImage: "checkmark")
                            } else {
                                Text(Self.rateCaption(rate))
                            }
                        }
                    }
                } label: {
                    quickActionVisual(
                        systemName: "gauge",
                        caption: abs(player.rate - 1) < 0.001 ? L("player.speed") : Self.rateCaption(player.rate),
                        isActive: abs(player.rate - 1) >= 0.001
                    )
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel(L("player.speed"))
                .frame(maxWidth: .infinity)
            }

            Button {
                resetTimer()
                cycleVideoAspectMode()
            } label: {
                quickActionVisual(systemName: selectedAspectMode.iconName, caption: aspectCaption, isActive: selectedAspectMode == .fill)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel(selectedAspectMode.accessibilityLabel)
            .frame(maxWidth: .infinity)

            Menu {
                Button {
                    resetTimer()
                    armSleepTimer(minutes: nil)
                } label: {
                    if sleepTimerMinutes == nil {
                        Label(L("player.sleep_timer.off"), systemImage: "checkmark")
                    } else {
                        Text(L("player.sleep_timer.off"))
                    }
                }
                ForEach(Self.sleepTimerOptions, id: \.self) { minutes in
                    Button {
                        resetTimer()
                        armSleepTimer(minutes: minutes)
                    } label: {
                        if sleepTimerMinutes == minutes {
                            Label(L("player.sleep_timer.minutes", minutes), systemImage: "checkmark")
                        } else {
                            Text(L("player.sleep_timer.minutes", minutes))
                        }
                    }
                }
            } label: {
                quickActionVisual(
                    systemName: sleepTimerMinutes == nil ? "moon.fill" : "moon.zzz.fill",
                    caption: sleepTimerMinutes.map { L("player.sleep_timer.minutes", $0) } ?? L("player.sleep_timer.short"),
                    isActive: sleepTimerMinutes != nil
                )
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel(L("player.sleep_timer"))
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .onAppear { player.updateTracks() }
    }

    @ViewBuilder
    private var audioTrackMenuItems: some View {
        if player.audioTracks.isEmpty {
            Text(L("player.tracks.empty.audio"))
        } else {
            ForEach(player.audioTracks) { track in
                Button {
                    resetTimer()
                    player.selectAudioTrack(id: track.id)
                } label: {
                    if player.currentAudioTrackId == track.id {
                        Label(track.title, systemImage: "checkmark")
                    } else {
                        Text(track.title)
                    }
                }
            }
        }
        Divider()
        Button {
            resetTimer()
            openTrackSettings(focus: .audio)
        } label: {
            Label(L("player.tracks.more"), systemImage: "slider.horizontal.3")
        }
    }

    @ViewBuilder
    private var subtitleMenuItems: some View {
        ForEach(player.subtitleTracks) { track in
            Button {
                resetTimer()
                player.selectSubtitleTrack(id: track.id)
            } label: {
                if player.currentSubtitleTrackId == track.id {
                    Label(track.title, systemImage: "checkmark")
                } else {
                    Text(track.title)
                }
            }
        }
        Divider()
        Button {
            resetTimer()
            openTrackSettings(focus: .subtitle)
        } label: {
            Label(L("player.tracks.more"), systemImage: "slider.horizontal.3")
        }
    }

    /// The Fill/Fit button's caption is the CURRENT mode's localized
    /// name — tapping cycles fit → fill → 1:1 (the aspect cycle).
    private var aspectCaption: String {
        switch selectedAspectMode {
        case .fit: return L("player.aspect_fit")
        case .fill: return L("player.aspect_fill")
        case .center: return L("player.aspect_native")
        }
    }

    private static let playbackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private static let sleepTimerOptions: [Int] = [15, 30, 45, 60]

    private static func rateCaption(_ rate: Float) -> String {
        rate.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(rate))×"
            : String(format: "%g×", Double(rate))
    }

    /// Round 11 (kept): Settings ▸ Player ▸ "Default sleep timer" —
    /// armed once when this player opens, and only when the user
    /// has not already set a timer for this session.
    private func applyDefaultSleepTimerIfNeeded() {
        guard !didApplyDefaultSleepTimer else { return }
        didApplyDefaultSleepTimer = true
        guard defaultSleepTimerMinutes > 0, sleepTimerMinutes == nil else { return }
        armSleepTimer(minutes: defaultSleepTimerMinutes)
    }

    /// Arms (or disarms, with nil) the REAL sleep timer: a one-shot
    /// Timer that pauses playback when the chosen minutes elapse.
    private func armSleepTimer(minutes: Int?) {
        sleepCountdownTimer?.invalidate()
        sleepCountdownTimer = nil
        sleepTimerMinutes = minutes
        sleepTimerEndsAt = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        guard let minutes else { return }
        sleepCountdownTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { _ in
            Task { @MainActor in
                if player.isPlaying { player.togglePlayPause() }
                sleepTimerMinutes = nil
                sleepTimerEndsAt = nil
                sleepCountdownTimer = nil
                showControls = true
            }
        }
    }

    /// Whole minutes remaining on the armed sleep timer.
    private func sleepRemainingMinutes(now: Date) -> Int? {
        guard let sleepTimerEndsAt else { return nil }
        return max(1, Int(ceil(sleepTimerEndsAt.timeIntervalSince(now) / 60)))
    }

    private func openTrackSettings(focus: PlaybackTrackSettingsSheet.SectionFocus = .all) {
        player.updateTracks()
        trackSheetFocus = focus
        showTrackSettings = true
    }

    /// Round 12 (point 2): the Playback Tracks panel — a compact,
    /// translucent floating card centered over the video (the owner
    /// rejected the full-screen sheet/page outright). The dimmed
    /// backdrop fills the player area and dismisses on tap; the
    /// panel itself hosts the SAME `PlaybackTrackSettingsSheet`
    /// content (every track/delay/subtitle/import/debug/stream-URL
    /// control, unchanged), now with an injected close action.
    /// Sized off the player geometry: at most 560 pt wide and ~62 %
    /// of the height, always inside the frame with margin.
    private func trackSettingsOverlay(containerSize: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.38)
                .frame(width: containerSize.width, height: containerSize.height)
                .contentShape(Rectangle())
                .onTapGesture { showTrackSettings = false }

            PlaybackTrackSettingsSheet(
                player: player,
                streamURL: url,
                focus: trackSheetFocus,
                onClose: { showTrackSettings = false }
            )
            .frame(
                width: min(max(containerSize.width - 32, 0), 560),
                height: min(containerSize.height * 0.62, max(containerSize.height - 32, 0))
            )
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    AppTheme.surface.opacity(0.88)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        }
        .animation(.easeInOut(duration: 0.22), value: showTrackSettings)
    }

    // MARK: - Round 14/15 player surfaces (failure, end-of-series, seeks, zaps, skip)

    /// Round 14 (A2): the failure card is up when a failure
    /// message exists that the user hasn't already closed the
    /// player over. (Close dismisses the player itself, so the
    /// card never needs a separate dismissed flag in practice;
    /// `dismissedFailureMessage` covers the expired-view's own
    /// close path if it is ever reused in place.)
    private var showFailureCard: Bool {
        hasPlaybackFailure
            && (player.playbackFailureMessage ?? nil) != dismissedFailureMessage
    }

    /// The centered failure card: real cause (from the engine's
    /// mapping — HTTP status / refusal / codec), plain language,
    /// one Close that leaves the player. Accent is AppTheme.live
    /// (round 15, B9 — no hard-coded reds in the player).
    private func playbackFailureCard(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(AppTheme.live)
            Text(L("player.playback_error"))
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                performPlayerDismiss()
            } label: {
                Text(L("common.close"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.accent, in: Capsule())
            }
            .buttonStyle(PressScaleButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .padding(.horizontal, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("player.playback_error"))
        .accessibilityValue(message)
    }

    /// Round 15 (B8): shown when the last episode of a series
    /// ends. Watch again replays THIS episode from the start
    /// (the engine's completed-state play seeks to 0 itself).
    private var endOfSeriesCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(AppTheme.accent)
            Text(L("player.series_finished.title"))
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    performPlayerDismiss()
                } label: {
                    Text(L("common.back"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(PressScaleButtonStyle())

                Button {
                    resetTimer()
                    player.seekAbsolute(to: 0)
                    if !player.isPlaying { player.togglePlayPause() }
                    showControls = true
                } label: {
                    Text(L("player.series_finished.watch_again"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(AppTheme.accent, in: Capsule())
                }
                .buttonStyle(PressScaleButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .padding(.horizontal, 28)
    }

    /// Round 14 (B12): the double-tap seek indicator glyph —
    /// arrow + seconds, matching the ±10 transport symbols.
    private func skipSeekIndicator(forward: Bool) -> some View {
        Image(systemName: forward ? "goforward.10" : "gobackward.10")
            .font(.system(size: 40, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 84, height: 84)
            .background(Color.black.opacity(0.35), in: Circle())
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    /// Round 14 (B12): double-tap seek — the same ±10 s jump and
    /// the same rigid haptic as the center transport buttons,
    /// plus the visual indicator above.
    private func handleDoubleTapSeek(forward: Bool) {
        guard effectiveSeekable, !hasPlaybackFailure else { return }
        noteUserInteraction()
        player.jump(seconds: forward ? 10 : -10)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        skipIndicatorToken &+= 1
        let token = skipIndicatorToken
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            skipIndicatorDirection = forward ? 1 : -1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard token == skipIndicatorToken else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                skipIndicatorDirection = nil
            }
        }
    }

    /// Round 14 (B3): fullscreen live channel zap — swipe up =
    /// next channel, swipe down = previous, through the shell's
    /// existing prev/next callbacks (same path as the on-screen
    /// channel buttons). Settings contract (round 14/15), read
    /// fresh at trigger time: "player.zappingEnabled" gates the
    /// gesture (default ON — an unset key means enabled);
    /// "player.zappingDirection" is "upNext" (default, swipe up
    /// = next) or "downNext" (swipe DOWN = next, inverting the
    /// incoming direction).
    private func handleChannelZap(direction: Int) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "player.zappingEnabled") != nil,
           !defaults.bool(forKey: "player.zappingEnabled") {
            return
        }
        let effectiveDirection =
            defaults.string(forKey: "player.zappingDirection") == "downNext"
                ? -direction
                : direction
        if effectiveDirection > 0 {
            guard let next = onNextChannel else { return }
            next()
        } else {
            guard let previous = onPreviousChannel else { return }
            previous()
        }
        noteUserInteraction()
        lastZapAt = Date()
        UISelectionFeedbackGenerator().selectionChanged()
        // A zap swipe down also feeds the pull-down dismiss drag;
        // snap any partial morph back so the zap reads as a zap.
        if miniProgress > 0, !isMiniCommitted {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                miniProgress = 0
            }
        }
    }

    // MARK: - Round 15 (C8): per-series learned Skip Intro

    private var learnedSkipKey: String? {
        guard type == "series", let seriesId else { return nil }
        return "player.learnedSkip.\(seriesId)"
    }

    /// The landing position (absolute seconds) learned for this
    /// series, if the user has ever pressed Skip Intro in it.
    private var learnedSkipSeconds: Double? {
        guard let learnedSkipKey else { return nil }
        let value = UserDefaults.standard.double(forKey: learnedSkipKey)
        return value > 0 ? value : nil
    }

    /// Where Skip Intro lands: the learned per-series position
    /// when present, else the generic Settings length from here.
    private var skipIntroTargetSeconds: Double {
        learnedSkipSeconds ?? Double(skipIntroLengthSeconds)
    }

    private var skipIntroVisible: Bool {
        showSkipIntro && !isLiveStream && player.durationMs > 0
            && Double(player.timeMs) / 1000.0 < skipIntroTargetSeconds
            && !hasPlaybackFailure
    }

    private func performSkipIntro() {
        if let learned = learnedSkipSeconds {
            // Learned path: jump to the ABSOLUTE learned landing
            // position for this series.
            player.seekAbsolute(to: learned)
            return
        }
        // Generic path (unchanged jump), and — for series only —
        // LEARN the actual landing position for next time.
        let landing = Double(player.timeMs) / 1000.0 + Double(skipIntroLengthSeconds)
        player.jump(seconds: skipIntroLengthSeconds)
        if let learnedSkipKey {
            UserDefaults.standard.set(landing, forKey: learnedSkipKey)
        }
    }

    /// In the compact horizontal size class (iPhone), a tighter layout — leaves horizontal
    /// room for the edge sliders. On regular (iPad), the wide original layout.
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    private var transportSpacing: CGFloat { isCompactWidth ? 22 : 56 }
    private var transportSkipHit: CGFloat { isCompactWidth ? 52 : 64 }
    private var transportSkipSymbol: CGFloat { isCompactWidth ? 30 : 36 }
    private var transportPlayHit: CGFloat { isCompactWidth ? 84 : 96 }
    private var transportPlaySymbol: CGFloat { isCompactWidth ? 46 : 52 }

    /// Round 19 (R19-1a): the center transport follows the STRONG
    /// arrangement, realized as in the owner's Super X photo:
    /// [prev] [-10s] [BIG pause/play disc] [+10s] [next] — the
    /// flanks are episode prev/next on series, channel prev/next on
    /// live (where there are no +-10 skips: live is not seekable),
    /// and — round 20 (R20-2) — queue prev/next on movies opened
    /// with a queue, identical in form to the episode flanks.
    /// The disc is the Super X dark-blur circle (ultraThinMaterial +
    /// black 30% + white hairline), NOT STRONG's gold fill.
    private var centerTransport: some View {
        HStack(spacing: (showSeriesEpisodeSkip || showLiveChannelSkip || showVODQueueSkip) ? (isCompactWidth ? 14 : 26) : transportSpacing) {
            if showLiveChannelSkip && !isCenterTransportLoading {
                transparentTransportButton(
                    systemName: "backward.end.fill",
                    symbolSize: 24,
                    hitFrame: 44
                ) {
                    onPreviousChannel?()
                }
                .accessibilityLabel(L("player.a11y.previous_channel"))
                .disabled(!canGoToPreviousChannel || hasPlaybackFailure)
                .opacity(!canGoToPreviousChannel || hasPlaybackFailure ? 0.38 : 1)
            }

            if showSeriesEpisodeSkip && !isCenterTransportLoading {
                transparentTransportButton(
                    systemName: "backward.end.fill",
                    symbolSize: 24,
                    hitFrame: 44
                ) {
                    onPreviousEpisode?()
                }
                .accessibilityLabel(L("player.a11y.previous_episode"))
                .disabled(!canGoToPreviousEpisode || hasPlaybackFailure)
                .opacity(!canGoToPreviousEpisode || hasPlaybackFailure ? 0.38 : 1)
            }

            // Round 20 (R20-2): the movie player is the series
            // player — a movie opened with a queue (VODPlayerShell,
            // M3U VOD queue) gets the SAME prev/next flanks in the
            // SAME position, size and treatment as the series
            // episode flanks above, driven by the queue callbacks
            // those shells already pass. (Round 19 moved prev/next
            // into the center transport but wired only the live
            // and series flanks; `showVODQueueSkip` was left
            // orphaned and the movie queue callbacks were dead
            // on screen.)
            if showVODQueueSkip && !isCenterTransportLoading {
                transparentTransportButton(
                    systemName: "backward.end.fill",
                    symbolSize: 24,
                    hitFrame: 44
                ) {
                    onPreviousChannel?()
                }
                .accessibilityLabel(L("player.a11y.previous_item"))
                .disabled(!canGoToPreviousChannel || hasPlaybackFailure)
                .opacity(!canGoToPreviousChannel || hasPlaybackFailure ? 0.38 : 1)
            }

            if effectiveSeekable && !isCenterTransportLoading {
                transparentTransportButton(
                    systemName: "gobackward.10",
                    symbolSize: transportSkipSymbol,
                    hitFrame: transportSkipHit
                ) {
                    player.jump(seconds: -10)
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
                .accessibilityLabel(L("player.a11y.skip_back_10"))
                .disabled(hasPlaybackFailure)
                .opacity(hasPlaybackFailure ? 0.4 : 1)
            }

            centerPlayPauseOrLoadingButton

            if effectiveSeekable && !isCenterTransportLoading {
                transparentTransportButton(
                    systemName: "goforward.10",
                    symbolSize: transportSkipSymbol,
                    hitFrame: transportSkipHit
                ) {
                    player.jump(seconds: 10)
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
                .accessibilityLabel(L("player.a11y.skip_forward_10"))
                .disabled(hasPlaybackFailure)
                .opacity(hasPlaybackFailure ? 0.4 : 1)
            }

            if showSeriesEpisodeSkip && !isCenterTransportLoading {
                transparentTransportButton(
                    systemName: "forward.end.fill",
                    symbolSize: 24,
                    hitFrame: 44
                ) {
                    onNextEpisode?()
                }
                .accessibilityLabel(L("player.a11y.next_episode"))
                .disabled(!canGoToNextEpisode || hasPlaybackFailure)
                .opacity(!canGoToNextEpisode || hasPlaybackFailure ? 0.38 : 1)
            }

            // Round 20 (R20-2): next-movie flank — the mirror of
            // the prev-movie flank above (see its note).
            if showVODQueueSkip && !isCenterTransportLoading {
                transparentTransportButton(
                    systemName: "forward.end.fill",
                    symbolSize: 24,
                    hitFrame: 44
                ) {
                    onNextChannel?()
                }
                .accessibilityLabel(L("player.a11y.next_item"))
                .disabled(!canGoToNextChannel || hasPlaybackFailure)
                .opacity(!canGoToNextChannel || hasPlaybackFailure ? 0.38 : 1)
            }

            if showLiveChannelSkip && !isCenterTransportLoading {
                transparentTransportButton(
                    systemName: "forward.end.fill",
                    symbolSize: 24,
                    hitFrame: 44
                ) {
                    onNextChannel?()
                }
                .accessibilityLabel(L("player.a11y.next_channel"))
                .disabled(!canGoToNextChannel || hasPlaybackFailure)
                .opacity(!canGoToNextChannel || hasPlaybackFailure ? 0.38 : 1)
            }
        }
        .padding(.vertical, 8)
    }

    /// Orta: yüklenirken `ProgressView`, hazır olunca oynat / duraklat.
    /// Round 19: play/pause is a BIG circular button — a dark blur
    /// disc with a white glyph (the Super X photo's center anchor) —
    /// instead of the bare symbol the pre-restyle player used.
    private var centerPlayPauseOrLoadingButton: some View {
        Group {
            if isCenterTransportLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white.opacity(0.95))
                    .scaleEffect(1.6)
                    .frame(width: transportPlayHit, height: transportPlayHit)
                    .allowsHitTesting(false)
            } else {
                Button {
                    resetTimer()
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: transportPlaySymbol, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: transportPlayHit, height: transportPlayHit)
                        .background {
                            ZStack {
                                Circle().fill(.ultraThinMaterial)
                                Circle().fill(Color.black.opacity(0.30))
                            }
                        }
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                        .contentShape(Circle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel(player.isPlaying ? L("player.a11y.pause") : L("player.a11y.play"))
                .disabled(hasPlaybackFailure)
                .opacity(hasPlaybackFailure ? 0.4 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isCenterTransportLoading)
    }

    /// Glass arkaplansız iOS native stili transport butonu: SF Symbol + subtle shadow.
    private func transparentTransportButton(
        systemName: String,
        symbolSize: CGFloat,
        hitFrame: CGFloat = 64,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            resetTimer()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
                .shadow(color: .black.opacity(0.45), radius: 5, y: 1)
                .frame(width: hitFrame, height: hitFrame)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Round 19 (R19-1a/1b): the bottom chrome is the ONE
    /// quick-actions row above the scrub timeline (the arrangement
    /// in the owner's photos), for every content type through this
    /// single PlayerView. The old trailing glass rows (live channel
    /// skip/list, series episode skip, VOD queue skip) are gone:
    /// channel/episode prev/next moved into the center transport
    /// and the channel list opens from the row's Guide button.
    private var bottomTransportChrome: some View {
        VStack(alignment: .trailing, spacing: 10) {
            quickActionsRow

            if !isLiveStream {
                scrubTimelineCard
            }
        }
    }

    /// iOS native player stili: kartsız, düz düzen; okunabilirlik alt gradient'ten gelir.
    private var scrubTimelineCard: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(isScrubbing ? formatMs(Int(scrubValue * Double(player.durationMs))) : formatMs(Int(player.timeMs)))
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 0.5)
                .frame(minWidth: 52, alignment: .leading)

            PlayerTimeline(
                value: sliderBinding,
                isSeekable: effectiveSeekable,
                onEditingChanged: { editing in
                    if editing {
                        if isFastForwarding { applySpeedHoldEnded() }
                        resetTimer()
                        isScrubbing = true
                        scrubValue = displayedSliderPosition
                    } else {
                        let target = scrubValue
                        lockedSliderValue = target
                        player.seek(to: Float(target))
                        isScrubbing = false
                        resetTimer()
                        sliderUnlockGeneration += 1
                        let gen = sliderUnlockGeneration
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 2_800_000_000)
                            guard gen == sliderUnlockGeneration else { return }
                            lockedSliderValue = nil
                        }
                    }
                },
                onDragValue: { dragVal in
                    scrubValue = dragVal
                    // Each drag tick postpones auto-hide; otherwise a >5 s scrub would
                    // remove the timeline mid-gesture (drag cancelled, seek lost).
                    resetTimer()
                }
            )
            .layoutPriority(1)
            // DragGesture VoiceOver altında erişilemez; kaydırıcıyı ayarlanabilir öğe
            // olarak sun (yan parlaklık/ses slider'larıyla aynı desen). ±10 sn adım,
            // round 19 center transport'un goforward/gobackward.10 butonlarıyla tutarlı.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("player.a11y.playback_position"))
            .accessibilityValue("\(formatMs(Int(player.timeMs))) / \(totalDurationLabel)")
            .accessibilityAdjustableAction { direction in
                guard effectiveSeekable else { return }
                resetTimer()
                switch direction {
                case .increment: player.jump(seconds: 10)
                case .decrement: player.jump(seconds: -10)
                @unknown default: break
                }
            }

            Text(totalDurationLabel)
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 0.5)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    private var totalDurationLabel: String {
        if isLiveStream { return L("player.live_badge") }
        if player.durationMs > 500 { return formatMs(Int(player.durationMs)) }
        return "--:--"
    }

    private func formatMs(_ ms: Int) -> String {
        let totalSeconds = max(ms, 0) / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // Round 16 (R6): appendBitrateSample / formatBitrate removed
    // with the debug overlay — nothing else read the samples.

    private func glassIconButton(
        systemName: String, size: CGFloat,
        symbolSize: CGFloat? = nil,
        // Round 15 (C1): every glass button in the player carries
        // a translated VoiceOver label, passed through to
        // `GlassSystemIconButton`.
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        GlassSystemIconButton(
            systemName: systemName,
            pointSize: symbolSize ?? size * 0.34,
            buttonSize: size,
            accessibilityLabel: accessibilityLabel,
            action: {
                resetTimer()
                action()
            }
        )
    }

    // MARK: - Orientation (round 9)

    /// Landscape exists ONLY inside the fullscreen player: fullscreen
    /// raises the AppDelegate lock to free rotation; the mini card and
    /// dismissal restore the portrait browse lock. (The unreferenced
    /// `LiveChannelBrowserScreen` below assigns the lock directly to
    /// force `.landscape` over the player and restores the player's
    /// mask on exit — untouched by this change.)
    private func syncOrientationLockForPlayerMode() {
        if overlayMode == .fullscreen {
            AppDelegate.setOrientationLock(.allButUpsideDown)
        } else {
            restoreBrowseOrientationLock()
        }
    }

    private func restoreBrowseOrientationLock() {
        let browse = AppDelegate.browseOrientationLock
        AppDelegate.setOrientationLock(
            browse,
            forceOrientation: browse == .portrait ? .portrait : nil
        )
    }

    /// Trailing clearance for the bottom-trailing pills (Skip Intro,
    /// auto-advance): their right edge must stay LEFT of the volume
    /// gesture capsule in every orientation, so the pill never sits on
    /// the slider zone whether the chrome (and with it the sliders) is
    /// shown or hidden — the pills' show/hide animation is vertical
    /// only, this horizontal offset is constant.
    private func pillTrailingPadding(_ insets: EdgeInsets) -> CGFloat {
        // Round 10: the visible gap past the capsule grows 12 → 20 —
        // with the inset now exact (see the Skip Intro fix), 12 pt
        // still read as "touching" on the owner's recording.
        16 + insets.trailing
            + PlayerControlCenterStyleEdgeSliders.trackSize(isCompactWidth: isCompactWidth).width
            + 20
        
    }

    /// Leading clearance for the bottom-LEADING Skip Intro pill
    /// (round 11): the mirror of `pillTrailingPadding` — the pill's
    /// left edge starts past the brightness gesture capsule (edge
    /// padding 16 + safe-area inset + capsule width) plus a 20 pt
    /// gap, so the pill clears the left bar exactly as the
    /// auto-advance pill clears the right one.
    private func pillLeadingPadding(_ insets: EdgeInsets) -> CGFloat {
        16 + insets.leading
            + PlayerControlCenterStyleEdgeSliders.trackSize(isCompactWidth: isCompactWidth).width
            + 20
        
    }

    // Round 17 (R17-3): `transportRowTrailingClearance` was deleted
    // with the floating bottom rows it served — nothing in the
    // bottom chrome reaches toward the volume capsule anymore.

    private func resetTimer() {
        // Round 15 (C8): every control in the player funnels its
        // interaction through here — that makes this the single
        // "the user is present" signal for the still-watching
        // counter.
        noteUserInteraction()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            // Never hide the chrome mid-scrub: removing the timeline cancels the drag
            // without onEditingChanged(false), leaking isScrubbing=true and dropping
            // the seek. A held-still thumb schedules no drag ticks, so guard here too.
            guard !isScrubbing else {
                resetTimer()
                return
            }
            // Cross-fade out like the native player instead of a hard cut.
            withAnimation(.easeInOut(duration: 0.28)) { showControls = false }
        }
    }

    private func resetVideoTransformForAspectSwitch() {
        withAnimation(.easeInOut(duration: 0.2)) {
            videoPinchBase = 1
            videoZoomPan.pinchLive = 1
            videoPanCommitted = .zero
        }
    }

    private func applySelectedAspectMode(force: Bool = false) {
        player.setAspectMode(selectedAspectMode, force: force)
    }

    /// Round 20 (R20-3/R20-4): ONE-TIME migration of the persisted
    /// aspect mode, superseding round 19's (whose flag is already
    /// consumed on the owner's phone, so it can never run again).
    /// Proven build-54 mechanism: the ONLY source of the series
    /// zoom-crop is the persisted `player.videoAspectMode = "fill"`
    /// — the surface's cover transform (`aspectFillScale`) is
    /// non-1 only in `.fill`, the mode is read from this single key
    /// by the one shared PlayerView for movies, series and live
    /// alike (no shell or per-type override exists), and the
    /// owner's own build-54 recording shows Settings ▸ "Default
    /// video fit" = Fill, i.e. the stored value was "fill" on
    /// build 54 despite round 19's migration. That migration was
    /// one-time and player-appear-only, while the key keeps TWO
    /// live writers pristine build 33 does not gate: the in-player
    /// aspect cycle button and the round-14 Settings picker (plus
    /// settings-backup import) — any one write of "fill" after the
    /// flag was consumed re-persists Fill for every later open,
    /// and the migration could never correct it again. This R20
    /// migration therefore resets the persisted value to Fit
    /// exactly once on build 55, so the phone starts in Fit
    /// (whole frame) on ALL types like a fresh build-33 install.
    /// The single source of truth stays this one AppStorage key,
    /// exactly as in build 33: deliberate in-session cycling to
    /// Fill afterwards still works and persists, unchanged.
    private func migratePersistedAspectModeIfNeeded() {
        let key = "player.aspectModeMigratedR20"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if videoAspectModeRaw != VideoAspectMode.fit.rawValue {
            videoAspectModeRaw = VideoAspectMode.fit.rawValue
        }
    }

    private func showAspectToast() {
        aspectToastToken &+= 1
        let token = aspectToastToken
        withAnimation(.easeInOut(duration: 0.18)) {
            aspectToastText = selectedAspectMode.title
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard token == aspectToastToken else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                aspectToastText = nil
            }
        }
    }
}

/// Applies `.clipped()` only when needed, so fit/center playback avoids the extra
/// offscreen compositing pass (cheaper on open and during the pull-down morph).
private struct ConditionalClip: ViewModifier {
    let active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if active { content.clipped() } else { content }
    }
}

struct LiveChannelBrowserScreen: View {
    let sections: [LiveChannelCategorySection]
    let currentStreamId: Int?
    let onSelectChannel: (DBLiveStream) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategoryId: String
    @State private var highlightedStreamId: Int

    init(
        sections: [LiveChannelCategorySection],
        currentStreamId: Int?,
        onSelectChannel: @escaping (DBLiveStream) -> Void
    ) {
        self.sections = sections
        self.currentStreamId = currentStreamId
        self.onSelectChannel = onSelectChannel
        let firstSectionId = sections.first?.id ?? "all"
        let categoryIdForCurrentStream: String? = {
            guard let sid = currentStreamId else { return nil }
            return sections.first(where: { $0.streams.contains(where: { $0.streamId == sid }) })?.id
        }()
        let initialCategoryId = categoryIdForCurrentStream ?? firstSectionId
        let initialStreamId = currentStreamId
            ?? sections.first(where: { $0.id == initialCategoryId })?.streams.first?.streamId
            ?? sections.first?.streams.first?.streamId
            ?? 0
        _selectedCategoryId = State(initialValue: initialCategoryId)
        _highlightedStreamId = State(initialValue: initialStreamId)
    }

    private var activeSection: LiveChannelCategorySection? {
        sections.first(where: { $0.id == selectedCategoryId }) ?? sections.first
    }

    private var currentStreams: [DBLiveStream] {
        activeSection?.streams ?? []
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                categoryHorizontalBar
                channelListColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(L("dashboard.channels"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.body.weight(.semibold))
                }
                .tint(.white)
                .buttonStyle(.plain)
                .accessibilityLabel(L("common.back"))
            }
        }
        .onAppear {
            AppDelegate.orientationLock = .landscape
            requestLandscapeGeometryUpdateIfPossible()
            syncSelectionToCurrentStreamIfPossible()
        }
        .onDisappear {
            AppDelegate.orientationLock = .allButUpsideDown
        }
    }

    /// If the selected channel is in `currentStreams`, align it with the list (first open and category change).
    private func scrollChannelListToHighlightedItem(proxy: ScrollViewProxy) {
        guard let stream = currentStreams.first(where: { $0.streamId == highlightedStreamId }) else { return }
        Task { @MainActor in
            // A short delay for the LazyVStack measurement; otherwise scrollTo sometimes has no effect.
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(stream.id, anchor: .center)
            }
        }
    }

    private func requestLandscapeGeometryUpdateIfPossible() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let prefs = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: UIInterfaceOrientationMask.landscape
        )
        scene.requestGeometryUpdate(prefs) { _ in }
    }

    private func syncSelectionToCurrentStreamIfPossible() {
        guard let sid = currentStreamId else { return }
        guard let section = sections.first(where: { $0.streams.contains(where: { $0.streamId == sid }) }) else { return }
        if selectedCategoryId != section.id {
            selectedCategoryId = section.id
        }
        if highlightedStreamId != sid {
            highlightedStreamId = sid
        }
    }

    /// Horizontally scrolling categories under the heading. `fixedSize` is used so the horizontal ScrollView doesn't swell vertically.
    private var categoryHorizontalBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 9) {
                ForEach(sections) { section in
                    Button {
                        selectedCategoryId = section.id
                    } label: {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selectedCategoryId == section.id ? AppTheme.accent : Color.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.white.opacity(0.06))
    }

    private var channelListColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(currentStreams) { stream in
                        channelListRow(stream: stream)
                            .id(stream.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.06))
            .onAppear {
                scrollChannelListToHighlightedItem(proxy: proxy)
            }
            .onChange(of: selectedCategoryId) { _, _ in
                scrollChannelListToHighlightedItem(proxy: proxy)
            }
            .onChange(of: highlightedStreamId) { _, _ in
                scrollChannelListToHighlightedItem(proxy: proxy)
            }
        }
    }

    private func channelListRow(stream: DBLiveStream) -> some View {
        let isSelected = stream.streamId == highlightedStreamId
        let isCurrent = stream.streamId == currentStreamId
        return Button {
            highlightedStreamId = stream.streamId
            onSelectChannel(stream)
        } label: {
            HStack(spacing: 8) {
                CachedImage(
                    url: stream.streamIcon.flatMap { URL(string: $0) },
                    width: 30,
                    height: 30,
                    cornerRadius: 7,
                    iconName: "tv",
                    loadProfile: .standard
                )
                Text(stream.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isCurrent {
                    Text(L("player.live_on_air"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(AppTheme.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(channelRowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    private func channelRowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
    }
}

/// The bottom horizontal panel used to show the channel list in the live player without interrupting playback.
/// At the top there are horizontal category chips; at the bottom, horizontally scrolled channel cards.
struct LiveChannelSidePanel: View {
    let sections: [ChannelPanelSection]
    let currentItemId: String?
    let onSelectChannel: (String) -> Void

    @State private var selectedCategoryId: String

    init(
        sections: [ChannelPanelSection],
        currentItemId: String?,
        onSelectChannel: @escaping (String) -> Void
    ) {
        self.sections = sections
        self.currentItemId = currentItemId
        self.onSelectChannel = onSelectChannel
        let initialId: String = {
            if let cid = currentItemId,
               let match = sections.first(where: { section in
                   section.items.contains(where: { $0.id == cid })
               }) {
                return match.id
            }
            return sections.first?.id ?? ""
        }()
        _selectedCategoryId = State(initialValue: initialId)
    }

    private var activeItems: [ChannelPanelItem] {
        sections.first(where: { $0.id == selectedCategoryId })?.items ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            categoryPicker
            channelStrip
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.55))
        .overlay(alignment: .top) {
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(Color.white.opacity(0.18))
        }
        .contentShape(Rectangle())
    }

    private var categoryPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(sections) { section in
                        Button {
                            selectedCategoryId = section.id
                        } label: {
                            Text(section.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(selectedCategoryId == section.id ? AppTheme.accent : Color.white.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                        .id(section.id)
                    }
                }
                .padding(.horizontal, 14)
            }
            .onAppear { scrollToSelectedCategory(proxy: proxy) }
            .onChange(of: selectedCategoryId) { _, _ in
                scrollToSelectedCategory(proxy: proxy)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func scrollToSelectedCategory(proxy: ScrollViewProxy) {
        guard sections.contains(where: { $0.id == selectedCategoryId }) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(selectedCategoryId, anchor: .center)
            }
        }
    }

    private var channelStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(activeItems) { item in
                        channelCard(item: item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .frame(height: 104)
            .onAppear { scrollToCurrent(proxy: proxy) }
            .onChange(of: selectedCategoryId) { _, _ in
                scrollToCurrent(proxy: proxy)
            }
            .onChange(of: currentItemId) { _, _ in
                syncCategoryToCurrentIfNeeded()
                scrollToCurrent(proxy: proxy)
            }
        }
    }

    private func scrollToCurrent(proxy: ScrollViewProxy) {
        guard let cid = currentItemId,
              activeItems.contains(where: { $0.id == cid }) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(cid, anchor: .center)
            }
        }
    }

    private func syncCategoryToCurrentIfNeeded() {
        guard let cid = currentItemId else { return }
        guard let section = sections.first(where: { $0.items.contains(where: { $0.id == cid }) }) else { return }
        if selectedCategoryId != section.id {
            selectedCategoryId = section.id
        }
    }

    private func channelCard(item: ChannelPanelItem) -> some View {
        let isCurrent = item.id == currentItemId
        return Button {
            onSelectChannel(item.id)
        } label: {
            VStack(alignment: .center, spacing: 6) {
                CachedImage(
                    url: item.iconURL,
                    width: 56,
                    height: 56,
                    cornerRadius: 10,
                    iconName: "tv",
                    loadProfile: .standard
                )
                Text(item.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 72)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCurrent ? Color.white.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct WatchHistoryTags: Equatable {
    let playlistId: UUID
    let streamId: String
    let type: String
    let seriesId: String?
    let title: String
    let secondaryTitle: String?
    let imageURL: String?
    let containerExtension: String?
}
