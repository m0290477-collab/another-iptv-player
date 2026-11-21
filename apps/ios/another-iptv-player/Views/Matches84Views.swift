import SwiftUI
import SafariServices
import GRDB

// Build 84: the combined sports update's surfaces — the Watch
// action (item 3b), the player page (item 4), league leaders
// (item 7), league news (item 8), the Live Now page (item 13),
// the Highlights hub (item 14), the box score + play-by-play
// content (items 11/19), the win-probability chart (item 18),
// team comparison (item 22), and the shared countdown / offline
// stamp helpers (items 10/23).
//
// Every view renders ONLY payload-verified data (see
// Matches84.swift); an empty source renders an honest empty
// state, never a placeholder. All motion goes through the
// existing Motion tokens — press feedback everywhere, content
// crossfades on data swaps, nothing over playback.

// MARK: - Watch playback (item 3b)

/// The play half of the Watch action, shared by the row button
/// below: presents the hit through the SAME overlay paths the
/// detail screen's shipped watch section uses (PlayerView for
/// M3U, LivePlayerShell for Xtream) — playback code untouched.
enum WatchPlayback {
    static func play(hit: WatchChannelHit, overlay: PlayerOverlayController) {
        switch hit.streamRef {
        case .m3u(let url, let name, let logoURL):
            overlay.present(playlistId: hit.playlistId) {
                PlayerView(
                    url: url,
                    title: name,
                    artworkURL: logoURL,
                    isLiveStream: true,
                    playlistId: hit.playlistId,
                    streamId: url.absoluteString,
                    type: "live",
                    isFavorite: false,
                    onToggleFavorite: nil
                )
            }
        case .xtreamLive(let playlistId, let streamId):
            Task {
                let resolved = try? await AppDatabase.shared.read { db in
                    (
                        try Playlist.fetchOne(db, key: playlistId),
                        try DBLiveStream
                            .filter(Column("playlistId") == playlistId)
                            .filter(Column("streamId") == streamId)
                            .fetchOne(db)
                    )
                }
                guard let playlist = resolved?.0, let stream = resolved?.1 else { return }
                await MainActor.run {
                    overlay.present(playlistId: playlist.id) {
                        LivePlayerShell(
                            playlist: playlist,
                            queue: [stream],
                            sections: [],
                            initialStream: stream,
                            initialHistory: nil,
                            subtitle: nil
                        )
                    }
                }
            }
        }
    }
}

/// The Watch action on match rows/cards: appears ONLY when the
/// match is live or upcoming AND the user's active playlist
/// carries a broadcasting channel (broadcaster pattern or a
/// team name — see MatchWatchService). One tap plays the first
/// match directly; a long-press menu offers the rest. No hits →
/// the view renders nothing at all (no dead ends).
struct WatchPlayButton: View {
    let sport: MatchSport
    let leaguePath: String
    let match: MatchEvent
    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @State private var hits: [WatchChannelHit] = []

    private var eligible: Bool {
        match.state == .live || match.state == .upcoming
    }

    var body: some View {
        Group {
            if !hits.isEmpty {
                Menu {
                    ForEach(hits, id: \.id) { hit in
                        Button {
                            WatchPlayback.play(hit: hit, overlay: playerOverlay)
                        } label: {
                            Label(hit.channelName, systemImage: "play.tv")
                        }
                    }
                } label: {
                    Label(L("matches.watch.button"), systemImage: "play.tv.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.onAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppTheme.accent, in: Capsule())
                } primaryAction: {
                    if let first = hits.first {
                        WatchPlayback.play(hit: first, overlay: playerOverlay)
                    }
                }
                .buttonStyle(PressOpacityButtonStyle())
                .accessibilityLabel(L("matches.watch.button"))
            }
        }
        .task(id: match.id) {
            guard eligible else { return }
            hits = await MatchWatchService.hits(sport: sport, leaguePath: leaguePath, match: match)
        }
    }
}

// MARK: - Countdown + offline stamp (items 10/23)

/// A live countdown to a kickoff, ticking on a slow periodic
/// timeline (30 s — a text label, not an animation loop). At
/// kickoff it renders the LIVE word instead.
struct CountdownText: View {
    let target: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let remaining = target.timeIntervalSince(context.date)
            if remaining <= 0 {
                Text(L("matches.live"))
                    .foregroundStyle(AppTheme.live)
            } else {
                Text(L("matches.next_in", Self.format(remaining)))
            }
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }
}

/// The visible "last updated" stamp shown when a sports screen
/// is rendering its disk-cached payload (item 23).
struct LastUpdatedStamp: View {
    let date: Date

    var body: some View {
        Label(L("matches.last_updated", date.formatted(date: .omitted, time: .shortened)),
              systemImage: "clock.arrow.circlepath")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Safari sheet (item 8)

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

// MARK: - Player photos (item 1)
//
// Every new surface below renders player photos through the
// EXISTING `PlayerPhotoDisc` (MatchesExtrasViews): the ESPN
// headshot (payload href → CDN pattern, resolved by the data
// layer through MatchesService / CoreCoordinates) via the
// shared Nuke pipeline, with the initials disc ONLY as the
// no-photo fallback — i.e. only where ESPN carries no photo
// for that athlete anywhere.
//
// Build 86: SOCCER surfaces additionally pass a
// `SoccerPhotoQuery` to the same disc — where ESPN has no
// photo, a verified fallback (FPL → Wikidata → TheSportsDB,
// `SoccerPhotoResolver`) swaps in over the initials. Every
// other sport passes nil and is unchanged.

// MARK: - Player page (item 4)

/// A player's page: photo, team, the identity fields the core
/// athlete payload carries (position / number / age /
/// nationality — each rendered only when present), the season
/// stats from the payload's own statistics $ref, and recent
/// matches from the athlete's own event log.
struct PlayerPageView: View {
    let sport: MatchSport
    let leaguePath: String
    let athleteId: String
    var fallbackName: String?

    @State private var profile: PlayerProfile?
    @State private var didLoad = false
    /// Build 86: TheSportsDB biography (soccer only) —
    /// rendered only when the free source verifies the
    /// record as this player (name + team).
    @State private var playerBio: String?

    var body: some View {
        List {
            if let profile {
                headerSection(profile)
                if hasIdentityRows(profile) {
                    identitySection(profile)
                }
                if !profile.statLines.isEmpty {
                    statsSection(profile)
                }
                if !profile.recentEvents.isEmpty {
                    recentSection(profile)
                }
                // Build 87 (item 6): compare this player with
                // another from the same league's leaders.
                Section {
                    NavigationLink {
                        PlayerCompareView(
                            sport: sport, leaguePath: leaguePath,
                            firstAthleteId: athleteId
                        )
                    } label: {
                        Label(L("matches.compare_players"), systemImage: "person.2")
                            .font(AppTheme.fontCardTitle)
                    }
                    .buttonStyle(PressOpacityButtonStyle())
                }
                if let playerBio {
                    bioSection(playerBio)
                }
            } else if didLoad {
                Section {
                    Text(L("matches.empty"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text(L("common.loading"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(profile?.name ?? fallbackName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            profile = await PlayerProfileService.fetch(
                sport: sport, leaguePath: leaguePath, athleteId: athleteId
            )
            didLoad = true
            // Build 86: the biography lookup runs only once
            // the profile (and with it the verified team) is
            // known — soccer only.
            if sport == .soccer, let profile {
                playerBio = await SportsDBService.playerBio(
                    name: profile.name, teamName: profile.teamName
                )
            }
        }
    }

    private func bioSection(_ bio: String) -> some View {
        Section {
            Text(bio)
                .font(.subheadline)
        } header: {
            Text(L("matches.player.bio"))
        }
    }

    private func headerSection(_ profile: PlayerProfile) -> some View {
        Section {
            HStack(spacing: 14) {
                PlayerPhotoDisc(
                    url: profile.headshotURL, name: profile.name, size: 72,
                    fallback: sport == .soccer
                        ? SoccerPhotoQuery(
                            athleteId: profile.athleteId, name: profile.name,
                            teamName: profile.teamName, leaguePath: leaguePath,
                            citizenship: profile.citizenship, dateOfBirth: nil
                        )
                        : nil
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                    if let teamId = profile.teamId, let teamName = profile.teamName {
                        // Build 87 (item 1): hockey profiles
                        // open the NHL club page (teamId is the
                        // club abbreviation there).
                        if sport == .nhl {
                            NavigationLink {
                                NHLTeamPageView(
                                    abbrev: teamId, name: teamName,
                                    logoURL: profile.teamLogoURL
                                )
                            } label: {
                                HStack(spacing: 6) {
                                    CachedImage(url: profile.teamLogoURL, width: 22, height: 22, cornerRadius: 11, iconName: "shield")
                                    Text(teamName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                            .buttonStyle(PressOpacityButtonStyle())
                        } else {
                            NavigationLink {
                                TeamPageView(team: TeamRef(
                                    id: teamId, sport: sport, leaguePath: leaguePath,
                                    name: teamName, logoURL: profile.teamLogoURL
                                ))
                            } label: {
                                HStack(spacing: 6) {
                                    CachedImage(url: profile.teamLogoURL, width: 22, height: 22, cornerRadius: 11, iconName: "shield")
                                    Text(teamName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                            .buttonStyle(PressOpacityButtonStyle())
                        }
                    } else if let teamName = profile.teamName {
                        Text(teamName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private func hasIdentityRows(_ profile: PlayerProfile) -> Bool {
        profile.positionName != nil || profile.jersey != nil
            || profile.age != nil || profile.citizenship != nil
            || profile.batsText != nil || profile.throwsText != nil
    }

    private func identitySection(_ profile: PlayerProfile) -> some View {
        Section {
            if let position = profile.positionName {
                infoRow(L("matches.player.position"), position)
            }
            if let jersey = profile.jersey {
                infoRow(L("matches.player.number"), jersey)
            }
            if let age = profile.age {
                infoRow(L("matches.player.age"), "\(age)")
            }
            if let citizenship = profile.citizenship {
                infoRow(L("matches.player.nationality"), citizenship)
            }
            // Build 85: baseball's hands — rendered only
            // where the payload carries them (MLB).
            if let bats = profile.batsText {
                infoRow(L("matches.player.bats"), bats)
            }
            if let throwsText = profile.throwsText {
                infoRow(L("matches.player.throws"), throwsText)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
    }

    private func statsSection(_ profile: PlayerProfile) -> some View {
        Section {
            ForEach(Array(profile.statLines.enumerated()), id: \.offset) { _, line in
                infoRow(line.label, line.value)
            }
        } header: {
            Text(L("matches.player.stats"))
        }
    }

    private func recentSection(_ profile: PlayerProfile) -> some View {
        Section {
            ForEach(Array(profile.recentEvents.enumerated()), id: \.offset) { _, event in
                HStack {
                    Text(event.name)
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer()
                    Text(event.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("matches.player.recent"))
        }
    }
}

// MARK: - League leaders (item 7)

/// The leaders page: every category the core leaders payload
/// verified for this league (soccer: goals + assists; NBA:
/// points / assists / rebounds per game; NFL: passing /
/// rushing / receiving yards) behind one category picker.
/// Rows carry the player's photo (item 1) and open the player
/// page (item 4).
struct LeadersView: View {
    let sport: MatchSport
    let leaguePath: String
    var leagueName: String?

    @State private var categories: [LeaderCategory84] = []
    @State private var rowsByCategory: [String: [LeaderRow84]] = [:]
    @State private var selectedCategory: String?
    @State private var stamp: Date?
    @State private var didLoad = false

    private var rows: [LeaderRow84] {
        selectedCategory.flatMap { rowsByCategory[$0] } ?? []
    }

    var body: some View {
        List {
            if let stamp {
                Section {
                    LastUpdatedStamp(date: stamp)
                }
                .listRowBackground(Color.clear)
            }
            if categories.count > 1 {
                Section {
                    // Build 85: a segmented control fits the
                    // shipped sports' 2–3 categories; MLB's
                    // eighteen verified categories get a menu
                    // picker instead of overflowing. (Two
                    // branches because the two styles are
                    // different concrete types.)
                    if categories.count > 4 {
                        Picker(L("matches.leaders"), selection: categorySelection) {
                            ForEach(categories) { category in
                                Text(category.displayName).tag(category.name)
                            }
                        }
                        .pickerStyle(.menu)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    } else {
                        Picker(L("matches.leaders"), selection: categorySelection) {
                            ForEach(categories) { category in
                                Text(category.displayName).tag(category.name)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }
                .listRowBackground(Color.clear)
            }
            Section {
                if rows.isEmpty {
                    Text(didLoad ? L("matches.empty") : L("common.loading"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        NavigationLink {
                            PlayerPageView(
                                sport: sport, leaguePath: leaguePath,
                                athleteId: row.athleteId, fallbackName: row.name
                            )
                        } label: {
                            leaderRow(index: index, row: row)
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L("matches.leaders"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let result = await MatchesLeadersService.fetchAll(sport: sport, leaguePath: leaguePath)
            categories = result.categories
            rowsByCategory = result.rows
            stamp = result.stamp
            if selectedCategory == nil {
                selectedCategory = result.categories.first?.name
            }
            didLoad = true
        }
    }

    private var categorySelection: Binding<String> {
        Binding(
            get: { selectedCategory ?? categories.first?.name ?? "" },
            set: { newValue in
                withAnimation(Motion.animate(Motion.chipSwap)) { selectedCategory = newValue }
            }
        )
    }

    private func leaderRow(index: Int, row: LeaderRow84) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            PlayerPhotoDisc(
                url: row.headshotURL, name: row.name, size: 36,
                fallback: sport == .soccer
                    ? SoccerPhotoQuery(
                        athleteId: row.athleteId, name: row.name,
                        teamName: row.teamName, leaguePath: leaguePath,
                        citizenship: nil, dateOfBirth: nil
                    )
                    : nil
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let teamName = row.teamName {
                    Text(teamName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(row.valueText)
                .font(.headline.weight(.bold))
                .foregroundStyle(AppTheme.accent)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - League news (item 8)

/// ESPN headlines for the league — rendered only when the
/// verified news feed returns articles; tapping a headline
/// opens the publisher page in the in-app Safari sheet.
struct LeagueNewsView: View {
    let leaguePath: String
    var leagueName: String?

    @State private var articles: [NewsArticle84] = []
    @State private var stamp: Date?
    @State private var didLoad = false
    @State private var safariURL: URL?

    var body: some View {
        List {
            if let stamp {
                Section {
                    LastUpdatedStamp(date: stamp)
                }
                .listRowBackground(Color.clear)
            }
            Section {
                if articles.isEmpty {
                    Text(didLoad ? L("matches.empty") : L("common.loading"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(articles) { article in
                        Button {
                            safariURL = article.webURL
                        } label: {
                            newsRow(article)
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                        .disabled(article.webURL == nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L("matches.news"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: safariItem) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
        .task {
            let result = await LeagueNewsService.fetch(leaguePath: leaguePath)
            articles = result.articles
            stamp = result.stamp
            didLoad = true
        }
    }

    private struct SafariItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var safariItem: Binding<SafariItem?> {
        Binding(
            get: { safariURL.map { SafariItem(url: $0) } },
            set: { safariURL = $0?.url }
        )
    }

    private func newsRow(_ article: NewsArticle84) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(article.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if let summary = article.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let published = article.published {
                    Text(published.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            if let imageURL = article.imageURL {
                CachedImage(
                    url: imageURL,
                    width: 72, height: 48,
                    cornerRadius: 8,
                    contentMode: .fill,
                    iconName: "newspaper"
                )
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Live Now (item 13)

/// Every live match across all 20 competitions right now,
/// grouped by competition. Refreshes on the Matches cadence
/// (the shared 60-second loop pattern — no new timer system),
/// and each row carries the Watch action where item 3b matches.
struct LiveNowView: View {
    @State private var groups: [LiveNowGroup] = []
    @State private var didLoad = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if groups.isEmpty {
                    Text(didLoad ? L("matches.empty") : L("common.loading"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.leagueName ?? group.leaguePath)
                                .font(AppTheme.fontSectionTitle)
                                .padding(.horizontal, 16)
                            VStack(spacing: 0) {
                                ForEach(Array(group.matches.enumerated()), id: \.element.id) { index, match in
                                    VStack(alignment: .leading, spacing: 6) {
                                        NavigationLink {
                                            MatchDetailView(
                                                sport: group.sport, leaguePath: group.leaguePath,
                                                match: match, leagueName: group.leagueName
                                            )
                                        } label: {
                                            MatchRowView(match: match, isStale: false, sport: group.sport)
                                        }
                                        .buttonStyle(PressOpacityButtonStyle())
                                        WatchPlayButton(
                                            sport: group.sport, leaguePath: group.leaguePath,
                                            match: match
                                        )
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    if index < group.matches.count - 1 {
                                        Divider().padding(.leading, 12)
                                    }
                                }
                            }
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(AppTheme.cardBorderColor, lineWidth: 1)
                            )
                            .padding(.horizontal, 16)
                        }
                        .sectionAppear()
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(AppTheme.background)
        .navigationTitle(L("matches.live_now"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }

    private func refresh() async {
        groups = await SportsHubService.liveNow()
        didLoad = true
    }
}

// MARK: - Highlights hub (item 14)

/// One feed of highlight videos across competitions —
/// today's and yesterday's finished matches, only the videos
/// their own summary payloads carry (the build-81 verified
/// set), playing in-app through the same direct-MP4 AVKit
/// sheet. Build 87 (item 13): the feed is GROUPED BY SPORT
/// under sport headers in the app's sport order — never one
/// mixed list.
struct HighlightsHubView: View {
    @State private var highlights: [HubHighlight] = []
    @State private var didLoad = false
    @State private var selected: MatchVideo?

    /// The feed's sport groups, in MatchSport order.
    private var sportGroups: [(sport: MatchSport, items: [HubHighlight])] {
        MatchSport.allCases.compactMap { sport in
            let items = highlights.filter { $0.sport == sport }
            return items.isEmpty ? nil : (sport: sport, items: items)
        }
    }

    var body: some View {
        List {
            if highlights.isEmpty {
                Section {
                    Text(didLoad ? L("matches.empty") : L("common.loading"))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(sportGroups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group.items) { item in
                            Button {
                                selected = item.video
                            } label: {
                                highlightRow(item)
                            }
                            .buttonStyle(PressOpacityButtonStyle())
                        }
                    } header: {
                        Text(L(group.sport.titleKey))
                            .font(AppTheme.fontBadge)
                            .foregroundStyle(AppTheme.accent)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L("matches.highlights_hub"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { video in
            HighlightPlayerView(url: video.url)
        }
        .task {
            highlights = await SportsHubService.highlights()
            didLoad = true
        }
    }

    private func highlightRow(_ item: HubHighlight) -> some View {
        HStack(spacing: 12) {
            ZStack {
                CachedImage(
                    url: item.video.thumbnailURL,
                    width: 104, height: 60,
                    cornerRadius: 8,
                    contentMode: .fill,
                    iconName: "play.rectangle"
                )
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let home = item.homeName, let away = item.awayName {
                    Text("\(home) – \(away)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                Text(item.video.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let league = item.leagueName {
                        Text(league)
                    }
                    if let date = item.date {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Box score + play-by-play content (items 11/19)

/// The Box Score tab content (rendered as a Section's rows in
/// the detail list): a team switcher, then per payload group a
/// horizontally scrolling stat grid — the payload's own column
/// labels and values, DNP where the payload marks it, photos
/// per item 1, and a tap through to the player page (item 4).
struct BoxScoreRows: View {
    let teams: [MatchBoxScoreTeam]
    let sport: MatchSport
    let leaguePath: String

    @State private var selectedTeam = 0

    private var team: MatchBoxScoreTeam? {
        teams.indices.contains(selectedTeam) ? teams[selectedTeam] : teams.first
    }

    var body: some View {
        if teams.count > 1 {
            Picker(L("matches.team_label"), selection: $selectedTeam) {
                ForEach(Array(teams.enumerated()), id: \.element.id) { index, team in
                    Text(team.teamName ?? "").tag(index)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .listRowBackground(Color.clear)
        }
        if let team {
            ForEach(team.groups) { group in
                if let title = group.title {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                boxGrid(group)
            }
        }
    }

    private func boxGrid(_ group: MatchBoxScoreGroup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                gridHeader(group)
                Divider()
                ForEach(group.players) { player in
                    gridRow(group, player)
                    Divider()
                }
                if !group.totals.isEmpty {
                    totalsRow(group)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 0))
    }

    private func gridHeader(_ group: MatchBoxScoreGroup) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 148, height: 22)
            ForEach(Array(group.columns.enumerated()), id: \.offset) { _, column in
                Text(column)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44)
            }
        }
    }

    private func gridRow(_ group: MatchBoxScoreGroup, _ player: MatchBoxScorePlayer) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                PlayerPhotoDisc(url: player.headshotURL, name: player.name, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(player.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if player.isStarter {
                        Text("★")
                            .font(.system(size: 8))
                            .foregroundStyle(AppTheme.accent)
                    }
                }
            }
            .frame(width: 148, alignment: .leading)
            if player.didNotPlay {
                Text(player.dnpReason.map { "\(L("matches.box.dnp")) – \($0)" } ?? L("matches.box.dnp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(group.columns.enumerated()), id: \.offset) { index, _ in
                    Text(index < player.values.count ? player.values[index] : "–")
                        .font(.caption.monospacedDigit())
                        .frame(width: 44)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            Group {
                if let athleteId = player.athleteId {
                    NavigationLink {
                        PlayerPageView(
                            sport: sport, leaguePath: leaguePath,
                            athleteId: athleteId, fallbackName: player.name
                        )
                    } label: { EmptyView() }
                    .opacity(0)
                }
            }
        )
    }

    private func totalsRow(_ group: MatchBoxScoreGroup) -> some View {
        HStack(spacing: 0) {
            Text(L("matches.box.totals"))
                .font(.caption.weight(.bold))
                .frame(width: 148, alignment: .leading)
            ForEach(Array(group.columns.enumerated()), id: \.offset) { index, _ in
                Text(index < group.totals.count ? group.totals[index] : "–")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .frame(width: 44)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }
}

/// The Play-by-Play tab content: newest first, period + clock
/// where the payload carries them, the score after the play,
/// scoring plays accented.
struct PlayByPlayRows: View {
    let plays: [MatchPlayEntry]

    var body: some View {
        ForEach(plays) { play in
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 1) {
                    if let period = play.periodLabel {
                        Text(period)
                            .font(.caption2.weight(.bold))
                    }
                    if let clock = play.clockText {
                        Text(clock)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, alignment: .leading)
                Text(play.text)
                    .font(.caption)
                    .fontWeight(play.scoringPlay ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let score = play.scoreText {
                    Text(score)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(play.scoringPlay ? AppTheme.accent : .secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Win-probability chart (item 18)

/// The win-probability curve: the payload's home-win
/// percentages in play order as a smooth path (drawn manually —
/// no new dependency), a dashed 50% reference, and the latest
/// value labelled with the home team's name. Rendered only
/// where the summary publishes the series (NBA/NFL).
struct WinProbabilityChart: View {
    let values: [Double]
    let homeName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("matches.detail.win_probability"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let last = values.last, let homeName {
                    Text("\(homeName) \(Int((last * 100).rounded()))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height / 2))
                        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    }
                    .stroke(Color.secondary.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    Path { path in
                        for (index, value) in values.enumerated() {
                            let x = size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                            let y = size.height * CGFloat(1 - min(max(value, 0), 1))
                            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            }
            .frame(height: 84)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Form chips (item 5)

/// Last-results chips, FotMob-style: one disc per result the
/// derivation actually found (W green / D grey / L red), oldest
/// first, newest last. Renders nothing for an empty run — the
/// count shown IS the verified count.
struct FormChipsRow: View {
    let results: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                Text(result)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(color(for: result), in: Circle())
            }
        }
    }

    private func color(for result: String) -> Color {
        switch result {
        case "W": return Color(red: 0.13, green: 0.62, blue: 0.28)
        case "L": return Color(red: 0.85, green: 0.22, blue: 0.24)
        default: return Color(red: 0.45, green: 0.47, blue: 0.50)
        }
    }
}

// MARK: - Compare teams (item 22)

/// Side-by-side season comparison for two teams of the SAME
/// league, from the standings payload already fetched (position
/// / record / goals or points, payload-labelled) plus the
/// derived form — nothing else, nothing invented.
struct CompareTeamsView: View {
    let team: TeamRef

    @State private var groups: [StandingGroup] = []
    @State private var form: [String: [String]] = [:]
    @State private var opponent: StandingEntry?

    private var allEntries: [StandingEntry] {
        groups.flatMap { $0.entries }
    }

    private var ownEntry: StandingEntry? {
        allEntries.first { $0.teamId == team.id }
    }

    var body: some View {
        List {
            if let own = ownEntry {
                if let opponent {
                    comparisonSection(own: own, other: opponent)
                } else {
                    Section {
                        ForEach(allEntries.filter { $0.teamId != team.id }, id: \.id) { entry in
                            Button {
                                withAnimation(Motion.animate(Motion.chipSwap)) { opponent = entry }
                            } label: {
                                HStack(spacing: 10) {
                                    CachedImage(url: entry.logoURL, width: 26, height: 26, cornerRadius: 13, iconName: "shield")
                                    Text(entry.teamName)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressOpacityButtonStyle())
                        }
                    } header: {
                        Text(L("matches.compare.pick"))
                    }
                }
            } else {
                Section {
                    Text(L("common.loading"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L("matches.compare"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let result = await MatchesStandingsService.fetch(sport: team.sport, leaguePath: team.leaguePath)
            groups = result.groups
            form = await TeamFormService.form(sport: team.sport, leaguePath: team.leaguePath)
        }
    }

    private func position(of entry: StandingEntry) -> Int? {
        for group in groups {
            if let index = group.entries.firstIndex(where: { $0.teamId == entry.teamId }) {
                return index + 1
            }
        }
        return nil
    }

    private func comparisonSection(own: StandingEntry, other: StandingEntry) -> some View {
        // Build 84 fix round 1: a plain Group of rows, not a
        // Section — returned opaquely into the List builder, the
        // Section form made the compiler synthesise a Table row
        // content type that does not conform to View. The rows
        // themselves are unchanged.
        Group {
            HStack {
                compareHeader(own)
                Spacer()
                compareHeader(other)
            }
            compareRow(
                label: L("matches.compare.position"),
                left: position(of: own).map { "\($0)" },
                right: position(of: other).map { "\($0)" }
            )
            ForEach(compareKeys(own: own, other: other), id: \.self) { key in
                compareRow(
                    label: own.statLabels[key] ?? other.statLabels[key] ?? key,
                    left: own.stats[key],
                    right: other.stats[key]
                )
            }
            if let ownForm = own.teamId.flatMap({ form[$0] }),
               let otherForm = other.teamId.flatMap({ form[$0] }) {
                HStack {
                    FormChipsRow(results: ownForm)
                    Spacer()
                    Text(L("matches.table_form"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    FormChipsRow(results: otherForm)
                }
            }
            Button {
                withAnimation(Motion.animate(Motion.chipSwap)) { opponent = nil }
            } label: {
                Text(L("matches.compare.pick"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            .buttonStyle(PressOpacityButtonStyle())
        }
    }

    private func compareHeader(_ entry: StandingEntry) -> some View {
        VStack(spacing: 6) {
            CachedImage(url: entry.logoURL, width: 44, height: 44, cornerRadius: 22, iconName: "shield")
            Text(entry.teamName)
                .font(.subheadline.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    private func compareRow(label: String, left: String?, right: String?) -> some View {
        HStack {
            Text(left ?? "–")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(right ?? "–")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// The compared stat keys per sport, in table order —
    /// rendered only when at least one side carries the stat.
    private func compareKeys(own: StandingEntry, other: StandingEntry) -> [String] {
        let candidates: [String]
        switch team.sport {
        case .soccer:
            candidates = ["gamesPlayed", "wins", "ties", "losses",
                          "pointsFor", "pointsAgainst", "pointDifferential", "points"]
        case .nba, .nfl:
            candidates = ["wins", "losses", "ties", "winPercent",
                          "pointsFor", "pointsAgainst", "pointDifferential", "streak"]
        case .mlb:
            // Build 85: the MLB payload's own comparison set,
            // including its published Last Ten Games record.
            candidates = ["wins", "losses", "winPercent", "gamesBehind",
                          "pointsFor", "pointsAgainst", "pointDifferential",
                          "Last Ten Games", "streak"]
        case .nhl:
            // Build 87 (item 1): for exhaustiveness — NHL
            // teams never reach CompareTeamsView (their page
            // is NHLTeamPageView, which offers no compare
            // entry), but the NHL entries' keys mirror the
            // ESPN names if one ever did.
            candidates = ["gamesPlayed", "wins", "losses", "otLosses",
                          "pointsFor", "pointsAgainst", "pointDifferential", "points"]
        }
        return candidates.filter { own.stats[$0] != nil || other.stats[$0] != nil }
    }
}
