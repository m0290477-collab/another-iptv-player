import Foundation

/// Round 16 (F2): the ONE shared playlist save pipeline.
///
/// Before this service existed, the verify → timezone-capture →
/// sync sequence and the fetch → parse → replace sequence lived
/// in several hand-kept copies: the playlist gate (which creates
/// playlists) carried three, and the two edit sheets
/// (AddPlaylistView / AddM3UPlaylistView) carried the originals —
/// free to drift apart on any future fix.
///
/// Callers keep everything that is genuinely theirs: the gate's
/// duplicate-account merge, expired-account parking, direct app
/// entry and health recording; the sheets' name-only fast paths,
/// error wording and dismissal. Only the duplicated pipelines
/// live here, so sign-in/save behavior stays identical everywhere.
enum PlaylistSaveService {

    /// Verify an Xtream account and capture the panel timezone
    /// onto the playlist (timeshift start-time conversion reads
    /// it later). Returns the auth response plus the client built
    /// from the playlist, so the caller applies its own auth /
    /// expiry policy and syncs with the very same client.
    static func verifyXtream(
        playlist: inout Playlist
    ) async throws -> (response: XtreamAuthResponse, client: XtreamAPIClient) {
        let client = XtreamAPIClient(playlist: playlist)
        let response = try await client.verify()
        // Capture the panel timezone for timeshift start-time conversion.
        if let tz = response.serverInfo?.timezone?.trimmingCharacters(in: .whitespacesAndNewlines), !tz.isEmpty {
            playlist.serverTimezone = tz
        }
        return (response, client)
    }

    /// Sync + save an Xtream playlist's full catalog.
    static func syncXtream(
        playlist: Playlist,
        client: XtreamAPIClient,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        try await XtreamImporter.syncAndSave(playlist: playlist, client: client, progress: progress)
    }

    /// The M3U pipeline: take the local file's content or download
    /// the remote list, parse it, and replace the playlist's
    /// channels in the database. `progress` receives the same
    /// localized status strings both callers used to set by hand.
    ///
    /// - Parameter checkCancellation: the gate's original copy
    ///   bailed out silently between steps when its task was
    ///   cancelled (pass `true` there); the edit sheet's copy ran
    ///   to completion (pass `false`). Cancellation surfaces as a
    ///   thrown `CancellationError` for the caller to reset on.
    static func importM3U(
        playlist: Playlist,
        localContent: String?,
        remoteURLString: String,
        clearServerURL: Bool,
        checkCancellation: Bool,
        progress: @MainActor (String?) -> Void
    ) async throws {
        let rawContent: String
        if let localContent {
            rawContent = localContent
        } else {
            progress(L("add_m3u.downloading"))
            rawContent = try await M3UService().fetchRemote(urlString: remoteURLString)
        }
        if checkCancellation, Task.isCancelled { throw CancellationError() }

        progress(L("add_m3u.parsing"))
        let parsed = try await M3UParser.parseAsync(rawContent)

        progress(L("add_m3u.saving_db"))
        try await M3UImporter.replace(
            playlist: playlist,
            channels: parsed.channels,
            epgURL: parsed.epgURL,
            clearServerURL: clearServerURL
        )
    }
}
