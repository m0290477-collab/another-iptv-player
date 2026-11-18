import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

/// FFmpeg remux: kaynak URL (mkv/ts/avi…) → HLS segmentleri. Video daima passthrough
/// (H.264/HEVC); if the audio is compatible it is passed through, otherwise (MP2/DTS/TrueHD…) it is transcoded to AAC.
/// It runs on a background queue.
///
/// Two segment forms:
/// - H.264 → MPEG-TS segments (the `hls` muxer is not compiled into FFmpegKit; segmentation with the mpegts muxer
///   + m3u8 production is done manually, verified on device).
/// - HEVC → fMP4 segments (the HLS spec does not accept HEVC in TS): a single `mp4` muxer,
///   It produces fragments at our boundaries with `frag_custom`; the bytes are captured via custom AVIO
///   and split into init.mp4 + segNNNNN.m4s files.
final class RemuxHLSWriter {
  enum RemuxError: LocalizedError {
    case openInputFailed(Int32)
    case noCompatibleStreams
    case openOutputFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)

    var errorDescription: String? {
      switch self {
      case let .openInputFailed(code): return "remux: input open failed (\(code))"
      case .noCompatibleStreams: return "remux: no AVPlayer-compatible streams"
      case let .openOutputFailed(code): return "remux: output open failed (\(code))"
      case let .writeFailed(code): return "remux: write failed (\(code))"
      case let .readFailed(code): return "remux: source read failed (\(code))"
      }
    }
  }

  /// AVERROR_EOF — FFERRTAG('E','O','F',' '); the function-like C macro is not
  /// imported into Swift.
  private static let avErrorEOF: Int32 = -541_478_725

  enum SegmentFormat {
    case mpegTS
    case fmp4
  }

  static let compatibleVideoCodecs: Set<UInt32> = [
    AV_CODEC_ID_H264.rawValue, AV_CODEC_ID_HEVC.rawValue,
  ]
  /// Audio suitable for passthrough; it varies by form. Every audio outside the list is transcoded
  /// to AAC (if a decoder exists; otherwise the audio is dropped and the video goes silent).
  private static let fmp4AudioPassthrough: Set<UInt32> = [
    AV_CODEC_ID_AAC.rawValue, AV_CODEC_ID_AC3.rawValue, AV_CODEC_ID_EAC3.rawValue,
  ]
  private static let tsAudioPassthrough: Set<UInt32> = [
    AV_CODEC_ID_AAC.rawValue, AV_CODEC_ID_AC3.rawValue, AV_CODEC_ID_EAC3.rawValue,
    AV_CODEC_ID_MP3.rawValue,
  ]

  private let sourceURL: URL
  private let outputDirectory: URL
  private let startSeconds: TimeInterval
  private let isLive: Bool
  private let userAgent: String?
  /// The time to wait before the input is opened: it gives a just-closed connection
  /// (previous session / phone player) a chance to die at the panel —
  /// on connection-limited panels, a first-open collision was turning into a permanent error.
  /// If `readyToOpen` is given, this value is not a fixed delay but an UPPER LIMIT.
  private let openDelaySeconds: Double
  /// If given: before opening the input, wait until this condition becomes true (or the `openDelaySeconds`
  /// limit is reached). On a zap, it guarantees waiting until the previous session's source connection actually
  /// closes and the panel frees its slot.
  private let readyToOpen: (() -> Bool)?
  private let targetSegmentSeconds: Double
  /// The number of segments kept in the playlist on live (sliding window). VOD uses an event playlist
  /// (all segments stay): the sliding-window/live-view attempt produced stall and window-escape
  /// problems in the field and was reverted by the user's decision.
  private let liveWindowSize = 8
  /// Allows forcing the form for testing; nil = automatic by codec.
  let forcedFormat: SegmentFormat?

  /// External subtitle to expose to the AirPlay target as an HLS WebVTT rendition.
  /// nil = cast video-only (unchanged behaviour). Phase 1: TS/VOD only.
  private let subtitleFileURL: URL?
  private let subtitleName: String?
  private let subtitleLanguage: String?
  private var subtitleAssetsWritten = false
  private let clientPlaylistLock = NSLock()
  private var clientPlaylistFileNameStorage = "stream.m3u8"
  /// Filename the cast AVPlayer should load: the subtitle master once a rendition has
  /// been written, else the raw video playlist. Written on the remux thread, read by the
  /// session after playlist readiness (well after the first segment), hence the lock.
  var clientPlaylistFileName: String {
    clientPlaylistLock.lock(); defer { clientPlaylistLock.unlock() }
    return clientPlaylistFileNameStorage
  }
  private func setClientPlaylistFileName(_ name: String) {
    clientPlaylistLock.lock(); clientPlaylistFileNameStorage = name; clientPlaylistLock.unlock()
  }

  private let queue = DispatchQueue(label: "AirPlayRemux.writer", qos: .userInitiated)
  /// The interrupt callback reads it; it breaks the blocking av_read_frame on cancellation.
  private let cancelled = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
  /// The remux loop has fully resolved and the source connection (avformat_close_input) has closed.
  /// The next session understands from here that the panel slot has been freed.
  private let closedLock = NSLock()
  private var sourceClosed = false
  var isClosed: Bool {
    closedLock.lock()
    defer { closedLock.unlock() }
    return sourceClosed
  }
  private(set) var playlistURL: URL
  /// The source's total duration (written when the input opens; stays 0 on live).
  private(set) var sourceDurationSeconds: TimeInterval = 0
  /// The position the input seek ACTUALLY landed at. If `av_seek_frame` fails
  /// (unseekable source) it returns to 0 — the timeline accounting must look at this,
  /// aksi halde UI istenen konumu gösterirken cast 0:00'dan oynar.
  private(set) var effectiveStartSeconds: TimeInterval

  var onError: ((Error) -> Void)?

  // MARK: - VOD pacing (round-16 leaky bucket)

  /// On VOD the writer writes at most this far ahead of the playback position. If left unlimited,
  /// the whole movie downloads at line speed: the panel's connection limit saturates
  /// (handover errors), disk/battery are wasted.
  private let pacingAheadSeconds: Double = 25
  private let positionLock = NSLock()
  private var playbackPositionSeconds: Double = 0

  /// The cast player's source-time position; feeds the pacing gate.
  func updatePlaybackPosition(_ seconds: TimeInterval) {
    positionLock.lock()
    playbackPositionSeconds = seconds
    positionLock.unlock()
  }

  private func currentPlaybackPosition() -> Double {
    positionLock.lock()
    defer { positionLock.unlock() }
    return playbackPositionSeconds
  }

  /// If the written media time is ahead of the allowed window, it waits (cancellation-aware).
  /// Before playback starts, the base is the real start position (0 if the seek failed):
  /// the session accumulates the start buffer (12 sec < 25 sec window) unblocked.
  private func waitForPacing(mediaSeconds: Double) {
    guard !isLive else { return }
    while cancelled.pointee == 0 {
      let floorPosition = max(currentPlaybackPosition(), effectiveStartSeconds)
      if mediaSeconds <= floorPosition + pacingAheadSeconds { return }
      Thread.sleep(forTimeInterval: 0.2)
    }
  }

  init(
    sourceURL: URL,
    outputDirectory: URL,
    startSeconds: TimeInterval,
    isLive: Bool,
    userAgent: String?,
    openDelaySeconds: Double = 0,
    readyToOpen: (() -> Bool)? = nil,
    forcedFormat: SegmentFormat? = nil,
    subtitleFileURL: URL? = nil,
    subtitleName: String? = nil,
    subtitleLanguage: String? = nil
  ) {
    self.sourceURL = sourceURL
    self.outputDirectory = outputDirectory
    self.startSeconds = startSeconds
    self.isLive = isLive
    self.userAgent = userAgent
    self.openDelaySeconds = openDelaySeconds
    self.readyToOpen = readyToOpen
    self.forcedFormat = forcedFormat
    self.subtitleFileURL = subtitleFileURL
    self.subtitleName = subtitleName
    self.subtitleLanguage = subtitleLanguage
    effectiveStartSeconds = startSeconds
    targetSegmentSeconds = isLive ? 1.5 : 4
    cancelled.pointee = 0
    playlistURL = outputDirectory.appendingPathComponent("stream.m3u8")
  }

  deinit {
    cancelled.deallocate()
  }

  func start() {
    queue.async { [self] in
      do {
        try runRemuxLoop()
      } catch {
        if cancelled.pointee == 0 {
          Log.error("AirPlayRemux", "remux failed: \(error.localizedDescription)")
          DispatchQueue.main.async { [weak self] in self?.onError?(error) }
        }
      }
      // The loop resolved → the avformat_close_input in defer ran → the source connection
      // closed. The next session may be waiting for this.
      closedLock.lock()
      sourceClosed = true
      closedLock.unlock()
    }
  }

  func cancel() {
    cancelled.pointee = 1
  }

  // MARK: - Ses transcode (MP2/DTS/… → AAC)

  /// Decode → swresample (FLTP) → FIFO → AAC encode chain. Timestamps are seated on the input's
  /// absolute timeline (starting from the PTS of the first decoded frame).
  private final class AudioTranscoder {
    let decoder: UnsafeMutablePointer<AVCodecContext>
    let encoder: UnsafeMutablePointer<AVCodecContext>
    /// The time base of the encoder output packets: 1/sampleRate.
    var encoderTimeBase: AVRational { AVRational(num: 1, den: sampleRate) }
    private var swr: OpaquePointer?
    private let fifo: OpaquePointer
    private let sampleRate: Int32
    private let decodedFrame = av_frame_alloc()
    private let convertedFrame = av_frame_alloc()
    private let encodeFrame = av_frame_alloc()
    private let encodedPacket = av_packet_alloc()
    /// The PTS of the next encode frame (in sample units); set on the first frame.
    private var nextPts: Int64 = .min

    init?(inStream: UnsafeMutablePointer<AVStream>) {
      guard let codecpar = inStream.pointee.codecpar,
            let decCodec = avcodec_find_decoder(codecpar.pointee.codec_id),
            let decCtx = avcodec_alloc_context3(decCodec)
      else { return nil }
      avcodec_parameters_to_context(decCtx, codecpar)
      decCtx.pointee.pkt_timebase = inStream.pointee.time_base
      guard avcodec_open2(decCtx, decCodec, nil) >= 0 else {
        var freeing: UnsafeMutablePointer<AVCodecContext>? = decCtx
        avcodec_free_context(&freeing)
        return nil
      }
      decoder = decCtx

      guard let encCodec = avcodec_find_encoder(AV_CODEC_ID_AAC),
            let encCtx = avcodec_alloc_context3(encCodec)
      else {
        var freeing: UnsafeMutablePointer<AVCodecContext>? = decCtx
        avcodec_free_context(&freeing)
        return nil
      }
      let rate = decCtx.pointee.sample_rate > 0 ? decCtx.pointee.sample_rate : 48000
      sampleRate = rate
      encCtx.pointee.sample_rate = rate
      av_channel_layout_copy(&encCtx.pointee.ch_layout, &decCtx.pointee.ch_layout)
      if encCtx.pointee.ch_layout.nb_channels <= 0 || encCtx.pointee.ch_layout.nb_channels > 6 {
        av_channel_layout_uninit(&encCtx.pointee.ch_layout)
        av_channel_layout_default(&encCtx.pointee.ch_layout, 2)
      }
      encCtx.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
      encCtx.pointee.bit_rate = 160_000
      encCtx.pointee.time_base = AVRational(num: 1, den: rate)
      // For mp4/fMP4, the extradata (AudioSpecificConfig) must be in the global header.
      encCtx.pointee.flags |= 1 << 22  // AV_CODEC_FLAG_GLOBAL_HEADER (makro import edilmiyor)
      guard avcodec_open2(encCtx, encCodec, nil) >= 0 else {
        var f1: UnsafeMutablePointer<AVCodecContext>? = decCtx
        avcodec_free_context(&f1)
        var f2: UnsafeMutablePointer<AVCodecContext>? = encCtx
        avcodec_free_context(&f2)
        return nil
      }
      encoder = encCtx

      guard let fifoPtr = av_audio_fifo_alloc(
        AV_SAMPLE_FMT_FLTP, encCtx.pointee.ch_layout.nb_channels, rate
      ) else { return nil }
      fifo = fifoPtr
    }

    deinit {
      var d: UnsafeMutablePointer<AVCodecContext>? = decoder
      avcodec_free_context(&d)
      var e: UnsafeMutablePointer<AVCodecContext>? = encoder
      avcodec_free_context(&e)
      swr_free(&swr)
      av_audio_fifo_free(fifo)
      var f1 = decodedFrame
      av_frame_free(&f1)
      var f2 = convertedFrame
      av_frame_free(&f2)
      var f3 = encodeFrame
      av_frame_free(&f3)
      var p = encodedPacket
      av_packet_free(&p)
    }

    /// Processes the input audio packet; `emit` is called for every AAC packet produced.
    func process(
      packet: UnsafeMutablePointer<AVPacket>?,
      emit: (UnsafeMutablePointer<AVPacket>) throws -> Void
    ) throws {
      guard let decodedFrame, let convertedFrame else { return }
      _ = avcodec_send_packet(decoder, packet)
      while avcodec_receive_frame(decoder, decodedFrame) == 0 {
        defer { av_frame_unref(decodedFrame) }
        let tb = decoder.pointee.pkt_timebase
        let framePts = decodedFrame.pointee.pts
        if framePts != Int64.min, tb.den > 0 {
          let framePtsSamples = av_rescale_q(framePts, tb, AVRational(num: 1, den: sampleRate))
          if nextPts == .min {
            nextPts = framePtsSamples
          } else {
            // A time jump in the source (reconnect/gap): if the synthetic PTS continues flat,
            // the audio drifts a little more from the video at every jump (cumulative desync). On a deviation larger than 200 ms,
            // re-lock the sync to the source's time.
            let expected = nextPts + Int64(av_audio_fifo_size(fifo))
            if abs(framePtsSamples - expected) > Int64(sampleRate / 5) {
              nextPts = framePtsSamples - Int64(av_audio_fifo_size(fifo))
            }
          }
        } else if nextPts == .min {
          nextPts = 0
        }
        if swr == nil {
          swr_alloc_set_opts2(
            &swr,
            &encoder.pointee.ch_layout, AV_SAMPLE_FMT_FLTP, sampleRate,
            &decodedFrame.pointee.ch_layout,
            AVSampleFormat(rawValue: decodedFrame.pointee.format), decodedFrame.pointee.sample_rate,
            0, nil
          )
          guard swr != nil, swr_init(swr) >= 0 else {
            throw RemuxError.openOutputFailed(-1)
          }
        }
        // Convert and write to the FIFO.
        convertedFrame.pointee.sample_rate = sampleRate
        convertedFrame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        av_channel_layout_copy(&convertedFrame.pointee.ch_layout, &encoder.pointee.ch_layout)
        convertedFrame.pointee.nb_samples =
          swr_get_out_samples(swr, decodedFrame.pointee.nb_samples)
        guard av_frame_get_buffer(convertedFrame, 0) >= 0 else {
          throw RemuxError.writeFailed(-1)
        }
        defer { av_frame_unref(convertedFrame) }
        let outData = UnsafeMutableRawPointer(convertedFrame.pointee.extended_data)
          .assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
        let inData = UnsafeMutableRawPointer(decodedFrame.pointee.extended_data)
          .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let converted = swr_convert(
          swr, outData, convertedFrame.pointee.nb_samples,
          inData, decodedFrame.pointee.nb_samples
        )
        guard converted >= 0 else { throw RemuxError.writeFailed(converted) }
        if converted > 0 {
          let raw = UnsafeMutableRawPointer(convertedFrame.pointee.extended_data)
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
          av_audio_fifo_write(fifo, raw, converted)
        }
        try drainEncoder(flush: false, emit: emit)
      }
    }

    /// Source finished/cancelled: encodes the remaining samples and flushes the encoder.
    func finish(emit: (UnsafeMutablePointer<AVPacket>) throws -> Void) throws {
      try? process(packet: nil, emit: emit)  // decoder drain
      try drainEncoder(flush: true, emit: emit)
    }

    private func drainEncoder(
      flush: Bool,
      emit: (UnsafeMutablePointer<AVPacket>) throws -> Void
    ) throws {
      guard let encodeFrame, let encodedPacket else { return }
      let frameSize = encoder.pointee.frame_size > 0 ? encoder.pointee.frame_size : 1024
      while av_audio_fifo_size(fifo) >= frameSize
        || (flush && av_audio_fifo_size(fifo) > 0)
      {
        let take = min(av_audio_fifo_size(fifo), frameSize)
        encodeFrame.pointee.nb_samples = take
        encodeFrame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        encodeFrame.pointee.sample_rate = sampleRate
        av_channel_layout_copy(&encodeFrame.pointee.ch_layout, &encoder.pointee.ch_layout)
        guard av_frame_get_buffer(encodeFrame, 0) >= 0 else { return }
        let raw = UnsafeMutableRawPointer(encodeFrame.pointee.extended_data)
          .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        av_audio_fifo_read(fifo, raw, take)
        encodeFrame.pointee.pts = nextPts == .min ? 0 : nextPts
        nextPts = encodeFrame.pointee.pts + Int64(take)
        _ = avcodec_send_frame(encoder, encodeFrame)
        av_frame_unref(encodeFrame)
        while avcodec_receive_packet(encoder, encodedPacket) == 0 {
          try emit(encodedPacket)
          av_packet_unref(encodedPacket)
        }
        if flush, av_audio_fifo_size(fifo) <= 0 { break }
      }
      if flush {
        _ = avcodec_send_frame(encoder, nil)
        while avcodec_receive_packet(encoder, encodedPacket) == 0 {
          try emit(encodedPacket)
          av_packet_unref(encodedPacket)
        }
      }
    }
  }

  // MARK: - Timestamp repair

  /// MKV/HEVC container dts is unreliable: missing on most frames, and equal/backwards
  /// on those that have it. The muxer's estimate produces -22 in mp4 and a SILENT ALIGNMENT SHIFT in TS
  /// (the root of the field audio drift — round 18). dts is produced deterministically without
  /// waiting for the container: decode-order clock = previous dts + frame duration.
  /// Both segment loops share this single implementation; because it is a pure value type
  /// it is table-testable.
  struct TimestampRepair {
    private var lastDTS: Int64?
    private var lastDuration: Int64 = 0

    /// Video: dts is always synthesized. nil = the packet must be skipped (no pts on the first frame).
    mutating func repairVideo(pts: Int64, duration: Int64) -> (pts: Int64, dts: Int64)? {
      let dur = max(duration > 0 ? duration : lastDuration, 1)
      let outPts: Int64
      let outDts: Int64
      if let last = lastDTS {
        var dts = last + dur
        if pts != Int64.min, dts > pts { dts = pts }
        if dts <= last { dts = last + 1 }
        // On a backwards time jump, the monotonicity bump can push dts above pts;
        // pts is lifted so the muxer doesn't die with EINVAL.
        outPts = (pts != Int64.min && pts < dts) ? dts : pts
        outDts = dts
      } else {
        guard pts != Int64.min else { return nil }
        // First frame (keyframe): the decode clock starts ~4 frames behind pts so that
        // dts ≤ pts always holds on B-frames (the mp4 edit list compensates).
        outPts = pts
        outDts = pts - dur * 4
      }
      lastDTS = outDts
      if duration > 0 { lastDuration = duration }
      return (outPts, outDts)
    }

    /// Audio: the container ts is reliable; it is only corrected when missing/backwards.
    /// nil = the packet must be skipped (both stamps missing while there is no reference yet).
    mutating func repairAudio(
      pts: Int64, dts: Int64, duration: Int64
    ) -> (pts: Int64, dts: Int64)? {
      var outPts = pts
      var outDts = dts
      if outPts == Int64.min, outDts == Int64.min {
        guard let last = lastDTS else { return nil }
        outDts = last + max(duration > 0 ? duration : lastDuration, 1)
        outPts = outDts
      } else if outDts == Int64.min {
        outDts = outPts
      }
      if let last = lastDTS, outDts <= last {
        let bumped = last + 1
        if outPts != Int64.min, outPts < bumped { outPts = bumped }
        outDts = bumped
      }
      lastDTS = outDts
      if duration > 0 { lastDuration = duration }
      return (outPts, outDts)
    }
  }

  // MARK: - Shared state

  private struct SegmentRecord {
    let index: Int
    let fileName: String
    let duration: Double
  }

  private var segments: [SegmentRecord] = []
  /// Segments that have left the playlist window but whose file has not yet been deleted:
  /// pencerenin ucundan okuyan (geciken) TV, playlist güncellemesini görmeden
  /// if they request one they should not get a 404 — a deletion margin of a few segments is left.
  private var retiredSegments: [SegmentRecord] = []

  private func recordSegment(index: Int, fileName: String, duration: Double, final: Bool) {
    // On a forward discontinuity (a source time jump), lastSeconds-startSeconds grows
    // absurdly; an absurd EXTINF breaks AVPlayer's seekable map — crop it to a reasonable ceiling.
    let clamped = min(duration, targetSegmentSeconds * 4)
    segments.append(SegmentRecord(index: index, fileName: fileName, duration: clamped))
    if isLive {
      while segments.count > liveWindowSize {
        retiredSegments.append(segments.removeFirst())
      }
      while retiredSegments.count > 3 {
        let old = retiredSegments.removeFirst()
        try? FileManager.default.removeItem(
          at: outputDirectory.appendingPathComponent(old.fileName)
        )
      }
    }
    writePlaylist(final: final)
    writeSubtitleAssetsIfNeeded()
  }

  /// Once the first segment exists (so the container format is known), write the WebVTT
  /// subtitle rendition + a master playlist that references the (unchanged) video playlist
  /// and the subtitle group, then point the cast player at that master. Runs at most once.
  /// Phase 1 scope: external SRT over the H.264/MPEG-TS VOD path only — HEVC/fMP4 and live
  /// are skipped (cast stays video-only) rather than shipping mis-synced subtitles.
  private func writeSubtitleAssetsIfNeeded() {
    guard !subtitleAssetsWritten,
          let subtitleFileURL,
          let firstSegment = segments.first
    else { return }
    subtitleAssetsWritten = true  // attempt once, regardless of outcome
    guard firstSegment.fileName.hasSuffix(".ts"), !isLive else { return }
    // Round 15 (C2): routed through the format-aware builder —
    // imported .vtt files now parse as WebVTT (not SRT) and
    // legacy-encoded files decode via the fallback chain.
    guard let built = AirPlaySubtitleRendition.build(fromSubtitleFile: subtitleFileURL) else {
      Log.error("AirPlayRemux", "subtitle file unreadable/empty; casting video-only")
      return
    }
    let vttName = "subs.vtt"
    let subsPlaylistName = "subs.m3u8"
    let masterName = "master.m3u8"
    let duration = max(built.durationSeconds, sourceDurationSeconds, 1)
    do {
      try built.webVTT.write(
        to: outputDirectory.appendingPathComponent(vttName), atomically: true, encoding: .utf8
      )
      try AirPlaySubtitleRendition
        .subtitleMediaPlaylist(vttFileName: vttName, durationSeconds: duration)
        .write(
          to: outputDirectory.appendingPathComponent(subsPlaylistName),
          atomically: true, encoding: .utf8
        )
      try AirPlaySubtitleRendition.masterPlaylist(
        videoPlaylistFileName: "stream.m3u8",
        subtitlePlaylistFileName: subsPlaylistName,
        name: subtitleName ?? "Subtitles",
        languageCode: subtitleLanguage
      ).write(
        to: outputDirectory.appendingPathComponent(masterName), atomically: true, encoding: .utf8
      )
      setClientPlaylistFileName(masterName)
      Log.info("AirPlayRemux", "subtitle rendition written (~\(Int(built.durationSeconds))s of cues)")
    } catch {
      Log.error("AirPlayRemux", "subtitle rendition write failed: \(error.localizedDescription)")
    }
  }

  /// The first segment is kept short so the playlist (and the first frame on the TV) is ready early.
  private func targetDuration(forSegmentIndex index: Int) -> Double {
    index == 0 ? min(1.5, targetSegmentSeconds) : targetSegmentSeconds
  }


  private enum AudioMode {
    case none
    case copy(inputIndex: Int)
    case transcode(inputIndex: Int, AudioTranscoder)

    var inputIndex: Int? {
      switch self {
      case .none: return nil
      case let .copy(index), let .transcode(index, _): return index
      }
    }
  }

  // MARK: - Remux loop (on the queue)

  private func runRemuxLoop() throws {
    if let readyToOpen {
      // Wait until the previous session's source connection closes (so the panel slot frees);
      // openDelaySeconds is the upper limit. When it closes, leave a short settling margin.
      let cap = Date().addingTimeInterval(openDelaySeconds > 0 ? openDelaySeconds : 3.0)
      var drained = false
      while cancelled.pointee == 0, Date() < cap {
        if readyToOpen() {
          drained = true
          break
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
      if cancelled.pointee != 0 { return }
      if drained { Thread.sleep(forTimeInterval: 0.3) }
    } else if openDelaySeconds > 0 {
      let deadline = Date().addingTimeInterval(openDelaySeconds)
      while cancelled.pointee == 0, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
      }
      if cancelled.pointee != 0 { return }
    }
    var inputCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
    inputCtx?.pointee.interrupt_callback.callback = { opaque in
      opaque?.assumingMemoryBound(to: Int32.self).pointee ?? 0
    }
    inputCtx?.pointee.interrupt_callback.opaque = UnsafeMutableRawPointer(cancelled)

    var inputOpts: OpaquePointer?
    defer { av_dict_free(&inputOpts) }
    if let userAgent, !userAgent.isEmpty {
      av_dict_set(&inputOpts, "user_agent", userAgent, 0)
    }
    av_dict_set(&inputOpts, "reconnect", "1", 0)
    av_dict_set(&inputOpts, "reconnect_streamed", "1", 0)
    av_dict_set(&inputOpts, "rw_timeout", "15000000", 0)
    if isLive {
      av_dict_set(&inputOpts, "analyzeduration", "2000000", 0)
      av_dict_set(&inputOpts, "probesize", "1500000", 0)
      // Live does not EOF: panel resets can look like a clean EOF.
      // Reconnect at the protocol layer — otherwise the EOF counts as a disconnect at the upper layer
      // and cast drops ("the picture cuts out" on a live zap).
      av_dict_set(&inputOpts, "reconnect_at_eof", "1", 0)
    }

    var openResult = avformat_open_input(&inputCtx, sourceURL.absoluteString, nil, &inputOpts)
    guard openResult >= 0, let input = inputCtx else {
      throw RemuxError.openInputFailed(openResult)
    }
    defer {
      var closing: UnsafeMutablePointer<AVFormatContext>? = input
      avformat_close_input(&closing)
    }
    openResult = avformat_find_stream_info(input, nil)
    guard openResult >= 0 else { throw RemuxError.openInputFailed(openResult) }
    if input.pointee.duration > 0 {
      sourceDurationSeconds = Double(input.pointee.duration) / Double(AV_TIME_BASE)
    }

    if !isLive, startSeconds > 1 {
      // stream_index=-1 → the timestamp must be at the same origin as the packets: on sources with a non-zero start_time
      // (TS catchup recordings), if it is not added it lands in the wrong place.
      var ts = Int64(startSeconds * Double(AV_TIME_BASE))
      if input.pointee.start_time != Int64.min {
        ts += input.pointee.start_time
      }
      let seekResult = av_seek_frame(input, -1, ts, AVSEEK_FLAG_BACKWARD)
      if seekResult < 0 {
        // Unseekable source: it will be written from 0:00 — if the timeline accounting doesn't
        // know this, the UI shows the requested position while cast plays from the start.
        Log.error("AirPlayRemux", "input seek failed (\(seekResult)); remuxing from 0:00")
        effectiveStartSeconds = 0
      }
    }

    // Stream selection: the first compatible video + the first audio (transcode if incompatible).
    let streamCount = Int(input.pointee.nb_streams)
    var videoInputIndex = -1
    var videoIsHEVC = false
    var firstAudioIndex = -1
    var audioCodecId: UInt32 = 0
    for i in 0..<streamCount {
      guard let inStream = input.pointee.streams[i],
            let codecpar = inStream.pointee.codecpar
      else { continue }
      let codecId = codecpar.pointee.codec_id.rawValue
      switch codecpar.pointee.codec_type {
      case AVMEDIA_TYPE_VIDEO:
        if videoInputIndex < 0, Self.compatibleVideoCodecs.contains(codecId) {
          videoInputIndex = i
          videoIsHEVC = codecId == AV_CODEC_ID_HEVC.rawValue
        }
      case AVMEDIA_TYPE_AUDIO:
        if firstAudioIndex < 0 {
          firstAudioIndex = i
          audioCodecId = codecId
        }
      default:
        break
      }
    }
    guard videoInputIndex >= 0 else { throw RemuxError.noCompatibleStreams }

    let format = forcedFormat ?? (videoIsHEVC ? .fmp4 : .mpegTS)
    let passthrough = format == .fmp4 ? Self.fmp4AudioPassthrough : Self.tsAudioPassthrough

    var audioMode: AudioMode = .none
    if firstAudioIndex >= 0, let audioStream = input.pointee.streams[firstAudioIndex] {
      if passthrough.contains(audioCodecId) {
        audioMode = .copy(inputIndex: firstAudioIndex)
      } else if let transcoder = AudioTranscoder(inStream: audioStream) {
        Log.info("AirPlayRemux", "audio transcode to AAC (source codec id \(audioCodecId))")
        audioMode = .transcode(inputIndex: firstAudioIndex, transcoder)
      } else {
        Log.error("AirPlayRemux", "audio codec \(audioCodecId) not decodable; dropping audio")
        audioMode = .none
      }
    }

    switch format {
    case .mpegTS:
      try runTSLoop(
        input: input, videoInputIndex: videoInputIndex, audioMode: audioMode
      )
    case .fmp4:
      try runFMP4Loop(
        input: input, videoInputIndex: videoInputIndex, audioMode: audioMode
      )
    }
  }

  /// Packet timestamp → seconds (in the input time base). Int64.min == AV_NOPTS_VALUE.
  private func packetSeconds(
    _ packet: AVPacket,
    inStream: UnsafeMutablePointer<AVStream>,
    fallback: Double
  ) -> Double {
    let rawTS = packet.dts != Int64.min ? packet.dts : packet.pts
    return rawTS != Int64.min ? Double(rawTS) * av_q2d(inStream.pointee.time_base) : fallback
  }

  /// Sets up the video(0) + audio(1, if any) streams on the output ctx.
  private func addOutputStreams(
    to output: UnsafeMutablePointer<AVFormatContext>,
    input: UnsafeMutablePointer<AVFormatContext>,
    videoInputIndex: Int,
    audioMode: AudioMode
  ) throws {
    guard let videoIn = input.pointee.streams[videoInputIndex],
          let videoOut = avformat_new_stream(output, nil)
    else { throw RemuxError.openOutputFailed(-1) }
    var result = avcodec_parameters_copy(videoOut.pointee.codecpar, videoIn.pointee.codecpar)
    guard result >= 0 else { throw RemuxError.openOutputFailed(result) }
    if videoOut.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
      // Apple only accepts the 'hvc1' sample entry for HEVC in HLS ('hev1' → -12848).
      videoOut.pointee.codecpar.pointee.codec_tag =
        UInt32(UInt8(ascii: "h")) | UInt32(UInt8(ascii: "v")) << 8
        | UInt32(UInt8(ascii: "c")) << 16 | UInt32(UInt8(ascii: "1")) << 24
    } else {
      videoOut.pointee.codecpar.pointee.codec_tag = 0
    }

    switch audioMode {
    case .none:
      break
    case let .copy(inputIndex):
      guard let audioIn = input.pointee.streams[inputIndex],
            let audioOut = avformat_new_stream(output, nil)
      else { throw RemuxError.openOutputFailed(-1) }
      result = avcodec_parameters_copy(audioOut.pointee.codecpar, audioIn.pointee.codecpar)
      guard result >= 0 else { throw RemuxError.openOutputFailed(result) }
      audioOut.pointee.codecpar.pointee.codec_tag = 0
    case let .transcode(_, transcoder):
      guard let audioOut = avformat_new_stream(output, nil) else {
        throw RemuxError.openOutputFailed(-1)
      }
      result = avcodec_parameters_from_context(audioOut.pointee.codecpar, transcoder.encoder)
      guard result >= 0 else { throw RemuxError.openOutputFailed(result) }
      audioOut.pointee.codecpar.pointee.codec_tag = 0
    }
  }

  // MARK: - MPEG-TS segment yolu (H.264)

  private final class TSSegmentContext {
    let ctx: UnsafeMutablePointer<AVFormatContext>
    let index: Int
    var startSeconds: Double
    var lastSeconds: Double

    init(ctx: UnsafeMutablePointer<AVFormatContext>, index: Int, startSeconds: Double) {
      self.ctx = ctx
      self.index = index
      self.startSeconds = startSeconds
      lastSeconds = startSeconds
    }
  }

  private func runTSLoop(
    input: UnsafeMutablePointer<AVFormatContext>,
    videoInputIndex: Int,
    audioMode: AudioMode
  ) throws {
    var current: TSSegmentContext?
    var nextSegmentIndex = 0

    func openSegment(startSeconds: Double) throws {
      let fileName = String(format: "seg%05d.ts", nextSegmentIndex)
      let path = outputDirectory.appendingPathComponent(fileName).path
      var outCtx: UnsafeMutablePointer<AVFormatContext>?
      var result = avformat_alloc_output_context2(&outCtx, nil, "mpegts", path)
      guard result >= 0, let out = outCtx else { throw RemuxError.openOutputFailed(result) }
      do {
        try addOutputStreams(
          to: out, input: input, videoInputIndex: videoInputIndex, audioMode: audioMode
        )
      } catch {
        avformat_free_context(out)
        throw error
      }
      result = avio_open(&out.pointee.pb, path, AVIO_FLAG_WRITE)
      guard result >= 0 else {
        avformat_free_context(out)
        throw RemuxError.openOutputFailed(result)
      }
      result = avformat_write_header(out, nil)
      guard result >= 0 else {
        avio_closep(&out.pointee.pb)
        avformat_free_context(out)
        throw RemuxError.openOutputFailed(result)
      }
      current = TSSegmentContext(ctx: out, index: nextSegmentIndex, startSeconds: startSeconds)
      nextSegmentIndex += 1
    }

    func closeSegment(final: Bool) {
      guard let segment = current else { return }
      current = nil
      av_write_trailer(segment.ctx)
      avio_closep(&segment.ctx.pointee.pb)
      let fileName = String(format: "seg%05d.ts", segment.index)
      avformat_free_context(segment.ctx)
      recordSegment(
        index: segment.index,
        fileName: fileName,
        duration: max(segment.lastSeconds - segment.startSeconds, 0.5),
        final: final
      )
    }

    // Transcoded AAC paketleri: encoder tb → mevcut segmentin ses stream tb'sine.
    func writeTranscodedPacket(
      _ encoded: UnsafeMutablePointer<AVPacket>, transcoder: AudioTranscoder
    ) throws {
      guard let segment = current,
            let outStream = segment.ctx.pointee.streams[1]
      else { return }
      encoded.pointee.stream_index = 1
      av_packet_rescale_ts(
        encoded, transcoder.encoderTimeBase, outStream.pointee.time_base
      )
      let result = av_interleaved_write_frame(segment.ctx, encoded)
      if result < 0 { throw RemuxError.writeFailed(result) }
    }

    var videoClock = TimestampRepair()
    var audioClock = TimestampRepair()
    var packet = AVPacket()
    // The last written video media time (on the source timeline) — the pacing gate
    // and the early-EOF detection looks at it.
    var paceClock = effectiveStartSeconds
    while cancelled.pointee == 0 {
      waitForPacing(mediaSeconds: paceClock)
      if cancelled.pointee != 0 { break }
      let readResult = av_read_frame(input, &packet)
      if readResult == Self.avErrorEOF {
        // Live never "ends": EOF = the source dropped. On VOD, an EOF well behind the duration
        // is also a drop (the panel may have closed the connection cleanly) —
        // both are errors, NOT completion; if ENDLIST were written, the movie would end mid-way
        // sahte "bitti" + auto-next tetiklenir.
        if isLive { throw RemuxError.readFailed(readResult) }
        if sourceDurationSeconds > 0, paceClock < sourceDurationSeconds - 30 {
          throw RemuxError.readFailed(readResult)
        }
        break
      }
      if readResult < 0 { throw RemuxError.readFailed(readResult) }
      defer { av_packet_unref(&packet) }
      let inIndex = Int(packet.stream_index)
      guard let inStream = input.pointee.streams[inIndex] else { continue }
      let isVideo = inIndex == videoInputIndex
      let isAudio = inIndex == audioMode.inputIndex
      guard isVideo || isAudio else { continue }

      let seconds = packetSeconds(packet, inStream: inStream, fallback: current?.lastSeconds ?? 0)
      if isVideo, seconds > paceClock { paceClock = seconds }
      let isKeyframe = (packet.flags & AV_PKT_FLAG_KEY) != 0
      if let segment = current, isVideo, isKeyframe,
         seconds - segment.startSeconds >= targetDuration(forSegmentIndex: segment.index)
      {
        closeSegment(final: false)
      }
      if current == nil {
        guard isVideo, isKeyframe else { continue }
        try openSegment(startSeconds: seconds)
      }
      guard let segment = current else { continue }
      if isVideo || audioMode.inputIndex == inIndex, seconds > segment.lastSeconds {
        segment.lastSeconds = seconds
      }

      if isAudio, case let .transcode(_, transcoder) = audioMode {
        try transcoder.process(packet: &packet) { encoded in
          try writeTranscodedPacket(encoded, transcoder: transcoder)
        }
        continue
      }

      let outIndex = isVideo ? 0 : 1
      guard let outStream = segment.ctx.pointee.streams[outIndex] else { continue }
      packet.stream_index = Int32(outIndex)
      av_packet_rescale_ts(&packet, inStream.pointee.time_base, outStream.pointee.time_base)
      if isVideo {
        guard let repaired = videoClock.repairVideo(pts: packet.pts, duration: packet.duration)
        else { continue }
        packet.pts = repaired.pts
        packet.dts = repaired.dts
      } else {
        guard let repaired = audioClock.repairAudio(
          pts: packet.pts, dts: packet.dts, duration: packet.duration
        ) else { continue }
        packet.pts = repaired.pts
        packet.dts = repaired.dts
      }
      packet.pos = -1
      let writeResult = av_interleaved_write_frame(segment.ctx, &packet)
      if writeResult < 0 {
        closeSegment(final: false)
        throw RemuxError.writeFailed(writeResult)
      }
    }
    // On cancellation the final flush is skipped: flushing a half muxer both makes noise ("Cannot write
    // moov…") and produces needless closing work that occupies the panel's connection limit.
    if cancelled.pointee == 0, case let .transcode(_, transcoder) = audioMode, current != nil {
      try? transcoder.finish { encoded in
        try writeTranscodedPacket(encoded, transcoder: transcoder)
      }
    }
    if cancelled.pointee == 0 {
      closeSegment(final: !isLive)
    } else if let segment = current {
      current = nil
      avio_closep(&segment.ctx.pointee.pb)
      avformat_free_context(segment.ctx)
    }
  }

  // MARK: - fMP4 segment yolu (HEVC)

  /// Accumulates the bytes the custom AVIO writes; split into a file at a fragment boundary.
  private final class ByteSink {
    var data = Data()
  }

  private func runFMP4Loop(
    input: UnsafeMutablePointer<AVFormatContext>,
    videoInputIndex: Int,
    audioMode: AudioMode
  ) throws {
    let sink = ByteSink()
    let sinkRef = Unmanaged.passRetained(sink)
    defer { sinkRef.release() }

    let bufferSize: Int32 = 1 << 16
    guard let avioBuffer = av_malloc(Int(bufferSize)) else {
      throw RemuxError.openOutputFailed(-1)
    }
    let writeCallback: @convention(c) (
      UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32
    ) -> Int32 = { opaque, buf, size in
      guard let opaque, let buf, size > 0 else { return size }
      let sink = Unmanaged<ByteSink>.fromOpaque(opaque).takeUnretainedValue()
      sink.data.append(buf, count: Int(size))
      return size
    }
    var avio = avio_alloc_context(
      avioBuffer.assumingMemoryBound(to: UInt8.self), bufferSize, 1,
      sinkRef.toOpaque(), nil, writeCallback, nil
    )
    guard avio != nil else {
      av_free(avioBuffer)
      throw RemuxError.openOutputFailed(-1)
    }

    var outCtx: UnsafeMutablePointer<AVFormatContext>?
    var result = avformat_alloc_output_context2(&outCtx, nil, "mp4", nil)
    guard result >= 0, let out = outCtx else {
      avioFree(&avio)
      throw RemuxError.openOutputFailed(result)
    }
    out.pointee.pb = avio
    defer {
      out.pointee.pb = nil
      avioFree(&avio)
      avformat_free_context(out)
    }

    try addOutputStreams(
      to: out, input: input, videoInputIndex: videoInputIndex, audioMode: audioMode
    )

    var headerOpts: OpaquePointer?
    // frag_custom: we determine the fragment boundaries (NULL-frame flush);
    // delay_moov: the moov is written on the first flush — for codecs like EAC3, for the boxes in the moov
    // wants to see a packet first; skip_trailer: do not produce mfra.
    av_dict_set(
      &headerOpts, "movflags",
      "+empty_moov+default_base_moof+frag_custom+delay_moov+skip_trailer", 0
    )
    result = avformat_write_header(out, &headerOpts)
    av_dict_free(&headerOpts)
    guard result >= 0 else { throw RemuxError.openOutputFailed(result) }

    var segmentIndex = 0
    var segmentStart: Double = 0
    var segmentLast: Double = 0
    var segmentHasData = false
    var initWritten = false

    func emitFragment(final: Bool) throws {
      // First the interleave queue is drained; then av_write_frame(NULL) flushes the muxer —
      // frag_custom'da fragment (moof+mdat) ancak bununla üretilir (interleaved NULL yetmez).
      // with delay_moov the first flush also produces the moov; it is split at the box boundary.
      _ = av_interleaved_write_frame(out, nil)
      _ = av_write_frame(out, nil)
      if !initWritten {
        _ = av_write_frame(out, nil)
      }
      avio_flush(out.pointee.pb)
      guard !sink.data.isEmpty else { return }
      if !initWritten {
        let (initData, fragmentData) = Self.splitAtFirstFragmentBox(sink.data)
        guard !initData.isEmpty else { return }
        // If a disk error (full disk, etc.) is swallowed, the TV freezes silently; let it surface as an error.
        try initData.write(to: outputDirectory.appendingPathComponent("init.mp4"))
        Log.info(
          "AirPlayRemux",
          "fmp4 init: \(initData.count)B, first fragment: \(fragmentData.count)B"
        )
        initWritten = true
        sink.data = fragmentData
      }
      guard segmentHasData, !sink.data.isEmpty else { return }
      let fileName = String(format: "seg%05d.m4s", segmentIndex)
      try sink.data.write(to: outputDirectory.appendingPathComponent(fileName))
      sink.data.removeAll(keepingCapacity: true)
      recordSegment(
        index: segmentIndex,
        fileName: fileName,
        duration: max(segmentLast - segmentStart, 0.5),
        final: final
      )
      segmentIndex += 1
      segmentHasData = false
    }

    func writeTranscodedPacket(
      _ encoded: UnsafeMutablePointer<AVPacket>, transcoder: AudioTranscoder
    ) throws {
      guard let outStream = out.pointee.streams[1] else { return }
      encoded.pointee.stream_index = 1
      av_packet_rescale_ts(encoded, transcoder.encoderTimeBase, outStream.pointee.time_base)
      let writeResult = av_interleaved_write_frame(out, encoded)
      if writeResult < 0 { throw RemuxError.writeFailed(writeResult) }
      segmentHasData = true
    }

    var videoClock = TimestampRepair()
    var audioClock = TimestampRepair()
    var packet = AVPacket()
    var startedAtKeyframe = false
    var paceClock = effectiveStartSeconds
    while cancelled.pointee == 0 {
      waitForPacing(mediaSeconds: paceClock)
      if cancelled.pointee != 0 { break }
      let readResult = av_read_frame(input, &packet)
      if readResult == Self.avErrorEOF {
        // See the note in the TS loop: on live and on VOD well behind its duration,
        // EOF is a disconnect — not completion.
        if isLive { throw RemuxError.readFailed(readResult) }
        if sourceDurationSeconds > 0, paceClock < sourceDurationSeconds - 30 {
          throw RemuxError.readFailed(readResult)
        }
        break
      }
      if readResult < 0 { throw RemuxError.readFailed(readResult) }
      defer { av_packet_unref(&packet) }
      let inIndex = Int(packet.stream_index)
      guard let inStream = input.pointee.streams[inIndex] else { continue }
      let isVideo = inIndex == videoInputIndex
      let isAudio = inIndex == audioMode.inputIndex
      guard isVideo || isAudio else { continue }

      let seconds = packetSeconds(packet, inStream: inStream, fallback: segmentLast)
      if isVideo, seconds > paceClock { paceClock = seconds }
      let isKeyframe = (packet.flags & AV_PKT_FLAG_KEY) != 0
      if !startedAtKeyframe {
        guard isVideo, isKeyframe else { continue }
        startedAtKeyframe = true
        segmentStart = seconds
        segmentLast = seconds
      }
      if segmentHasData, isVideo, isKeyframe,
         seconds - segmentStart >= targetDuration(forSegmentIndex: segmentIndex)
      {
        try emitFragment(final: false)
        segmentStart = seconds
      }
      if seconds > segmentLast { segmentLast = seconds }

      if isAudio, case let .transcode(_, transcoder) = audioMode {
        try transcoder.process(packet: &packet) { encoded in
          try writeTranscodedPacket(encoded, transcoder: transcoder)
        }
        continue
      }

      let outIndex = isVideo ? 0 : 1
      guard let outStream = out.pointee.streams[outIndex] else { continue }
      packet.stream_index = Int32(outIndex)
      av_packet_rescale_ts(&packet, inStream.pointee.time_base, outStream.pointee.time_base)
      if isVideo {
        guard let repaired = videoClock.repairVideo(pts: packet.pts, duration: packet.duration)
        else { continue }
        packet.pts = repaired.pts
        packet.dts = repaired.dts
      } else {
        guard let repaired = audioClock.repairAudio(
          pts: packet.pts, dts: packet.dts, duration: packet.duration
        ) else { continue }
        packet.pts = repaired.pts
        packet.dts = repaired.dts
      }
      packet.pos = -1
      let logPTS = packet.pts
      let logDTS = packet.dts
      let writeResult = av_interleaved_write_frame(out, &packet)
      if writeResult < 0 {
        Log.error(
          "AirPlayRemux",
          "fmp4 write failed \(writeResult): out=\(outIndex) pts=\(logPTS) dts=\(logDTS) key=\(isKeyframe)"
        )
        throw RemuxError.writeFailed(writeResult)
      }
      segmentHasData = true
    }
    if cancelled.pointee == 0 {
      if case let .transcode(_, transcoder) = audioMode, startedAtKeyframe {
        try? transcoder.finish { encoded in
          try writeTranscodedPacket(encoded, transcoder: transcoder)
        }
      }
      try emitFragment(final: !isLive)
      av_write_trailer(out)
    }
  }

  /// Splits the MP4 box stream at the first 'moof'/'styp' box: before it is the init (ftyp+moov),
  /// after it the first media fragment.
  static func splitAtFirstFragmentBox(_ data: Data) -> (initData: Data, fragmentData: Data) {
    var offset = data.startIndex
    while offset + 8 <= data.endIndex {
      let size = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
      let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
      if type == "moof" || type == "styp" {
        return (Data(data[data.startIndex..<offset]), Data(data[offset...]))
      }
      guard size >= 8, offset + size <= data.endIndex else { break }
      offset += size
    }
    return (Data(data), Data())
  }

  private func avioFree(_ avio: inout UnsafeMutablePointer<AVIOContext>?) {
    guard let ctx = avio else { return }
    av_free(ctx.pointee.buffer)
    ctx.pointee.buffer = nil
    avio_context_free(&avio)
  }

  // MARK: - Playlist

  /// Atomic m3u8 writing: so AVPlayer doesn't read a half playlist.
  private func writePlaylist(final: Bool) {
    guard !segments.isEmpty else { return }
    let usesFMP4 = segments[0].fileName.hasSuffix(".m4s")
    // Base targetSegmentSeconds: instead of the TD starting at 2 and then growing on the first (short) segment,
    // it starts stably; on a source with sparse keyframes it can still grow.
    let target = max(
      Int(segments.map(\.duration).max()!.rounded(.up)),
      Int(targetSegmentSeconds.rounded(.up))
    )
    var lines: [String] = [
      "#EXTM3U",
      "#EXT-X-VERSION:\(usesFMP4 ? 7 : 3)",
      "#EXT-X-INDEPENDENT-SEGMENTS",
      "#EXT-X-TARGETDURATION:\(max(target, 1))",
      "#EXT-X-MEDIA-SEQUENCE:\(segments[0].index)",
    ]
    if !isLive {
      // A fresh client takes the growing event playlist for live and joins FROM THE BROADCAST EDGE.
      // On AirPlay, because Apple TV fetches the playlist ITSELF, the phone-side seek
      // correction cannot preserve the TV's join — the root of the freeze + silent forward
      // jump at first open. EVENT + START=0 starts every fresh client from the beginning.
      lines.append("#EXT-X-PLAYLIST-TYPE:EVENT")
      lines.append("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES")
    }
    if usesFMP4 {
      lines.append("#EXT-X-MAP:URI=\"init.mp4\"")
    }
    for segment in segments {
      lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
      lines.append(segment.fileName)
    }
    if final {
      lines.append("#EXT-X-ENDLIST")
    }
    let content = lines.joined(separator: "\n") + "\n"
    do {
      try content.write(to: playlistURL, atomically: true, encoding: .utf8)
    } catch {
      // A stale playlist silently freezes the TV (disk full/sandbox): surface it as an error.
      Log.error("AirPlayRemux", "playlist write failed: \(error.localizedDescription)")
      if cancelled.pointee == 0 {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
      }
    }
  }

  /// Fast codec pre-check on the engine side: candidacy now looks only at the video —
  /// uyumsuz ses AAC'ye transcode edilir. Profil ekli adlar normalize edilir.
  static func isCompatible(videoFourCC: String, audioFourCC _: String? = nil) -> Bool {
    ["avc1", "h264", "hvc1", "hev1", "hevc"].contains(normalizeCodec(videoFourCC))
  }

  static func normalizeCodec(_ raw: String) -> String {
    raw.lowercased()
      .split(separator: " ").first.map(String.init)?
      .trimmingCharacters(in: .whitespaces) ?? ""
  }
}
