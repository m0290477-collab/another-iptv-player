import SwiftUI
import Combine

/// Bridge type: the guide/detail surfaces map their EPG programme into this so
/// `CatchupPlayerShell` doesn't depend on XMLTV internals.
struct CatchupProgramme: Equatable {
    let title: String
    let description: String?
    let startUTC: Date
    let stopUTC: Date
}

/// Presents a pre-resolved Xtream timeshift stream as a finite (VOD-like) asset:
/// `isLiveStream: false` gives a seek bar (when the panel supports it), no live
/// chrome, and — via `suppressWatchHistory` — no history contamination.
struct CatchupPlayerShell: View {
    let playlist: Playlist
    let stream: DBLiveStream
    let programme: CatchupProgramme
    let url: URL
    /// Round 14 (B1): forwarded to `PlayerView.onNavigateToDetail`
    /// so tapping the player title navigates to the channel's
    /// detail, like every other player shell. Optional: callers
    /// that present catch-up from a surface with no detail route
    /// leave it nil and the title tap stays inert.
    var onNavigateToDetail: ((String, String) -> Void)? = nil

    var body: some View {
        PlayerView(
            url: url,
            title: programme.title,
            subtitle: "\(stream.name) · \(EPGTimeFormat.range(programme.startUTC, programme.stopUTC))",
            artworkURL: stream.streamIcon.flatMap { URL(string: $0) },
            isLiveStream: false,
            playlistId: playlist.id,
            streamId: String(stream.streamId),
            type: "live",
            suppressWatchHistory: true,
            onNavigateToDetail: onNavigateToDetail
        )
    }
}

/// Resolves a timeshift URL (off-main probe) and presents the catch-up player via
/// the shared player overlay. Reused by the guide and channel-detail surfaces.
@MainActor
final class CatchupPlaybackController: ObservableObject {
    @Published var isResolving = false
    @Published var errorMessage: String?

    /// Shared across every instance so a stale resolve from a different sheet's
    /// controller can't overlay-present after a newer catch-up request started.
    private static var requestGeneration = 0

    func play(playlist: Playlist, stream: DBLiveStream, programme: CatchupProgramme,
              overlay: PlayerOverlayController,
              onNavigateToDetail: ((String, String) -> Void)? = nil) async {
        guard !isResolving else { return }
        isResolving = true
        defer { isResolving = false }

        Self.requestGeneration += 1
        let generation = Self.requestGeneration

        let timeZone = await PanelTimeZoneResolver.resolve(playlist: playlist)
        let duration = CatchupAvailability.requestDurationMinutes(
            programmeStart: programme.startUTC, programmeStop: programme.stopUTC)
        do {
            let resolved = try await CatchupURLResolver.resolve(
                playlist: playlist, streamId: stream.streamId,
                startUTC: programme.startUTC, durationMinutes: duration,
                panelTimeZone: timeZone, allowedFormats: nil)
            guard generation == Self.requestGeneration else { return }
            overlay.present(playlistId: playlist.id) {
                CatchupPlayerShell(
                    playlist: playlist, stream: stream, programme: programme,
                    url: resolved.url, onNavigateToDetail: onNavigateToDetail
                )
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? L("epg.catchup.error.unavailable")
        }
    }
}
