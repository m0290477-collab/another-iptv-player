import Foundation
import GRDB

enum PlaylistKind: String, Codable {
    case xtream
    case m3u
}

struct Playlist: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable {
    var id: UUID
    var name: String
    var serverURL: String
    var username: String
    var password: String
    var createdAt: Date = Date()
    var filterAdultContent: Bool = false
    var type: String = PlaylistKind.xtream.rawValue
    var m3uEpgURL: String? = nil
    /// User-entered EPG (XMLTV) URL override for M3U playlists. Takes precedence
    /// over the `x-tvg-url` header captured in `m3uEpgURL`.
    var epgURLOverride: String? = nil
    /// Whether EPG fetch/display is enabled for this playlist.
    var epgEnabled: Bool = true
    /// IANA timezone name from Xtream `server_info` — timeshift `start` params are
    /// interpreted in the panel's local time, not the device's.
    var serverTimezone: String? = nil
    /// Cached probe result for the timeshift URL shape: "path" | "php".
    var timeshiftStyle: String? = nil
    /// Build 61 (B10, Q18): optional backup server URL. The API /
    /// importer layer retries against it when the primary fails to
    /// CONNECT (network-level failure only — never on an auth or
    /// HTTP refusal, which the backup would answer identically).
    var backupURL: String? = nil
    /// Build 61 (B10, G2): per-playlist custom User-Agent, applied to
    /// playlist fetch, EPG fetch and stream playback. Nil/empty =
    /// previous behaviour (per-channel M3U UA / engine default).
    var customUserAgent: String? = nil
    /// Build 61 (B10, G2): per-playlist custom HTTP headers as a
    /// JSON object string (`{"X-Key": "value"}`), edited in the
    /// add/edit forms as one "Name: Value" line per header. Applied
    /// at the same three fetch/playback points as the User-Agent.
    var customHeadersJSON: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, serverURL, username, password, createdAt, filterAdultContent, type, m3uEpgURL
        case epgURLOverride, epgEnabled, serverTimezone, timeshiftStyle
        case backupURL, customUserAgent, customHeadersJSON
    }

    init(
        id: UUID = UUID(),
        name: String,
        serverURL: String,
        username: String = "",
        password: String = "",
        filterAdultContent: Bool = false,
        type: PlaylistKind = .xtream,
        m3uEpgURL: String? = nil,
        epgURLOverride: String? = nil,
        epgEnabled: Bool = true,
        serverTimezone: String? = nil,
        timeshiftStyle: String? = nil,
        backupURL: String? = nil,
        customUserAgent: String? = nil,
        customHeadersJSON: String? = nil
    ) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.filterAdultContent = filterAdultContent
        self.type = type.rawValue
        self.m3uEpgURL = m3uEpgURL
        self.epgURLOverride = epgURLOverride
        self.epgEnabled = epgEnabled
        self.serverTimezone = serverTimezone
        self.timeshiftStyle = timeshiftStyle
        self.backupURL = backupURL
        self.customUserAgent = customUserAgent
        self.customHeadersJSON = customHeadersJSON
    }

    nonisolated var kind: PlaylistKind {
        PlaylistKind(rawValue: type) ?? .xtream
    }

    /// Effective EPG source URL for M3U playlists: a user override wins over the
    /// `x-tvg-url` header value so re-imports don't clobber a manual URL.
    nonisolated var effectiveEPGURL: String? {
        if let o = epgURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            return o
        }
        return m3uEpgURL
    }

    // MARK: - Build 61 (B10): connection extras (G2 / G4 / Q18)

    /// The trimmed custom EPG (XMLTV) override for EITHER playlist
    /// kind (G4). For M3U this is exactly `effectiveEPGURL`'s first
    /// source; for Xtream the refresh coordinator consults this
    /// before falling back to the provider's own xmltv.php.
    nonisolated var customEPGURL: String? {
        let o = epgURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (o?.isEmpty == false) ? o : nil
    }

    /// The trimmed backup URL (Q18), nil when unset.
    nonisolated var trimmedBackupURL: String? {
        let b = backupURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (b?.isEmpty == false) ? b : nil
    }

    /// The trimmed per-playlist User-Agent (G2), nil when unset.
    nonisolated var trimmedUserAgent: String? {
        let u = customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (u?.isEmpty == false) ? u : nil
    }

    /// Decoded custom headers (G2). A malformed JSON value decodes
    /// to no headers — the field is user text, never a crash path.
    nonisolated var customHeaders: [String: String] {
        guard let json = customHeadersJSON, !json.isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    /// Encodes header pairs for storage; empty input clears the field.
    static func encodeCustomHeaders(_ headers: [String: String]) -> String? {
        let cleaned = headers.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        guard !cleaned.isEmpty,
              let data = try? JSONEncoder().encode(cleaned),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    /// Parses the add/edit form's "Name: Value" lines (one header
    /// per line) into pairs. Lines without a colon are ignored —
    /// the form shows the parsed result back, so nothing is
    /// silently invented or lost without the user seeing it.
    static func parseHeaderLines(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !value.isEmpty { result[name] = value }
        }
        return result
    }

    /// The form representation of the stored headers.
    nonisolated var customHeadersText: String {
        customHeaders
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    /// Applies this playlist's G2 headers (+ UA) to a request.
    /// Used by the playlist fetch, M3U fetch and EPG fetch paths.
    nonisolated func applyCustomHeaders(to request: inout URLRequest) {
        for (name, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let ua = trimmedUserAgent {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
    }

    /// The User-Agent a playback load should use for this playlist:
    /// the playlist's own UA wins over a per-channel (M3U) UA.
    nonisolated func playbackUserAgent(channelUserAgent: String?) -> String? {
        if let ua = trimmedUserAgent { return ua }
        let ch = channelUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (ch?.isEmpty == false) ? ch : nil
    }
}

// MARK: - Persistence
extension Playlist {
    static let databaseTableName = "playlist"
}
