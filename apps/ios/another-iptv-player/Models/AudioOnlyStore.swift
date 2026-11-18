import Foundation
import Combine

/// Build 61 (B8, H1): audio-only mode for live channels.
///
/// State only — the actual video shutdown happens in the playback
/// layer through `KSPlayerEngine.setVideoDecodingSuspended(_:)`,
/// KSPlayer's built-in path that stops video decode while audio
/// keeps playing (the same call the engine documents for background
/// playback). This store records, per playlist + channel, whether
/// audio-only is explicitly on/off; channels without an explicit
/// choice follow the Settings default (`player.audioOnlyDefault`,
/// owned by the Playback settings section).
@MainActor
final class AudioOnlyStore: ObservableObject {
    static let shared = AudioOnlyStore()

    @Published private(set) var version: Int = 0

    /// The Settings Playback-group default (AppStorage key).
    static let defaultKey = "player.audioOnlyDefault"

    private init() {}

    private static func onKey(playlistId: UUID) -> String {
        "audioonly.on.\(playlistId.uuidString)"
    }

    private static func offKey(playlistId: UUID) -> String {
        "audioonly.off.\(playlistId.uuidString)"
    }

    private func intSet(_ key: String) -> Set<Int> {
        Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
    }

    var defaultEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.defaultKey)
    }

    /// Effective state for one channel: explicit choice wins, else
    /// the Settings default.
    func isEnabled(playlistId: UUID, streamId: Int) -> Bool {
        if intSet(Self.onKey(playlistId: playlistId)).contains(streamId) { return true }
        if intSet(Self.offKey(playlistId: playlistId)).contains(streamId) { return false }
        return defaultEnabled
    }

    func setEnabled(_ enabled: Bool, playlistId: UUID, streamId: Int) {
        var on = intSet(Self.onKey(playlistId: playlistId))
        var off = intSet(Self.offKey(playlistId: playlistId))
        on.remove(streamId)
        off.remove(streamId)
        // Store only choices that differ from the default — a choice
        // equal to the default needs no record and follows future
        // default changes.
        if enabled != defaultEnabled {
            if enabled { on.insert(streamId) } else { off.insert(streamId) }
        }
        UserDefaults.standard.set(Array(on), forKey: Self.onKey(playlistId: playlistId))
        UserDefaults.standard.set(Array(off), forKey: Self.offKey(playlistId: playlistId))
        version &+= 1
    }

    func toggle(playlistId: UUID, streamId: Int) {
        setEnabled(!isEnabled(playlistId: playlistId, streamId: streamId), playlistId: playlistId, streamId: streamId)
    }

    func removeAll(playlistId: UUID) {
        UserDefaults.standard.removeObject(forKey: Self.onKey(playlistId: playlistId))
        UserDefaults.standard.removeObject(forKey: Self.offKey(playlistId: playlistId))
        version &+= 1
    }
}
