import Foundation
import GRDB
import WidgetKit

/// Round 15 (C3): the widget data bridge.
///
/// The app writes ONE Codable snapshot as JSON into the App Group
/// container (`group.com.irqus.superx`); the SuperXWidgets
/// extension reads exactly that file. The snapshot is built ONLY
/// from real local data — watch history, favorites and the EPG
/// store's current now/next snapshot — never from placeholders.
/// When a section has no real data its array is simply empty and
/// the widget renders its honest "Open Super X" state.
///
/// The widget target carries its own copy of these structs
/// (`SuperXWidgets/WidgetSnapshot.swift`) — keep the two in sync.
struct WidgetSnapshot: Codable, Equatable {
    struct ContinueItem: Codable, Equatable {
        var title: String
        var subtitle: String?
        var progress: Double
    }
    struct FavoriteChannel: Codable, Equatable {
        var name: String
        var logoURL: String?
    }
    struct OnNowItem: Codable, Equatable {
        var channel: String
        var programme: String
    }

    var generatedAt: Date
    var continueWatching: [ContinueItem]
    var favoriteChannels: [FavoriteChannel]
    var onNow: [OnNowItem]

    static let empty = WidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        continueWatching: [], favoriteChannels: [], onNow: [])
}

enum WidgetSnapshotStore {
    static let appGroupId = "group.com.irqus.superx"
    static let fileName = "widget-snapshot.json"

    static func snapshotURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent(fileName)
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let url = snapshotURL(),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    static func load() -> WidgetSnapshot {
        guard let url = snapshotURL(),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    /// Rebuilds the snapshot from the active playlist's real local
    /// data, writes it to the App Group container and asks WidgetKit
    /// to reload timelines. Safe to call on dashboard appear and
    /// after a catalog load; all reads are read-only.
    @MainActor
    static func refresh(playlist: Playlist) async {
        let playlistId = playlist.id
        let isM3U = playlist.kind == .m3u

        struct RawData {
            var history: [DBWatchHistory] = []
            var favoriteChannels: [WidgetSnapshot.FavoriteChannel] = []
            var favoriteKeys: [(name: String, key: String?)] = []
        }

        let raw: RawData = (try? await AppDatabase.shared.read { db -> RawData in
            var data = RawData()
            data.history = try DBWatchHistory
                .filter(Column("playlistId") == playlistId)
                .order(Column("lastWatchedAt").desc)
                .limit(30)
                .fetchAll(db)
            if isM3U {
                let favorites = try DBM3UFavorite
                    .filter(Column("playlistId") == playlistId)
                    .order(Column("createdAt").desc)
                    .fetchAll(db)
                for favorite in favorites.prefix(8) {
                    guard let channel = try DBM3UChannel
                        .filter(Column("id") == favorite.channelId && Column("playlistId") == playlistId)
                        .fetchOne(db) else { continue }
                    data.favoriteChannels.append(.init(name: channel.name, logoURL: channel.tvgLogo))
                    data.favoriteKeys.append((channel.name, EPGChannelKey.forM3U(channel)))
                }
            } else {
                let favorites = try DBFavorite
                    .filter(Column("playlistId") == playlistId && Column("type") == "live")
                    .order(Column("createdAt").desc)
                    .fetchAll(db)
                for favorite in favorites.prefix(8) {
                    guard let stream = try DBLiveStream
                        .filter(Column("streamId") == favorite.streamId && Column("playlistId") == playlistId)
                        .fetchOne(db) else { continue }
                    data.favoriteChannels.append(.init(name: stream.name, logoURL: stream.streamIcon))
                    data.favoriteKeys.append((stream.name, EPGChannelKey.forXtream(stream)))
                }
            }
            return data
        }) ?? RawData()

        // Continue Watching: in-progress VOD/series history only
        // (live has no progress), one card per series (the latest
        // in-progress episode — the C8 rule the Home row follows).
        var continueWatching: [WidgetSnapshot.ContinueItem] = []
        var seenSeries = Set<String>()
        for item in raw.history where item.type != "live" {
            guard item.durationMs > 0 else { continue }
            let progress = Double(item.lastTimeMs) / Double(item.durationMs)
            guard progress > 0.02, progress < 0.98 else { continue }
            if item.type == "series" {
                let group = item.seriesId ?? item.streamId
                if seenSeries.contains(group) { continue }
                seenSeries.insert(group)
            }
            continueWatching.append(.init(
                title: item.title,
                subtitle: item.secondaryTitle,
                progress: min(max(progress, 0), 1)))
            if continueWatching.count == 5 { break }
        }

        // On Now: the EPG store's current snapshot, restricted to
        // the user's favorite channels — real programmes only.
        var onNow: [WidgetSnapshot.OnNowItem] = []
        if let epg = EPGStore.shared.snapshot {
            for favorite in raw.favoriteKeys {
                if let now = epg[favorite.key]?.now {
                    onNow.append(.init(channel: favorite.name, programme: now.title))
                }
                if onNow.count == 5 { break }
            }
        }

        write(WidgetSnapshot(
            generatedAt: Date(),
            continueWatching: continueWatching,
            favoriteChannels: raw.favoriteChannels,
            onNow: onNow))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
