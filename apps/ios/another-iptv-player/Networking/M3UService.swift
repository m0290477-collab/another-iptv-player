import Foundation

enum M3UServiceError: LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case serverError(Int)
    case fileReadError(Error)
    case encodingUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return L("net.error.invalid_url", url)
        case .networkError(let err): return L("net.error.network", err.localizedDescription)
        case .serverError(let code): return L("net.error.server", code)
        case .fileReadError(let err): return L("net.error.file_read", err.localizedDescription)
        case .encodingUnsupported: return L("net.error.encoding_unsupported")
        }
    }
}

/// Downloads M3U/M3U8 content from a remote URL or reads it from a local file.
struct M3UService {
    let urlSession: URLSession

    init(urlSession: URLSession = PanelURLSession.shared) {
        self.urlSession = urlSession
    }

    /// Build 61 (B10, G2): when a playlist is supplied, its custom
    /// headers + User-Agent ride on the fetch. Callers without a
    /// playlist keep the previous behaviour exactly.
    func fetchRemote(urlString: String, playlist: Playlist? = nil) async throws -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw M3UServiceError.invalidURL(urlString)
        }

        do {
            let data: Data
            let response: URLResponse
            if let playlist, (!playlist.customHeaders.isEmpty || playlist.trimmedUserAgent != nil) {
                var request = URLRequest(url: url)
                playlist.applyCustomHeaders(to: &request)
                (data, response) = try await urlSession.data(for: request)
            } else {
                (data, response) = try await urlSession.data(from: url)
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw M3UServiceError.serverError(http.statusCode)
            }
            return try decode(data: data)
        } catch let e as M3UServiceError {
            throw e
        } catch {
            throw M3UServiceError.networkError(error)
        }
    }

    // nonisolated: runs inside the detached task in `readLocalAsync`.
    nonisolated func readLocal(url: URL) throws -> String {
        // Security-scoped resource (required for fileImporter URLs).
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            return try decode(data: data)
        } catch let e as M3UServiceError {
            throw e
        } catch {
            throw M3UServiceError.fileReadError(error)
        }
    }

    /// Off-main variant: `Data(contentsOf:)` + decode can take seconds for tens-of-MB
    /// playlists (or iCloud files that download on first read) and would freeze the UI.
    /// The security-scope bracket is per-process, so it is safe inside the detached task.
    func readLocalAsync(url: URL) async throws -> String {
        let service = self
        return try await Task.detached(priority: .userInitiated) {
            try service.readLocal(url: url)
        }.value
    }

    // MARK: - Decoding

    nonisolated private func decode(data: Data) throws -> String {
        // BOM first: UTF-16 files decode "successfully" from isoLatin1 but full of NULs
        // and #EXTM3U would never match. Because isoLatin1 succeeds for EVERY byte sequence,
        // it must come last (last resort, with mojibake risk).
        if data.count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.index(after: data.startIndex)]
            if b0 == 0xFF, b1 == 0xFE, let s = String(data: data, encoding: .utf16LittleEndian) {
                return String(s.drop(while: { $0 == "\u{FEFF}" }))
            }
            if b0 == 0xFE, b1 == 0xFF, let s = String(data: data, encoding: .utf16BigEndian) {
                return String(s.drop(while: { $0 == "\u{FEFF}" }))
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        // Turkish lists usually arrive as Windows-1254; try it before Latin1.
        if let s = String(data: data, encoding: .windowsCP1254) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw M3UServiceError.encodingUnsupported
    }
}
