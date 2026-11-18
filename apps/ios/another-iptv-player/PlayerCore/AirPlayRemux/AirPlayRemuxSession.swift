import Foundation

/// The life cycle of an AirPlay remux session: temp directory + FFmpeg remux writer +
/// local HTTP server. When `localPlaylistURL` is ready it is given to AVPlayer; on Apple TV
/// segmentleri telefonun LAN adresinden çeker.
final class AirPlayRemuxSession {
  let sourceURL: URL
  /// The second at which the remux started inside the source — playback position = offset + local position.
  let startOffsetSeconds: TimeInterval
  let isLive: Bool
  /// Content to accumulate before playback starts on VOD (sec). High on first start
  /// (stall protection), low on seek refresh (the user is actively waiting).
  let minimumBufferSeconds: Double

  private let directory: URL
  private let sessionPathComponent: String
  private let writer: RemuxHLSWriter
  private let server: LocalHTTPServer
  private(set) var localPlaylistURL: URL?

  var onError: ((Error) -> Void)?

  /// Once access to the local server has been verified once, long retries are unnecessary in later sessions.
  private static var hasVerifiedLocalNetwork = false

  /// A previous session: the new writer must wait until this one's source connection closes
  /// (a double-open collision on a connection-limited panel). It is released when start completes.
  private var previousToDrain: AirPlayRemuxSession?

  /// Has this session's source connection actually closed (the writer loop resolved)?
  var isSourceClosed: Bool { writer.isClosed }

  init(
    sourceURL: URL,
    startOffsetSeconds: TimeInterval,
    isLive: Bool,
    userAgent: String?,
    minimumBufferSeconds: Double = 12,
    openDelaySeconds: Double = 0,
    previousToDrain: AirPlayRemuxSession? = nil,
    subtitleFileURL: URL? = nil,
    subtitleName: String? = nil,
    subtitleLanguage: String? = nil
  ) throws {
    self.sourceURL = sourceURL
    self.startOffsetSeconds = isLive ? 0 : startOffsetSeconds
    self.isLive = isLive
    self.minimumBufferSeconds = minimumBufferSeconds
    self.previousToDrain = previousToDrain
    // A per-session subdirectory under the shared server's root: on zapping, the listener and the
    // local-network verification are not rebuilt.
    server = LocalHTTPServer.shared
    sessionPathComponent = "s\(UUID().uuidString.prefix(8))"
    directory = server.directory.appendingPathComponent(sessionPathComponent, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // `self` holds it strongly; the closure captures weakly → no cycle, but it stays alive while waiting.
    let readyToOpen: (() -> Bool)? = previousToDrain.map { prev in
      { [weak prev] in prev?.isSourceClosed ?? true }
    }
    writer = RemuxHLSWriter(
      sourceURL: sourceURL,
      outputDirectory: directory,
      startSeconds: self.startOffsetSeconds,
      isLive: isLive,
      userAgent: userAgent,
      openDelaySeconds: openDelaySeconds,
      readyToOpen: readyToOpen,
      subtitleFileURL: subtitleFileURL,
      subtitleName: subtitleName,
      subtitleLanguage: subtitleLanguage
    )
  }

  /// Safety net: if the reference is dropped without stop() being called (a state machine bug, etc.),
  /// a stray writer is prevented from holding the panel connection forever.
  deinit {
    writer.cancel()
  }

  /// Starts the server + remux; the completion is called when the playlist hits disk with its first segment.
  /// If the playlist does not form within ~10 sec, it returns an error (source could not be opened, etc.).
  func start(completion: @escaping (Result<URL, Error>) -> Void) {
    do {
      try server.start()
    } catch {
      completion(.failure(error))
      return
    }
    guard let ip = LocalHTTPServer.lanIPv4Address(), server.port > 0 else {
      completion(
        .failure(
          NSError(
            domain: "AirPlayRemux", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No LAN IPv4 address (Wi-Fi off?)"]
          )))
      return
    }
    let playlistPath = writer.playlistURL.path
    let baseURL = "http://\(ip):\(server.port)/\(sessionPathComponent)"
    // Playlist production and accessibility verification run in PARALLEL; it completes when
    // both finish. On live, the margin is kept wide because the first segment fills in real time.
    // On VOD, buffer accumulation is awaited (below) — at 4K the download can be ~real-time.
    let deadline = Date().addingTimeInterval(25)
    var playlistReady = false
    var serverVerified = false
    var finished = false
    let finishIfReady = {
      guard playlistReady, serverVerified, !finished else { return }
      finished = true
      self.previousToDrain = nil  // the writer has now opened it; drop the drain reference
      // If a subtitle rendition was requested, the writer has upgraded the client
      // playlist to the subtitle master by now (written on the first segment; readiness
      // needs many more). Otherwise this is still the raw video playlist.
      let localURL = URL(string: "\(baseURL)/\(self.writer.clientPlaylistFileName)")!
      self.localPlaylistURL = localURL
      completion(.success(localURL))
    }
    let failOnce = { (error: Error) in
      guard !finished else { return }
      finished = true
      self.previousToDrain = nil
      self.stop()
      completion(.failure(error))
    }
    // Writer errors during the start window fail the start immediately (a source
    // with incompatible codecs must not sit out the full playlist deadline);
    // errors after a successful start are forwarded to `onError`.
    writer.onError = { [weak self] (error: Error) in
      DispatchQueue.main.async {
        guard let self else { return }
        if finished {
          self.onError?(error)
        } else {
          failOnce(error)
        }
      }
    }
    writer.start()
    waitForPlaylist(path: playlistPath, deadline: deadline) { ready in
      if ready {
        playlistReady = true
        finishIfReady()
      } else {
        failOnce(
          NSError(
            domain: "AirPlayRemux", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Remux playlist not produced in time"]
          ))
      }
    }
    // /ping returns 200 immediately, independent of the playlist; the first request can trigger the iOS "Local Network" permission
    // dialog — retries are needed until the user answers.
    let attempts = Self.hasVerifiedLocalNetwork ? 5 : 20
    let pingURL = URL(string: "http://\(ip):\(server.port)/ping")!
    Task { [weak self] in
      guard let self else { return }
      // Round 15 (C11): async/await reachability probe (was a
      // recursive completion-handler data task).
      let reachable = await self.verifyReachable(url: pingURL, attemptsLeft: attempts)
      DispatchQueue.main.async {
        if reachable {
          Self.hasVerifiedLocalNetwork = true
          serverVerified = true
          finishIfReady()
        } else {
          failOnce(
            NSError(
              domain: "AirPlayRemux", code: 3,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Local server unreachable (local network permission denied?)"
              ]
            ))
        }
      }
    }
  }

  var sourceDurationSeconds: TimeInterval { writer.sourceDurationSeconds }

  /// The position the input seek actually landed at; on an unseekable source it falls to 0.
  /// The timeline accounting must use this instead of the requested offset.
  var effectiveStartOffsetSeconds: TimeInterval { writer.effectiveStartSeconds }

  /// The cast player's source-time position — feeds the writer's VOD pacing gate.
  func updatePlaybackPosition(_ seconds: TimeInterval) {
    writer.updatePlaybackPosition(seconds)
  }

  /// Round 15 (C11): async/await probe — same semantics as the
  /// old completion-handler recursion: HTTP 200 = reachable, one
  /// retry per second until the attempt budget runs out.
  private func verifyReachable(url: URL, attemptsLeft: Int) async -> Bool {
    var request = URLRequest(url: url)
    request.timeoutInterval = 2
    if let (_, response) = try? await URLSession.shared.data(for: request),
       (response as? HTTPURLResponse)?.statusCode == 200 {
      return true
    }
    guard attemptsLeft > 1 else { return false }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    return await verifyReachable(url: url, attemptsLeft: attemptsLeft - 1)
  }

  func stop() {
    writer.cancel()
    // The shared server is not stopped; only this session's directory is cleaned. Deletion is
    // DELAYED: during a content change, Apple TV may keep probing the old playlist for a while
    // — when the directory was deleted in 1 sec, 404s pushed the item to .failed and
    // killed a healthy handover. Thanks to pacing, the directory holds ~25-35 sec of media.
    let dir = directory
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
      try? FileManager.default.removeItem(at: dir)
    }
  }

  /// Has enough content accumulated in the playlist for cast to start? Live: 3 segments
  /// are enough (they fill in real time). VOD: let a buffer accumulate so AVPlayer doesn't run at the writer's tail
  /// — when a 4K download is near real-time, stalls on the TV are inevitable without a buffer.
  /// ENDLIST (short content/remux finished) is sufficient in every case.
  /// Pure function: the regression lock for the round 13-14 fixes (buffer gates).
  static func playlistReady(
    content: String,
    isLive: Bool,
    minimumBufferSeconds: Double
  ) -> Bool {
    if content.contains("#EXT-X-ENDLIST") { return true }
    let durations = content.split(separator: "\n")
      .filter { $0.hasPrefix("#EXTINF:") }
      .compactMap { Double($0.dropFirst("#EXTINF:".count).dropLast()) }
    return isLive
      ? durations.count >= 3
      : durations.reduce(0, +) >= minimumBufferSeconds
  }

  private func waitForPlaylist(
    path: String,
    deadline: Date,
    completion: @escaping (Bool) -> Void
  ) {
    let isLive = self.isLive
    DispatchQueue.global(qos: .userInitiated).async {
      while Date() < deadline {
        if let content = try? String(contentsOfFile: path, encoding: .utf8),
           Self.playlistReady(
             content: content, isLive: isLive, minimumBufferSeconds: self.minimumBufferSeconds
           )
        {
          DispatchQueue.main.async { completion(true) }
          return
        }
        Thread.sleep(forTimeInterval: 0.25)
      }
      DispatchQueue.main.async { completion(false) }
    }
  }
}
