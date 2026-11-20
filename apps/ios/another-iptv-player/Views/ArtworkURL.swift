import Foundation

/// Build 81 (items 5a/5b): provider artwork URL handling.
///
/// Panels hand back artwork strings in rough shape — surrounding
/// whitespace, literal spaces or other unencoded characters in the
/// path (titles with spaces are common in Xtream poster paths).
/// `URL(string:)` returns nil for those, so every surface that
/// built its URL with the strict parser rendered the placeholder
/// for an image the provider DID supply. This helper is the one
/// lenient front door: trim, try strict, then retry once with the
/// illegal characters percent-encoded.
enum ArtworkURL {
    static func url(from raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed) { return url }
        // Second chance: encode the characters URL(string:) rejects
        // (spaces and friends) while leaving the URL's structural
        // characters — scheme, host, path slashes, query — intact.
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: " ")
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed),
           let url = URL(string: encoded) {
            return url
        }
        return nil
    }
}

/// Build 81 (item 5b): a session-scoped memo of artwork URLs that
/// have already failed to load.
///
/// The Nuke pipeline deliberately keeps NO negative cache (see
/// IPTVRemoteImagePipeline in CachedImage.swift), so a dead poster
/// URL re-issued a fresh request — up to the loader's 5 s timeout —
/// every single time its cell scrolled back on screen, competing
/// for the loader's 10 connections-per-host with the posters that
/// could actually load. That retry storm is a provable part of
/// "posters are hard to open". CachedImage now consults this memo
/// before issuing a request: a URL that failed within the TTL
/// renders its (designed) placeholder immediately instead of
/// re-hammering the CDN. After the TTL the URL is retried once
/// more, so a transient failure is never a life sentence; a
/// success anywhere clears the entry.
final class ArtworkFailureMemo {
    static let shared = ArtworkFailureMemo()

    private var failures: [String: Date] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval = 15 * 60

    func isFailed(_ url: URL) -> Bool {
        let key = url.absoluteString
        lock.lock()
        defer { lock.unlock() }
        guard let failedAt = failures[key] else { return false }
        if Date().timeIntervalSince(failedAt) > ttl {
            failures.removeValue(forKey: key)
            return false
        }
        return true
    }

    func recordFailure(_ url: URL) {
        lock.lock()
        failures[url.absoluteString] = Date()
        lock.unlock()
    }

    func recordSuccess(_ url: URL) {
        lock.lock()
        failures.removeValue(forKey: url.absoluteString)
        lock.unlock()
    }
}
