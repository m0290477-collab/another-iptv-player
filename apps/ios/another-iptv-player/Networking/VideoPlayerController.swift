import AVFoundation
import Combine
import Foundation
import KSPlayer
import MediaPlayer
import SwiftUI
import UIKit
import os

struct TrackMenuOption: Identifiable, Hashable {
  let id: Int
  let title: String
  let detail: String?
  let langCode: String?
  /// mpv `track-list/N/external`: external file track added via `sub-add`.
  let isExternal: Bool
  /// The title is not real metadata; it is derived from the index (like "Part 2"). It should NOT be SAVED
  /// as a preference — it would select an unrelated segment at the same position in the next video.
  let isSyntheticTitle: Bool

  init(id: Int, title: String, detail: String? = nil, langCode: String? = nil, isExternal: Bool = false, isSyntheticTitle: Bool = false) {
    self.id = id
    self.title = title
    self.detail = detail
    self.langCode = langCode
    self.isExternal = isExternal
    self.isSyntheticTitle = isSyntheticTitle
  }
}

enum VideoPlayerState: Int {
  case idle = 0
  case loading = 1
  case buffering = 2
  case playing = 3
  case paused = 4
  case stopped = 5
  case ended = 6
  case error = 7
}

/// The three aspect presentations the player cycles through. Named fixed ratios
/// (16:9/4:3/16:10) were removed: they only ever pillar/letter-boxed the source at
/// its natural ratio inside a forced frame — indistinguishable from Fit for most
/// content and misleading. Fit / Fill / Center covers the real intents (respect the
/// source, crop-to-fill the screen, or map 1:1) — same set AVPlayer/Infuse expose.
enum VideoAspectMode: String, CaseIterable {
  /// Aspect-fit: source shown at its natural ratio, letter/pillar-boxed to fit the screen.
  case fit
  /// Zoom-to-fill: source scaled to cover the whole screen at its natural ratio; overflow cropped.
  case fill
  /// 1:1 pixel mapping (downscaled only if it doesn't fit).
  case center

  var iconName: String {
    switch self {
    case .fit: return "rectangle.arrowtriangle.2.inward"
    case .fill: return "rectangle.arrowtriangle.2.outward"
    case .center: return "square.dashed"
    }
  }

  var title: String {
    switch self {
    case .fit: return "Fit"
    case .fill: return "Fill"
    case .center: return "1:1"
    }
  }

  var accessibilityLabel: String {
    "Aspect ratio: \(title)"
  }
}

/// `PlayerView` köprüsü: `KSPlayerEngine` + Now Playing / uzaktan kumanda.
final class VideoPlayerController: ObservableObject {
  /// SwiftUI may construct the incoming player before the outgoing player's
  /// `onDisappear` runs. Weak process-level registration lets the new controller
  /// see and claim an active AirPlay owner during that overlap window.
  private final class WeakControllerReference {
    weak var value: VideoPlayerController?
    init(_ value: VideoPlayerController) { self.value = value }
  }

  private static var activeControllerReferences: [WeakControllerReference] = []

  private static func register(_ controller: VideoPlayerController) {
    activeControllerReferences.removeAll { $0.value == nil }
    activeControllerReferences.append(WeakControllerReference(controller))
  }

  private static func unregister(_ controller: VideoPlayerController) {
    activeControllerReferences.removeAll { $0.value == nil || $0.value === controller }
  }

  private static func engagedCastController() -> CastController? {
    activeControllerReferences.removeAll { $0.value == nil }
    return activeControllerReferences.lazy
      .compactMap(\.value)
      .filter { !$0.isTornDown }
      .compactMap(\.castController)
      .first { $0.isEngaged }
  }

  private static func hasNativeExternalPlayback(excluding controller: VideoPlayerController) -> Bool {
    activeControllerReferences.removeAll { $0.value == nil }
    return activeControllerReferences.lazy
      .compactMap(\.value)
      .contains { other in
        other !== controller && !other.isTornDown
          && (other.engine.isExternalPlaybackActive
              || other.isAirPlayPlaybackActive)
      }
  }

  /// AVAudioSession is process-wide while VideoPlayerController is screen-scoped.
  /// A newly opened player claims a newer lease so an older controller's delayed
  /// teardown cannot deactivate the session underneath current playback.
  nonisolated private static let audioSessionLeaseLock = NSLock()
  nonisolated(unsafe) private static var audioSessionLeaseSerial: UInt64 = 0
  nonisolated(unsafe) private static var currentAudioSessionLease: UInt64?

  nonisolated private static func claimAudioSessionLease() -> (token: UInt64, previous: UInt64?) {
    audioSessionLeaseLock.lock()
    defer { audioSessionLeaseLock.unlock() }
    let previous = currentAudioSessionLease
    audioSessionLeaseSerial &+= 1
    currentAudioSessionLease = audioSessionLeaseSerial
    return (audioSessionLeaseSerial, previous)
  }

  nonisolated private static func rollBackAudioSessionLease(
    _ token: UInt64, previous: UInt64?
  ) {
    audioSessionLeaseLock.lock()
    defer { audioSessionLeaseLock.unlock() }
    if currentAudioSessionLease == token {
      currentAudioSessionLease = previous
    }
  }

  nonisolated private static func deactivateAudioSessionIfCurrent(_ token: UInt64) {
    audioSessionLeaseLock.lock()
    defer { audioSessionLeaseLock.unlock() }
    guard currentAudioSessionLease == token else { return }
    currentAudioSessionLease = nil
    try? AVAudioSession.sharedInstance().setActive(
      false, options: .notifyOthersOnDeactivation
    )
  }

  private let log = Logger(
    // Round 16 (R9): fallback names this app's own bundle id
    // (was the upstream project's name; never executes in the
    // shipped app, where the bundle identifier is always present).
    subsystem: Bundle.main.bundleIdentifier ?? "com.irqus.superx",
    category: "VideoPlayer"
  )

  let engine: KSPlayerEngine
  /// AirPlay cast orchestrator. While a cast session is active the engine is fully stopped;
  /// presentation and transport flow through this object.
  let castController: CastController?
  private let castOwnerToken = UUID()

  @Published var state: VideoPlayerState = .idle
  @Published var isPlaying: Bool = false
  @Published var isSeekable: Bool = false
  @Published var position: Float = 0
  @Published var durationMs: Int64 = 0
  @Published var timeMs: Int64 = 0
  @Published var bufferingProgress: Float = 0
  @Published var rate: Float = 1.0
  @Published var videoWidth: Int = 0
  @Published var videoHeight: Int = 0
  @Published var streamFPS: Double = 0
  @Published var renderFPS: Double = 0
  @Published var videoBitrate: Double = 0
  @Published var droppedFrameCount: Int64 = 0
  @Published var delayedFrameCount: Int64 = 0
  @Published var cacheBufferingState: Double = 0
  @Published var cacheDurationSeconds: Double = 0
  @Published var cacheAheadSeconds: Double = 0
  @Published var avSyncSeconds: Double = 0
  @Published var networkSpeedBps: Double = 0
  @Published var hwdecCurrent: String = ""
  @Published var videoCodecName: String = ""
  @Published var seekLatencyMs: Int = -1
  /// Network / loading error (a reflection of `KSPlayerEngine.playbackFailureMessage`).
  @Published var playbackFailureMessage: String?

  /// Build 64 (A3-iii): true while a FRESH presentation's load is
  /// spending the reconnect ladder. PlayerView shows a visible
  /// "Reconnecting…" state for it instead of a silent spinner.
  /// Only fresh presentations raise it — same-item reconnects of
  /// an established session keep the build 61/63 invisible
  /// behavior, and it is never raised during established playback
  /// (the owner's silence-during-playback rule).
  @Published private(set) var isRetryingConnection = false

  @Published var videoTracks: [TrackMenuOption] = []
  @Published var audioTracks: [TrackMenuOption] = []
  @Published var subtitleTracks: [TrackMenuOption] = [TrackMenuOption(id: -1, title: L("player.subtitle_off"))]
  @Published var currentVideoTrackId: Int = -1
  @Published var currentAudioTrackId: Int = -1
  @Published var currentSubtitleTrackId: Int = -1

  @Published var isPiPActive: Bool = false
  /// True only on the KSPlayer/AVPlayer path: real AirPlay external playback is possible.
  @Published private(set) var isAirPlayVideoCapable: Bool = false
  /// For the debug overlay: the active audio codec (AirPlay candidacy diagnosis).
  @Published private(set) var audioCodecName: String = ""
  /// On the FFmpeg path: the AirPlay button first prepares the remux, then opens the system picker.
  @Published private(set) var needsAirPlayPreparation: Bool = false
  /// Cast oturumu sunumda: transport/scrubber cast'e akar, track menüsü pasif.
  @Published private(set) var isCastPresenting: Bool = false
  /// The video is currently playing on the AirPlay target (native external or remux cast);
  /// the "Playing on AirPlay" placeholder is shown on the local surface.
  @Published private(set) var isAirPlayPlaybackActive: Bool = false
  @Published var aspectMode: VideoAspectMode = .fit
  /// Live broadcast flag: updated via `setPlaybackPresentation`. The PiP sample buffer
  /// delegate reads this value to hide the skip controls (mpv duration may return 0 for live).
  @Published var isLiveStream: Bool = false

  /// System screen brightness (0…1). External changes such as Control Center are updated via `brightnessDidChange`.
  @Published private(set) var screenBrightness: CGFloat

  var hdrAvailable: Bool = false

  private struct PendingLoadRequest {
    let url: URL
    let startSeconds: TimeInterval?
    let isLiveStream: Bool
    let userAgent: String?
    /// Build 61 (FA, F-2/G2): the active playlist's custom headers,
    /// carried with the UA so reconnect/stall retries keep them.
    let customHeaders: [String: String]
  }

  private var pendingLoadRequest: PendingLoadRequest?
  /// The last `play(url:)` request — AirPlay preparation and cast handover build content from here.
  private var currentLoadRequest: PendingLoadRequest?
  private var isTornDown = false
  private var audioSessionActivated = false
  private var audioSessionLease: UInt64?
  /// System brightness before the app's first in-player adjustment; restored on teardown
  /// so leaving the player never strands the whole device at the in-video level.
  private var brightnessToRestore: CGFloat?
  private var playbackPresentation: PlaybackPresentation?
  private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
  private var seriesEpisodeOnPrevious: (() -> Void)?
  private var seriesEpisodeOnNext: (() -> Void)?
  /// To re-apply the enabled state when the remote commands are rebuilt.
  private var episodeNavCanPrevious = false
  private var episodeNavCanNext = false
  private var episodeNavSwapSkip = true
  private var cancellables = Set<AnyCancellable>()

  private var nowPlayingArtwork: UIImage?
  /// Round 15 (C11): the artwork fetch is an async task, not a
  /// completion-handler data task.
  private var artworkFetchTask: Task<Void, Never>?
  private var artworkFetchURL: URL?
  private var seekRequestStartedAt: Date?
  private var seekSourceTimeMs: Int64?
  /// When the first `isPlaybackEstablished` event arrives after `play`, the saved track preferences are applied.
  private var pendingPreferredTrackSelection = false
  // === Build 61 (B9, P2): auto-reconnect. ===
  // Round 20 restored build 33's exactly-one silent retry for a
  // recoverable failure; the build-61 SPEC's P2 explicitly
  // supersedes that for this update: a recoverable failure — or a
  // mid-stream stall (see the stall watchdog below) — is retried
  // with backoff, up to 3 attempts, before the failure is allowed
  // to reach the existing failure banner. NO new UI is involved:
  // while a retry is pending or in flight, the failure message is
  // simply not published yet. Reset on every explicit `play(url:)`
  // and on every successful establishment.
  private var autoReconnectAttempts = 0
  /// Build 63 (item 16): true when the CURRENT load directly
  /// replaced a just-stopped stream — either it superseded a
  /// previous load on this controller (zap / next episode) or this
  /// controller was created within seconds of another player's
  /// teardown (close one title, open another). On a
  /// connection-limited panel the previous slot frees a beat AFTER
  /// the old stream stops, so the replacement open can be refused
  /// (HTTP 403/451) or reset (open-stage failure) inside that
  /// window. Both classes are TERMINAL for a cold open (round 14:
  /// retrying a genuinely dead stream only delays the real
  /// message), but a replacement load gets the same bounded
  /// reconnect ladder as a transient failure.
  private var currentLoadMayRetryRefusal = false
  /// Build 64 (A3-iii): whether the CURRENT load is the first load
  /// of a fresh presentation (marked by PlayerView via
  /// `markNextLoadAsFreshPresentation`). On the preserved
  /// controller, `currentLoadMayRetryRefusal` arms from a mere
  /// prior request or a teardown < 20 s ago — in build 63 that
  /// made a FIRST user-initiated load of a new item silently
  /// absorb a refusal for ~12 s of ladder before the honest
  /// banner. The ladder still runs for fresh loads (the
  /// slot-release race is real there too), but the fresh flag
  /// drives the visible `isRetryingConnection` state while it
  /// does, so the wait is never silent.
  private var currentLoadIsFreshPresentation = false
  private var nextLoadIsFreshPresentation = false

  /// Marks the next `play()` call as the first load of a fresh
  /// presentation. One-shot: consumed by that load.
  func markNextLoadAsFreshPresentation() {
    nextLoadIsFreshPresentation = true
  }

  /// When any controller last tore down (stamped in `teardown()`).
  private static var lastTeardownAt: Date?
  private var pendingReconnectWorkItem: DispatchWorkItem?
  private static let reconnectBackoffs: [TimeInterval] = [1, 3, 8]
  private static let maxReconnectAttempts = 3
  /// Stall watchdog: armed while an established stream reports
  /// buffering; if the position has not meaningfully advanced
  /// when it fires, the stream is treated as stalled and a
  /// reconnect is spent on it.
  private var stallWatchdogWorkItem: DispatchWorkItem?
  private static let stallWatchdogDelay: TimeInterval = 20
  /// Build 61 (B9, Q10): the current load's final failure has
  /// been recorded into `ChannelHealthStore` (once per load).
  private var healthFailureRecordedForCurrentLoad = false
  /// Build 61 (B9, E6): wall-clock stamp of the current `play`
  /// request; the first-frame edge turns it into a TTFF sample.
  private var loadRequestedAt: Date?
  private var ttffRecordedForCurrentLoad = false
  private var lastEngineFirstFrame = false
  /// Build 61 (B9, P3 + E2): adaptive buffer state. The base
  /// values are the ones `KSPlayerEngine.makeOptions` applied
  /// from the user's item-7 buffer setting for THIS load — the
  /// tuner only ever moves `preferredForwardBufferDuration`
  /// between the fast-start floor and that base, never above it.
  private var bufferBaseForward: TimeInterval?
  private var bufferRampFloor: TimeInterval = 1
  private var lastBufferHealthCheckAt: Date?
  private var lastBufferAheadSeconds: Double = 0

  /// Imported external subtitles (`ImportedSubtitleStore`): the content key comes from
  /// PlayerView; once playback is established the stored files are re-added to mpv.
  @Published private(set) var importedSubtitleFiles: [URL] = []
  private var importedSubtitleContentKey: String?

  init() {
    engine = KSPlayerEngine()
    castController = CastController.takeCrossScreenHandoff()
      ?? Self.engagedCastController()
      ?? CastController()
    screenBrightness = UIScreen.main.brightness
    wireEngine()
    wireCastController()
    Self.register(self)
  }

  deinit {
    teardown()
  }

  /// The last seen engine states for edge detection (`changePublisher` publishes in batches).
  private var lastEngineIsReady = false
  private var lastEngineEstablished = false

  private func wireEngine() {
    // The DispatchQueue scheduler always schedules async; even if objectWillChange fires BEFORE
    // the change, the values are already updated by the time the sink runs.
    engine.changePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        self?.handleEngineChange()
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        // The file-mandated `if current != new` guard: @Published fires objectWillChange even for the same
        // value, needlessly invalidating PlayerView throughout a drag.
        // invalidate ediyordu.
        let b = UIScreen.main.brightness
        if self.screenBrightness != b { self.screenBrightness = b }
      }
      .store(in: &cancellables)

    // Phone call / Siri / alarm: iOS deactivates our session and mpv's audio output
    // stops. Without this observer the player stays silent until fully reopened.
    NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        self?.handleAudioSessionInterruption(note)
      }
      .store(in: &cancellables)

    // Headphone removal / Bluetooth disconnect: platform convention (AVPlayer behavior)
    // is to pause playback — otherwise the audio suddenly continues from the speaker.
    // This rule does NOT apply while cast is active: playback is on the TV, AirPlay route decisions belong
    // to CastController (two observers contradicting each other was a field finding).
    NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        guard let self,
              let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: reasonRaw) == .oldDeviceUnavailable,
              self.isPlaying,
              self.castController?.isEngaged != true
        else { return }
        self.engine.pause()
      }
      .store(in: &cancellables)
  }

  private func wireCastController() {
    guard let cast = castController else { return }
    cast.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        self?.handleEngineChange()
      }
      .store(in: &cancellables)
    cast.attachOwner(
      token: castOwnerToken,
      stopDirectPlayback: { [weak self] in
      guard let self else { return }
      self.engine.stopPlayback()
      // KSPlayerLayer.deinit deletes ALL remote-command targets with removeTarget(nil);
      // deletes; the lock screen controls are rebuilt after every layer teardown.
      self.reinstallRemoteCommands()
      },
      resumeDirectPlayback: { [weak self] content, at in
      guard let self, !self.isTornDown else { return }
      self.play(
        url: content.url,
        startSeconds: content.isLive || at < 2 ? nil : at,
        isLiveStream: content.isLive,
        userAgent: content.userAgent
      )
      },
      onTimeTick: { [weak self] seconds in
        self?.engine.updateSubtitleCue(at: seconds)
      }
    )
    // A controller taken from the cross-screen handoff is already presenting;
    // publish that state immediately instead of waiting for its next time tick.
    handleEngineChange()
  }

  private func handleEngineChange() {
    let established = engine.isPlaybackEstablished
    if established != lastEngineEstablished {
      lastEngineEstablished = established
      // Round 20 (R20-4): build 33 does nothing extra on
      // establishment here — the round-14 startup-cap disarm and
      // the round-18 retry re-arm are removed with their machinery.
      if established, pendingPreferredTrackSelection {
        pendingPreferredTrackSelection = false
        // If an imported subtitle is selected, the global subtitle preference must not override it.
        let importedSelected = restoreImportedSubtitles()
        updateTracks(applyPreferences: true, skipSubtitleSelection: importedSelected)
      }
      if established {
        // === Build 61 (B9): a successful start resets the P2
        // reconnect budget and records the Q10 success (which
        // clears the channel's consecutive-failure streak). ===
        autoReconnectAttempts = 0
        currentLoadMayRetryRefusal = false
        if isRetryingConnection { isRetryingConnection = false }
        cancelPendingReconnect()
        cancelStallWatchdog()
        if let key = importedSubtitleContentKey {
          ChannelHealthStore.shared.recordSuccess(for: key)
        }
      }
    }
    // === Build 61 (B9, E6): time-to-first-frame sample ===
    let firstFrame = engine.hasRenderedFirstFrame
    if firstFrame != lastEngineFirstFrame {
      lastEngineFirstFrame = firstFrame
      if firstFrame, !ttffRecordedForCurrentLoad, let started = loadRequestedAt {
        ttffRecordedForCurrentLoad = true
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        TTFFLog.record(milliseconds: ms, isLive: currentLoadRequest?.isLiveStream ?? false)
      }
    }
    let ready = engine.isReady
    if ready != lastEngineIsReady {
      lastEngineIsReady = ready
      if ready { tryFlushPendingLoad() }
    }
    let castPresenting = castController?.isPresenting ?? false
    // === Build 61 (B9, P2): auto-reconnect with backoff. ===
    // A recoverable failure (timeout / host unreachable / HTTP
    // 5xx) spends one reconnect attempt after a backoff delay —
    // up to `maxReconnectAttempts` — before the failure is
    // published to the existing banner. While a reconnect is
    // pending, the failure stays unpublished (the return below),
    // so the user sees the loading state, never a flashing error.
    // A fresh KSPlayerLayer is built by tryFlushPendingLoad, which
    // also reinstalls the remote commands the previous layer's
    // deinit wiped.
    if !castPresenting,
       engine.playbackFailureMessage != nil,
       let request = currentLoadRequest {
      // Build 63 (item 16): a replacement load may also spend the
      // ladder on a provider refusal / open failure (see
      // currentLoadMayRetryRefusal) — the panel-slot-release race.
      let refusalRetry = currentLoadMayRetryRefusal
        && (engine.playbackFailureIsProviderRefusal || engine.playbackFailureIsOpenFailure)
      if engine.playbackFailureIsRecoverable || refusalRetry,
         autoReconnectAttempts < Self.maxReconnectAttempts,
         pendingReconnectWorkItem == nil {
        let delay = Self.reconnectBackoffs[min(autoReconnectAttempts, Self.reconnectBackoffs.count - 1)]
        autoReconnectAttempts += 1
        log.info("Auto-reconnect attempt \(self.autoReconnectAttempts) in \(delay)s after recoverable failure")
        // Resume from the current position, not the original
        // startSeconds — otherwise a mid-stream retry silently
        // rewinds to wherever the user started this load from.
        let resumeAt: TimeInterval? = engine.isPlaybackEstablished && engine.position > 0.5
          ? engine.position
          : request.startSeconds
        let item = DispatchWorkItem { [weak self] in
          guard let self, !self.isTornDown else { return }
          self.pendingReconnectWorkItem = nil
          self.pendingLoadRequest = PendingLoadRequest(
            url: request.url,
            startSeconds: resumeAt,
            isLiveStream: request.isLiveStream,
            userAgent: request.userAgent,
            customHeaders: request.customHeaders
          )
          self.tryFlushPendingLoad()
        }
        pendingReconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        // Build 64 (A3-iii): on a fresh presentation the ladder
        // wait is VISIBLE, not a silent spinner.
        if currentLoadIsFreshPresentation, !isRetryingConnection {
          isRetryingConnection = true
        }
        return
      }
      if pendingReconnectWorkItem != nil {
        // A reconnect is already scheduled: keep the failure
        // unpublished until it has had its chance.
        if currentLoadIsFreshPresentation, !isRetryingConnection {
          isRetryingConnection = true
        }
        return
      }
      // The failure is final for this load (never recoverable, or
      // the reconnect budget is exhausted): record it once for
      // Q10 dead-channel marking, then let the message flow to
      // the pristine banner below — unchanged.
      if isRetryingConnection { isRetryingConnection = false }
      recordHealthFailureIfNeeded()
    }
    // === Build 61 (B9, P2): stall watchdog arming. ===
    if !castPresenting, engine.isPlaybackEstablished, engine.isBuffering, !engine.isPaused {
      armStallWatchdogIfNeeded()
    } else {
      cancelStallWatchdog()
    }
    let failure = castPresenting ? nil : engine.playbackFailureMessage
    if failure == nil, isRetryingConnection { isRetryingConnection = false }
    if playbackFailureMessage != failure { playbackFailureMessage = failure }
    let ks = engine
    if isPiPActive != ks.isPiPActive { isPiPActive = ks.isPiPActive }
    if audioCodecName != ks.audioCodecName { audioCodecName = ks.audioCodecName }
    // Remux candidacy: the FFmpeg path + compatible codecs.
    let remuxCandidate = ks.isFFmpegBackendActive
      && !ks.videoCodecName.isEmpty
      && RemuxHLSWriter.isCompatible(
        videoFourCC: ks.videoCodecName,
        audioFourCC: ks.audioCodecName.isEmpty ? nil : ks.audioCodecName
      )
    let capable = castPresenting || ks.isAirPlayVideoCapable || remuxCandidate
    if isAirPlayVideoCapable != capable { isAirPlayVideoCapable = capable }
    let needsPrep = !castPresenting && !ks.isAirPlayVideoCapable && remuxCandidate
    if needsAirPlayPreparation != needsPrep { needsAirPlayPreparation = needsPrep }
    let airPlayActive = castPresenting
      ? (castController?.isExternalPlaybackActive ?? false)
      : ks.isExternalPlaybackActive
    if isAirPlayPlaybackActive != airPlayActive { isAirPlayPlaybackActive = airPlayActive }
    if isCastPresenting != castPresenting { isCastPresenting = castPresenting }
    syncFromEngine()
    updateAdaptiveBuffer()
  }

  // MARK: - Build 61 (B9): reconnect, health, adaptive buffer

  private func cancelPendingReconnect() {
    pendingReconnectWorkItem?.cancel()
    pendingReconnectWorkItem = nil
  }

  private func cancelStallWatchdog() {
    stallWatchdogWorkItem?.cancel()
    stallWatchdogWorkItem = nil
  }

  /// P2 stall detection: while an established stream sits in
  /// buffering, give it `stallWatchdogDelay` seconds; if the
  /// playhead has not meaningfully advanced by then, spend one
  /// reconnect attempt on a reload at the current position. The
  /// watchdog re-arms only after it fires or is cancelled, so a
  /// long rebuffer cannot spend the whole budget at once.
  private func armStallWatchdogIfNeeded() {
    guard stallWatchdogWorkItem == nil, currentLoadRequest != nil else { return }
    let armedPosition = engine.position
    let item = DispatchWorkItem { [weak self] in
      guard let self, !self.isTornDown else { return }
      self.stallWatchdogWorkItem = nil
      guard self.engine.isPlaybackEstablished,
            self.engine.isBuffering,
            !self.engine.isPaused,
            self.engine.position - armedPosition < 2,
            self.autoReconnectAttempts < Self.maxReconnectAttempts,
            self.pendingReconnectWorkItem == nil,
            let request = self.currentLoadRequest
      else { return }
      self.autoReconnectAttempts += 1
      self.log.info("Stall watchdog: reconnect attempt \(self.autoReconnectAttempts) after \(Self.stallWatchdogDelay)s without progress")
      let resumeAt: TimeInterval? = self.engine.position > 0.5 ? self.engine.position : request.startSeconds
      self.pendingLoadRequest = PendingLoadRequest(
        url: request.url,
        startSeconds: resumeAt,
        isLiveStream: request.isLiveStream,
        userAgent: request.userAgent,
        customHeaders: request.customHeaders
      )
      self.tryFlushPendingLoad()
    }
    stallWatchdogWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallWatchdogDelay, execute: item)
  }

  /// Q10: record the current load's final failure, once, for
  /// live content only (dead-CHANNEL marking — VOD/series
  /// failures are not channel health).
  private func recordHealthFailureIfNeeded() {
    guard !healthFailureRecordedForCurrentLoad,
          currentLoadRequest?.isLiveStream == true,
          let key = importedSubtitleContentKey
    else { return }
    healthFailureRecordedForCurrentLoad = true
    ChannelHealthStore.shared.recordFailure(for: key)
  }

  /// P3 + E2: adaptive buffer over the retained `KSOptions`.
  ///
  /// KSPlayerLayer keeps the very `KSOptions` instance the load
  /// was built with, and both engines read
  /// `preferredForwardBufferDuration` LIVE: KSAVPlayer sinks it
  /// onto `AVPlayerItem.preferredForwardBufferDuration`
  /// (KSAVPlayer.swift), and KSMEPlayer's `playable()` gate
  /// compares buffered time against it on every capacity check
  /// (KSOptions.swift). Mutating it here is therefore a real,
  /// mid-playback adjustment on both paths — no engine fork.
  ///
  /// E2 fast start: on first sight of a load's options, the
  /// forward buffer drops to the fast-start floor (1 s, or the
  /// base itself when the user's base is lower), so the playable
  /// gate opens as early as the stream allows.
  /// P3 ramp/adaptation: about once a second, the tuner reads
  /// the buffer-ahead trend — the cushion ahead of the playhead
  /// only grows when delivered throughput outpaces playback, so
  /// its trend IS the throughput signal available at this level.
  /// While the cushion is healthy and not draining, the forward
  /// buffer steps back UP toward the user's base; while the
  /// cushion is nearly empty, it steps back DOWN toward the
  /// floor so a rebuffer recovers sooner. The value NEVER
  /// exceeds the base `KSPlayerEngine` applied from the user's
  /// item-7 setting — the manual choice is the ceiling, always.
  private func updateAdaptiveBuffer() {
    guard let options = engine.layer?.options else { return }
    if bufferBaseForward == nil {
      let base = options.preferredForwardBufferDuration
      bufferBaseForward = base
      bufferRampFloor = min(1, base)
      if options.preferredForwardBufferDuration > bufferRampFloor {
        options.preferredForwardBufferDuration = bufferRampFloor
      }
      lastBufferAheadSeconds = 0
      lastBufferHealthCheckAt = Date()
      return
    }
    guard let base = bufferBaseForward else { return }
    let now = Date()
    if let last = lastBufferHealthCheckAt, now.timeIntervalSince(last) < 1 { return }
    lastBufferHealthCheckAt = now
    let ahead = cacheAheadSeconds
    let draining = ahead < lastBufferAheadSeconds - 0.25
    lastBufferAheadSeconds = ahead
    let current = options.preferredForwardBufferDuration
    if ahead >= current + 2, !draining, current < base {
      options.preferredForwardBufferDuration = min(base, current + 1)
    } else if ahead < 1, current > bufferRampFloor {
      options.preferredForwardBufferDuration = max(bufferRampFloor, current - 1)
    }
  }

  private func handleAudioSessionInterruption(_ note: Notification) {
    guard let info = note.userInfo,
          let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }
    switch type {
    case .began:
      // The session is already deactivated by the system; clear the flag so the
      // next setupAudioSession() call is not short-circuited.
      audioSessionActivated = false
      if isPlaying { routedPause() }
    case .ended:
      let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
      setupAudioSession()
      if options.contains(.shouldResume), !isTornDown {
        routedPlay()
      }
    @unknown default:
      break
    }
  }

  // MARK: - Transport routing (engine ↔ cast)

  /// Cast oturumu sunumdayken transport cast player'a, aksi halde motora gider.
  private var castPresentingNow: Bool { castController?.isPresenting ?? false }

  private func routedPlay() {
    if let cast = castController, cast.isPresenting {
      cast.play()
    } else {
      engine.play()
    }
  }

  private func routedPause() {
    if let cast = castController, cast.isPresenting {
      cast.pause()
    } else {
      engine.pause()
    }
  }

  /// Absolute (source-time) seek; the remote control and the scrubber pass through here.
  func seekAbsolute(to seconds: TimeInterval) {
    markSeekRequestStart()
    if let cast = castController, cast.isPresenting {
      cast.seek(toSource: seconds)
    } else {
      engine.seek(to: seconds)
    }
  }

  /// Presentation source: cast while a cast session is active, otherwise the engine. The single key point —
  /// all @Published mappings below are fed from this snapshot.
  private struct PresentationSnapshot {
    var position: TimeInterval
    var duration: TimeInterval
    var isPaused: Bool
    var isBuffering: Bool
    var isCompleted: Bool
    var isSeekable: Bool
    var isEstablished: Bool
    var isReady: Bool
    var failureMessage: String?
    var rate: Double
  }

  private func presentationSnapshot() -> PresentationSnapshot {
    if let cast = castController, cast.isPresenting {
      return PresentationSnapshot(
        position: cast.position,
        duration: cast.duration,
        isPaused: cast.isPaused,
        isBuffering: cast.isBuffering,
        isCompleted: cast.isCompleted,
        isSeekable: cast.isSeekable,
        isEstablished: cast.isPlaybackEstablished,
        isReady: true,
        failureMessage: nil,
        rate: Double(rate)
      )
    }
    return PresentationSnapshot(
      position: engine.position,
      duration: engine.duration,
      isPaused: engine.isPaused,
      isBuffering: engine.isBuffering,
      isCompleted: engine.isCompleted,
      isSeekable: engine.isSeekable,
      isEstablished: engine.isPlaybackEstablished,
      isReady: engine.isReady,
      failureMessage: engine.playbackFailureMessage,
      rate: engine.playbackRate
    )
  }

  /// Every @Published assignment fires `objectWillChange` — Swift's @Published does no equality check.
  /// Guard all assignments with `if current != new`; otherwise there are 8×22 = ~176 needless SwiftUI invalidations per second.
  private func syncFromEngine() {
    let snapshot = presentationSnapshot()
    let pos = snapshot.position
    let dur = snapshot.duration
    let posMs = Int64((pos.isFinite ? pos : 0) * 1000)
    let durMs = Int64((dur.isFinite ? dur : 0) * 1000)
    if timeMs != posMs { timeMs = posMs }
    if durationMs != durMs { durationMs = durMs }

    let newPosition: Float
    if dur > 0, pos.isFinite {
      newPosition = Float(min(max(pos / dur, 0), 1))
    } else {
      newPosition = 0
    }
    if position != newPosition { position = newPosition }

    let failed = !(snapshot.failureMessage ?? "").isEmpty
    let newIsPlaying =
      !failed && snapshot.isEstablished && snapshot.isReady
      && !snapshot.isPaused && !snapshot.isCompleted
    if isPlaying != newIsPlaying { isPlaying = newIsPlaying }

    let newRate = Float(snapshot.rate)
    if rate != newRate { rate = newRate }

    if isSeekable != snapshot.isSeekable { isSeekable = snapshot.isSeekable }

    let newBuf: Float = snapshot.isBuffering ? 0.35 : 0
    if bufferingProgress != newBuf { bufferingProgress = newBuf }

    if videoWidth != engine.videoDisplayWidth { videoWidth = engine.videoDisplayWidth }
    if videoHeight != engine.videoDisplayHeight { videoHeight = engine.videoDisplayHeight }
    if streamFPS != engine.streamFPS { streamFPS = engine.streamFPS }
    if renderFPS != engine.renderFPS { renderFPS = engine.renderFPS }
    if videoBitrate != engine.videoBitrate { videoBitrate = engine.videoBitrate }
    if droppedFrameCount != engine.droppedFrameCount {
      droppedFrameCount = engine.droppedFrameCount
    }
    if delayedFrameCount != engine.delayedFrameCount {
      delayedFrameCount = engine.delayedFrameCount
    }
    if cacheBufferingState != engine.cacheBufferingState {
      cacheBufferingState = engine.cacheBufferingState
    }
    if cacheDurationSeconds != engine.cacheDurationSeconds {
      cacheDurationSeconds = engine.cacheDurationSeconds
    }
    let newAhead = max(engine.bufferTimelineEnd - (Double(timeMs) / 1000.0), 0)
    if cacheAheadSeconds != newAhead { cacheAheadSeconds = newAhead }
    if avSyncSeconds != engine.avSyncSeconds { avSyncSeconds = engine.avSyncSeconds }
    if networkSpeedBps != engine.networkSpeedBps { networkSpeedBps = engine.networkSpeedBps }
    let newHwdec = castPresentingNow ? "airplay-cast" : engine.hwdecCurrent
    if hwdecCurrent != newHwdec { hwdecCurrent = newHwdec }
    if videoCodecName != engine.videoCodecName { videoCodecName = engine.videoCodecName }

    updateSeekLatencyIfNeeded(currentTimeMs: timeMs)

    let newState: VideoPlayerState
    if failed {
      newState = .error
    } else if !snapshot.isReady {
      newState = .idle
    } else if snapshot.isCompleted {
      newState = .ended
    } else if snapshot.isBuffering {
      newState = .buffering
    } else if snapshot.isPaused {
      newState = .paused
    } else {
      newState = .playing
    }
    if state != newState { state = newState }

    applyIdleTimerPolicy()
    updateNowPlayingInfo()
  }

  /// Prevents the screen from auto-locking during playback; returns to normal when paused or when leaving the screen.
  private func applyIdleTimerPolicy() {
    let disableIdleTimer = isPlaying
    if Thread.isMainThread {
      UIApplication.shared.isIdleTimerDisabled = disableIdleTimer
    } else {
      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = disableIdleTimer
      }
    }
  }

  private func tryFlushPendingLoad() {
    guard let request = pendingLoadRequest else { return }
    pendingLoadRequest = nil
    log.info("Loading URL into engine: \(request.url.absoluteString, privacy: .public)")
    engine.load(
      request.url,
      play: true,
      startSeconds: request.startSeconds,
      liveLowLatency: request.isLiveStream,
      userAgent: request.userAgent,
      customHeaders: request.customHeaders
    )
    // While a new KSPlayerLayer is being set up, the old one's deinit
    // deleted their targets; rebuild the lock screen controls.
    reinstallRemoteCommands()
    let saved = SubtitleAppearancePersistence.load()
    engine.applySubtitleAppearanceFromSettings(saved)
    engine.setSubDelay(seconds: saved.delaySeconds)
    engine.setAudioDelay(seconds: AudioDelayPersistence.load())
    // === Build 61 (B9, Q3): a delay stored FOR THIS CONTENT wins
    // over the global one. The content context is set by
    // PlayerView before every `play`, so it is already known here.
    if let key = importedSubtitleContentKey {
      if let subDelay = PerContentTrackPreferences.subtitleDelay(for: key) {
        engine.setSubDelay(seconds: subDelay)
      }
      if let audioDelay = PerContentTrackPreferences.audioDelay(for: key) {
        engine.setAudioDelay(seconds: audioDelay)
      }
    }
  }

  func setupAudioSession() {
    if audioSessionActivated { return }
    let lease = Self.claimAudioSessionLease()
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
      try session.setActive(true, options: [])
      audioSessionActivated = true
      audioSessionLease = lease.token
    } catch {
      Self.rollBackAudioSessionLease(lease.token, previous: lease.previous)
      log.error("AVAudioSession: \(error.localizedDescription)")
    }
  }

  func play(
    url: URL,
    startSeconds: TimeInterval? = nil,
    isLiveStream: Bool = false,
    userAgent: String? = nil,
    // Build 61 (FA, F-2/G2): playlist custom headers, alongside the UA.
    customHeaders: [String: String] = [:]
  ) {
    guard !isTornDown else { return }
    // === Build 61 (B9): fresh per-load state for P2/Q10/E6/P3 ===
    autoReconnectAttempts = 0
    cancelPendingReconnect()
    cancelStallWatchdog()
    // Build 64 (A3-iii): consume the fresh-presentation mark.
    currentLoadIsFreshPresentation = nextLoadIsFreshPresentation
    nextLoadIsFreshPresentation = false
    if isRetryingConnection { isRetryingConnection = false }
    healthFailureRecordedForCurrentLoad = false
    loadRequestedAt = Date()
    ttffRecordedForCurrentLoad = false
    bufferBaseForward = nil
    lastBufferHealthCheckAt = nil
    lastBufferAheadSeconds = 0
    // Build 63 (item 16): arm the refusal-retry BEFORE the new
    // request replaces the old one.
    currentLoadMayRetryRefusal = currentLoadRequest != nil
      || (Self.lastTeardownAt.map { Date().timeIntervalSince($0) < 20 } ?? false)
    PlaybackPrewarmService.shared.cancelNeighbors()
    currentLoadRequest = PendingLoadRequest(
      url: url,
      startSeconds: startSeconds,
      isLiveStream: isLiveStream,
      userAgent: userAgent,
      customHeaders: customHeaders
    )
    // While a cast session is active (zap / auto-next), content flows through the cast pipeline; the engine
    // does NOT OPEN — opening a second connection to the panel was the root cause of handover errors on
    // connection-limited panels. During native-external playback, a zap to FFmpeg content also
    // proceeds directly via the remux handover. Third path: if the previous player screen closed mid-cast
    // (close movie → open live), CastController itself is handed over
    // to the new screen; `cast.isEngaged` selects this path directly.
    if let cast = castController {
      let nativeNext = !KSPlayerEngine.prefersFFmpegFirst(for: url)
      let overlapsNativeExternalPlayback =
        !cast.isEngaged && Self.hasNativeExternalPlayback(excluding: self)
      if overlapsNativeExternalPlayback {
        CastController.claimNativeExternalPlaybackFromActiveController()
      }
      let hasNativeExternalContinuation = overlapsNativeExternalPlayback
        || (!cast.isEngaged && CastController.takeNativeExternalPlaybackContinuation())
      let continueNativeExternalPlayback = hasNativeExternalContinuation
      let crossoverToRemux =
        engine.isExternalPlaybackActive
        && !nativeNext
      if cast.isEngaged || crossoverToRemux || continueNativeExternalPlayback {
        pendingPreferredTrackSelection = false
        setupAudioSession()
        // The engine is stopped; the subtitle model carries the previous content's selection.
        // Because cast ticks kept doing cue searches, the selection is cleared so the wrong content's subtitles are not printed.
        // the selection is cleared so it is not printed.
        engine.selectSubtitleTrack(id: -1)
        let content = CastController.Content(
          url: url,
          isLive: isLiveStream,
          userAgent: userAgent,
          startAt: isLiveStream ? 0 : (startSeconds ?? 0),
          knownDuration: 0,
          nativelyPlayable: nativeNext
        )
        if cast.isEngaged {
          cast.playContent(content)
        } else if continueNativeExternalPlayback {
          cast.continueNativeExternalPlayback(with: content)
        } else {
          cast.startRemuxCast(content: content) { _ in }
        }
        return
      }
    }
    pendingPreferredTrackSelection = true
    setupAudioSession()
    pendingLoadRequest = currentLoadRequest
    tryFlushPendingLoad()
  }

  func setupAudioHandler() {
    setupAudioSession()
    setupRemoteCommands()
  }

  func setPlaybackPresentation(_ presentation: PlaybackPresentation) {
    playbackPresentation = presentation
    if isLiveStream != presentation.isLive {
      isLiveStream = presentation.isLive
    }
    scheduleNowPlayingArtworkFetch(for: presentation)
    updateNowPlayingInfo(force: true)
  }

  func togglePlayPause() {
    if isPlaying {
      routedPause()
    } else {
      routedPlay()
    }
  }

  func jump(seconds: Int) {
    if castPresentingNow {
      seekAbsolute(to: Double(timeMs) / 1000.0 + Double(seconds))
      return
    }
    markSeekRequestStart()
    engine.jumpRelative(seconds: seconds)
  }

  func seek(to pos: Float) {
    // Round 14 (B2): resume/seek math is undefined when the
    // duration is unknown — guard BOTH paths (the cast path
    // already did; the engine path relied on the engine's own
    // guard, which a cast-shaped duration of 0 could bypass).
    guard durationMs > 0 else { return }
    if castPresentingNow {
      let dur = Double(durationMs) / 1000.0
      seekAbsolute(to: dur * Double(min(max(pos, 0), 1)))
      return
    }
    markSeekRequestStart()
    engine.seekToFraction(pos)
  }

  func setRate(_ newRate: Float) {
    if let cast = castController, cast.isPresenting {
      cast.setRate(newRate)
    } else {
      engine.setPlaybackRate(Double(newRate))
    }
    rate = newRate
  }

  func setVolume(_ value: Double) {
    let clamped = min(max(value, 0), 125)
    if let cast = castController, cast.isPresenting {
      cast.setVolume(clamped)
    } else {
      engine.setVolume(clamped)
    }
  }

  /// `UIScreen` brightness; applied on the main thread.
  func setScreenBrightness(_ value: CGFloat) {
    let clamped = min(max(value, 0), 1)
    let apply = { [weak self] in
      guard let self else { return }
      if self.brightnessToRestore == nil {
        self.brightnessToRestore = UIScreen.main.brightness
      }
      UIScreen.main.brightness = clamped
      if self.screenBrightness != clamped { self.screenBrightness = clamped }
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  func setAspectMode(_ mode: VideoAspectMode, force: Bool = false) {
    if !force, aspectMode == mode { return }
    aspectMode = mode
  }

  func updateTracks(applyPreferences: Bool = false, skipSubtitleSelection: Bool = false) {
    engine.reloadTrackList { [weak self] video, audio, subs, vid, aid, sid in
      guard let self else { return }
      // Guarded like the rest of the class: @Published fires objectWillChange even on
      // an unchanged assignment, and this runs on every track-menu open / establish.
      if self.videoTracks != video { self.videoTracks = video }
      if self.audioTracks != audio { self.audioTracks = audio }
      if self.subtitleTracks != subs { self.subtitleTracks = subs }
      if self.currentVideoTrackId != vid { self.currentVideoTrackId = vid }
      if self.currentAudioTrackId != aid { self.currentAudioTrackId = aid }
      if self.currentSubtitleTrackId != sid { self.currentSubtitleTrackId = sid }
      guard applyPreferences else { return }
      let prefs = PlaybackTrackPreferences.load()
      // Round 20 (R20-4): build-33 preference application restored
      // — the remembered video pick applies to live exactly as to
      // VOD (the round-12 live ABR carve-out is removed), and the
      // GLOBAL preferences are applied.
      // === Build 61 (B9, Q2): the per-content memory
      // (PerContentTrackPreferences) is consulted FIRST for this
      // content's identity; the global preference remains the
      // fallback when the content has no remembered choice. (The
      // round-15 per-series layer was removed in round 20; this
      // is its build-61 successor, keyed by the same content
      // identity imported subtitles use, series included.) ===
      let contentKey = self.importedSubtitleContentKey
      let videoPick = contentKey.flatMap { PerContentTrackPreferences.pickVideo(from: video, for: $0) }
        ?? PlaybackTrackPreferences.pickVideo(from: video, prefs: prefs)
      if let pick = videoPick {
        self.engine.selectVideoTrack(id: pick)
        if self.currentVideoTrackId != pick { self.currentVideoTrackId = pick }
      }
      let audioPick = contentKey.flatMap { PerContentTrackPreferences.pickAudio(from: audio, for: $0) }
        ?? PlaybackTrackPreferences.pickAudio(from: audio, prefs: prefs)
      if let pick = audioPick {
        self.engine.selectAudioTrack(id: pick)
        if self.currentAudioTrackId != pick { self.currentAudioTrackId = pick }
      }
      if !skipSubtitleSelection {
        let subtitlePick = contentKey.flatMap { PerContentTrackPreferences.pickSubtitle(from: subs, for: $0) }
          ?? PlaybackTrackPreferences.pickSubtitle(from: subs, prefs: prefs)
        if let pick = subtitlePick {
          self.engine.selectSubtitleTrack(id: pick)
          if self.currentSubtitleTrackId != pick { self.currentSubtitleTrackId = pick }
        }
      }
    }
  }

  func selectVideoTrack(id: Int) {
    engine.selectVideoTrack(id: id)
    currentVideoTrackId = id
    if let opt = videoTracks.first(where: { $0.id == id }) {
      PlaybackTrackPreferences.saveVideo(from: opt)
      // Build 61 (B9, Q2): also remember the pick for THIS content.
      if let key = importedSubtitleContentKey {
        PerContentTrackPreferences.saveVideo(from: opt, for: key)
      }
    }
  }

  func selectAudioTrack(id: Int) {
    engine.selectAudioTrack(id: id)
    currentAudioTrackId = id
    if let opt = audioTracks.first(where: { $0.id == id }) {
      PlaybackTrackPreferences.saveAudio(from: opt)
      // Build 61 (B9, Q2): also remember the pick for THIS content.
      if let key = importedSubtitleContentKey {
        PerContentTrackPreferences.saveAudio(from: opt, for: key)
      }
    }
  }

  func selectSubtitleTrack(id: Int) {
    engine.selectSubtitleTrack(id: id)
    currentSubtitleTrackId = id
    if let opt = subtitleTracks.first(where: { $0.id == id }) {
      PlaybackTrackPreferences.saveSubtitle(from: opt)
      // Build 61 (B9, Q2): also remember the pick for THIS content.
      if let key = importedSubtitleContentKey {
        PerContentTrackPreferences.saveSubtitle(from: opt, for: key)
      }
      if let key = importedSubtitleContentKey {
        // Remember external track selection per content; picking embedded / off resets it.
        let importedName = opt.isExternal && importedFileNames.contains(opt.title) ? opt.title : nil
        ImportedSubtitleStore.setSelectedFileName(importedName, for: key)
      }
    }
  }

  // Round 20 (R20-4): the round-15 per-series track-preference
  // layer (MARK block that stood here) is REMOVED — build 33
  // applies only the global `PlaybackTrackPreferences`.

  // MARK: - Imported subtitles (issue #98)

  private var importedFileNames: Set<String> {
    Set(importedSubtitleFiles.map(\.lastPathComponent))
  }

  /// Identity of the playing content; set by PlayerView before every `play` call.
  func setImportedSubtitleContext(contentKey: String) {
    importedSubtitleContentKey = contentKey
    importedSubtitleFiles = ImportedSubtitleStore.subtitleFiles(for: contentKey)
  }

  /// Adds the stored files to mpv; returns whether the saved selection was applied.
  private func restoreImportedSubtitles() -> Bool {
    guard let key = importedSubtitleContentKey else { return false }
    let files = ImportedSubtitleStore.subtitleFiles(for: key)
    importedSubtitleFiles = files
    guard !files.isEmpty else { return false }
    let selectedName = ImportedSubtitleStore.selectedFileName(for: key)
    var didSelect = false
    for file in files {
      let name = file.lastPathComponent
      let select = name == selectedName
      didSelect = didSelect || select
      engine.addExternalSubtitle(filePath: file.path, title: name, select: select)
    }
    return didSelect
  }

  func importSubtitleFile(at pickedURL: URL) throws {
    guard let key = importedSubtitleContentKey else { return }
    let saved = try ImportedSubtitleStore.importFile(at: pickedURL, for: key)
    let name = saved.lastPathComponent
    // If a track with the same name was added before, drop the old one (file was overwritten).
    if let existing = subtitleTracks.first(where: { $0.isExternal && $0.title == name }) {
      engine.removeExternalSubtitle(id: existing.id)
    }
    ImportedSubtitleStore.setSelectedFileName(name, for: key)
    importedSubtitleFiles = ImportedSubtitleStore.subtitleFiles(for: key)
    engine.addExternalSubtitle(filePath: saved.path, title: name, select: true)
    updateTracks()
  }

  func deleteImportedSubtitle(_ url: URL) {
    guard let key = importedSubtitleContentKey else { return }
    let name = url.lastPathComponent
    ImportedSubtitleStore.removeFile(url, for: key)
    importedSubtitleFiles = ImportedSubtitleStore.subtitleFiles(for: key)
    if let existing = subtitleTracks.first(where: { $0.isExternal && $0.title == name }) {
      engine.removeExternalSubtitle(id: existing.id)
      updateTracks()
    }
  }

  func applySubtitleAppearanceSettings(_ settings: SubtitleAppearanceSettings) {
    SubtitleAppearancePersistence.save(settings)
    engine.applySubtitleAppearanceFromSettings(settings)
    engine.setSubDelay(seconds: settings.delaySeconds)
    // Build 61 (B9, Q3): the delay half of the appearance is
    // also remembered for this content.
    if let key = importedSubtitleContentKey {
      PerContentTrackPreferences.saveSubtitleDelay(settings.delaySeconds, for: key)
    }
  }

  func applySubtitleDelaySeconds(_ seconds: Double) {
    engine.setSubDelay(seconds: seconds)
    // Build 61 (B9, Q3): remember the delay for this content.
    if let key = importedSubtitleContentKey {
      PerContentTrackPreferences.saveSubtitleDelay(seconds, for: key)
    }
  }

  /// UHF flow: set up the remux, when ready completion(true) — the UI opens the system picker at that moment.
  func prepareAirPlay(completion: @escaping (Bool) -> Void) {
    guard let cast = castController else {
      completion(false)
      return
    }
    let ks = engine
    guard needsAirPlayPreparation else {
      completion(true)  // the native path or cast is already presenting — the picker can open directly
      return
    }
    guard let request = currentLoadRequest else {
      completion(false)
      return
    }
    // If the first time tick has not yet arrived for resumed content, the engine reports 0;
    // fall back to the requested start second (so cast doesn't start from 0:00).
    let at: TimeInterval
    if ks.isPlaybackEstablished, ks.position > 0.5 {
      at = ks.position
    } else {
      at = request.startSeconds ?? 0
    }
    let subtitle = selectedExternalSubtitle()
    let content = CastController.Content(
      url: request.url,
      isLive: request.isLiveStream,
      userAgent: request.userAgent,
      startAt: request.isLiveStream ? 0 : at,
      knownDuration: ks.duration,
      nativelyPlayable: false,
      startPaused: ks.isPlaybackEstablished && ks.isPaused,
      subtitleFileURL: subtitle?.url,
      subtitleName: subtitle?.name,
      subtitleLanguage: subtitle?.language
    )
    cast.startRemuxCast(content: content, completion: completion)
  }

  /// The currently-selected EXTERNAL subtitle (imported SRT), mapped to its file — used to
  /// expose it on the AirPlay target as an HLS WebVTT rendition. Returns nil when the
  /// selection is "off" or an embedded track (Phase 1 covers external SRT only).
  private func selectedExternalSubtitle() -> (url: URL, name: String, language: String?)? {
    guard currentSubtitleTrackId >= 0,
          let opt = subtitleTracks.first(where: { $0.id == currentSubtitleTrackId }),
          opt.isExternal,
          let url = importedSubtitleFiles.first(where: { $0.lastPathComponent == opt.title })
    else { return nil }
    return (url, url.deletingPathExtension().lastPathComponent, opt.langCode)
  }

  func applyAudioDelaySeconds(_ seconds: Double) {
    AudioDelayPersistence.save(seconds)
    engine.setAudioDelay(seconds: seconds)
    // Build 61 (B9, Q3): remember the delay for this content.
    if let key = importedSubtitleContentKey {
      PerContentTrackPreferences.saveAudioDelay(seconds, for: key)
    }
  }

  func teardown() {
    if isTornDown { return }
    isTornDown = true
    // Build 61 (B9, P2): no reconnect or stall work may fire
    // into a torn-down controller.
    cancelPendingReconnect()
    cancelStallWatchdog()
    Self.unregister(self)
    Self.lastTeardownAt = Date()
    seriesEpisodeOnPrevious = nil
    seriesEpisodeOnNext = nil
    MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = false
    MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = false
    let restoreBrightness = brightnessToRestore
    brightnessToRestore = nil
    let restoreSystemState = {
      UIApplication.shared.isIdleTimerDisabled = false
      if let restoreBrightness {
        UIScreen.main.brightness = restoreBrightness
      }
    }
    if Thread.isMainThread {
      restoreSystemState()
    } else {
      DispatchQueue.main.async(execute: restoreSystemState)
    }
    cancellables.removeAll()
    removeRemoteCommands()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    playbackPresentation = nil
    cancelNowPlayingArtworkFetch(clearImage: true)
    pendingLoadRequest = nil
    let wasActivated = audioSessionActivated
    let leaseToRelease = audioSessionLease
    audioSessionActivated = false
    audioSessionLease = nil
    if wasActivated, let leaseToRelease {
      // If a non-mixable .playback session is left open, the app we interrupted (Music/Spotify) never
      // receives a resume signal after the player closes.
      // Because mpv's audio unit is disposed async, close it with a short delay.
      // A newer controller may claim the process-wide session during this delay;
      // the lease guard then turns this teardown into a no-op.
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
        Self.deactivateAudioSessionIfCurrent(leaseToRelease)
      }
    }
    seekRequestStartedAt = nil
    seekSourceTimeMs = nil
    seekLatencyMs = -1
    playbackFailureMessage = nil
    // Native AirPlay belongs to KSPlayer's screen-scoped AVPlayer. Capture the
    // selected route before disposing that engine so the next screen can promote
    // its item to the long-lived cast player instead of continuing audio-only.
    if castController?.isEngaged != true,
       engine.isExternalPlaybackActive || isAirPlayPlaybackActive {
      CastController.markNativeExternalPlaybackForNextLoad()
    }
    // Keep one external-playback AVPlayer alive while the user leaves a series
    // and opens a live channel. Recreating it here flaps the route and strands
    // the next FFmpeg stream as audio-only AirPlay.
    if castController?.parkForCrossScreenHandoff(owner: castOwnerToken) != true {
      castController?.dispose()
    }
    engine.dispose()
  }

  private func markSeekRequestStart() {
    seekRequestStartedAt = Date()
    seekSourceTimeMs = timeMs
    seekLatencyMs = -1
  }

  private func updateSeekLatencyIfNeeded(currentTimeMs: Int64) {
    guard seekLatencyMs < 0 else { return }
    guard let startedAt = seekRequestStartedAt, let sourceTimeMs = seekSourceTimeMs else { return }
    let shifted = abs(currentTimeMs - sourceTimeMs) >= 900
    let stalledTooLong = Date().timeIntervalSince(startedAt) >= 5.0
    guard shifted || stalledTooLong else { return }
    seekLatencyMs = max(Int(Date().timeIntervalSince(startedAt) * 1000), 0)
    seekRequestStartedAt = nil
    seekSourceTimeMs = nil
  }

  // MARK: - Now Playing

  private var lastNowPlayingUpdate: TimeInterval = 0

  private func updateNowPlayingInfo(force: Bool = false) {
    guard let p = playbackPresentation else { return }
    let now = CFAbsoluteTimeGetCurrent()
    if !force, now - lastNowPlayingUpdate < 0.8 { return }
    lastNowPlayingUpdate = now

    let durationSec = max(Double(durationMs) / 1000.0, 0)
    let elapsedSec = max(Double(timeMs) / 1000.0, 0)

    // On live channels with EPG, show the programme as the title and the channel
    // as the artist; otherwise the channel/content title.
    let displayTitle: String
    let displayArtist: String
    if p.isLive, let programme = p.programmeTitle, !programme.isEmpty {
      displayTitle = programme
      displayArtist = p.title
    } else {
      displayTitle = p.title
      displayArtist = p.subtitle ?? "Super X"
    }

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: displayTitle,
      MPMediaItemPropertyArtist: displayArtist,
      MPMediaItemPropertyPlaybackDuration: durationSec,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSec,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]
    if p.isLive {
      // Keep the system LIVE badge and no scrubber — do not synthesize a duration
      // from the programme interval (it would misrepresent the transport).
      info[MPNowPlayingInfoPropertyIsLiveStream] = true
      info[MPMediaItemPropertyPlaybackDuration] = 0
    }
    if let img = nowPlayingArtwork {
      // The system calls again at the requested size; a single `UIImage` is enough.
      let b = img.size
      let bounds = CGSize(width: max(b.width, 1), height: max(b.height, 1))
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: bounds) { _ in img }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func cancelNowPlayingArtworkFetch(clearImage: Bool) {
    artworkFetchTask?.cancel()
    artworkFetchTask = nil
    artworkFetchURL = nil
    if clearImage { nowPlayingArtwork = nil }
  }

  /// Now Playing only accepts a bitmap (`MPMediaItemArtwork`); we download the URL ourselves.
  /// Round 15 (C11): async/await fetch (was a completion-handler
  /// data task); cancellation and the stale-URL guard are unchanged.
  private func scheduleNowPlayingArtworkFetch(for presentation: PlaybackPresentation) {
    guard let url = presentation.artworkURL else {
      cancelNowPlayingArtworkFetch(clearImage: true)
      return
    }
    if artworkFetchURL == url, nowPlayingArtwork != nil { return }
    if artworkFetchURL == url, artworkFetchTask != nil { return }

    cancelNowPlayingArtworkFetch(clearImage: true)
    artworkFetchURL = url

    let capturedURL = url
    artworkFetchTask = Task { [weak self] in
      let image: UIImage?
      do {
        let (data, _) = try await URLSession.shared.data(from: capturedURL)
        image = UIImage(data: data)
      } catch {
        image = nil
      }
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self, self.artworkFetchURL == capturedURL else { return }
        self.nowPlayingArtwork = image
        self.artworkFetchTask = nil
        if image == nil { self.artworkFetchURL = nil }
        self.updateNowPlayingInfo(force: true)
      }
    }
  }

  private func setupRemoteCommands() {
    guard remoteCommandTargets.isEmpty else { return }
    let center = MPRemoteCommandCenter.shared()

    center.playCommand.isEnabled = true
    let t1 = center.playCommand.addTarget { [weak self] _ in
      self?.routedPlay()
      return .success
    }
    remoteCommandTargets.append((center.playCommand, t1))

    center.pauseCommand.isEnabled = true
    let t2 = center.pauseCommand.addTarget { [weak self] _ in
      self?.routedPause()
      return .success
    }
    remoteCommandTargets.append((center.pauseCommand, t2))

    center.togglePlayPauseCommand.isEnabled = true
    let t3 = center.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.togglePlayPause()
      return .success
    }
    remoteCommandTargets.append((center.togglePlayPauseCommand, t3))

    center.changePlaybackPositionCommand.isEnabled = true
    let tSeek = center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self,
            let e = event as? MPChangePlaybackPositionCommandEvent,
            self.durationMs > 0
      else { return .commandFailed }
      self.seekAbsolute(to: e.positionTime)
      return .success
    }
    remoteCommandTargets.append((center.changePlaybackPositionCommand, tSeek))

    center.skipForwardCommand.isEnabled = true
    center.skipForwardCommand.preferredIntervals = [15]
    let t4 = center.skipForwardCommand.addTarget { [weak self] _ in
      self?.jump(seconds: 15)
      return .success
    }
    remoteCommandTargets.append((center.skipForwardCommand, t4))

    center.skipBackwardCommand.isEnabled = true
    center.skipBackwardCommand.preferredIntervals = [15]
    let t5 = center.skipBackwardCommand.addTarget { [weak self] _ in
      self?.jump(seconds: -15)
      return .success
    }
    remoteCommandTargets.append((center.skipBackwardCommand, t5))

    center.previousTrackCommand.isEnabled = false
    let t6 = center.previousTrackCommand.addTarget { [weak self] _ in
      guard let cb = self?.seriesEpisodeOnPrevious else { return .commandFailed }
      cb()
      return .success
    }
    remoteCommandTargets.append((center.previousTrackCommand, t6))

    center.nextTrackCommand.isEnabled = false
    let t7 = center.nextTrackCommand.addTarget { [weak self] _ in
      guard let cb = self?.seriesEpisodeOnNext else { return .commandFailed }
      cb()
      return .success
    }
    remoteCommandTargets.append((center.nextTrackCommand, t7))
  }

  /// Previous–next episode from Control Center / lock screen (only while playing a series).
  /// - swapSkipForNav: true → skip commands are turned off, prev/next are shown (series & live TV).
  /// false → skip stays active; always false for movies.
  func configureSeriesEpisodeSkipping(
    canPrevious: Bool,
    canNext: Bool,
    onPrevious: (() -> Void)?,
    onNext: (() -> Void)?,
    swapSkipForNav: Bool = true
  ) {
    seriesEpisodeOnPrevious = canPrevious ? onPrevious : nil
    seriesEpisodeOnNext = canNext ? onNext : nil
    episodeNavCanPrevious = canPrevious && onPrevious != nil
    episodeNavCanNext = canNext && onNext != nil
    episodeNavSwapSkip = swapSkipForNav
    applyEpisodeNavCommandEnablement()
  }

  private func applyEpisodeNavCommandEnablement() {
    let center = MPRemoteCommandCenter.shared()
    let hasEpisodeNav = episodeNavCanPrevious || episodeNavCanNext
    // iOS hides previousTrack/nextTrack buttons when skipForward/skipBackward are enabled.
    // For series & live TV: swap skip → prev/next. For movies: keep skip enabled.
    let disableSkip = episodeNavSwapSkip && hasEpisodeNav
    center.skipForwardCommand.isEnabled = !disableSkip
    center.skipBackwardCommand.isEnabled = !disableSkip
    center.previousTrackCommand.isEnabled = episodeNavSwapSkip && episodeNavCanPrevious
    center.nextTrackCommand.isEnabled = episodeNavSwapSkip && episodeNavCanNext
  }

  /// `KSPlayerLayer.deinit` unconditionally calls `removeTarget(nil)` and deletes Now Playing
  /// — after every layer teardown (new load, cast handover) our own commands
  /// and Now Playing must be rebuilt; otherwise the lock screen dies after the first zap.
  private func reinstallRemoteCommands() {
    guard !remoteCommandTargets.isEmpty else { return }
    removeRemoteCommands()
    setupRemoteCommands()
    applyEpisodeNavCommandEnablement()
    updateNowPlayingInfo(force: true)
  }

  private func removeRemoteCommands() {
    for (cmd, token) in remoteCommandTargets {
      cmd.removeTarget(token)
    }
    remoteCommandTargets.removeAll()
  }
}
