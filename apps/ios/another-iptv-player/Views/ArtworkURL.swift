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
/// for the loader's connections-per-host with the posters that
/// could actually load. That retry storm is a provable part of
/// "posters are hard to open". CachedImage now consults this memo
/// before issuing a request: a URL inside its block window renders
/// its (designed) placeholder immediately instead of re-hammering
/// the CDN; after the window the URL is retried, so a transient
/// failure is never a life sentence; a success anywhere clears
/// the entry.
///
/// Build 89 (item 7): the flat 15-minute TTL was itself a root
/// cause of "posters never appear". On a cold Movies open,
/// hundreds of requests to the one panel host queued behind
/// Nuke's serial task queues and blew the 5 s request timeout;
/// every timed-out poster — including mainstream titles whose
/// URLs were perfectly valid — was then memoised for a flat
/// 15 minutes, which is the whole testing session: the tab
/// showed title cards with no retry. The memo is now a bounded
/// backoff ladder keyed on CONSECUTIVE failures: the first
/// failure blocks a URL for only 30 s (a transient storm clears
/// and the poster retries on the next appearance), the second
/// for 90 s, and only a URL that keeps failing earns the long
/// 5-minute block that keeps genuinely dead URLs from hammering
/// the host. Cancellations never reach this memo at all —
/// CachedImage filters them out before recording (a cell that
/// scrolled off is not a failed URL).
final class ArtworkFailureMemo {
    static let shared = ArtworkFailureMemo()

    private struct Entry {
        var consecutiveFailures: Int
        var lastFailureAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    /// Hard bound on memo size (performance guard): the whole
    /// catalog is ~37k items, and the memo must never grow
    /// without limit inside a long session.
    private let maxEntries = 4096

    /// The block window for a URL that has failed `count` times
    /// in a row. Short for the transient case, long only for
    /// URLs that demonstrably keep failing.
    private func blockDuration(consecutiveFailures count: Int) -> TimeInterval {
        if count <= 1 { return 30 }
        if count == 2 { return 90 }
        return 300
    }

    private func isBlocked(_ entry: Entry, now: Date) -> Bool {
        now.timeIntervalSince(entry.lastFailureAt) <= blockDuration(consecutiveFailures: entry.consecutiveFailures)
    }

    func isFailed(_ url: URL) -> Bool {
        let key = url.absoluteString
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return false }
        if !isBlocked(entry, now: Date()) {
            entries.removeValue(forKey: key)
            return false
        }
        return true
    }

    func recordFailure(_ url: URL) {
        let key = url.absoluteString
        let now = Date()
        lock.lock()
        if entries[key] == nil, entries.count >= maxEntries {
            // Bound the map: drop every entry whose block has
            // already expired; if it is still full of live
            // entries, reset — the memo is only a retry
            // throttle, so the worst case of a reset is a dead
            // URL being retried once early.
            entries = entries.filter { isBlocked($0.value, now: now) }
            if entries.count >= maxEntries { entries.removeAll() }
        }
        var entry = entries[key] ?? Entry(consecutiveFailures: 0, lastFailureAt: now)
        entry.consecutiveFailures += 1
        entry.lastFailureAt = now
        entries[key] = entry
        lock.unlock()
    }

    func recordSuccess(_ url: URL) {
        lock.lock()
        entries.removeValue(forKey: url.absoluteString)
        lock.unlock()
    }
}
