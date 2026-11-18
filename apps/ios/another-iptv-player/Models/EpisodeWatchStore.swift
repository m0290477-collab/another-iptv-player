import Foundation
import Combine

/// Build 61 (B8, C5): watched-episode tracking.
///
/// The AUTO mark derives from the existing watch-history writes: an
/// episode whose history row is at ≥90% of its duration counts as
/// watched (the spec's C5 threshold; it deliberately differs from the
/// ≥98% "finished/resume" threshold used by the player shells — an
/// episode can be *watched* for progress purposes while its last
/// seconds remain resumable). No history rows are created or modified
/// by this store.
///
/// The MANUAL toggle on episode rows writes an explicit override per
/// episode (keyed by playlist + the episode's history identity, i.e.
/// `episodeId ?? id` — the same identity `WatchHistoryRequest` uses):
/// "watched" forces watched, "unwatched" forces not-watched even when
/// history says ≥90%. Toggling back to the state history already
/// implies clears the override.
@MainActor
final class EpisodeWatchStore: ObservableObject {
    static let shared = EpisodeWatchStore()

    @Published private(set) var version: Int = 0

    private init() {}

    /// The C5 auto-watched threshold.
    static let autoWatchedThreshold = 0.90

    nonisolated private static func watchedKey(playlistId: UUID) -> String {
        "episodes.manually_watched.\(playlistId.uuidString)"
    }

    nonisolated private static func unwatchedKey(playlistId: UUID) -> String {
        "episodes.manually_unwatched.\(playlistId.uuidString)"
    }

    private func stringSet(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    /// The manual verdict for one episode: true = forced watched,
    /// false = forced unwatched, nil = no override (history decides).
    func manualVerdict(playlistId: UUID, episodeKey: String) -> Bool? {
        Self.manualVerdict(playlistId: playlistId, episodeKey: episodeKey)
    }

    /// Non-isolated read (UserDefaults only) so catalog computations
    /// running inside GRDB read closures can consult overrides.
    nonisolated static func manualVerdict(playlistId: UUID, episodeKey: String) -> Bool? {
        let watched = Set(UserDefaults.standard.stringArray(forKey: watchedKey(playlistId: playlistId)) ?? [])
        if watched.contains(episodeKey) { return true }
        let unwatched = Set(UserDefaults.standard.stringArray(forKey: unwatchedKey(playlistId: playlistId)) ?? [])
        if unwatched.contains(episodeKey) { return false }
        return nil
    }

    /// Applies a manual toggle. `historyWatched` is the state the
    /// history row currently implies; when the requested state equals
    /// it, the override is cleared instead of stored.
    func setWatched(_ watched: Bool, playlistId: UUID, episodeKey: String, historyWatched: Bool) {
        var watchedSet = stringSet(Self.watchedKey(playlistId: playlistId))
        var unwatchedSet = stringSet(Self.unwatchedKey(playlistId: playlistId))
        watchedSet.remove(episodeKey)
        unwatchedSet.remove(episodeKey)
        if watched != historyWatched {
            if watched { watchedSet.insert(episodeKey) } else { unwatchedSet.insert(episodeKey) }
        }
        UserDefaults.standard.set(Array(watchedSet), forKey: Self.watchedKey(playlistId: playlistId))
        UserDefaults.standard.set(Array(unwatchedSet), forKey: Self.unwatchedKey(playlistId: playlistId))
        version &+= 1
    }

    func removeAll(playlistId: UUID) {
        UserDefaults.standard.removeObject(forKey: Self.watchedKey(playlistId: playlistId))
        UserDefaults.standard.removeObject(forKey: Self.unwatchedKey(playlistId: playlistId))
        version &+= 1
    }
}

/// Pure C5 watched computation, callable off the main actor (series
/// progress is computed inside detached catalog tasks).
nonisolated enum EpisodeWatched {
    /// Auto verdict from a history row's position/duration.
    static func historyWatched(lastTimeMs: Int, durationMs: Int) -> Bool {
        guard durationMs > 0 else { return false }
        return Double(lastTimeMs) / Double(durationMs) >= EpisodeWatchStore.autoWatchedThreshold
    }

    /// Final verdict: manual override wins, history decides otherwise.
    static func isWatched(manual: Bool?, lastTimeMs: Int, durationMs: Int) -> Bool {
        if let manual { return manual }
        return historyWatched(lastTimeMs: lastTimeMs, durationMs: durationMs)
    }

    /// Per-series progress fraction in [0, 1]; nil when the series has
    /// no episodes at all (progress is then honestly unknown, and the
    /// UI shows nothing rather than 0%).
    static func progress(watched: Int, total: Int) -> Double? {
        guard total > 0 else { return nil }
        return Double(watched) / Double(total)
    }
}
