import Foundation

enum XtreamError: LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case unauthenticated
    case decodingError(Error)
    case serverError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return L("misc.xtream.invalid_url", url)
        case .networkError(let error): return L("net.error.network", error.localizedDescription)
        case .unauthenticated: return L("misc.xtream.auth_error")
        case .decodingError(let error): return L("misc.xtream.decode_error", error.localizedDescription)
        case .serverError(let status): return L("misc.xtream.server_error", status)
        }
    }
}

/// A session with bounded timeouts for IPTV panel/playlist requests. `URLSession.shared`
/// comes with a 60s idle + 7-DAY resource timeout — an unresponsive panel
/// used to leave the add/refresh flow hanging for minutes, uncancellable.
/// `nonisolated`: URLSession is Sendable; used from background contexts (EPG download).
nonisolated enum PanelURLSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
}

class XtreamAPIClient {
    private let playlist: Playlist
    private let urlSession: URLSession

    init(playlist: Playlist, urlSession: URLSession = PanelURLSession.shared) {
        self.playlist = playlist
        self.urlSession = urlSession
    }

    /// Masks credentials in URLs that will end up in logs and error texts — panel URLs
    /// carry username/password and those can leak via alert screenshots/logs.
    private static func redacted(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString) else { return "<invalid-url>" }
        comps.queryItems = comps.queryItems?.map { item in
            if item.name == "username" || item.name == "password" {
                return URLQueryItem(name: item.name, value: "***")
            }
            return item
        }
        return comps.string ?? "<invalid-url>"
    }
    
    // Auto-formatting the base URL. Build 61 (B10, Q18): an
    // explicit base override is the playlist's backup server, used
    // by the one failover retry in `fetch`.
    private func getBaseURLComponents(baseOverride: String? = nil) -> URLComponents {
        var baseString = (baseOverride ?? playlist.serverURL).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !baseString.lowercased().hasPrefix("http://") && !baseString.lowercased().hasPrefix("https://") {
            baseString = "http://\(baseString)"
        }
        
        if baseString.hasSuffix("/") {
            baseString.removeLast()
        }
        
        if !baseString.lowercased().hasSuffix("player_api.php") {
             baseString += "/player_api.php"
        }
        
        // Remove spaces inside URL just in case
        baseString = baseString.replacingOccurrences(of: " ", with: "")
        
        var comps = URLComponents(string: baseString) ?? URLComponents()
        
        comps.queryItems = [
            URLQueryItem(name: "username", value: playlist.username.trimmingCharacters(in: .whitespacesAndNewlines)),
            // Build 66 (W2, item 6): the working password resolves
            // from the Keychain via the single resolver — the
            // database column is legacy and blank.
            URLQueryItem(name: "password", value: (CredentialStore.password(for: playlist) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        
        return comps
    }
    
    private func fetch<T: Decodable>(action: String? = nil, queryItems: [URLQueryItem] = []) async throws -> T {
        do {
            return try await fetchOnce(action: action, queryItems: queryItems, baseOverride: nil)
        } catch let error as XtreamError {
            // Build 61 (B10, Q18): automatic failover — a
            // CONNECTION failure against the primary retries the
            // same request once against the playlist's backup
            // server URL. Auth refusals and HTTP errors are NOT
            // retried (the backup would answer identically).
            // Silent-but-logged; surfaced in playlist settings via
            // the backup-URL field's note.
            guard case .networkError = error, let backup = playlist.trimmedBackupURL else { throw error }
            Log.info("XtreamAPI", "Primary server unreachable — failing over to the playlist's backup URL")
            return try await fetchOnce(action: action, queryItems: queryItems, baseOverride: backup)
        }
    }

    private func fetchOnce<T: Decodable>(action: String? = nil, queryItems: [URLQueryItem] = [], baseOverride: String?) async throws -> T {
        var comps = getBaseURLComponents(baseOverride: baseOverride)
        
        if let action = action {
            comps.queryItems?.append(URLQueryItem(name: "action", value: action))
        }
        
        if !queryItems.isEmpty {
            comps.queryItems?.append(contentsOf: queryItems)
        }
        
        // '+' is valid in a query per RFC 3986 so URLComponents does not encode it, but PHP-
        // based Xtream panels turn '+' into a space in $_GET — an 'ab+12' password
        // would arrive as 'ab 12' and sign-in would be silently rejected.
        comps.percentEncodedQuery = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

        guard let url = comps.url else {
            // Do not put a raw (credential-bearing) URL in error text shown to the user.
            throw XtreamError.invalidURL(Self.redacted(comps.string ?? ""))
        }


        do {
            // Build 61 (B10, G2): the playlist's custom headers +
            // User-Agent ride on every panel request when set.
            let data: Data
            let response: URLResponse
            if !playlist.customHeaders.isEmpty || playlist.trimmedUserAgent != nil {
                var request = URLRequest(url: url)
                playlist.applyCustomHeaders(to: &request)
                (data, response) = try await urlSession.data(for: request)
            } else {
                (data, response) = try await urlSession.data(from: url)
            }

            // Round 16 (R7): the debug dump that printed the ENTIRE
            // get_series_info JSON response on every fetch is
            // removed — production logging must never carry full
            // panel payloads.

            // Check HTTP status code
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                 throw XtreamError.serverError("HTTP \(httpResponse.statusCode)")
            }

            // Catch JSON decoding errors safely
            do {
                let decoder = JSONDecoder()
                return try decoder.decode(T.self, from: data)
            } catch(let error) {
                // Round 16 (R7): the raw-payload decoding-error
                // prints are removed with the series-info dump.
                throw XtreamError.decodingError(error)
            }
        } catch let error as XtreamError {
            throw error
        } catch {
            throw XtreamError.networkError(error)
        }
    }
    
    // MARK: - API Methods
    
    func verify() async throws -> XtreamAuthResponse {
        // Just the base query items, no action for login/verify
        let response: XtreamAuthResponse = try await fetch()
        
        // Check if userInfo is nil, that usually means unauthorized in Xtream
        if response.userInfo == nil || response.userInfo?.auth == 0 {
            throw XtreamError.unauthenticated
        }
        
        return response
    }
    
    func getLiveCategories() async throws -> [XtreamCategory] {
        let failable: [FailableDecodable<XtreamCategory>] = try await fetch(action: "get_live_categories")
        return failable.compactMap { $0.base }
    }
    
    func getVODCategories() async throws -> [XtreamCategory] {
        let failable: [FailableDecodable<XtreamCategory>] = try await fetch(action: "get_vod_categories")
        return failable.compactMap { $0.base }
    }
    
    func getSeriesCategories() async throws -> [XtreamCategory] {
        let failable: [FailableDecodable<XtreamCategory>] = try await fetch(action: "get_series_categories")
        return failable.compactMap { $0.base }
    }
    
    func getLiveStreams(categoryId: String? = nil) async throws -> [XtreamLiveStream] {
        var queryItems: [URLQueryItem] = []
        if let catId = categoryId {
            queryItems.append(URLQueryItem(name: "category_id", value: catId))
        }
        let failable: [FailableDecodable<XtreamLiveStream>] = try await fetch(action: "get_live_streams", queryItems: queryItems)
        return failable.compactMap { $0.base }
    }
    
    func getVODStreams(categoryId: String? = nil) async throws -> [XtreamVODStream] {
        var queryItems: [URLQueryItem] = []
        if let catId = categoryId {
            queryItems.append(URLQueryItem(name: "category_id", value: catId))
        }
        let failable: [FailableDecodable<XtreamVODStream>] = try await fetch(action: "get_vod_streams", queryItems: queryItems)
        return failable.compactMap { $0.base }
    }
    
    func getSeries(categoryId: String? = nil) async throws -> [XtreamSeries] {
        var queryItems: [URLQueryItem] = []
        if let catId = categoryId {
            queryItems.append(URLQueryItem(name: "category_id", value: catId))
        }
        let failable: [FailableDecodable<XtreamSeries>] = try await fetch(action: "get_series", queryItems: queryItems)
        return failable.compactMap { $0.base }
    }
    
    func getSeriesInfo(seriesId: Int) async throws -> XtreamSeriesInfoResponse {
        var queryItems: [URLQueryItem] = []
        queryItems.append(URLQueryItem(name: "series_id", value: String(seriesId)))
        return try await fetch(action: "get_series_info", queryItems: queryItems)
    }

    func getVODInfo(vodId: Int) async throws -> XtreamVODInfoResponse {
        var queryItems: [URLQueryItem] = []
        queryItems.append(URLQueryItem(name: "vod_id", value: String(vodId)))
        return try await fetch(action: "get_vod_info", queryItems: queryItems)
    }

    // MARK: - EPG

    /// Short now/next EPG for one channel — used as the player overlay fallback
    /// when the XMLTV guide is missing/broken. Never call this per shelf card.
    func getShortEPG(streamId: Int, limit: Int = EPGConstants.shortEPGLimit) async throws -> XtreamEPGListingsResponse {
        let queryItems = [
            URLQueryItem(name: "stream_id", value: String(streamId)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        return try await fetch(action: "get_short_epg", queryItems: queryItems)
    }

    /// Full per-channel EPG table (past + future, includes archive flags) — used
    /// for the channel detail list and catch-up when XMLTV lacks past programmes.
    func getSimpleDataTable(streamId: Int) async throws -> XtreamEPGListingsResponse {
        let queryItems = [URLQueryItem(name: "stream_id", value: String(streamId))]
        return try await fetch(action: "get_simple_data_table", queryItems: queryItems)
    }

}
