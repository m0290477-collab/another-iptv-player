import SwiftUI
import Foundation
import Combine
import GRDB
import GRDBQuery

struct MovieDetailView: View {
    let playlist: Playlist
    var movie: DBVODStream
    /// The queue for the previous/next movie in the player. If empty, it opens as a single movie.
    var queue: [DBVODStream] = []

    @Environment(\.posterMetrics) private var posterMetrics
    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @ObservedObject private var watchlistStore = WatchlistStore.shared
    @State private var isLoading = false
    /// Round 14 (B7): a metadata fetch failure no longer replaces the
    /// page with an error screen — the detail renders fully from the
    /// local record and the failure only arms a quiet retry row.
    @State private var metadataFetchFailed = false
    /// Round 15 (C7) related-title computations (More Like This
    /// scoring, franchise group, duplicate editions) run once per
    /// movie in a task, never per body pass.
    @State private var moreLikeThisItems: [DBVODStream] = []
    @State private var franchiseItems: [DBVODStream] = []
    @State private var editions: [DBVODStream] = []
    /// C7: pre-download size from the server's Content-Length, when
    /// it provides one (nil = unknown = row hidden, never estimated).
    @State private var downloadSizeText: String?
    /// One navigation route for genre + people browsing — a single
    /// `navigationDestination(item:)` per type is all SwiftUI allows.
    @State private var pendingRoute: MovieDetailRoute?
    @State private var enlargedImage: IdentifiableURL?
    @State private var showNavTitle: Bool = false
    @State private var pendingMovieDetail: DBVODStream?
    // Build 61 (B8, from B3's flags): parental-lock guard for the
    // VOD detail-open path — mirrors LiveStreamsView's live guard.
    @State private var parentalBlocked = false
    @State private var showParentalPIN = false
    /// Build 63 (item 6): a Play tap that cannot build a stream
    /// URL must SAY so — build 62 returned silently here.
    @State private var showPlayFailure = false
    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @Query<VODByIDRequest> private var movieRecord: DBVODStream?
    @Query<IsFavoriteRequest> private var isFavorite: Bool
    @Query<WatchHistoryRequest> private var watchHistory: DBWatchHistory?

    init(playlist: Playlist, movie: DBVODStream, queue: [DBVODStream] = []) {
        self.playlist = playlist
        self.movie = movie
        self.queue = queue
        _movieRecord = Query(VODByIDRequest(streamId: movie.streamId, playlistId: playlist.id), in: \.appDatabase)
        _isFavorite = Query(IsFavoriteRequest(streamId: movie.streamId, playlistId: playlist.id, type: "vod"), in: \.appDatabase)
        _watchHistory = Query(WatchHistoryRequest(streamId: String(movie.streamId), playlistId: playlist.id, type: "vod"), in: \.appDatabase)
    }

    private var currentMovie: DBVODStream {
        movieRecord ?? movie
    }

    private var resumeMs: Int? {
        guard let h = watchHistory, h.lastTimeMs > 5000 else { return nil }
        // On a finished (≥98%) movie, "Continue" was teleporting to the last seconds; when it returns nil,
        // the primary action falls back to watching from the start (consistent with resumeProgress).
        if h.durationMs > 0, Double(h.lastTimeMs) / Double(h.durationMs) >= 0.98 { return nil }
        return h.lastTimeMs
    }

    private var resumeProgress: Double? {
        guard let h = watchHistory, h.durationMs > 0 else { return nil }
        let p = Double(h.lastTimeMs) / Double(h.durationMs)
        return (p > 0.02 && p < 0.98) ? p : nil
    }

    /// Round 15 (C7): the trailer tile appears ONLY when the stored
    /// value actually validates as a YouTube reference — a full
    /// youtube.com / youtu.be URL, or a bare 11-character video id.
    /// Panel junk ("N/A", other hosts, arbitrary text) yields no tile.
    private var trailerURL: URL? {
        guard let raw = currentMovie.youtubeTrailer?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if raw.lowercased().hasPrefix("http") {
            guard let url = URL(string: raw),
                  let host = url.host?.lowercased(),
                  host.contains("youtube.com") || host.contains("youtu.be") else { return nil }
            return url
        }
        let idCharset = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard raw.count == 11, raw.unicodeScalars.allSatisfy({ idCharset.contains($0) }) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(raw)")
    }

    private var heroConfig: DetailHeroConfig {
        DetailHeroConfig(
            title: currentMovie.name,
            backdropURL: currentMovie.backdropPath.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : URL(string: t) },
            posterURL: currentMovie.streamIcon.flatMap { URL(string: $0) },
            year: DetailFormatting.year(from: currentMovie.releaseDate),
            releaseDate: currentMovie.releaseDate,
            runtime: currentMovie.duration?.trimmingCharacters(in: .whitespaces),
            // Round 14 (B7): the hero reads the ONE normalization
            // point — the same value the poster badge and the Top
            // Movies ranking use.
            rating10: ContentRating.normalizedRating10(
                rating: currentMovie.rating,
                rating5Based: currentMovie.rating5Based
            ),
            ratingText: currentMovie.rating,
            posterIconName: "film",
            backdropIconName: "film"
        )
    }

    private var moreLikeThisSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader(title: L("detail.more_like_this"))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(moreLikeThisItems) { item in
                        Button {
                            pendingMovieDetail = item
                        } label: {
                            VODStreamCard(
                                playlistId: playlist.id,
                                stream: item,
                                posterWidth: posterMetrics.searchCardWidth,
                                posterHeight: posterMetrics.searchCardHeight,
                                imageLoadProfile: .shelf
                            )
                        }
                        // Build 81 (item 8): poster-card press feedback.
                        .buttonStyle(PressScaleButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
            .shelfEdgeFade()
        }
    }

    /// C7 franchise shelf: the other entries of this movie's
    /// collection (same normalized base title), in release order.
    private var franchiseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader(title: L("detail.collection"))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(franchiseItems) { item in
                        Button {
                            pendingMovieDetail = item
                        } label: {
                            VODStreamCard(
                                playlistId: playlist.id,
                                stream: item,
                                posterWidth: posterMetrics.searchCardWidth,
                                posterHeight: posterMetrics.searchCardHeight,
                                imageLoadProfile: .shelf
                            )
                        }
                        // Build 81 (item 8): poster-card press feedback.
                        .buttonStyle(PressScaleButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
            .shelfEdgeFade()
        }
    }

    /// C7 duplicate editions: the same normalized title + year exists
    /// more than once in the catalog (different categories / file
    /// types). Each row is labeled ONLY with real data — the edition's
    /// own category name and container extension.
    private var editionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailSectionHeader(title: L("detail.versions"))
                .padding(.horizontal, 16)

            VStack(spacing: 8) {
                ForEach(editions) { edition in
                    Button {
                        if edition.streamId != currentMovie.streamId {
                            pendingMovieDetail = edition
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: edition.streamId == currentMovie.streamId ? "checkmark.circle.fill" : "film")
                                .foregroundStyle(edition.streamId == currentMovie.streamId ? AppTheme.accent : .secondary)
                            Text(MovieCatalogNaming.categoryName(for: edition, in: contentStore) ?? "")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let ext = edition.containerExtension?.trimmingCharacters(in: .whitespaces), !ext.isEmpty {
                                Text(ext.uppercased())
                                    .font(AppTheme.fontBadge)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                                .fill(AppTheme.elevated)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    var body: some View {
        // Round 14 (B7): the page ALWAYS renders from the local
        // record — a slow or failed metadata fetch never blocks the
        // detail page or playback.
        contentScroll
        .navigationTitle(showNavTitle ? currentMovie.name : "")
        .navigationBarTitleDisplayMode(.inline)
        // Round 10 / build 78: the favorite action lives in the
        // glass action row under the Play button
        // (DetailGlassActionsRow) — the toolbar star is gone so
        // the action exists exactly once on this page.
        .fullScreenCover(item: $enlargedImage) { wrapper in
            FullscreenImageViewer(url: wrapper.url)
        }
        .navigationDestination(item: $pendingMovieDetail) { nextMovie in
            MovieDetailView(playlist: playlist, movie: nextMovie, queue: queue)
        }
        .navigationDestination(item: $pendingRoute) { route in
            switch route {
            case .genre(let genre):
                MovieGenreGridView(playlist: playlist, initialGenre: genre)
            case .person(let person):
                PersonTitlesView(playlist: playlist, person: person)
            }
        }
        .task {
            // Build 61 (B8): parental guard + NEW-badge clearing.
            if ParentalControlStore.shared.isBlocked(
                playlistId: playlist.id, type: "vod", categoryId: currentMovie.categoryId
            ) {
                parentalBlocked = true
                showParentalPIN = true
            }
            FirstSeenStore.shared.markOpened(playlistId: playlist.id, itemKey: "vod:\(currentMovie.streamId)")
            if !currentMovie.metadataLoaded {
                await fetchMovieInfo()
            }
        }
        .sheet(isPresented: $showParentalPIN) {
            PINEntrySheet(message: L("parental.locked.enter_pin")) {
                if let categoryId = currentMovie.categoryId {
                    ParentalControlStore.shared.unlockForSession(
                        playlistId: playlist.id, type: "vod", categoryId: categoryId
                    )
                }
                parentalBlocked = false
            }
        }
        // Build 63 (item 6): the play-failure alert (existing
        // playback error copy — no new strings).
        .alert(L("playback.error.failed_to_start"), isPresented: $showPlayFailure) {
            Button(L("common.ok")) { showPlayFailure = false }
        }
        .overlay {
            if parentalBlocked {
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(L("parental.locked.title"))
                        .font(.headline)
                    Button(L("parental.locked.enter_pin")) { showParentalPIN = true }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
            }
        }
        .task(id: currentMovie.streamId) { await computeRelated() }
        .task(id: currentMovie.streamId) { await fetchDownloadSize() }
        .cinematicBackground()
    }

    private var contentScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHero(config: heroConfig, heroHeight: 380) { url in
                    enlargedImage = IdentifiableURL(url: url)
                }

                // Round 14 (B1/B7): genre chips navigate to the
                // Movies tab's genre-filtered grid.
                GenreChipRow(genres: DetailFormatting.genreList(currentMovie.genre)) { genre in
                    pendingRoute = .genre(genre)
                }

                DetailActionBar(
                    primaryTitle: resumeMs != nil ? L("detail.resume") : L("detail.watch_now"),
                    primarySubtitle: resumeMs.map { DetailFormatting.formatMs($0) },
                    primaryIcon: resumeMs != nil ? "play.circle.fill" : "play.fill",
                    progress: resumeProgress,
                    onPrimary: { presentMoviePlayer(resume: true) },
                    restartTitle: resumeMs != nil ? L("detail.restart") : nil,
                    onRestart: resumeMs != nil ? { presentMoviePlayer(resume: false) } : nil,
                    // C7: the trailer renders as its own tile below
                    // (backdrop + play badge) — not the action bar's
                    // text link — so it exists exactly once here.
                    trailerURL: nil
                )

                // Build 78 (Style 1): favorite / download /
                // watchlist as the picked mockup's round glass
                // trio — the same three actions the square favorite
                // row, the download pill and the full-width
                // watchlist row performed (watchlist stays a state
                // SEPARATE from Favorites, with its own surface on
                // the Movies tab).
                DetailGlassActionsRow(
                    isFavorite: isFavorite,
                    onToggleFavorite: toggleFavorite,
                    isWatchlisted: watchlistStore.contains(playlistId: playlist.id, streamId: currentMovie.streamId),
                    onToggleWatchlist: {
                        // R6: the toggle carries a display snapshot
                        // so a later-vanished entry stays listed,
                        // marked unavailable (unchanged behavior).
                        watchlistStore.toggleMovie(
                            playlistId: playlist.id, streamId: currentMovie.streamId,
                            title: currentMovie.name, imageURL: currentMovie.streamIcon
                        )
                    }
                ) {
                    if let remoteURL = PlaybackURLBuilder(playlist: playlist).movieURL(
                        streamId: currentMovie.streamId,
                        containerExtension: currentMovie.containerExtension
                    ) {
                        DownloadButton(
                            id: DownloadManager.idFor(vod: playlist.id, streamId: currentMovie.streamId),
                            playlistId: playlist.id,
                            streamId: String(currentMovie.streamId),
                            type: "vod",
                            title: currentMovie.name,
                            secondaryTitle: currentMovie.genre,
                            imageURL: currentMovie.streamIcon,
                            remoteURL: remoteURL,
                            containerExtension: currentMovie.containerExtension,
                            glassCircle: true
                        )
                    } else {
                        EmptyView()
                    }
                }
                // The same tight spacing as the trailer row; neutralizing the VStack spacing 20 with -10
                // DetailActionBar içindeki 10pt ritme hizalar.
                .padding(.top, -10)

                // Build 61 (B8, J1): add to a custom favorite group.
                FavoriteGroupMenuItems(
                    playlist: playlist,
                    item: FavoriteGroupStore.Item(
                        type: "vod",
                        itemId: String(currentMovie.streamId),
                        title: currentMovie.name,
                        imageURL: currentMovie.streamIcon
                    )
                )
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, -6)

                if let downloadSizeText {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption)
                        Text(downloadSizeText)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, -12)
                }

                if metadataFetchFailed && !currentMovie.metadataLoaded {
                    // B7: non-blocking retry — a quiet row, never a
                    // page takeover.
                    Button {
                        Task { await fetchMovieInfo() }
                    } label: {
                        Label(L("common.try_again"), systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, -8)
                }

                // Build 78: the trailer card exists ONLY with a
                // validated trailer URL AND artwork to show — the
                // empty black box from the owner's recording is
                // gone by construction.
                if let trailerURL, trailerImageURL != nil {
                    trailerTile(url: trailerURL)
                }

                if let plot = currentMovie.plot?.trimmingCharacters(in: .whitespacesAndNewlines), !plot.isEmpty {
                    DetailPlotBlock(plot: plot)
                        .padding(.top, 4)
                }

                if let director = currentMovie.director?.trimmingCharacters(in: .whitespacesAndNewlines), !director.isEmpty {
                    // C7: director names are tappable — they browse
                    // that person's titles in this catalog.
                    DetailInfoTextBlock(label: L("movie.director"), value: director) { person in
                        pendingRoute = .person(person)
                    }
                }

                if let cast = currentMovie.cast?.trimmingCharacters(in: .whitespacesAndNewlines), !cast.isEmpty {
                    // Build 65 (Cinematic detail) / build 78
                    // (shared component): the cast renders as the
                    // mockup's round-avatar row. Provider data
                    // carries cast NAMES only — no headshot URLs
                    // exist — so each avatar is a monogram of the
                    // REAL name (never an invented photo). Tapping
                    // still browses that person's titles (the C7
                    // person route), and the full list scrolls —
                    // nothing is clipped away.
                    DetailCastRow(names: DetailFormatting.peopleList(cast)) { person in
                        pendingRoute = .person(person)
                    }
                    // Build 81 (item 8): cast row fades/rises in.
                    .sectionAppear()
                }

                // Build 61 (B8, metadata completion): the remaining
                // get_vod_info fields the provider returned — release
                // date and country — each shown ONLY when present.
                if let release = currentMovie.releaseDate?.trimmingCharacters(in: .whitespacesAndNewlines), !release.isEmpty {
                    DetailInfoTextBlock(label: L("meta.release_date"), value: release)
                }

                if let country = currentMovie.country?.trimmingCharacters(in: .whitespacesAndNewlines), !country.isEmpty {
                    DetailInfoTextBlock(label: L("meta.country"), value: country)
                }

                // B7: the container extension is real record data —
                // shown on the detail page.
                if let ext = currentMovie.containerExtension?.trimmingCharacters(in: .whitespaces), !ext.isEmpty {
                    DetailInfoTextBlock(label: L("movie.format"), value: ext.uppercased())
                }

                if editions.count > 1 {
                    editionsSection
                }

                if !franchiseItems.isEmpty {
                    franchiseSection
                }

                // Build 61 (B8, J2): More Like This renders only
                // with at least 3 same-genre matches.
                if moreLikeThisItems.count >= 3 {
                    moreLikeThisSection
                        // Build 81 (item 8): section entrance.
                        .sectionAppear()
                }
            }
            .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y > 240
        } action: { _, newValue in
            if showNavTitle != newValue {
                withAnimation(.easeInOut(duration: 0.18)) { showNavTitle = newValue }
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    /// Build 78: the trailer tile's artwork — the movie's real
    /// backdrop (poster fallback), the same chain the tile always
    /// used, hoisted into one place so the tile can require it:
    /// a trailer card with NO image at all was an empty black box
    /// on the owner's recording. No artwork, no card — exactly
    /// like no trailer, no card.
    private var trailerImageURL: URL? {
        currentMovie.backdropPath.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : URL(string: t) }
            ?? currentMovie.streamIcon.flatMap { URL(string: $0) }
    }

    /// C7 trailer tile (build 78 form): the movie's real backdrop
    /// (poster fallback) as a 16:9 card with the mockup's big glass
    /// play button; opens the validated YouTube URL externally.
    /// Rendered ONLY when a validated trailer URL and artwork both
    /// exist (see the call site).
    private func trailerTile(url: URL) -> some View {
        let tileWidth = UIScreen.main.bounds.width - 32
        let tileHeight = tileWidth * 9 / 16
        return Link(destination: url) {
            ZStack {
                CachedImage(
                    url: trailerImageURL,
                    width: tileWidth,
                    height: tileHeight,
                    cornerRadius: AppTheme.cornerRadius,
                    contentMode: .fill,
                    iconName: "film",
                    loadProfile: .standard
                )
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 56, height: 56)
                Image(systemName: "play.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                VStack {
                    Spacer()
                    HStack {
                        Text(L("detail.trailer"))
                            .font(AppTheme.fontBadge)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .frame(height: tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    /// C7 computations over the in-memory catalog, run once per
    /// movie off the main thread:
    /// - More Like This scoring: shared genres (3 pts each) + shared
    ///   cast/director (2 pts each) + year proximity (up to 2 pts,
    ///   decaying over a decade); ties break by normalized rating,
    ///   then recency. THE one More Like This implementation.
    /// - Franchise group: same normalized base title, ≥2 members.
    /// - Duplicate editions: same normalized title + release year.
    private func computeRelated() async {
        let snapshot = contentStore.vodStreams.map(\.stream)
        let source = currentMovie
        let result = await Task.detached(priority: .utility) {
            () -> (more: [DBVODStream], franchise: [DBVODStream], editions: [DBVODStream]) in
            let myGenres = Set(DetailFormatting.genreList(source.genre).map { $0.lowercased() })
            let myPeople = Set(
                (DetailFormatting.peopleList(source.cast) + DetailFormatting.peopleList(source.director))
                    .map { $0.lowercased() }
            )
            let myYear = DetailFormatting.releaseYear(from: source.releaseDate)
            let myCategory = source.categoryId

            var scored: [(movie: DBVODStream, score: Double, rating: Double, added: Int)] = []
            scored.reserveCapacity(64)
            for candidate in snapshot where candidate.streamId != source.streamId {
                var score = 0.0
                let genres = Set(DetailFormatting.genreList(candidate.genre).map { $0.lowercased() })
                score += 3.0 * Double(genres.intersection(myGenres).count)
                let people = Set(
                    (DetailFormatting.peopleList(candidate.cast) + DetailFormatting.peopleList(candidate.director))
                        .map { $0.lowercased() }
                )
                score += 2.0 * Double(people.intersection(myPeople).count)
                if let myYear, let year = DetailFormatting.releaseYear(from: candidate.releaseDate) {
                    let diff = abs(myYear - year)
                    if diff < 10 { score += 2.0 * (1.0 - Double(diff) / 10.0) }
                }
                // Same provider category stays a weak signal (the
                // round-10 relation), far below a real genre match.
                if let myCategory, candidate.categoryId == myCategory { score += 0.5 }
                guard score > 0 else { continue }
                scored.append((
                    movie: candidate,
                    score: score,
                    rating: ContentRating.normalizedRating10(rating: candidate.rating, rating5Based: candidate.rating5Based) ?? -1,
                    added: candidate.added.flatMap(Int.init) ?? Int.min
                ))
            }
            scored.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.rating != b.rating { return a.rating > b.rating }
                return a.added > b.added
            }
            let more = Array(scored.prefix(15).map(\.movie))

            let base = MovieCatalogNaming.franchiseBase(source.name)
            var franchise: [DBVODStream] = []
            if !base.isEmpty {
                franchise = snapshot
                    .filter { $0.streamId != source.streamId && MovieCatalogNaming.franchiseBase($0.name) == base }
                    .sorted { a, b in
                        let ya = DetailFormatting.releaseYear(from: a.releaseDate) ?? Int.max
                        let yb = DetailFormatting.releaseYear(from: b.releaseDate) ?? Int.max
                        if ya != yb { return ya < yb }
                        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    }
            }

            let nameKey = MovieCatalogNaming.normalizedTitle(source.name)
            var editions: [DBVODStream] = []
            if !nameKey.isEmpty {
                editions = snapshot
                    .filter {
                        MovieCatalogNaming.normalizedTitle($0.name) == nameKey
                            && DetailFormatting.releaseYear(from: $0.releaseDate) == myYear
                    }
                    .sorted { $0.streamId < $1.streamId }
            }
            return (more, franchise, editions)
        }.value
        guard !Task.isCancelled else { return }
        moreLikeThisItems = result.more
        franchiseItems = result.franchise
        editions = result.editions
    }

    /// C7: one HEAD request for the movie's remote file; the size is
    /// shown only when the server actually sends a Content-Length.
    private func fetchDownloadSize() async {
        downloadSizeText = nil
        guard let url = PlaybackURLBuilder(playlist: playlist).movieURL(
            streamId: currentMovie.streamId,
            containerExtension: currentMovie.containerExtension
        ) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.expectedContentLength > 0 else { return }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: http.expectedContentLength)
        guard !Task.isCancelled else { return }
        downloadSizeText = L("download.file_size_format", size)
    }

    private func presentMoviePlayer(resume: Bool) {
        Task {
            // Build 63 (item 6): bounded lookup — Play presents
            // within ~1.5 s worst case, streaming from the remote
            // URL if the local-file check can't answer in time.
            let localURL = await DownloadManager.shared.localURL(
                forId: DownloadManager.idFor(vod: playlist.id, streamId: currentMovie.streamId),
                timeout: 1.5
            )
            await MainActor.run {
                presentMoviePlayer(resume: resume, localOverrideURL: localURL)
            }
        }
    }

    private func presentMoviePlayer(resume: Bool, localOverrideURL: URL?) {
        // resumeMs is limited (finished movie → nil); using the raw lastTimeMs was jumping to the end
        // even when "Watch" was pressed on a finished movie.
        let r = resume ? resumeMs : nil
        let originStreamId = currentMovie.streamId
        let navigateToDetail: (String, String) -> Void = { type, id in
            guard type == "vod" else {
                playerOverlay.dismiss()
                return
            }
            if let vId = Int(id), vId == originStreamId {
                playerOverlay.dismiss()
                return
            }
            Task {
                if let vId = Int(id),
                   let movie = try? await AppDatabase.shared.read({ db in
                    try DBVODStream.filter(Column("streamId") == vId && Column("playlistId") == playlist.id).fetchOne(db)
                }) {
                    await MainActor.run {
                        playerOverlay.dismiss()
                        pendingMovieDetail = movie
                    }
                } else {
                    await MainActor.run { playerOverlay.dismiss() }
                }
            }
        }
        // If there is a downloaded file, skip the queue and play as a single movie from the local file.
        if localOverrideURL == nil, !queue.isEmpty {
            playerOverlay.present(playlistId: playlist.id) {
                VODPlayerShell(
                    playlist: playlist,
                    queue: queue,
                    initialMovie: currentMovie,
                    initialResumeMs: r,
                    onNavigateToDetail: navigateToDetail
                )
            }
            return
        }
        let url: URL = {
            if let localOverrideURL { return localOverrideURL }
            return PlaybackURLBuilder(playlist: playlist).movieURL(
                streamId: currentMovie.streamId,
                containerExtension: currentMovie.containerExtension
            ) ?? URL(fileURLWithPath: "/dev/null")
        }()
        guard url.path != "/dev/null" else {
            // Build 63 (item 6): was a silent return — the tap
            // looked dead. Surface the plain failure instead.
            showPlayFailure = true
            return
        }
        let parts = [currentMovie.genre, currentMovie.releaseDate].compactMap { $0 }.filter { !$0.isEmpty }
        playerOverlay.present(skipDownloadCheck: localOverrideURL != nil, playlistId: playlist.id) {
            PlayerView(
                url: url,
                title: currentMovie.name,
                subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "),
                artworkURL: currentMovie.streamIcon.flatMap { URL(string: $0) },
                isLiveStream: false,
                playlistId: playlist.id,
                streamId: String(currentMovie.streamId),
                type: "vod",
                resumeTimeMs: r,
                containerExtension: currentMovie.containerExtension,
                // Build 61 (B10, G2): playlist User-Agent to the engine load path.
                userAgent: playlist.playbackUserAgent(channelUserAgent: nil),
                // Build 61 (FA, F-2/G2): custom headers alongside the UA.
                customHeaders: playlist.customHeaders,
                onNavigateToDetail: navigateToDetail
            )
        }
    }

    private func fetchMovieInfo() async {
        isLoading = true
        metadataFetchFailed = false
        let client = XtreamAPIClient(playlist: playlist)
        do {
            let response = try await client.getVODInfo(vodId: movie.streamId)

            // Copy the @Query-backed currentMovie on the MAIN actor: the write closure
            // runs on GRDB's background writer queue, and reading SwiftUI property-wrapper
            // state from there is a data race.
            let base = await MainActor.run { currentMovie }
            let saved: DBVODStream = try await AppDatabase.shared.write { db in
                var updatedMovie = base
                updatedMovie.metadataLoaded = true
                if let i = response.info {
                    // Build 61 (B8, metadata completion): `actors`
                    // is the panel's alternate cast field and
                    // `description` its alternate plot field — used
                    // only when the primary field is absent.
                    updatedMovie.cast = i.cast ?? i.actors
                    updatedMovie.director = i.director
                    updatedMovie.genre = i.genre
                    updatedMovie.plot = i.plot ?? i.descriptionText
                    updatedMovie.releaseDate = i.releaseDate
                    updatedMovie.rating = i.rating
                    updatedMovie.country = i.country
                    if let providerRating5 = i.rating5Based {
                        updatedMovie.rating5Based = providerRating5
                    }
                    updatedMovie.backdropPath = i.backdropPath?.first
                    updatedMovie.youtubeTrailer = i.youtubeTrailer
                    // Round 14 (B7): runtime is formatted from the
                    // panel's real `duration_secs`; the raw duration
                    // string is only a fallback.
                    if let formatted = DetailFormatting.runtimeFromSeconds(i.durationSecs) {
                        updatedMovie.duration = formatted
                    } else {
                        updatedMovie.duration = i.duration
                    }
                    updatedMovie.tmdbId = i.tmdbId
                    updatedMovie.kinopoiskURL = i.kinopoiskURL
                    // Round 14 (B7): the provider's own `rating5Based`
                    // is NEVER overwritten with a value derived from
                    // the 0–10 `rating` string — the old code halved
                    // `rating` into it, corrupting the one
                    // normalization point for every fetched movie.
                }
                try updatedMovie.update(db)
                return updatedMovie
            }

            await MainActor.run {
                PlaylistContentStore.shared.applyVODMetadata(saved)
                self.isLoading = false
            }
        } catch {
            // Round 14 (B7): failure is non-blocking — the page keeps
            // rendering from the local record; only the quiet retry
            // row appears.
            await MainActor.run {
                self.metadataFetchFailed = true
                self.isLoading = false
            }
        }
    }

    private func toggleFavorite() {
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    if isFavorite {
                        try DBFavorite
                            .filter(Column("streamId") == movie.streamId && Column("playlistId") == playlist.id && Column("type") == "vod")
                            .deleteAll(db)
                    } else {
                        let fav = DBFavorite(streamId: movie.streamId, playlistId: playlist.id, type: "vod")
                        try fav.insert(db)
                    }
                }
                // Build 61 (B8, R6): snapshot for the unavailable state.
                if isFavorite {
                    FavoriteSnapshotStore.shared.remove(playlistId: playlist.id, type: "vod", streamId: movie.streamId)
                } else {
                    FavoriteSnapshotStore.shared.record(playlistId: playlist.id, type: "vod", streamId: movie.streamId, title: movie.name, imageURL: movie.streamIcon)
                }
            } catch {
                Log.error("MovieDetail", "Failed to toggle favorite: \(error.localizedDescription)")
            }
        }
    }

}
