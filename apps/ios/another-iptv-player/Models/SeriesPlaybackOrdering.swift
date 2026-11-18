import Foundation
import GRDB

/// Orders a series' episodes for prev/next navigation and first-episode
/// resolution.
///
/// Round 15 (C8) rules:
/// - Tiebreakers inside a season: episodeNum, then title, then id — the
///   panel's episode numbers collide often enough that number alone
///   left the chain order to fetch order.
/// - Season 0 ("Specials") sorts LAST in the chain, so the previous
///   neighbour of S1E1 is never a special (the S1E1 boundary is closed)
///   and first-episode/autoplay resolution — which takes the head of
///   this ordering — skips season 0 whenever a season ≥ 1 exists
///   (round 14, B8). Season 0 stays manually reachable: the episode
///   list plays a tapped episode directly, bypassing this ordering.
/// - When ONLY season 0 exists it is used as-is (nothing to skip to).
enum SeriesPlaybackOrdering {
    struct NavigationContext {
        var previous: DBEpisode?
        var next: DBEpisode?
        /// F-58: the NEXT episode's season/episode numbers, for the
        /// T-50 card's "Season N • Episode M" line. Computed centrally
        /// here so every player shell passes the same values; nil when
        /// there is no next episode.
        var nextSeasonNumber: Int? = nil
        var nextEpisodeNumber: Int? = nil

        static let empty = NavigationContext(previous: nil, next: nil)
    }

    /// Seasons in chain order: regular seasons ascending, season 0 last.
    static func orderedSeasons(_ seasons: [DBSeason]) -> [DBSeason] {
        seasons.sorted { a, b in
            let aKey = a.seasonNumber == 0 ? Int.max : a.seasonNumber
            let bKey = b.seasonNumber == 0 ? Int.max : b.seasonNumber
            if aKey != bKey { return aKey < bKey }
            return a.id < b.id
        }
    }

    /// Episodes of one season in chain order (C8 tiebreakers).
    static func orderedEpisodes(_ episodes: [DBEpisode]) -> [DBEpisode] {
        episodes.sorted { a, b in
            let aNum = a.episodeNum ?? Int.max
            let bNum = b.episodeNum ?? Int.max
            if aNum != bNum { return aNum < bNum }
            let aTitle = a.title ?? ""
            let bTitle = b.title ?? ""
            if aTitle != bTitle {
                return aTitle.localizedCaseInsensitiveCompare(bTitle) == .orderedAscending
            }
            return a.id < b.id
        }
    }

    static func orderedEpisodes(seriesId: Int, playlistId: UUID, db: Database) throws -> [DBEpisode] {
        let seasons = try DBSeason
            .filter(Column("seriesId") == seriesId && Column("playlistId") == playlistId)
            .fetchAll(db)
        var out: [DBEpisode] = []
        for s in orderedSeasons(seasons) {
            let eps = try DBEpisode
                .filter(Column("seasonId") == s.id)
                .fetchAll(db)
            out.append(contentsOf: orderedEpisodes(eps))
        }
        return out
    }

    /// The episode Play/autoplay should start from: the head of the
    /// chain ordering — the first episode of the first season ≥ 1 when
    /// one exists, season 0 only when it is all the series has.
    static func firstEpisode(seriesId: Int, playlistId: UUID, db: Database) throws -> DBEpisode? {
        try orderedEpisodes(seriesId: seriesId, playlistId: playlistId, db: db).first
    }

    static func index(playbackStreamId: String, in episodes: [DBEpisode]) -> Int? {
        episodes.firstIndex { ep in
            (ep.episodeId ?? ep.id) == playbackStreamId || ep.id == playbackStreamId
        }
    }

    static func neighbors(playbackStreamId: String, seriesId: Int, playlistId: UUID, db: Database) throws -> NavigationContext {
        let all = try orderedEpisodes(seriesId: seriesId, playlistId: playlistId, db: db)
        guard let i = index(playbackStreamId: playbackStreamId, in: all) else { return .empty }
        let prev = i > 0 ? all[i - 1] : nil
        let next = i < all.count - 1 ? all[i + 1] : nil
        // F-58: resolve the next episode's numbers from its own
        // records — the season number from its DBSeason row, and the
        // episode number from its stored `episodeNum`, falling back
        // to its 1-based position among its own season's episodes in
        // the ordered chain when the panel gave no number.
        var nextSeasonNumber: Int? = nil
        var nextEpisodeNumber: Int? = nil
        if let next {
            nextSeasonNumber = try DBSeason
                .filter(Column("id") == next.seasonId)
                .fetchOne(db)?.seasonNumber
            if let num = next.episodeNum {
                nextEpisodeNumber = num
            } else if let nextIndex = all.firstIndex(where: { $0.id == next.id }) {
                // The chain is ordered season by season, so the
                // position within the season is the distance from
                // that season's first episode in the chain.
                let firstOfSeason = all.indices.first(where: { all[$0].seasonId == next.seasonId }) ?? nextIndex
                nextEpisodeNumber = nextIndex - firstOfSeason + 1
            }
        }
        return NavigationContext(
            previous: prev, next: next,
            nextSeasonNumber: nextSeasonNumber, nextEpisodeNumber: nextEpisodeNumber
        )
    }

    /// `seriesIdHint`: the series identity coming from watch history or the UI (used if the episode row cannot be found).
    static func navigationContext(
        playlistId: UUID,
        playbackStreamId: String,
        seriesIdHint: String?,
        db: Database
    ) throws -> NavigationContext {
        var seriesIdInt: Int?
        if let ep = try DBEpisode
            .filter(Column("episodeId") == playbackStreamId || Column("id") == playbackStreamId)
            .fetchOne(db),
            let season = try DBSeason
                .filter(Column("id") == ep.seasonId && Column("playlistId") == playlistId)
                .fetchOne(db)
        {
            seriesIdInt = season.seriesId
        }
        if seriesIdInt == nil, let hint = seriesIdHint.flatMap({ Int($0) }) {
            seriesIdInt = hint
        }
        guard let sid = seriesIdInt else { return .empty }
        return try neighbors(playbackStreamId: playbackStreamId, seriesId: sid, playlistId: playlistId, db: db)
    }
}
