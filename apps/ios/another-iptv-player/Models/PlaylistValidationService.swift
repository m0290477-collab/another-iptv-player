import Foundation
import GRDB

/// Build 61 (B10, Q17 + L-pack + K1 + Q18): the ONE add/edit-time
/// validation and staged-import service.
///
/// Q17 rule: a playlist is tested BEFORE anything is saved.
/// - Xtream: the `get_user_info` auth probe (`XtreamAPIClient.verify`).
/// - M3U: a fetch + parse probe (remote URL or local file content).
/// Failures are DISTINCT and plain: bad URL / bad credentials /
/// expired account / unreachable server / empty playlist. On any
/// failure NOTHING is written — the import functions in
/// `PlaylistSaveService` only run after a successful probe, and the
/// M3U pipeline itself parses before it replaces any rows.
///
/// L1/L2/L3: `importXtream` / `importM3U` drive the add flow stage
/// by stage and report a real `PlaylistAddSummary` (real expiry,
/// real imported counts, the one non-critical stage that failed —
/// the guide — which can be retried on its own). The stage
/// callbacks fire from the actual importer calls, never a timer.
enum PlaylistValidationService {

    // MARK: - Q17 failure taxonomy

    enum ValidationFailure: LocalizedError, Equatable {
        /// The URL is not a usable http(s) URL with a host.
        case invalidURL
        /// The server answered but rejected the username/password.
        case badCredentials
        /// The account verified but its provider subscription has ended.
        case expiredAccount(expiryDate: Date?)
        /// The server could not be reached at all.
        case unreachable
        /// The source answered but carried no playable channels.
        case emptyPlaylist
        /// The server answered with an HTTP error / unreadable data.
        case serverRefused

        var errorDescription: String? {
            switch self {
            case .invalidURL: return L("addplaylist.error.invalid_url")
            case .badCredentials: return L("addplaylist.error.bad_credentials")
            case .expiredAccount: return L("addplaylist.error.expired")
            case .unreachable: return L("addplaylist.error.unreachable")
            case .emptyPlaylist: return L("addplaylist.error.empty")
            case .serverRefused: return L("addplaylist.error.server")
            }
        }
    }

    // MARK: - L1 stages

    /// The add-flow checklist stages, in order. States are driven
    /// exclusively by the real importer calls in this service.
    enum Stage: Int, CaseIterable, Equatable {
        case connecting
        case verifying
        case loadingChannels
        case loadingMoviesSeries
        case loadingGuide

        var titleKey: String {
            switch self {
            case .connecting: return "addplaylist.stage.connecting"
            case .verifying: return "addplaylist.stage.verifying"
            case .loadingChannels: return "addplaylist.stage.channels"
            case .loadingMoviesSeries: return "addplaylist.stage.movies_series"
            case .loadingGuide: return "addplaylist.stage.guide"
            }
        }
    }

    enum StageState: Equatable {
        case pending, active, done, failed
    }

    /// L2/L3 outcome of a completed (or partially completed) add.
    struct AddSummary: Equatable {
        let playlist: Playlist
        /// Real provider expiry (Xtream auth response). For M3U this
        /// is non-nil ONLY when the source itself carries an expiry
        /// — M3U sources in this app carry none, so it stays nil and
        /// the summary shows NO date row (L2 rule).
        let expiryDate: Date?
        let liveCount: Int
        let movieCount: Int
        let seriesCount: Int
        /// The non-critical stage that failed while the account was
        /// valid (L3) — currently only the guide can land here;
        /// content-stage failures abort the add and save nothing.
        let failedStage: Stage?
        /// Z1: the compatibility probe result (real reachable /
        /// sampled counts), nil when no live streams existed to
        /// probe or the probe was cancelled. Informational only —
        /// it never blocks a valid account.
        let compatibility: CompatibilityResult?
    }

    /// Z1 outcome: how many of the sampled live streams answered
    /// a short first-bytes probe.
    struct CompatibilityResult: Equatable {
        let reachable: Int
        let sampled: Int
    }

    // MARK: - URL sanity (shared by the probes)

    static func isUsableHTTPURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    // MARK: - Xtream probe (Q17)

    /// Runs the auth probe for an Xtream playlist. On success the
    /// (timezone-captured) playlist + auth response + client are
    /// returned and NOTHING has been saved yet. Expired accounts
    /// are a distinct failure here for the ADD/EDIT forms (the gate
    /// keeps its own browse-anyway parking behaviour, unchanged).
    static func probeXtream(
        playlist: Playlist
    ) async throws -> (playlist: Playlist, response: XtreamAuthResponse, client: XtreamAPIClient) {
        guard isUsableHTTPURL(playlist.serverURL) else { throw ValidationFailure.invalidURL }
        var candidate = playlist
        do {
            let (response, client) = try await PlaylistSaveService.verifyXtream(playlist: &candidate)
            // Record the verified expiry like every other verify
            // site (gate, T5 page) — this is also what lets the
            // L4 expired state clear after a successful Renew.
            ProviderExpiryStore.record(playlistId: candidate.id, expDate: response.userInfo?.expDate)
            if ProviderExpiryStore.isExpired(expDateString: response.userInfo?.expDate)
                || response.userInfo?.status?.caseInsensitiveCompare("Expired") == .orderedSame {
                throw ValidationFailure.expiredAccount(
                    expiryDate: ProviderExpiryStore.parseExpiryDate(response.userInfo?.expDate))
            }
            return (candidate, response, client)
        } catch let failure as ValidationFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as XtreamError {
            throw mapXtreamError(error)
        } catch {
            throw ValidationFailure.unreachable
        }
    }

    static func mapXtreamError(_ error: XtreamError) -> ValidationFailure {
        switch error {
        case .invalidURL: return .invalidURL
        case .unauthenticated: return .badCredentials
        case .networkError: return .unreachable
        case .serverError, .decodingError: return .serverRefused
        }
    }

    // MARK: - M3U probe (Q17)

    /// Fetches (or takes local content) and parses an M3U source
    /// WITHOUT saving anything. Returns the raw content + parsed
    /// channels so the caller imports exactly what was probed.
    /// Q18: a primary connection failure retries once against the
    /// playlist's backup URL when one is set.
    static func probeM3U(
        playlist: Playlist,
        localContent: String?
    ) async throws -> (content: String, parsed: ParsedM3UPlaylist, usedBackup: Bool) {
        if let localContent {
            let parsed = try await parseProbe(localContent)
            return (localContent, parsed, false)
        }
        guard isUsableHTTPURL(playlist.serverURL) else { throw ValidationFailure.invalidURL }
        do {
            let content = try await M3UService().fetchRemote(urlString: playlist.serverURL, playlist: playlist)
            let parsed = try await parseProbe(content)
            return (content, parsed, false)
        } catch let failure as ValidationFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as M3UServiceError {
            // Q18 failover: connection-level failures only.
            if case .networkError = error, let backup = playlist.trimmedBackupURL {
                do {
                    let content = try await M3UService().fetchRemote(urlString: backup, playlist: playlist)
                    let parsed = try await parseProbe(content)
                    return (content, parsed, true)
                } catch let failure as ValidationFailure {
                    throw failure
                } catch let backupError as M3UServiceError {
                    throw mapM3UError(backupError)
                }
            }
            throw mapM3UError(error)
        } catch {
            throw ValidationFailure.unreachable
        }
    }

    /// Parse half of the M3U probe: a source that parses to zero
    /// channels is the distinct `emptyPlaylist` failure.
    private static func parseProbe(_ content: String) async throws -> ParsedM3UPlaylist {
        do {
            let parsed = try await M3UParser.parseAsync(content)
            guard !parsed.channels.isEmpty else { throw ValidationFailure.emptyPlaylist }
            return parsed
        } catch is CancellationError {
            throw CancellationError()
        } catch is ValidationFailure {
            throw ValidationFailure.emptyPlaylist
        } catch {
            // M3UParserError (.empty / .noChannelsFound) and any
            // other parse failure mean the source carried nothing
            // playable — the same distinct outcome for the user.
            throw ValidationFailure.emptyPlaylist
        }
    }

    static func mapM3UError(_ error: M3UServiceError) -> ValidationFailure {
        switch error {
        case .invalidURL: return .invalidURL
        case .networkError: return .unreachable
        case .serverError, .fileReadError, .encodingUnsupported: return .serverRefused
        }
    }

    // MARK: - L1/L2/L3 staged Xtream import

    /// Full staged add for Xtream: probe (connecting + verifying),
    /// then the importer (the six panel fetches run in parallel
    /// inside `XtreamImporter` and are saved in one write, so the
    /// channels and movies/series stages complete together when
    /// that single real step lands — they are not separately
    /// timed), then the guide stage. Guide failure is L3 partial success — the
    /// playlist IS saved; every earlier failure saves nothing.
    /// Cancel mid-way throws `CancellationError` before the save
    /// for the probe stages; the importer's own save is its final
    /// step, so a cancelled import leaves no half-written catalog
    /// beyond the importer's existing semantics (playlist row is
    /// written by the importer only after all fetches succeed).
    static func importXtream(
        playlist: Playlist,
        onStage: @escaping @MainActor (Stage, StageState) -> Void
    ) async throws -> AddSummary {
        await onStage(.connecting, .active)
        let probed: (playlist: Playlist, response: XtreamAuthResponse, client: XtreamAPIClient)
        do {
            probed = try await probeXtream(playlist: playlist)
        } catch {
            await onStage(.connecting, .failed)
            throw error
        }
        await onStage(.connecting, .done)
        await onStage(.verifying, .done)

        await onStage(.loadingChannels, .active)
        try await PlaylistSaveService.syncXtream(
            playlist: probed.playlist, client: probed.client
        ) { _ in }
        try Task.checkCancellation()
        await onStage(.loadingChannels, .done)
        await onStage(.loadingMoviesSeries, .done)

        ProviderExpiryStore.record(playlistId: probed.playlist.id, expDate: probed.response.userInfo?.expDate)

        let counts = await importedCounts(playlistId: probed.playlist.id, kind: .xtream)
        // Z1: compatibility probe AFTER the catalog load.
        let compatibility = await probeCompatibility(playlist: probed.playlist)
        if Task.isCancelled { throw CancellationError() }
        let guideFailed = await runGuideStage(playlist: probed.playlist, onStage: onStage)
        return AddSummary(
            playlist: probed.playlist,
            expiryDate: ProviderExpiryStore.parseExpiryDate(probed.response.userInfo?.expDate),
            liveCount: counts.live, movieCount: counts.movies, seriesCount: counts.series,
            failedStage: guideFailed ? .loadingGuide : nil,
            compatibility: compatibility
        )
    }

    // MARK: - L1/L2/L3 staged M3U import

    /// Full staged add for M3U: probe (fetch + parse — connecting +
    /// verifying + channels complete from the one real pipeline),
    /// save via the shared importer path, then the guide stage
    /// (only when the playlist actually has a guide source; with no
    /// source the stage completes trivially — there is no guide to
    /// load, and the checklist row is marked done, not faked: the
    /// importer's parse already captured the source's EPG URL).
    static func importM3U(
        playlist: Playlist,
        localContent: String?,
        onStage: @escaping @MainActor (Stage, StageState) -> Void
    ) async throws -> AddSummary {
        await onStage(.connecting, .active)
        let probed: (content: String, parsed: ParsedM3UPlaylist, usedBackup: Bool)
        do {
            probed = try await probeM3U(playlist: playlist, localContent: localContent)
        } catch {
            await onStage(.connecting, .failed)
            throw error
        }
        await onStage(.connecting, .done)
        await onStage(.verifying, .done)
        await onStage(.loadingChannels, .active)
        try Task.checkCancellation()
        try await M3UImporter.replace(
            playlist: playlist,
            channels: probed.parsed.channels,
            epgURL: probed.parsed.epgURL,
            clearServerURL: localContent != nil
        )
        await onStage(.loadingChannels, .done)
        await onStage(.loadingMoviesSeries, .done)

        var saved = playlist
        saved.m3uEpgURL = probed.parsed.epgURL
        if localContent != nil { saved.serverURL = "" }
        let guideFailed: Bool
        if saved.effectiveEPGURL != nil {
            guideFailed = await runGuideStage(playlist: saved, onStage: onStage)
        } else {
            await onStage(.loadingGuide, .done)
            guideFailed = false
        }
        // Z1: compatibility probe AFTER the catalog load.
        let compatibility = await probeCompatibility(playlist: saved)
        if Task.isCancelled { throw CancellationError() }
        return AddSummary(
            playlist: saved,
            expiryDate: nil,
            liveCount: probed.parsed.channels.count, movieCount: 0, seriesCount: 0,
            failedStage: guideFailed ? .loadingGuide : nil,
            compatibility: compatibility
        )
    }

    // MARK: - Z1: compatibility probe

    private struct ProbeTarget {
        let url: URL
        let userAgent: String?
    }

    /// Probes a small sample (up to 10) of the playlist's live
    /// streams, spread across categories/groups (round-robin, so
    /// one dead category cannot fill the whole sample). Each probe
    /// is a short-timeout FIRST-BYTES check — it opens the stream
    /// URL exactly as the player builds it, reads the first chunk,
    /// and stops; it is NOT full playback and is labeled as such
    /// on the summary. Sequential with an overall cap, cancellable
    /// with the add task; a cancelled probe returns nil (no ratio
    /// is shown) rather than a partial count presented as complete.
    static func probeCompatibility(playlist: Playlist) async -> CompatibilityResult? {
        let targets = await sampleTargets(playlist: playlist)
        guard !targets.isEmpty else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)
        var reachable = 0
        for target in targets {
            if Task.isCancelled { return nil }
            if await probeFirstBytes(target: target, playlist: playlist, session: session) {
                reachable += 1
            }
        }
        if Task.isCancelled { return nil }
        return CompatibilityResult(reachable: reachable, sampled: targets.count)
    }

    private static func probeFirstBytes(target: ProbeTarget, playlist: Playlist, session: URLSession) async -> Bool {
        var request = URLRequest(url: target.url)
        playlist.applyCustomHeaders(to: &request)
        if request.value(forHTTPHeaderField: "User-Agent") == nil, let ua = target.userAgent {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200...399).contains(http.statusCode) {
                return false
            }
            // First chunk arrival = the stream actually serves data.
            for try await _ in bytes { return true }
            return false
        } catch {
            return false
        }
    }

    /// Round-robin sample across categories (Xtream) or groups
    /// (M3U), in catalog order, capped at 10.
    private static func sampleTargets(playlist: Playlist) async -> [ProbeTarget] {
        let cap = 10
        switch playlist.kind {
        case .xtream:
            let rows = (try? await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT streamId, categoryId FROM liveStream
                    WHERE playlistId = ? ORDER BY categoryId, sortIndex
                    """, arguments: [playlist.id])
            }) ?? []
            var groups: [[Int]] = []
            var groupIndex: [String: Int] = [:]
            for row in rows {
                let streamId: Int = row["streamId"]
                let category: String = row["categoryId"] ?? ""
                if let idx = groupIndex[category] {
                    groups[idx].append(streamId)
                } else {
                    groupIndex[category] = groups.count
                    groups.append([streamId])
                }
            }
            let builder = PlaybackURLBuilder(playlist: playlist)
            return spread(groups: groups, cap: cap).compactMap { streamId in
                builder.liveURL(streamId: streamId).map { ProbeTarget(url: $0, userAgent: nil) }
            }
        case .m3u:
            let rows = (try? await AppDatabase.shared.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT url, groupTitle, userAgent FROM m3uChannel
                    WHERE playlistId = ? ORDER BY groupTitle, sortIndex
                    """, arguments: [playlist.id])
            }) ?? []
            var groups: [[ProbeTarget]] = []
            var groupIndex: [String: Int] = [:]
            for row in rows {
                let urlString: String = row["url"]
                guard let url = URL(string: urlString) else { continue }
                let target = ProbeTarget(url: url, userAgent: playlist.playbackUserAgent(channelUserAgent: row["userAgent"]))
                let group: String = row["groupTitle"] ?? ""
                if let idx = groupIndex[group] {
                    groups[idx].append(target)
                } else {
                    groupIndex[group] = groups.count
                    groups.append([target])
                }
            }
            return spread(groups: groups, cap: cap)
        }
    }

    /// Round-robin pick: one from each group in turn until the
    /// cap or exhaustion.
    private static func spread<T>(groups: [[T]], cap: Int) -> [T] {
        var picked: [T] = []
        var depth = 0
        while picked.count < cap {
            var advanced = false
            for group in groups where depth < group.count {
                picked.append(group[depth])
                advanced = true
                if picked.count >= cap { break }
            }
            if !advanced { break }
            depth += 1
        }
        return picked
    }

    /// The guide stage (L1 last row / L3 retry target): a real
    /// EPG refresh through the existing coordinator. Returns true
    /// when the stage failed. Playlists with EPG disabled complete
    /// the stage without a fetch.
    static func runGuideStage(
        playlist: Playlist,
        onStage: @escaping @MainActor (Stage, StageState) -> Void
    ) async -> Bool {
        await onStage(.loadingGuide, .active)
        guard playlist.epgEnabled else {
            await onStage(.loadingGuide, .done)
            return false
        }
        do {
            _ = try await EPGRefreshCoordinator().refresh(playlist: playlist) { _ in }
            await onStage(.loadingGuide, .done)
            return false
        } catch {
            await onStage(.loadingGuide, .failed)
            return true
        }
    }

    /// Real imported counts for the L2 summary, read back from the
    /// database after the import — never the panel's claims.
    static func importedCounts(
        playlistId: UUID, kind: PlaylistKind
    ) async -> (live: Int, movies: Int, series: Int) {
        let counts = try? await AppDatabase.shared.read { db -> (Int, Int, Int) in
            switch kind {
            case .xtream:
                let live = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liveStream WHERE playlistId = ?", arguments: [playlistId]) ?? 0
                let movies = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vodStream WHERE playlistId = ?", arguments: [playlistId]) ?? 0
                let series = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM series WHERE playlistId = ?", arguments: [playlistId]) ?? 0
                return (live, movies, series)
            case .m3u:
                let live = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM m3uChannel WHERE playlistId = ?", arguments: [playlistId]) ?? 0
                return (live, 0, 0)
            }
        }
        return counts.map { (live: $0.0, movies: $0.1, series: $0.2) } ?? (0, 0, 0)
    }
}

// MARK: - K1: Xtream ready-link auto-fill

/// Build 61 (B10, K1): in-form paste parsing. When the user pastes
/// a full Xtream `get.php`-style URL (server + username + password
/// parameters) into ANY field of the gate / add / edit forms, the
/// forms fill Server / Username / Password automatically; the user
/// still confirms with Connect/Save as normal. Parse failure leaves
/// the pasted text exactly as-is and shows NO error. This is purely
/// a reaction to the field's own new value — there is NO clipboard
/// reading or watching anywhere in this type (S2 stays cut).
enum XtreamReadyLink {
    /// Returns the parsed credentials when `text` is a ready link,
    /// nil otherwise. Delegates to the existing detector — the same
    /// parser the QR flow and the M3U auto-detection already use.
    static func parse(_ text: String) -> XtreamLinkDetector.Credentials? {
        XtreamLinkDetector.detect(urlString: text)
    }
}
