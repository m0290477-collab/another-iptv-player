import Foundation

/// Build 61 (B9) — Q2 per-channel/per-series track memory and
/// Q3 per-content delay persistence.
///
/// The GLOBAL `PlaybackTrackPreferences` (protected file, round-20
/// build-33 behaviour) remember ONE audio/subtitle/video choice
/// for the whole app. This store adds the per-content layer the
/// gap audit asked for: choices made while watching a specific
/// channel or series are remembered FOR THAT CONTENT — keyed by
/// the same `<playlistId>_<type>_<streamId>` identity triple
/// `ImportedSubtitleStore` uses — and re-applied by
/// `VideoPlayerController` on the next play of the same content,
/// ahead of the global preference. For series, PlayerView passes
/// the SERIES' identity as the content key for every episode (the
/// same key imported subtitles already use), so one choice covers
/// the whole series.
///
/// Matching reuses the global store's exact rules
/// (`PlaybackTrackPreferences.langMatches` / `normalizeTitleToken`)
/// — language first, title-token fallback, synthetic "Track N"
/// titles never stored. Q3: the audio/subtitle delay sliders'
/// values are stored per content the same way; the controller
/// applies a stored per-content delay over the global one at load
/// and records changes made through its existing
/// `applyAudioDelaySeconds` / `applySubtitleDelaySeconds` paths.
enum PerContentTrackPreferences {
    private static let storageKey = "playback.perContentTrackPreferences.v1"
    private static let subtitleOffSentinel = "__off__"

    struct Entry: Codable, Equatable {
        var audioLang: String?
        var audioTitleFallback: String?
        var subtitleLang: String?
        var subtitleTitleFallback: String?
        var videoLang: String?
        var videoTitleFallback: String?
        var audioDelaySeconds: Double?
        var subtitleDelaySeconds: Double?
    }

    private struct Storage: Codable {
        var entries: [String: Entry] = [:]
    }

    // MARK: - Track choices (Q2)

    static func saveAudio(from option: TrackMenuOption, for contentKey: String) {
        update(contentKey) { entry in
            if let lang = option.normalizedLang, !lang.isEmpty {
                entry.audioLang = lang
                entry.audioTitleFallback = nil
            } else {
                entry.audioLang = nil
                entry.audioTitleFallback = option.isSyntheticTitle
                    ? nil : PlaybackTrackPreferences.normalizeTitleToken(option.title)
            }
        }
    }

    static func saveSubtitle(from option: TrackMenuOption, for contentKey: String) {
        update(contentKey) { entry in
            if option.id < 0 {
                entry.subtitleLang = subtitleOffSentinel
                entry.subtitleTitleFallback = nil
            } else if let lang = option.normalizedLang, !lang.isEmpty {
                entry.subtitleLang = lang
                entry.subtitleTitleFallback = nil
            } else {
                entry.subtitleLang = nil
                entry.subtitleTitleFallback = option.isSyntheticTitle
                    ? nil : PlaybackTrackPreferences.normalizeTitleToken(option.title)
            }
        }
    }

    static func saveVideo(from option: TrackMenuOption, for contentKey: String) {
        update(contentKey) { entry in
            if let lang = option.normalizedLang, !lang.isEmpty {
                entry.videoLang = lang
                entry.videoTitleFallback = nil
            } else {
                entry.videoLang = nil
                entry.videoTitleFallback = option.isSyntheticTitle
                    ? nil : PlaybackTrackPreferences.normalizeTitleToken(option.title)
            }
        }
    }

    /// The remembered audio pick for this content, or nil to fall
    /// through to the global preference / engine default.
    static func pickAudio(from tracks: [TrackMenuOption], for contentKey: String) -> Int? {
        guard let entry = load().entries[contentKey] else { return nil }
        return pick(from: tracks, lang: entry.audioLang, fallback: entry.audioTitleFallback)
    }

    static func pickVideo(from tracks: [TrackMenuOption], for contentKey: String) -> Int? {
        guard let entry = load().entries[contentKey] else { return nil }
        return pick(from: tracks, lang: entry.videoLang, fallback: entry.videoTitleFallback)
    }

    /// Returns -1 for a remembered "subtitles off" for this content.
    static func pickSubtitle(from tracks: [TrackMenuOption], for contentKey: String) -> Int? {
        guard let entry = load().entries[contentKey] else { return nil }
        if entry.subtitleLang == subtitleOffSentinel { return -1 }
        let realTracks = tracks.filter { $0.id >= 0 }
        guard !realTracks.isEmpty else { return nil }
        return pick(from: realTracks, lang: entry.subtitleLang, fallback: entry.subtitleTitleFallback)
    }

    static func hasEntry(for contentKey: String) -> Bool {
        load().entries[contentKey] != nil
    }

    // MARK: - Delays (Q3)

    static func saveAudioDelay(_ seconds: Double, for contentKey: String) {
        update(contentKey) { $0.audioDelaySeconds = seconds }
    }

    static func saveSubtitleDelay(_ seconds: Double, for contentKey: String) {
        update(contentKey) { $0.subtitleDelaySeconds = seconds }
    }

    static func audioDelay(for contentKey: String) -> Double? {
        load().entries[contentKey]?.audioDelaySeconds
    }

    static func subtitleDelay(for contentKey: String) -> Double? {
        load().entries[contentKey]?.subtitleDelaySeconds
    }

    // MARK: - Storage

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private static func pick(from tracks: [TrackMenuOption], lang: String?, fallback: String?) -> Int? {
        guard !tracks.isEmpty else { return nil }
        if let lang, !lang.isEmpty,
           let match = tracks.first(where: {
               PlaybackTrackPreferences.langMatches(stored: lang, trackLang: $0.normalizedLang)
           }) {
            return match.id
        }
        if let fallback, !fallback.isEmpty,
           let match = tracks.first(where: {
               PlaybackTrackPreferences.normalizeTitleToken($0.title) == fallback
           }) {
            return match.id
        }
        return nil
    }

    private static func update(_ contentKey: String, _ mutate: (inout Entry) -> Void) {
        var storage = load()
        var entry = storage.entries[contentKey] ?? Entry()
        mutate(&entry)
        storage.entries[contentKey] = entry
        if let data = try? JSONEncoder().encode(storage) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private static func load() -> Storage {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else { return Storage() }
        return decoded
    }
}
