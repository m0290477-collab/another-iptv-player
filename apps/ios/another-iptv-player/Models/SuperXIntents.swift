import AppIntents
import Foundation
import GRDB

/// Round 15 (C3): Siri / App Intents — "Play [channel]" and
/// "Resume".
///
/// Mechanism: an intent cannot present the player itself (the
/// player lives in the dashboard's `PlayerOverlayController`), so
/// `perform()` records a pending request in UserDefaults under
/// `intents.pendingPlayback` and opens the app
/// (`openAppWhenRun`). `DashboardView` consumes the request on
/// appear / foreground (after the catalog load) and presents
/// playback through the existing overlay path.
///
/// Channel resolution: the entity query reads the ACTIVE
/// playlist's live catalog from the local DB (`liveStream` table —
/// the same rows `PlaylistContentStore` loads). Suggested entities
/// are the user's favorite channels plus their most recently
/// watched live channels — real local data only.
struct ChannelEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Channel"
    static var defaultQuery = ChannelEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ChannelEntityQuery: EntityQuery {
    func entities(for identifiers: [ChannelEntity.ID]) async throws -> [ChannelEntity] {
        let all = await Self.catalogChannels()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ChannelEntity] {
        await Self.suggestedChannels()
    }

    /// Every live channel of the active playlist, from the local
    /// catalog tables (read-only).
    static func catalogChannels() async -> [ChannelEntity] {
        guard let playlistId = await Self.activePlaylistId() else { return [] }
        let streams = (try? await AppDatabase.shared.read { db in
            try DBLiveStream
                .filter(Column("playlistId") == playlistId)
                .order(Column("sortIndex"))
                .fetchAll(db)
        }) ?? []
        return streams.map { ChannelEntity(id: String($0.streamId), name: $0.name) }
    }

    /// Favorites first, then most recently watched live channels —
    /// the channels a voice request plausibly means.
    static func suggestedChannels() async -> [ChannelEntity] {
        guard let playlistId = await Self.activePlaylistId() else { return [] }
        return (try? await AppDatabase.shared.read { db -> [ChannelEntity] in
            var result: [ChannelEntity] = []
            var seen = Set<String>()
            let favorites = try DBFavorite
                .filter(Column("playlistId") == playlistId && Column("type") == "live")
                .order(Column("createdAt").desc)
                .fetchAll(db)
            for favorite in favorites {
                guard let stream = try DBLiveStream
                    .filter(Column("streamId") == favorite.streamId && Column("playlistId") == playlistId)
                    .fetchOne(db) else { continue }
                let entity = ChannelEntity(id: String(stream.streamId), name: stream.name)
                if seen.insert(entity.id).inserted { result.append(entity) }
            }
            let history = try DBWatchHistory
                .filter(Column("playlistId") == playlistId && Column("type") == "live")
                .order(Column("lastWatchedAt").desc)
                .limit(10)
                .fetchAll(db)
            for item in history {
                guard let stream = try DBLiveStream
                    .filter(Column("streamId") == (Int(item.streamId) ?? -1) && Column("playlistId") == playlistId)
                    .fetchOne(db) else { continue }
                let entity = ChannelEntity(id: String(stream.streamId), name: stream.name)
                if seen.insert(entity.id).inserted { result.append(entity) }
            }
            return result
        }) ?? []
    }

    /// The playlist the dashboard last entered (ContentView's
    /// `lastPlaylistId`), falling back to the first saved playlist.
    @MainActor
    static func activePlaylistId() -> UUID? {
        if let raw = UserDefaults.standard.string(forKey: "lastPlaylistId"),
           let id = UUID(uuidString: raw) {
            return id
        }
        return PlaylistContentStore.shared.activePlaylistId
    }
}

enum PendingPlayback {
    static let defaultsKey = "intents.pendingPlayback"

    static func store(_ values: [String: String]) {
        UserDefaults.standard.set(values, forKey: defaultsKey)
    }

    /// Reads AND clears the pending request (consume-once).
    static func consume() -> [String: String]? {
        guard let values = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]
        else { return nil }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return values
    }
}

struct PlayChannelIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Channel"
    static var description = IntentDescription("Plays a live channel in Super X.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Channel")
    var channel: ChannelEntity

    func perform() async throws -> some IntentResult {
        var values = ["kind": "live", "streamId": channel.id, "name": channel.name]
        if let playlistId = await ChannelEntityQuery.activePlaylistId() {
            values["playlistId"] = playlistId.uuidString
        }
        PendingPlayback.store(values)
        return .result()
    }
}

struct ResumeWatchingIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume"
    static var description = IntentDescription("Resumes the most recent title in Super X.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Resolve the most recent watch-history item NOW (real
        // local data); the dashboard re-reads the full history row
        // when it consumes the request.
        var values = ["kind": "resume"]
        if let playlistId = await ChannelEntityQuery.activePlaylistId() {
            values["playlistId"] = playlistId.uuidString
            let latest = (try? await AppDatabase.shared.read { db in
                try DBWatchHistory
                    .filter(Column("playlistId") == playlistId)
                    .order(Column("lastWatchedAt").desc)
                    .fetchOne(db)
            }) ?? nil
            if let latest {
                values["historyId"] = latest.id
            }
        }
        PendingPlayback.store(values)
        return .result()
    }
}

struct SuperXShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayChannelIntent(),
            phrases: [
                "Play \(\.$channel) in \(.applicationName)",
                "Play \(\.$channel) on \(.applicationName)",
            ],
            shortTitle: "Play Channel",
            systemImageName: "play.tv")
        AppShortcut(
            intent: ResumeWatchingIntent(),
            phrases: [
                "Resume in \(.applicationName)",
                "Resume watching in \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.circle")
    }
}
