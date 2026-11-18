import Foundation
import Network
import UIKit

/// Build 61 (B9) — P1 fast zapping (pre-CONNECTION level) + E1
/// active-host connection pre-warm.
///
/// What level was achievable, and why: KSPlayer creates its own
/// stream connections internally — KSMEPlayer opens the URL with
/// FFmpeg's avformat, KSAVPlayer with AVFoundation — and neither
/// exposes a way to hand it a pre-opened socket or to pre-buffer
/// into a spare instance without also starting full decode (a
/// spare `KSPlayerLayer` runs the whole pipeline: demux, decode,
/// render target). On one-connection-per-account IPTV panels a
/// second live stream connection can also get the ACTIVE stream
/// kicked by the provider. So pre-buffering was deliberately NOT
/// implemented; this service implements pre-CONNECTION instead:
/// for the PREVIOUS and NEXT channel only, it completes DNS
/// resolution + TCP connect + TLS handshake to the channel's
/// host ahead of the zap and holds the connection briefly. The
/// stream itself is never requested (no HTTP bytes are sent), so
/// no provider stream slot is consumed; what carries over to the
/// real open is the warmed system DNS cache and TLS session
/// state, plus an already-warm network path.
///
/// Bounds (critic-checkable):
///  - at most TWO neighbor connections at any time (prev + next);
///  - a neighbor connection is cancelled when the zap target set
///    changes, when playback of a new channel starts, or after
///    `neighborLifetime` seconds, whichever comes first;
///  - everything stands down while Multiview is active (the
///    multiview screen sets `multiviewActive`), while the data
///    saver is active (P6), and while a cast session owns playback
///    (callers simply stop updating the neighbor set).
///
/// E1: the same machinery keeps ONE warm connection to the
/// ACTIVE playlist's host while browsing in the foreground
/// (`setActiveHost`), re-established when it drops and torn down
/// when the playlist changes or the app backgrounds.
final class PlaybackPrewarmService {
    static let shared = PlaybackPrewarmService()

    /// Set by the Multiview screen on appear/disappear: pre-warm
    /// must never compete with the panes' own engines.
    var multiviewActive = false {
        didSet { if multiviewActive { cancelNeighbors() } }
    }

    private static let neighborLifetime: TimeInterval = 60

    private let queue = DispatchQueue(label: "superx.prewarm")
    private var neighborConnections: [String: NWConnection] = [:]
    private var neighborExpiry: [String: DispatchWorkItem] = [:]
    private var hostConnection: NWConnection?
    private var hostKey: String?
    private var hostRefreshTask: Task<Void, Never>?

    private var suspended: Bool {
        multiviewActive || DataSaverService.isActive
    }

    // MARK: - P1: previous / next channel

    /// Called by the live player shells whenever the current
    /// channel changes: warms exactly the two neighbours of the
    /// channel now playing and cancels everything else.
    func updateNeighbors(previous: URL?, next: URL?) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.suspended else {
                self.cancelNeighborsLocked()
                return
            }
            var wanted: [String: URL] = [:]
            for url in [previous, next] {
                if let url, let key = Self.connectionKey(for: url) {
                    wanted[key] = url
                }
            }
            for key in self.neighborConnections.keys where wanted[key] == nil {
                self.cancelNeighborLocked(key)
            }
            for (key, url) in wanted where self.neighborConnections[key] == nil {
                self.startNeighborLocked(key: key, url: url)
            }
        }
    }

    /// Playback of a (new) channel started: the previous neighbor
    /// set is meaningless now; the owning shell publishes the new
    /// set right after.
    func cancelNeighbors() {
        queue.async { [weak self] in self?.cancelNeighborsLocked() }
    }

    // MARK: - E1: active playlist host

    /// Keeps a warm connection to the given host while it remains
    /// the active target. Pass nil to stand down (playlist closed,
    /// app backgrounded).
    func setActiveHost(_ url: URL?) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = url.flatMap(Self.connectionKey(for:))
            guard key != self.hostKey else { return }
            self.hostKey = key
            self.hostConnection?.cancel()
            self.hostConnection = nil
            self.hostRefreshTask?.cancel()
            self.hostRefreshTask = nil
            guard let url, key != nil else { return }
            self.startHostLocked(url: url)
            // Keep-alive by supervision: re-check every 45 s and
            // re-establish a dropped connection, but only while
            // the app is in the foreground.
            self.hostRefreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 45 * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.queue.async { [weak self] in
                        guard let self,
                              UIApplication.shared.applicationState == .active,
                              !self.suspended,
                              self.hostConnection == nil,
                              let url = self.hostURL
                        else { return }
                        self.startHostLocked(url: url)
                    }
                }
            }
        }
    }

    private var hostURL: URL?

    // MARK: - Connection plumbing

    private static func connectionKey(for url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        return "\(url.scheme ?? "http")://\(host):\(port)"
    }

    private func makeConnection(for url: URL) -> NWConnection? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let portValue = url.port ?? (url.scheme == "https" ? 443 : 80)
        guard let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else { return nil }
        let parameters: NWParameters = url.scheme == "https" ? .tls : .tcp
        return NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
    }

    private func startNeighborLocked(key: String, url: URL) {
        guard let connection = makeConnection(for: url) else { return }
        neighborConnections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.queue.async { self?.cancelNeighborLocked(key) }
            }
        }
        connection.start(queue: queue)
        let expiry = DispatchWorkItem { [weak self] in
            self?.cancelNeighborLocked(key)
        }
        neighborExpiry[key] = expiry
        queue.asyncAfter(deadline: .now() + Self.neighborLifetime, execute: expiry)
    }

    private func cancelNeighborLocked(_ key: String) {
        neighborExpiry[key]?.cancel()
        neighborExpiry.removeValue(forKey: key)
        neighborConnections[key]?.cancel()
        neighborConnections.removeValue(forKey: key)
    }

    private func cancelNeighborsLocked() {
        for key in Array(neighborConnections.keys) {
            cancelNeighborLocked(key)
        }
    }

    private func startHostLocked(url: URL) {
        hostURL = url
        guard !suspended, let connection = makeConnection(for: url) else { return }
        hostConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { [weak self] in
                    if self?.hostConnection === connection {
                        self?.hostConnection = nil
                    }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}
