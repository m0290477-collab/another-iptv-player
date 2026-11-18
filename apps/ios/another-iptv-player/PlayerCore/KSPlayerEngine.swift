import AVFoundation
import Combine
import Foundation
import KSPlayer
import UIKit

/// Playback engine over `KSPlayerLayer` (KSAVPlayer with KSMEPlayer fallback).
/// Only the core of KSPlayer is used — video view + delegate callbacks; all UI stays ours.
///
/// This class knows NOTHING about AirPlay casting. The cast lifecycle (remux
/// session, cast player, route observation) lives in `CastController`, owned by
/// `VideoPlayerController`; the engine is simply stopped while a cast engagement
/// is active and reloaded when it ends.
final class KSPlayerEngine: NSObject, ObservableObject {
  @Published private(set) var isReady = false
  @Published private(set) var isPaused = true
  @Published private(set) var isSeekable = false
  @Published private(set) var isBuffering = false
  @Published private(set) var isCompleted = false
  @Published private(set) var isPlaybackEstablished = false
  /// Round 18 (R18-1): true once the player's clock has actually
  /// ticked for this load — i.e. frames are rendering on screen.
  /// `isSecondOpen` releases the first frames BEFORE `readyToPlay`
  /// flips `isPlaybackEstablished`, so a loading surface keyed on
  /// establishment alone lingers over already-playing video (the
  /// owner's 0:05–0:23 "Connecting…" recording). Loading UI keys
  /// its pre-establishment state on THIS flag instead.
  @Published private(set) var hasRenderedFirstFrame = false
  @Published private(set) var playbackFailureMessage: String?
  /// True when the last failure was a transient open failure (timeout / host
  /// unreachable) worth one silent retry, false for terminal ones. Read by
  /// `VideoPlayerController` to decide auto-retry.
  @Published private(set) var playbackFailureIsRecoverable = false
  /// Round 17 (R17-4), kept in round 20 as failure-card
  /// attribution only: true when the last failure carries an HTTP
  /// 4xx — the PROVIDER answered and refused (expired account,
  /// wrong credentials, dead title, 451). Open failures with no
  /// HTTP status (FFmpeg could not open the input at all) leave
  /// this false. (Round 20 removed the alternate-engine attempt
  /// this flag used to gate; it now only attributes the failure
  /// shown on the kept failure card.)
  @Published private(set) var playbackFailureIsProviderRefusal = false
  @Published private(set) var position: TimeInterval = 0
  @Published private(set) var duration: TimeInterval = 0
  @Published private(set) var playbackRate: Double = 1
  @Published private(set) var bufferTimelineEnd: TimeInterval = 0

  @Published private(set) var videoDisplayWidth: Int = 0
  @Published private(set) var videoDisplayHeight: Int = 0
  @Published private(set) var streamFPS: Double = 0
  @Published private(set) var renderFPS: Double = 0
  @Published private(set) var videoBitrate: Double = 0
  @Published private(set) var droppedFrameCount: Int64 = 0
  @Published private(set) var delayedFrameCount: Int64 = 0
  @Published private(set) var cacheBufferingState: Double = 0
  @Published private(set) var cacheDurationSeconds: Double = 0
  @Published private(set) var avSyncSeconds: Double = 0
  @Published private(set) var networkSpeedBps: Double = 0
  @Published private(set) var hwdecCurrent: String = ""
  @Published private(set) var videoCodecName: String = ""

  /// Bumped whenever `videoView` may point to a new UIView (engine fallback swaps the
  /// player instance); the SwiftUI surface remounts on change.
  @Published private(set) var surfaceRevision = 0
  /// Real AirPlay (external playback) is only possible on the AVPlayer engine; the remux candidacy
  /// on the FFmpeg path is computed by `VideoPlayerController`.
  @Published private(set) var isAirPlayVideoCapable = false
  /// Is the active player KSMEPlayer (the FFmpeg path)? A component of remux candidacy.
  @Published private(set) var isFFmpegBackendActive = false
  /// The active audio codec for debug overlay diagnosis + remux candidacy.
  @Published private(set) var audioCodecName: String = ""
  /// Current subtitle cue for the overlay (nil = hide).
  @Published private(set) var subtitleText: NSAttributedString?
  @Published private(set) var subtitleImage: UIImage?
  /// Native-frame pixel position of `subtitleImage` (PGS/DVB bitmap cues), from
  /// `SubtitlePart.origin`; `.zero` when the image spans multiple merged regions.
  @Published private(set) var subtitleImageOrigin: CGPoint = .zero
  @Published private(set) var subtitleAppearance = SubtitleAppearancePersistence.load()
  @Published private(set) var isPiPActive = false

  var changePublisher: AnyPublisher<Void, Never> {
    objectWillChange.eraseToAnyPublisher()
  }

  var videoView: UIView? { layer?.player.view }
  var isExternalPlaybackActive: Bool { layer?.player.isExternalPlaybackActive ?? false }

  private(set) var layer: KSPlayerLayer?
  private let subtitleModel = SubtitleModel()
  /// Reported subtitle track id → info. Ids are stable per load (insertion order).
  private var subtitleInfosById: [Int: any SubtitleInfo] = [:]
  private var removedSubtitleIDs: Set<String> = []
  private var externalSubtitleIDs: Set<String> = []
  private var embeddedSubtitleSourceAttached = false
  private var pendingAudioDelay: Double = 0
  private var loadTimeoutWorkItem: DispatchWorkItem?
  private var lastPositionPublish: TimeInterval = 0
  private var isDisposed = false
  /// Cached quarter-rotation of the current AVPlayer video track. Synchronous
  /// `preferredTransform` access is deprecated (iOS 16); the transform is loaded
  /// asynchronously once per track and consumed by `refreshDiagnostics`.
  private weak var quarterRotationQueriedTrack: AVAssetTrack?
  private var avTrackIsQuarterRotated = false

  // MARK: - Load

  func load(
    _ url: URL,
    play: Bool,
    startSeconds: TimeInterval?,
    liveLowLatency: Bool,
    userAgent: String?
  ) {
    guard !isDisposed else { return }
    resetForNewLoad()
    subtitleModel.url = url
    // Round 20 (R20-4): build-33 engine selection restored — the
    // engine order is chosen by content type only. In containers
    // AVPlayer cannot play (mkv/avi/ts/extensionless live TS),
    // waiting for AVPlayer to be tried and fail first was extending
    // the opening by seconds; start directly with FFmpeg. (The
    // round-11 `player.enginePreference` override and the round-17
    // alternate-engine flip are removed; build 33 wins.)
    if Self.prefersFFmpegFirst(for: url) {
      KSOptions.firstPlayerType = KSMEPlayer.self
      KSOptions.secondPlayerType = KSAVPlayer.self
    } else {
      KSOptions.firstPlayerType = KSAVPlayer.self
      KSOptions.secondPlayerType = KSMEPlayer.self
    }
    let options = Self.makeOptions(
      liveLowLatency: liveLowLatency,
      startSeconds: startSeconds,
      userAgent: userAgent
    )
    // The layer is built from scratch on every load. The `layer.set(url:)` path is NOT USED:
    // KSPlayerLayer.url.didSet, while any wireless route is active,
    // it overrides our choice and forces KSAVPlayer (a long failure + fallback wait on mkv/ts
    // — the second root cause of the "content won't open" complaint). The init path
    // stays faithful to the statics.
    if let oldLayer = layer {
      oldLayer.delegate = nil
      oldLayer.stop()
    }
    layer = KSPlayerLayer(url: url, isAutoPlay: play, options: options, delegate: self)
    bumpSurfaceRevision()
    isReady = true
    scheduleLoadTimeoutWatchdog()
  }

  /// Non-terminal stop: releases the layer (and its source connection) but keeps
  /// the engine reusable. Used when a cast engagement takes over playback.
  /// NOTE: `KSPlayerLayer.deinit` calls `MPRemoteCommandCenter removeTarget(nil)`
  /// unconditionally — the owner must reinstall its remote commands after this.
  func stopPlayback() {
    guard !isDisposed else { return }
    cancelLoadTimeoutWatchdog()
    layer?.delegate = nil
    layer?.stop()
    layer = nil
    if !isBuffering { isBuffering = true }
  }

  private func resetForNewLoad() {
    cancelLoadTimeoutWatchdog()
    playbackFailureMessage = nil
    playbackFailureIsRecoverable = false
    playbackFailureIsProviderRefusal = false
    isPlaybackEstablished = false
    hasRenderedFirstFrame = false
    isCompleted = false
    isBuffering = true
    isPaused = true
    isSeekable = false
    position = 0
    duration = 0
    bufferTimelineEnd = 0
    subtitleText = nil
    subtitleImage = nil
    subtitleImageOrigin = .zero
    subtitleInfosById = [:]
    removedSubtitleIDs = []
    externalSubtitleIDs = []
    embeddedSubtitleSourceAttached = false
    // Codec/capability diagnostics belong to the previous content; a stale value
    // must not gate AirPlay/remux candidacy for the next one.
    videoCodecName = ""
    audioCodecName = ""
    isFFmpegBackendActive = false
    isAirPlayVideoCapable = false
  }

  /// The extensions AVPlayer can play natively; everything else (mkv, avi, ts,
  /// extensionless Xtream live) goes to FFmpeg. Exactly the behavior of the mpv era —
  /// only the HLS/mp4 family goes up to AVPlayer (and real AirPlay).
  private static let avPlayerExtensions: Set<String> = [
    "m3u8", "mp4", "m4v", "mov", "mp3", "m4a", "aac",
  ]

  static func prefersFFmpegFirst(for url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return !avPlayerExtensions.contains(ext)
  }

  private static func makeOptions(
    liveLowLatency: Bool,
    startSeconds: TimeInterval?,
    userAgent: String?
  ) -> KSOptions {
    let options = KSOptions()
    if let userAgent, !userAgent.isEmpty {
      options.userAgent = userAgent
      // `KSOptions.userAgent` only sets the FFmpeg header (`formatContextOptions`). The
      // native path builds `AVURLAsset(url:options: options.avOptions)`, so without this
      // AVPlayer sends the default `AppleCoreMedia` UA. Panels that gate on User-Agent
      // reject that → AVPlayer fails → falls back to FFmpeg, losing native playback AND
      // native AirPlay. Mirror the UA onto the asset HTTP headers so UA-compatible content
      // stays on AVPlayer. (Set avOptions directly rather than `appendHeader`, which would
      // also duplicate the UA into the FFmpeg `headers` option.)
      var assetHeaders =
        options.avOptions["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String] ?? [:]
      assetHeaders["User-Agent"] = userAgent
      options.avOptions["AVURLAssetHTTPHeaderFieldsKey"] = assetHeaders
    }
    if let startSeconds, startSeconds > 0 {
      options.startPlayTime = startSeconds
    }
    // isSecondOpen: the first frame is released once each part decodes 2 frames — it shortens the opening
    // time. NOTE: therefore preferredForwardBufferDuration/maxBufferDuration does NOT
    // delay the FIRST frame; it only manages the re-buffer cushion and seek/second-open.
    options.isSecondOpen = true
    if liveLowLatency {
      // Round 20 (R20-4): build-33 buffer cushion restored
      // (2 s forward / 16 s max); the round-18 deepening is removed.
      options.preferredForwardBufferDuration = 2
      options.maxBufferDuration = 16
      // On the FFmpeg path, the first frame was stuck on avformat_find_stream_info's default 5 MB probe
      // being pulled over a slow IPTV socket. These two values are the values proven in the field
      // on the app's own remux input path (RemuxHLSWriter); on the AVPlayer/HLS [path]
      // path these fields are not read (inert). `nobuffer` is deliberately OFF — find_stream_info
      // it can cause the secondary audio track to be missed.
      // (These are build 33's own values — 1.5 MB / 2 s.)
      options.probesize = 1_500_000
      options.maxAnalyzeDuration = 2_000_000  // AV_TIME_BASE birimi = 2.0s
    } else {
      // Round 20 (R20-4): build-33 VOD cushion restored
      // (3 s forward / 60 s max); the round-18 raising is removed.
      options.preferredForwardBufferDuration = 3
      options.maxBufferDuration = 60
      // VOD (mkv/avi/ts): limit the worst-case analysis time without leaving multi-part headers closed.
      options.maxAnalyzeDuration = 3_000_000  // 3.0s tavan
    }
    // Let a single IO on a stalled socket fail in 10 sec; FFmpeg returns the real error code
    // before the watchdog (12s) kicks in. Only the FFmpeg path (AVPlayer ignores this).
    options.formatContextOptions["rw_timeout"] = 10_000_000  // mikrosaniye
    // Round 20 (R20-4): the round-18 FFmpeg HTTP reconnect options
    // are removed — build 33 set only `rw_timeout` here.
    // Remote commands are ours (VideoPlayerController). KSPlayerLayer's own
    // registration would double-handle events; its deinit still wipes all
    // targets regardless of this flag, which the controller compensates for.
    options.registerRemoteControll = false
    let defaults = UserDefaults.standard
    let pipEnabled = defaults.object(forKey: "player.pipEnabled") as? Bool ?? true
    let backgroundEnabled =
      defaults.object(forKey: "player.continuePlayingInBackground") as? Bool ?? true
    options.canStartPictureInPictureAutomaticallyFromInline = pipEnabled && backgroundEnabled
    // KSPlayerLayer manages the background transition itself (it doesn't touch it if PiP is active):
    // true → video decode durur ses sürer; false → pause.
    KSOptions.canBackgroundPlay = backgroundEnabled
    return options
  }

  // MARK: - Transport

  func play() {
    if isCompleted {
      layer?.seek(time: 0, autoPlay: true) { _ in }
      isCompleted = false
      return
    }
    layer?.play()
  }

  func pause() {
    layer?.pause()
  }

  func seek(to seconds: TimeInterval) {
    let target = max(seconds, 0)
    layer?.seek(time: target, autoPlay: !isPaused) { _ in }
  }

  func seekToFraction(_ pos: Float) {
    guard duration > 0 else { return }
    seek(to: duration * Double(min(max(pos, 0), 1)))
  }

  func jumpRelative(seconds: Int) {
    seek(to: position + Double(seconds))
  }

  func setVolume(_ value: Double) {
    layer?.player.playbackVolume = Float(min(max(value, 0), 125) / 100)
  }

  func setPlaybackRate(_ value: Double) {
    layer?.player.playbackRate = Float(value)
    if playbackRate != value { playbackRate = value }
  }

  /// Backgrounded without PiP: stop video decode, keep audio (KSPlayer built-in path).
  func setVideoDecodingSuspended(_ suspended: Bool) {
    guard let player = layer?.player else { return }
    if suspended {
      player.enterBackground()
    } else {
      player.enterForeground()
    }
  }

  func dispose() {
    guard !isDisposed else { return }
    isDisposed = true
    cancelLoadTimeoutWatchdog()
    layer?.stop()
    layer = nil
  }

  // MARK: - PiP

  func setPictureInPictureActive(_ active: Bool) {
    layer?.isPipActive = active
    refreshPiPState()
  }

  func togglePictureInPicture() {
    setPictureInPictureActive(!(layer?.isPipActive ?? false))
  }

  private func refreshPiPState() {
    let active = layer?.isPipActive ?? false
    if isPiPActive != active { isPiPActive = active }
  }

  // MARK: - Tracks

  func reloadTrackList(
    completion: @escaping (
      [TrackMenuOption], [TrackMenuOption], [TrackMenuOption], Int, Int, Int
    ) -> Void
  ) {
    guard let player = layer?.player else {
      completion([], [], [TrackMenuOption(id: -1, title: L("player.subtitle_off"))], -1, -1, -1)
      return
    }
    attachEmbeddedSubtitleSourceIfNeeded()

    let videoTracks = player.tracks(mediaType: .video)
    let audioTracks = player.tracks(mediaType: .audio)

    let video = Self.disambiguated(videoTracks.map { Self.menuOption(for: $0) })
    let audio = Self.disambiguated(audioTracks.map { Self.menuOption(for: $0) })

    var subs: [TrackMenuOption] = [TrackMenuOption(id: -1, title: L("player.subtitle_off"))]
    subtitleInfosById = [:]
    var nextId = 0
    var currentSubId = -1
    for info in subtitleModel.subtitleInfos {
      if removedSubtitleIDs.contains(info.subtitleID) { continue }
      let id = nextId
      nextId += 1
      subtitleInfosById[id] = info
      let isExternal = externalSubtitleIDs.contains(info.subtitleID)
      // Round 20 (R20-1): embedded subtitle infos carry no separate
      // language field at this construction site — KSPlayer names
      // them with the stream's raw language code ("dan", "hin", …),
      // which is exactly what the owner's photo shows in the menu.
      // When the whole name IS a bare language code, show the
      // localized language name instead and record the code on the
      // option, so PlaybackTrackPreferences matches by language
      // rather than by the fragile title token. External
      // (imported-file) entries are NEVER renamed:
      // VideoPlayerController matches them by exact title against
      // the imported file names.
      var subTitle = info.name
      var subLangCode: String? = nil
      if !isExternal,
         let code = Self.languageCode(fromWholeTrackName: info.name),
         let languageName = Self.displayLanguageName(forCode: code)
      {
        subTitle = languageName
        subLangCode = code
      }
      subs.append(
        TrackMenuOption(
          id: id,
          title: subTitle,
          langCode: subLangCode,
          isExternal: isExternal
        )
      )
      if subtitleModel.selectedSubtitleInfo?.subtitleID == info.subtitleID {
        currentSubId = id
      }
    }
    subs = Self.disambiguated(subs)

    let currentVideo = videoTracks.first { $0.isEnabled }.map { Int($0.trackID) } ?? -1
    let currentAudio = audioTracks.first { $0.isEnabled }.map { Int($0.trackID) } ?? -1
    completion(video, audio, subs, currentVideo, currentAudio, currentSubId)
  }

  private static func menuOption(for track: MediaPlayerTrack) -> TrackMenuOption {
    let rawName = track.name.trimmingCharacters(in: .whitespaces)
    // Round 20 (R20-1): the menu showed `track.name` verbatim, and
    // for audio/subtitle streams that name IS the raw ISO code
    // ("dan", "cze", "hin", …) — the owner's photo. Build the
    // display title from the track's real language code instead:
    // the full language name in the app's current UI language
    // (Foundation's localized name, never a hand-written table).
    var langCode = track.languageCode
    if (langCode ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
       let parsed = languageCode(fromWholeTrackName: rawName)
    {
      // No reported language code, but the name itself is a bare
      // code — that code IS the track's language; recording it on
      // the option also lets preferences match by language.
      langCode = parsed
    }
    let languageName = displayLanguageName(forCode: langCode)
    // A stream-provided title that says MORE than the language
    // (e.g. "Hindi [SDH]", a commentary label) is kept as a suffix
    // so same-language tracks stay distinguishable by their real
    // metadata. A name that merely restates the language — as the
    // raw code, or as the language's name in the UI language or in
    // English — is not a distinct title and is dropped.
    var streamTitle: String? = nil
    if !rawName.isEmpty {
      let rawIsOwnCode =
        normalizedLanguageCode(rawName) != nil
        && normalizedLanguageCode(rawName) == normalizedLanguageCode(langCode)
      let rawIsOtherCode = languageCode(fromWholeTrackName: rawName) != nil
      let rawIsLanguageName =
        (languageName != nil && rawName.caseInsensitiveCompare(languageName!) == .orderedSame)
        || englishLanguageName(forCode: langCode).map {
          rawName.caseInsensitiveCompare($0) == .orderedSame
        } ?? false
      if !rawIsOwnCode && !rawIsOtherCode && !rawIsLanguageName {
        streamTitle = rawName
      }
    }
    // FFmpeg often reports no title; "Track N" style fallbacks must not be stored
    // as a preference (see TrackMenuOption.isSyntheticTitle). A title
    // resolved from the language code is real metadata, not synthetic.
    let synthetic = rawName.isEmpty && languageName == nil
    let title: String
    if let languageName {
      title = streamTitle.map { "\(languageName) — \($0)" } ?? languageName
    } else if let streamTitle {
      title = streamTitle
    } else {
      title = L("player.tracks.fallback_title", Int(track.trackID))
    }
    var detailParts: [String] = []
    if track.mediaType == .video {
      let size = track.formatDescription.map { CMVideoFormatDescriptionGetDimensions($0) }
      if let size, size.width > 0 {
        detailParts.append("\(size.width)×\(size.height)")
      }
    }
    if track.bitRate > 0 {
      detailParts.append("\(track.bitRate / 1000) kbps")
    }
    return TrackMenuOption(
      id: Int(track.trackID),
      title: title,
      detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
      langCode: langCode,
      isSyntheticTitle: synthetic
    )
  }

  // MARK: - Track title localization (R20-1)

  /// Primary subtag of a language code ("en-US" / "en_US" → "en"),
  /// lowercased; nil for nil/empty input.
  private static func normalizedLanguageCode(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return nil }
    let primary =
      trimmed.replacingOccurrences(of: "_", with: "-")
        .split(separator: "-").first.map(String.init) ?? trimmed
    return primary.isEmpty ? nil : primary
  }

  /// ISO 639-2/B bibliographic codes whose terminological/639-1
  /// form differs (ger ≠ deu, cze ≠ ces, …). This maps CODES only —
  /// every display NAME still comes from Foundation. Used when
  /// `localizedString(forLanguageCode:)` does not resolve the
  /// bibliographic form directly.
  private static let bibliographicCodeAliases: [String: String] = [
    "ger": "de", "fre": "fr", "cze": "cs", "chi": "zh", "per": "fa",
    "rum": "ro", "slo": "sk", "alb": "sq", "mac": "mk", "may": "ms",
    "dut": "nl", "gre": "el", "arm": "hy", "baq": "eu", "bur": "my",
    "geo": "ka", "ice": "is", "mao": "mi", "tib": "bo", "wel": "cy",
  ]

  /// The full language name for a code, in the given locale;
  /// nil when the code is missing or Foundation has no name for
  /// it (an echoed-back code counts as "no name" — never invent).
  private static func languageName(forCode rawCode: String?, in locale: Locale) -> String? {
    guard let code = normalizedLanguageCode(rawCode) else { return nil }
    let candidates = [bibliographicCodeAliases[code], code].compactMap { $0 }
    for candidate in candidates {
      if let name = locale.localizedString(forLanguageCode: candidate),
         !name.isEmpty,
         name.lowercased() != candidate
      {
        return name
      }
    }
    return nil
  }

  /// The language name in the app's current UI language — the
  /// same locale the rest of the app binds to (`AppTheme.appLocale`,
  /// the C9 one-locale law), NOT the device locale.
  private static func displayLanguageName(forCode rawCode: String?) -> String? {
    languageName(forCode: rawCode, in: AppTheme.appLocale)
  }

  private static func englishLanguageName(forCode rawCode: String?) -> String? {
    languageName(forCode: rawCode, in: Locale(identifier: "en"))
  }

  /// The code when a whole track name IS a bare language code
  /// ("hin", "eng", "cze" — 2–3 ASCII letters that Foundation can
  /// name); nil for real titles, file names, or unknown strings.
  private static func languageCode(fromWholeTrackName name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (2...3).contains(trimmed.count),
          trimmed.allSatisfy({ $0.isASCII && $0.isLetter })
    else { return nil }
    let code = trimmed.lowercased()
    return displayLanguageName(forCode: code) != nil ? code : nil
  }

  /// Numbers entries whose display titles are still identical
  /// after language naming and stream-title suffixes ("Hindi",
  /// "Hindi 2", "Hindi 3" — first occurrence unnumbered, numbering
  /// follows list order, so it is stable for a given track list).
  /// The subtitle "Off" entry (id -1) and external entries (matched
  /// by exact title elsewhere) are never renamed. The suffix is a
  /// bare number — no new localized string is introduced.
  private static func disambiguated(_ options: [TrackMenuOption]) -> [TrackMenuOption] {
    var seen: [String: Int] = [:]
    return options.map { option in
      guard option.id >= 0, !option.isExternal else { return option }
      let occurrence = (seen[option.title] ?? 0) + 1
      seen[option.title] = occurrence
      guard occurrence > 1 else { return option }
      return TrackMenuOption(
        id: option.id,
        title: "\(option.title) \(occurrence)",
        detail: option.detail,
        langCode: option.langCode,
        isExternal: option.isExternal,
        isSyntheticTitle: option.isSyntheticTitle
      )
    }
  }

  func selectVideoTrack(id: Int) {
    guard let player = layer?.player,
          let track = player.tracks(mediaType: .video).first(where: { Int($0.trackID) == id })
    else { return }
    player.select(track: track)
  }

  func selectAudioTrack(id: Int) {
    guard let player = layer?.player,
          let track = player.tracks(mediaType: .audio).first(where: { Int($0.trackID) == id })
    else { return }
    player.select(track: track)
    applyAudioDelayToSelectedTrack()
  }

  func selectSubtitleTrack(id: Int) {
    if id < 0 {
      subtitleModel.selectedSubtitleInfo = nil
      subtitleText = nil
      subtitleImage = nil
      subtitleImageOrigin = .zero
      return
    }
    guard let info = subtitleInfosById[id] else { return }
    subtitleModel.selectedSubtitleInfo = info
  }

  // MARK: - Subtitles

  private func attachEmbeddedSubtitleSourceIfNeeded() {
    guard !embeddedSubtitleSourceAttached,
          let dataSource = layer?.player.subtitleDataSouce
    else { return }
    embeddedSubtitleSourceAttached = true
    subtitleModel.addSubtitle(dataSouce: dataSource)
  }

  func addExternalSubtitle(filePath: String, title: String, select: Bool) {
    let url = URL(fileURLWithPath: filePath)
    let info = URLSubtitleInfo(subtitleID: url.absoluteString, name: title, url: url)
    removedSubtitleIDs.remove(info.subtitleID)
    externalSubtitleIDs.insert(info.subtitleID)
    subtitleModel.addSubtitle(info: info)
    if select {
      subtitleModel.selectedSubtitleInfo = info
    }
  }

  func removeExternalSubtitle(id: Int) {
    guard let info = subtitleInfosById[id] else { return }
    // SubtitleModel has no removal API; hide the entry and drop the selection.
    removedSubtitleIDs.insert(info.subtitleID)
    if subtitleModel.selectedSubtitleInfo?.subtitleID == info.subtitleID {
      subtitleModel.selectedSubtitleInfo = nil
      subtitleText = nil
      subtitleImage = nil
      subtitleImageOrigin = .zero
    }
  }

  func setSubDelay(seconds: Double) {
    subtitleModel.subtitleDelay = seconds
  }

  func setAudioDelay(seconds: Double) {
    pendingAudioDelay = seconds
    applyAudioDelayToSelectedTrack()
  }

  /// KSMEPlayer only: FFmpeg audio tracks expose a per-track delay. The AVPlayer
  /// path has no equivalent — the setting is a silent no-op there.
  private func applyAudioDelayToSelectedTrack() {
    guard let player = layer?.player else { return }
    for track in player.tracks(mediaType: .audio) {
      if let ffTrack = track as? FFmpegAssetTrack, track.isEnabled {
        ffTrack.delay = pendingAudioDelay
      }
    }
  }

  func applySubtitleAppearanceFromSettings(_ settings: SubtitleAppearanceSettings) {
    subtitleAppearance = settings
    setSubDelay(seconds: settings.delaySeconds)
  }

  /// Drives the subtitle overlay from an external clock — used while a cast
  /// engagement is presenting (the layer is stopped, but external SRT subtitles
  /// can still be rendered over the cast placeholder).
  func updateSubtitleCue(at seconds: TimeInterval) {
    guard !isDisposed else { return }
    if subtitleModel.subtitle(currentTime: seconds) {
      let part = subtitleModel.parts.first
      subtitleText = part?.text
      subtitleImage = part?.image
      subtitleImageOrigin = part?.origin ?? .zero
    }
  }

  // MARK: - Watchdog

  // Round 20 (R20-4): build-33 watchdog restored verbatim in
  // behavior — it fires ONLY for a stream that never establishes.
  // The round-14/18 mid-stream stall re-arm (6 s stall window) is
  // removed; build 33 wins.
  private func scheduleLoadTimeoutWatchdog() {
    cancelLoadTimeoutWatchdog()
    let item = DispatchWorkItem { [weak self] in
      guard let self, !self.isDisposed else { return }
      if !self.isPlaybackEstablished, self.playbackFailureMessage == nil {
        self.playbackFailureIsRecoverable = true
        self.playbackFailureMessage = L("playback.error.timeout")
      }
    }
    loadTimeoutWorkItem = item
    // Kept strictly above the 10s FFmpeg rw_timeout so its specific error surfaces first;
    // trimmed from 16s so a dead channel doesn't spin the spinner as long.
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: item)
  }

  private func cancelLoadTimeoutWatchdog() {
    loadTimeoutWorkItem?.cancel()
    loadTimeoutWorkItem = nil
  }

  private func bumpSurfaceRevision() {
    surfaceRevision += 1
  }

  private func refreshDiagnostics() {
    guard let player = layer?.player else { return }
    // Round 19: the round-14 video-gravity re-assertion is REMOVED —
    // nothing in the engine touches the render layer's content mode
    // or video gravity any more; the layer keeps KSPlayer's own
    // default (aspect-fit), exactly as in the reference player.
    var size = player.naturalSize
    // AVPlayer's naturalSize is the encoded (unrotated) frame — it never consults the
    // track's preferredTransform, unlike the FFmpeg path's display-matrix handling.
    if let avPlayer = player as? KSAVPlayer,
       let assetTrack = avPlayer.player.currentItem?.tracks
         .first(where: { $0.isEnabled && $0.assetTrack?.mediaType == .video })?.assetTrack {
      updateQuarterRotation(for: assetTrack)
      if avTrackIsQuarterRotated {
        size = CGSize(width: size.height, height: size.width)
      }
    }
    let w = Int(size.width)
    let h = Int(size.height)
    if videoDisplayWidth != w { videoDisplayWidth = w }
    if videoDisplayHeight != h { videoDisplayHeight = h }
    let fps = Double(player.nominalFrameRate)
    if streamFPS != fps { streamFPS = fps }
    if let info = player.dynamicInfo {
      if renderFPS != info.displayFPS { renderFPS = info.displayFPS }
      let dropped = Int64(info.droppedVideoFrameCount)
      if droppedFrameCount != dropped { droppedFrameCount = dropped }
      if avSyncSeconds != info.audioVideoSyncDiff { avSyncSeconds = info.audioVideoSyncDiff }
      let bitrate = Double(info.videoBitrate)
      if videoBitrate != bitrate { videoBitrate = bitrate }
    }
    if let track = player.tracks(mediaType: .video).first(where: { $0.isEnabled }) {
      let codec = Self.codecName(of: track)
      if !codec.isEmpty, videoCodecName != codec { videoCodecName = codec }
    }
    if let track = player.tracks(mediaType: .audio).first(where: { $0.isEnabled }) {
      let codec = Self.codecName(of: track)
      if !codec.isEmpty, audioCodecName != codec { audioCodecName = codec }
    }
    let isAVPlayer = !(player is KSMEPlayer)
    let ffmpegActive = !isAVPlayer
    if isFFmpegBackendActive != ffmpegActive { isFFmpegBackendActive = ffmpegActive }
    let engineName = isAVPlayer ? "avplayer" : "ffmpeg"
    if hwdecCurrent != engineName { hwdecCurrent = engineName }
    // AVPlayer yolunda native external playback mümkün; FFmpeg yolundaki remux
    // the controller computes its candidacy.
    if isAirPlayVideoCapable != isAVPlayer { isAirPlayVideoCapable = isAVPlayer }
  }

  /// Loads `preferredTransform` asynchronously (the sync property is deprecated since
  /// iOS 16) once per track and caches whether the frame is quarter-rotated. The load
  /// is near-instant for an already-playing item, and diagnostics are re-run on
  /// completion so the swapped size is published without waiting for the next tick.
  private func updateQuarterRotation(for track: AVAssetTrack) {
    guard quarterRotationQueriedTrack !== track else { return }
    quarterRotationQueriedTrack = track
    avTrackIsQuarterRotated = false
    Task { [weak self] in
      guard let transform = try? await track.load(.preferredTransform) else { return }
      guard let self, !self.isDisposed, self.quarterRotationQueriedTrack === track else { return }
      let rotated = Self.isQuarterRotated(transform)
      if rotated != self.avTrackIsQuarterRotated {
        self.avTrackIsQuarterRotated = rotated
        self.refreshDiagnostics()
      }
    }
  }

  /// True for a ~90°/270° `preferredTransform` (portrait-recorded mp4/mov), where the
  /// encoded frame's width/height are swapped relative to the displayed orientation.
  private static func isQuarterRotated(_ transform: CGAffineTransform) -> Bool {
    var degrees = atan2(transform.b, transform.a) * 180 / .pi
    if degrees < 0 { degrees += 360 }
    return abs(degrees - 90) <= 1 || abs(degrees - 270) <= 1
  }

  /// In FFmpeg tracks `codecName` is always populated but arrives with the profile attached ("h264 (High)");
  /// formatDescription can stay nil on live TS until the extradata arrives — detection is based on codecName's
  /// normalized first word.
  private static func codecName(of track: MediaPlayerTrack) -> String {
    if let ffTrack = track as? FFmpegAssetTrack, !ffTrack.codecName.isEmpty {
      return RemuxHLSWriter.normalizeCodec(ffTrack.codecName)
    }
    guard let desc = track.formatDescription else { return "" }
    let code = CMFormatDescriptionGetMediaSubType(desc)
    let bytes: [UInt8] = [
      UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
      UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
    ]
    return (String(bytes: bytes, encoding: .ascii) ?? "")
      .trimmingCharacters(in: .whitespaces).lowercased()
  }
}

// MARK: - KSPlayerLayerDelegate

extension KSPlayerEngine: KSPlayerLayerDelegate {
  func player(layer: KSPlayerLayer, state: KSPlayerState) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isDisposed, layer === self.layer else { return }
      switch state {
      case .initialized, .preparing:
        if !self.isBuffering { self.isBuffering = true }
      case .readyToPlay:
        self.cancelLoadTimeoutWatchdog()
        if !self.isPlaybackEstablished { self.isPlaybackEstablished = true }
        // Establishing playback always supersedes a stale watchdog/error message.
        if self.playbackFailureMessage != nil { self.playbackFailureMessage = nil }
        if self.playbackFailureIsRecoverable { self.playbackFailureIsRecoverable = false }
        if self.isBuffering { self.isBuffering = false }
        self.isSeekable = layer.player.seekable
        // AVPlayer path: true AirPlay external playback.
        layer.player.allowsExternalPlayback = true
        self.applyAudioDelayToSelectedTrack()
        self.attachEmbeddedSubtitleSourceIfNeeded()
        self.bumpSurfaceRevision()
      case .buffering:
        if !self.isBuffering { self.isBuffering = true }
      case .bufferFinished:
        if self.isBuffering { self.isBuffering = false }
        if self.isPaused != !layer.player.isPlaying {
          self.isPaused = !layer.player.isPlaying
        }
      case .paused:
        if !self.isPaused { self.isPaused = true }
      case .playedToTheEnd:
        if !self.isCompleted { self.isCompleted = true }
        if !self.isPaused { self.isPaused = true }
      case .error:
        break  // message arrives via finish(error:)
      }
      if state == .bufferFinished || state == .readyToPlay {
        let playing = layer.player.isPlaying
        if self.isPaused == playing { self.isPaused = !playing }
      }
      self.refreshPiPState()
      self.refreshDiagnostics()
    }
  }

  func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isDisposed, layer === self.layer else { return }
      // Round 18 (R18-1): the position callback only runs while
      // the playback clock advances — frames are on screen. This
      // is the first-frame signal the loading UI keys on.
      if !self.hasRenderedFirstFrame { self.hasRenderedFirstFrame = true }
      let now = CFAbsoluteTimeGetCurrent()
      // The counterpart of the 0.12s position throttle in the mpv engine.
      if now - self.lastPositionPublish >= 0.12 {
        self.lastPositionPublish = now
        if self.position != currentTime { self.position = currentTime }
        let total = totalTime.isFinite ? max(totalTime, 0) : 0
        if self.duration != total { self.duration = total }
        let playable = layer.player.playableTime
        if playable.isFinite, self.bufferTimelineEnd != playable {
          self.bufferTimelineEnd = playable
          self.cacheDurationSeconds = max(playable - currentTime, 0)
        }
        self.refreshDiagnostics()
      }
      if self.subtitleModel.subtitle(currentTime: currentTime) {
        let part = self.subtitleModel.parts.first
        self.subtitleText = part?.text
        self.subtitleImage = part?.image
        self.subtitleImageOrigin = part?.origin ?? .zero
      }
    }
  }

  func player(layer: KSPlayerLayer, finish error: Error?) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isDisposed, layer === self.layer else { return }
      self.cancelLoadTimeoutWatchdog()
      if let error {
        // Round 14 (A2): surface the REAL cause (HTTP status /
        // server refusal / unsupported codec) instead of only the
        // generic "check your network" text.
        let failure = Self.playbackFailure(for: error)
        self.playbackFailureIsRecoverable = failure.recoverable
        self.playbackFailureIsProviderRefusal = failure.providerRefusal
        self.playbackFailureMessage = failure.message
      } else {
        self.isCompleted = true
        self.isPaused = true
      }
    }
  }

  // MARK: - Failure mapping (round 14, A2)

  private struct PlaybackFailure {
    let message: String
    /// True only for transient failures worth the controller's one
    /// silent retry (timeout / host unreachable / HTTP 5xx). A
    /// server REFUSAL (401/403/404/451…) is terminal: retrying the
    /// same dead stream silently would just delay the real message.
    let recoverable: Bool
    /// Round 17 (R17-4): true when an HTTP 4xx was found in the
    /// error chain — the provider answered and refused. Distinct
    /// from `recoverable`: a NON-refusal open failure (e.g.
    /// `.formatOpenInput` with no HTTP status) is not recoverable
    /// in the same-form sense, but it IS eligible for the
    /// controller's one alternate-engine attempt.
    let providerRefusal: Bool
  }

  private static func playbackFailure(for error: Error) -> PlaybackFailure {
    // 1) An HTTP status anywhere in the error chain is the real
    //    cause — name it (the owner's provider answered 451/403
    //    while the app said "check your network").
    if let status = httpStatusCode(in: error) {
      switch status {
      case 401:
        return PlaybackFailure(message: L("playback.error.unauthorized"), recoverable: false, providerRefusal: true)
      case 403:
        return PlaybackFailure(message: L("playback.error.forbidden"), recoverable: false, providerRefusal: true)
      case 404:
        return PlaybackFailure(message: L("playback.error.not_found"), recoverable: false, providerRefusal: true)
      case 400...499:
        return PlaybackFailure(message: L("playback.error.http_status", status), recoverable: false, providerRefusal: true)
      default:
        return PlaybackFailure(message: L("playback.error.http_status", status), recoverable: true, providerRefusal: false)
      }
    }
    let ns = error as NSError
    // 2) URL loading failures keep their established mapping.
    if ns.domain == NSURLErrorDomain {
      switch ns.code {
      case NSURLErrorTimedOut:
        return PlaybackFailure(message: L("playback.error.timeout"), recoverable: true, providerRefusal: false)
      case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
           NSURLErrorNotConnectedToInternet:
        return PlaybackFailure(message: L("playback.error.cannot_reach"), recoverable: true, providerRefusal: false)
      default:
        return PlaybackFailure(message: L("playback.error.failed_check_network"), recoverable: false, providerRefusal: false)
      }
    }
    // 3) KSPlayer's own error codes distinguish "no playable
    //    stream" and codec failures from a generic open failure.
    if ns.domain == KSPlayerErrorDomain,
       let code = KSPlayerErrorCode(rawValue: ns.code) {
      switch code {
      case .videoTracksUnplayable:
        return PlaybackFailure(message: L("playback.error.no_playable_stream"), recoverable: false, providerRefusal: false)
      case .codecContextCreate, .codecContextSetParam, .codecContextFindDecoder,
           .codesContextOpen, .codecVideoSendPacket, .codecAudioSendPacket,
           .codecVideoReceiveFrame, .codecAudioReceiveFrame:
        return PlaybackFailure(message: L("playback.error.unsupported"), recoverable: false, providerRefusal: false)
      case .formatOpenInput, .formatFindStreamInfo:
        return PlaybackFailure(message: L("playback.error.failed_to_start"), recoverable: false, providerRefusal: false)
      default:
        break
      }
    }
    return PlaybackFailure(message: L("playback.error.failed_check_network"), recoverable: false, providerRefusal: false)
  }

  /// Extracts an HTTP status code from an error chain: FFmpeg
  /// errors carry it in the underlying `AVError` (both as its
  /// FourCC-style code and inside its message, e.g. "Server
  /// returned 403 Forbidden"), AVPlayer errors describe it in
  /// their localized text / underlying errors.
  private static func httpStatusCode(in error: Error) -> Int? {
    var texts: [String] = []
    var avErrorCodes: [Int32] = []
    func collect(_ err: Error, depth: Int) {
      guard depth < 5 else { return }
      if let avError = err as? KSPlayer.AVError {
        texts.append(avError.message)
        avErrorCodes.append(avError.code)
      }
      let ns = err as NSError
      texts.append(ns.localizedDescription)
      if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
        collect(underlying, depth: depth + 1)
      }
    }
    collect(error, depth: 0)
    for code in avErrorCodes {
      for status in 400...599 where ffmpegHTTPErrorCode(forStatus: status) == code {
        return status
      }
    }
    let text = texts.joined(separator: " ")
    if let match = firstCapture(
      pattern: #"(?i)(?:http|status|returned)\D{0,24}([1-5][0-9]{2})"#, in: text
    ), let status = Int(match) {
      return status
    }
    if let match = firstCapture(
      pattern: #"\b(401|403|404|408|451|500|502|503|504)\b"#, in: text
    ), let status = Int(match) {
      return status
    }
    return nil
  }

  private static func firstCapture(pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }

  /// FFmpeg's `AVERROR_HTTP_*` codes are `FFERRTAG(0xF8, '4','0','3')`
  /// style FourCC tags of the status digits, negated.
  private static func ffmpegHTTPErrorCode(forStatus status: Int) -> Int32 {
    let digits = String(status).utf8.map { Int32($0) }
    guard digits.count == 3 else { return 0 }
    return -(0xF8 | (digits[0] << 8) | (digits[1] << 16) | (digits[2] << 24))
  }

  func player(layer _: KSPlayerLayer, bufferedCount _: Int, consumeTime _: TimeInterval) {}
}
