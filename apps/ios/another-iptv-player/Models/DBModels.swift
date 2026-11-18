import Foundation
import GRDB

struct DBCategory: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Hashable {
    var id: String
    var name: String
    var parentId: Int?
    var type: String // "live", "vod", "series"
    var sortIndex: Int = 0
    var playlistId: UUID
    
    static let databaseTableName = "category"
}

struct DBLiveStream: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Hashable {
    var streamId: Int
    var name: String
    var streamIcon: String?
    var epgChannelId: String?
    var categoryId: String?
    var sortIndex: Int = 0
    var playlistId: UUID
    /// Catch-up: 1 when the channel has a timeshift archive. Duration in days.
    /// Defaulted so existing labeled-arg construction sites keep compiling; the
    /// real values are populated on the next live catalog refresh.
    var tvArchive: Int = 0
    var tvArchiveDuration: Int = 0
    /// Build 61 (B8, H5): the provider's own channel number (Xtream
    /// `num` in get_live_streams). Nil when the provider supplies
    /// none — nothing is shown and nothing is faked.
    var channelNumber: Int? = nil

    var id: String { "\(streamId)_\(playlistId)" }

    static let databaseTableName = "liveStream"
}

struct DBVODStream: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Hashable {
    var streamId: Int
    var name: String
    var streamIcon: String?
    var categoryId: String?
    var rating: String?
    var containerExtension: String?
    
    // Metadata fields
    var director: String? = nil
    var cast: String? = nil
    var plot: String? = nil
    var genre: String? = nil
    var releaseDate: String? = nil
    var rating5Based: Double? = nil
    var backdropPath: String? = nil
    var youtubeTrailer: String? = nil
    var duration: String? = nil
    var tmdbId: String? = nil
    var kinopoiskURL: String? = nil
    var metadataLoaded: Bool = false
    /// The Xtream `get_vod_streams` `added` field — a unix timestamp string. Used for the recently-added ordering.
    var added: String? = nil

    var sortIndex: Int = 0
    var playlistId: UUID
    /// Build 61 (B8, metadata completion): the provider's own country
    /// from get_vod_info, when it returns one. The list endpoints
    /// carry no country, so this stays nil until a detail fetch
    /// supplies it — honestly empty, never invented.
    var country: String? = nil

    var id: String { "\(streamId)_\(playlistId)" }

    static let databaseTableName = "vodStream"
}

struct DBSeries: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Hashable {
    var seriesId: Int
    var name: String
    var cover: String?
    var plot: String? = nil
    var cast: String? = nil
    var director: String? = nil
    var genre: String? = nil
    var releaseDate: String? = nil
    var rating: String? = nil
    var lastModified: String? = nil
    var rating5Based: Double? = nil
    var backdropPath: String? = nil
    var youtubeTrailer: String? = nil
    var episodeRunTime: String? = nil
    var categoryId: String?
    var sortIndex: Int = 0
    var seasonsLoaded: Bool = false
    var playlistId: UUID
    
    var id: String { "\(seriesId)_\(playlistId)" }
    
    static let databaseTableName = "series"
}

struct DBSeason: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Hashable {
    var id: String
    var seasonNumber: Int
    var name: String?
    var overview: String?
    var cover: String?
    var airDate: String?
    var episodeCount: Int?
    var voteAverage: Double?
    var seriesId: Int
    var playlistId: UUID

    static let databaseTableName = "season"

    /// Playlist-scoped season PK. Panel `seriesId`s collide across panels;
    /// the bare "\(seriesId)_\(seasonNum)" key used to REPLACE two playlists' seasons into the same
    /// row, breaking prev/next episode navigation.
    static func scopedId(playlistId: UUID, seriesId: Int, seasonNumber: Int) -> String {
        "\(playlistId.uuidString)_\(seriesId)_\(seasonNumber)"
    }
}

struct DBEpisode: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Hashable {
    var id: String // "\(seriesId)_\(seasonNumber)_\(episodeNum)"
    var episodeId: String?
    var episodeNum: Int?
    var title: String?
    var containerExtension: String?
    /// Bölüm özeti (plot)
    var info: String?
    var cover: String?
    var duration: String?
    var rating: String?
    var seasonId: String

    static let databaseTableName = "episode"

    /// Playlist-scoped episode PK. `episodeId` (the panel's raw id) is kept EXACTLY for watch-history and
    /// download matching; only the row identity is scoped.
    static func scopedId(playlistId: UUID, panelEpisodeId: String?) -> String {
        "\(playlistId.uuidString)_\(panelEpisodeId ?? UUID().uuidString)"
    }
}

struct DBM3UFavorite: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    var channelId: String
    var playlistId: UUID
    var createdAt: Date = Date()

    static let databaseTableName = "m3uFavorite"
}

struct DBM3UChannel: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Hashable, Sendable {
    var id: String
    var playlistId: UUID
    var name: String
    var url: String
    var tvgId: String?
    var tvgName: String?
    var tvgLogo: String?
    var tvgCountry: String?
    var groupTitle: String?
    var userAgent: String?
    var sortIndex: Int = 0
    /// M3U catch-up attributes — parsed and persisted now for schema stability;
    /// M3U catch-up playback is deferred (Xtream catch-up ships first).
    var catchup: String?
    var catchupSource: String?
    var catchupDays: Int?
    /// Build 61 (B8, H5): the M3U `tvg-chno` attribute, when the
    /// playlist carries one. Nil = no number shown, nothing faked.
    var tvgChno: String? = nil

    static let databaseTableName = "m3uChannel"
}

struct DBFavorite: Codable, FetchableRecord, PersistableRecord, Equatable {
    var streamId: Int
    var playlistId: UUID
    var type: String // "live", "vod", "series"
    var createdAt: Date = Date()
    
    static let databaseTableName = "favorite"
}

// MARK: - Join Results
struct LiveStreamWithCategory: FetchableRecord, Decodable, Identifiable, Equatable {
    var stream: DBLiveStream
    var categoryName: String
    var id: String { stream.id }
}

struct VODWithCategory: FetchableRecord, Decodable, Identifiable, Equatable {
    var stream: DBVODStream
    var categoryName: String
    var id: String { stream.id }
}

struct SeriesWithCategory: FetchableRecord, Decodable, Identifiable, Equatable {
    var series: DBSeries
    var categoryName: String
    var id: String { series.id }
}

// MARK: - Download Model
enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case completed
    case failed
}

struct DBDownloadedItem: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Hashable {
    var id: String // "<type>.<playlistId>.<streamId>"
    var playlistId: UUID
    var streamId: String
    var type: String // "vod" or "episode"
    var title: String
    var secondaryTitle: String?
    var imageURL: String?
    var remoteURL: String
    /// A relative path under Application Support/Downloads — does not break if the device sandbox path changes.
    var localPath: String
    var containerExtension: String?
    var totalBytes: Int = 0
    var downloadedBytes: Int = 0
    var status: String // DownloadStatus rawValue
    var errorMessage: String?
    var createdAt: Date = Date()
    var completedAt: Date?
    var seriesId: String?
    var seasonNumber: Int?
    var episodeNumber: Int?

    static let databaseTableName = "downloadedItem"

    var downloadStatus: DownloadStatus {
        DownloadStatus(rawValue: status) ?? .failed
    }
}

// MARK: - Watch History Model
struct DBWatchHistory: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable, Hashable {
    var id: String // "\(playlistId)_\(type)_\(streamId)" (or episodeId for series)
    var playlistId: UUID
    var streamId: String // For Movies/Live, seriesId or episodeId for Series
    var type: String // "live", "vod", "series"
    var lastTimeMs: Int // Saved position
    var durationMs: Int // Total duration
    var lastWatchedAt: Date
    var seriesId: String? // Optional grouping for series
    
    // Metadata for quick listing without joins
    var title: String
    var secondaryTitle: String? // e.g., Series Name for episodes or Category for movies
    var imageURL: String?
    var containerExtension: String?
    
    static let databaseTableName = "watchHistory"
}
