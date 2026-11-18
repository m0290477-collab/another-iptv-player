import Foundation
import GRDB

/// Fetches all Xtream content (categories, live, VOD, series) and writes it to the
/// database together with the playlist. Shared by the Xtream add/edit flow and the
/// M3U flow's Xtream auto-detection.
enum XtreamImporter {

    /// Full sync: downloads everything from the panel, then saves playlist + content.
    /// The playlist row is saved before content so it stays visible even if a later
    /// step fails. `progress` receives localized status messages on the main actor.
    static func syncAndSave(
        playlist: Playlist,
        client: XtreamAPIClient,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        // Round 16 (R7): the sync progress prints are removed
        // (production logging on every sync); the timing locals
        // that only fed those prints went with them.

        // The six endpoints are independent — waiting sequentially made the total time the SUM
        // of six round trips; fetching in parallel cuts the time by more than half on slow panels.
        progress(L("add_playlist.fetching_categories"))
        async let liveCatsTask = client.getLiveCategories()
        async let vodCatsTask = client.getVODCategories()
        async let seriesCatsTask = client.getSeriesCategories()
        async let liveStreamsTask = client.getLiveStreams()
        async let vodsTask = client.getVODStreams()
        async let seriesTask = client.getSeries()
        let (liveCats, vodCats, seriesCats, liveStreams, vods, series) = try await (
            liveCatsTask, vodCatsTask, seriesCatsTask, liveStreamsTask, vodsTask, seriesTask
        )
        // 1. Save the playlist first so it shows up in the list even if content insertion fails.
        try await AppDatabase.shared.write { db in
            try playlist.save(db)
        }
        // N1 (B13): mirror the credentials into the synchronizable
        // keychain at the store layer — every Xtream add/edit path
        // funnels through this gateway.
        CredentialStore.mirror(playlist)

        progress(L("add_playlist.saving_db"))

        // Adult content filter
        let filterAdult = playlist.filterAdultContent
        let adultLiveCatIds   = filterAdult ? AdultContentFilter.adultCategoryIds(from: liveCats)   : []
        let adultVodCatIds    = filterAdult ? AdultContentFilter.adultCategoryIds(from: vodCats)    : []
        let adultSeriesCatIds = filterAdult ? AdultContentFilter.adultCategoryIds(from: seriesCats) : []

        // 2. Save content (upsert avoids conflicts).
        try await AppDatabase.shared.write { db in
            // Categories
            for (index, cat) in liveCats.enumerated() {
                if filterAdult, let name = cat.categoryName, AdultContentFilter.isAdultCategoryName(name) { continue }
                let dbCat = DBCategory(id: cat.id, name: cat.categoryName ?? L("content.unnamed"), parentId: cat.parentId, type: "live", sortIndex: index, playlistId: playlist.id)
                try dbCat.save(db)
            }
            for (index, cat) in vodCats.enumerated() {
                if filterAdult, let name = cat.categoryName, AdultContentFilter.isAdultCategoryName(name) { continue }
                let dbCat = DBCategory(id: cat.id, name: cat.categoryName ?? L("content.unnamed"), parentId: cat.parentId, type: "vod", sortIndex: index, playlistId: playlist.id)
                try dbCat.save(db)
            }
            for (index, cat) in seriesCats.enumerated() {
                if filterAdult, let name = cat.categoryName, AdultContentFilter.isAdultCategoryName(name) { continue }
                let dbCat = DBCategory(id: cat.id, name: cat.categoryName ?? L("content.unnamed"), parentId: cat.parentId, type: "series", sortIndex: index, playlistId: playlist.id)
                try dbCat.save(db)
            }

            // Live Streams
            for (index, stream) in liveStreams.enumerated() {
                if filterAdult, AdultContentFilter.isAdultLiveStream(stream, adultCategoryIds: adultLiveCatIds) { continue }
                let dbStream = DBLiveStream(streamId: stream.id, name: stream.name ?? L("content.unnamed"), streamIcon: stream.streamIcon, epgChannelId: stream.epgChannelId, categoryId: stream.categoryId, sortIndex: index, playlistId: playlist.id, tvArchive: stream.tvArchive ?? 0, tvArchiveDuration: stream.tvArchiveDuration ?? 0, channelNumber: stream.num)
                try dbStream.save(db)
            }

            // VODs
            for (index, stream) in vods.enumerated() {
                if filterAdult, AdultContentFilter.isAdultVODStream(stream, adultCategoryIds: adultVodCatIds) { continue }
                var dbVOD = DBVODStream(streamId: stream.id, name: stream.name ?? L("content.unnamed"), streamIcon: stream.streamIcon, categoryId: stream.categoryId, rating: stream.rating, containerExtension: stream.containerExtension, sortIndex: index, playlistId: playlist.id)
                dbVOD.added = stream.added
                try dbVOD.save(db)
            }

            // Series
            for (index, s) in series.enumerated() {
                if filterAdult, let cid = s.categoryId, adultSeriesCatIds.contains(cid) { continue }
                var dbSeries = DBSeries(seriesId: s.id, name: s.name ?? L("content.unnamed"), cover: s.cover, plot: s.plot, genre: s.genre, rating: s.rating, categoryId: s.categoryId, sortIndex: index, playlistId: playlist.id)
                dbSeries.lastModified = s.lastModified
                try dbSeries.save(db)
            }
        }

    }
}
