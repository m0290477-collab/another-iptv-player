import Foundation
import GoogleCast

/// B5 (build 61), Item 9 — Google Cast (official Google Cast iOS SDK,
/// SPM package `google-cast-ios-sdk` 4.8.6, product GoogleCastDynamic).
///
/// Owns the one-time `GCKCastContext` setup (default media receiver
/// application ID) and the media routing: the player registers the
/// currently playing stream via `updateNowPlaying(url:title:isLive:)`;
/// when a Cast session starts, that stream is loaded on the receiver
/// through `GCKRemoteMediaClient`. If a session is already connected
/// when the registration changes (channel zap), the new stream is
/// loaded immediately.
///
/// Integration points (coordinator wiring, player discipline §3):
/// - `GoogleCastButton` (defined in KSPlayerSurfaceView.swift beside
///   `AirPlayRoutePickerButton`) calls `setUpIfNeeded()` before the
///   button is created, so no app-delegate edit is needed.
/// - The player surface places `GoogleCastButton` beside the AirPlay
///   button and the play path calls `updateNowPlaying(...)` /
///   `clearNowPlaying()` — both are one-line calls.
///
/// Honest platform limit: the DEFAULT media receiver plays the
/// formats it supports (HLS, MP4, DASH, WebM…). A raw MPEG-TS or MKV
/// Xtream stream URL is sent as-is with its real content type; the
/// receiver may refuse formats outside its set — that is a receiver
/// capability limit, surfaced by the SDK's own error UI, not hidden.
final class GoogleCastService: NSObject {
    static let shared = GoogleCastService()

    struct NowPlaying {
        let url: URL
        let title: String
        let isLive: Bool
    }

    private(set) var isContextReady = false
    private var nowPlaying: NowPlaying?
    private let lock = NSLock()

    private override init() { super.init() }

    /// One-time Cast context setup with the default media receiver.
    /// Safe to call repeatedly; only the first call has an effect.
    func setUpIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !isContextReady else { return }
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.addListener(self)
        isContextReady = true
    }

    /// Registers the stream the local player is now playing. Called
    /// from the play path; loads onto a connected receiver at once.
    func updateNowPlaying(url: URL, title: String, isLive: Bool) {
        lock.lock()
        nowPlaying = NowPlaying(url: url, title: title, isLive: isLive)
        lock.unlock()
        if let session = GCKCastContext.sharedInstance().sessionManager.currentSession,
           session.connectionState == .connected {
            loadMedia(into: session)
        }
    }

    /// The local player stopped / was dismissed — future sessions
    /// will not auto-load stale content.
    func clearNowPlaying() {
        lock.lock()
        nowPlaying = nil
        lock.unlock()
    }

    private func loadMedia(into session: GCKSession) {
        lock.lock()
        let current = nowPlaying
        lock.unlock()
        guard let current, let client = session.remoteMediaClient else { return }

        let metadata = GCKMediaMetadata(metadataType: .generic)
        metadata.setString(current.title, forKey: kGCKMetadataKeyTitle)

        let infoBuilder = GCKMediaInformationBuilder(contentURL: current.url)
        infoBuilder.contentType = Self.contentType(for: current.url)
        infoBuilder.streamType = current.isLive ? .live : .buffered
        infoBuilder.metadata = metadata

        let requestBuilder = GCKMediaLoadRequestDataBuilder()
        requestBuilder.mediaInformation = infoBuilder.build()
        requestBuilder.autoplay = NSNumber(value: true)
        _ = client.loadMedia(with: requestBuilder.build())
    }

    /// Real MIME type for the stream URL's container, from its path
    /// extension; extensionless Xtream live URLs are HLS-served by
    /// most panels when no extension is present, and the receiver
    /// negotiates from the response in that case — we declare the
    /// panel-default MP4 only for known VOD-style extensions and HLS
    /// for extensionless live.
    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8":
            return "application/x-mpegURL"
        case "mpd":
            return "application/dash+xml"
        case "ts":
            return "video/MP2T"
        case "mkv":
            return "video/x-matroska"
        case "webm":
            return "video/webm"
        case "mp4", "m4v", "mov":
            return "video/mp4"
        default:
            return "application/x-mpegURL"
        }
    }
}

// MARK: - GCKSessionManagerListener

extension GoogleCastService: GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        loadMedia(into: session)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        // On resume the receiver usually still holds its media; only
        // load when it is idle, so a reconnect never restarts a
        // stream the receiver is already playing.
        if session.remoteMediaClient?.mediaStatus == nil {
            loadMedia(into: session)
        }
    }
}
