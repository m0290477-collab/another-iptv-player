import AVKit
import GRDB
import SwiftUI

/// Build 63 (owner, items 8b/8c/9): the match detail screen.
///
/// Everything on it comes from the SAME free ESPN public data —
/// the per-event summary endpoint (see MatchesService): the event
/// timeline (scorers + minute, cards with player + minute), team
/// statistics, and top performers with headshots (CDN photo when
/// the feed provides one, a clean initials disc when it doesn't —
/// never a broken image, never an invented photo/stat). Sections
/// the feed doesn't populate for a league are simply absent, and
/// a match with no detail data at all gets the honest empty
/// state. Item 9: each team can be followed from here for goal
/// notifications, with per-team notification toggles.
struct MatchDetailView: View {
    let sport: MatchSport
    let leaguePath: String
    /// The scoreboard row this screen was opened from (nil when
    /// opened from a push deep link — the header then comes from
    /// the summary payload itself).
    let seedMatch: MatchEvent?
    let eventId: String
    /// Feed league name when the opener knows it (item 10c uses
    /// it as a channel-name keyword).
    let leagueName: String?

    @State private var detail: MatchDetail?
    @State private var loadFailed = false
    @ObservedObject private var followStore = FollowedTeamsStore.shared
    /// Item 10c state.
    @State private var watchHits: [WatchChannelHit] = []
    @State private var watchLoaded = false
    /// Build 84 (item 3b): broadcaster-pattern Watch hits over
    /// the active playlist, shown ahead of the name-search hits.
    @State private var broadcastHits: [WatchChannelHit] = []
    /// Build 84 (item 15): the any-match kickoff PUSH toggle
    /// state (the local 15-minute reminder above is separate
    /// and unchanged).
    @State private var kickoffPushOn = false
    /// Item 10e state.
    @State private var reminderOn = false
    /// Build 65 (Match detail style 1 'Scoreboard Pro') introduced
    /// the tabbed sections; build 80 (item 16) re-arranges them
    /// the FotMob way at the owner's order: Facts / Lineup / Stats
    /// / H2H / Commentary — each tab existing ONLY when the feed
    /// actually carries that data. (The build-65 note claimed the
    /// summary had no head-to-head data; build 80's payload
    /// inspection found it in `seasonseries`, which the old
    /// decoder never read — see MatchesService.mapH2H. Still
    /// excluded, because ESPN's free data does not carry them:
    /// player ratings, momentum, Player of the Match.)
    @State private var detailTab = 0
    /// Build 81 (item 3): the highlight currently playing in-app.
    @State private var playingHighlight: MatchVideo?
    /// Build 87 (item 12): deeper head-to-head — meetings from
    /// the two previous seasons, intersected from the core
    /// API's per-season team event lists.
    @State private var deepMeetings: [MatchH2HMeeting] = []
    /// Build 85 (sweep): the recap article open in the Safari
    /// sheet, when the user taps it.
    @State private var articleURL: URL?
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    private enum DetailTab: Hashable {
        case facts, lineups, stats, h2h, commentary
        // Build 84 (items 11/19): box score + play-by-play —
        // NBA/NFL summaries only, present only when the payload
        // carries them.
        case boxScore, plays

        var title: String {
            switch self {
            case .facts: return L("matches.detail.facts")
            case .lineups: return L("matches.lineups")
            case .stats: return L("matches.stats")
            case .h2h: return L("matches.detail.h2h")
            case .commentary: return L("matches.detail.commentary")
            case .boxScore: return L("matches.box_score")
            case .plays: return L("matches.detail.play_by_play")
            }
        }
    }

    private var hasTimeline: Bool { !(detail?.timeline.isEmpty ?? true) }
    private var hasLineups: Bool { !(detail?.lineups.isEmpty ?? true) }
    private var hasStats: Bool { !(detail?.stats.isEmpty ?? true) }
    private var hasBoxScore: Bool { !(detail?.boxScore.isEmpty ?? true) }
    private var hasPlays: Bool { !(detail?.playsFeed.isEmpty ?? true) }
    /// Facts exists when any of its groups has real data:
    /// the timeline, the payload's match info, its videos,
    /// or (build 85) its recap/preview article.
    private var hasFacts: Bool {
        guard let detail else { return false }
        return hasTimeline || detail.info != nil || !detail.videos.isEmpty
            || detail.article != nil
    }
    private var hasH2H: Bool { !(detail?.h2h?.meetings.isEmpty ?? true) }
    private var hasCommentary: Bool { !(detail?.commentary.isEmpty ?? true) }

    /// The tabs that exist for THIS match, in display order.
    private var availableTabs: [DetailTab] {
        var tabs: [DetailTab] = []
        if hasFacts { tabs.append(.facts) }
        if hasLineups { tabs.append(.lineups) }
        if hasStats { tabs.append(.stats) }
        if hasBoxScore { tabs.append(.boxScore) }
        if hasPlays { tabs.append(.plays) }
        if hasH2H { tabs.append(.h2h) }
        if hasCommentary { tabs.append(.commentary) }
        return tabs
    }

    /// The selected tab, clamped when data changes.
    private var selectedTab: DetailTab? {
        let tabs = availableTabs
        guard !tabs.isEmpty else { return nil }
        return tabs[min(detailTab, tabs.count - 1)]
    }

    init(sport: MatchSport, leaguePath: String, match: MatchEvent, leagueName: String? = nil) {
        self.sport = sport
        self.leaguePath = leaguePath
        self.seedMatch = match
        self.eventId = match.id
        self.leagueName = leagueName
    }

    init(sport: MatchSport, leaguePath: String, eventId: String) {
        self.sport = sport
        self.leaguePath = leaguePath
        self.seedMatch = nil
        self.eventId = eventId
        self.leagueName = nil
    }

    private var home: MatchTeamSide? { seedMatch?.home ?? detail?.header?.home }
    private var away: MatchTeamSide? { seedMatch?.away ?? detail?.header?.away }
    private var state: MatchState? { seedMatch?.state ?? detail?.header?.state }

    var body: some View {
        // Build 87 (item 1): hockey's detail is the NHL API's
        // own page — the ESPN summary pipeline never sees the
        // .nhl sport (its payloads are a different shape).
        if sport == .nhl {
            NHLMatchDetailView(leaguePath: leaguePath, eventId: eventId, seedMatch: seedMatch)
        } else {
            espnBody
        }
    }

    private var espnBody: some View {
        Group {
            if detail == nil && !loadFailed {
                BrandedLoader()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadFailed && detail == nil {
                VStack(spacing: 14) {
                    Text(L("matches.error"))
                        .font(AppTheme.fontMetadata)
                        .multilineTextAlignment(.center)
                    Button(L("matches.retry")) {
                        loadFailed = false
                        Task { await load() }
                    }
                    .font(AppTheme.fontCardTitle)
                    .foregroundStyle(AppTheme.accent)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                contentList
            }
        }
        .cinematicBackground()
        .navigationTitle(L("matches.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: eventId) { await load() }
        // Build 81 (item 8): the FotMob tab swap eases instead of
        // snapping.
        .animation(Motion.animate(Motion.contentIn), value: detailTab)
        // Build 81 (item 3): in-app highlight playback.
        .fullScreenCover(item: $playingHighlight) { video in
            HighlightPlayerView(url: video.url)
        }
        // Build 85 (sweep): the recap article in the in-app
        // Safari sheet (the news surface's own pattern).
        .sheet(item: articleSafariItem) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
    }

    private struct ArticleSafariItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var articleSafariItem: Binding<ArticleSafariItem?> {
        Binding(
            get: { articleURL.map { ArticleSafariItem(url: $0) } },
            set: { articleURL = $0?.url }
        )
    }

    private func load() async {
        reminderOn = MatchReminderService.shared.isScheduled(eventId: eventId)
        kickoffPushOn = MatchKickoffPushStore.shared.contains(eventId: eventId)
        do {
            detail = try await MatchesService.fetchDetail(
                sport: sport, leaguePath: leaguePath, eventId: eventId
            )
        } catch {
            if detail == nil { loadFailed = true }
        }
        // Item 10c: the watch-on-your-channels search runs off
        // the local database only; it never blocks the detail.
        if state == .live || state == .upcoming {
            watchHits = await WatchChannelSearch.search(
                homeName: home?.name, awayName: away?.name, leagueName: leagueName
            )
            // Build 84 (item 3b): the broadcaster-pattern match
            // over the ACTIVE playlist, with the summary's own
            // broadcaster names as extra needles — also local.
            if let seedMatch {
                broadcastHits = await MatchWatchService.hits(
                    sport: sport, leaguePath: leaguePath, match: seedMatch,
                    extraNeedles: detail?.broadcastNames ?? []
                )
            }
        }
        // Build 87 (item 12): deeper H2H loads after the
        // detail — the two teams' core event lists for the
        // two previous seasons, intersected; meetings the
        // summary already showed are excluded by event id.
        if let h2h = detail?.h2h, !h2h.meetings.isEmpty,
           let homeId = home?.teamId, let awayId = away?.teamId {
            deepMeetings = await DeepH2HService.fetch(
                sport: sport, leaguePath: leaguePath,
                homeId: homeId, awayId: awayId,
                homeName: home?.name, awayName: away?.name,
                excludeIds: Set(h2h.meetings.map(\.id))
            )
        }
        watchLoaded = true
    }

    // MARK: Content

    private var contentList: some View {
        List {
            Section {
                headerView
            }
            .listRowBackground(AppTheme.surface)

            followSection

            reminderSection

            kickoffPushSection

            watchSection

            headerExtrasSection

            if let detail, !detail.leaders.isEmpty {
                Section {
                    leadersRow(detail.leaders)
                } header: {
                    sectionHeader(L("matches.detail.top_performers"))
                }
                .listRowBackground(AppTheme.surface)
            }

            // Build 65 (Scoreboard Pro): ONE tab bar over the
            // detail sections; the selected tab's rows render
            // below it. Tabs exist only for data the feed
            // actually carries (see `availableTabs`).
            if let detail, !availableTabs.isEmpty {
                Section {
                    Picker("", selection: $detailTab) {
                        ForEach(Array(availableTabs.enumerated()), id: \.offset) { index, tab in
                            Text(tab.title).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                .listRowBackground(Color.clear)

                if selectedTab == .facts {
                    // Build 80 (item 16): Facts — match info,
                    // the event timeline, and the payload's
                    // official videos (item 15), each group
                    // rendered only when the payload carries it.
                    if let info = detail.info {
                        Section {
                            infoRows(info)
                        } header: {
                            sectionHeader(L("matches.detail.match_info"))
                        }
                        .listRowBackground(AppTheme.surface)
                    }
                    if !detail.timeline.isEmpty {
                        Section {
                            ForEach(detail.timeline) { event in
                                // Build 84 (item 4): a timeline
                                // event with a known athlete
                                // opens the player page.
                                if let athleteId = event.athleteId {
                                    NavigationLink {
                                        PlayerPageView(
                                            sport: sport, leaguePath: leaguePath,
                                            athleteId: athleteId, fallbackName: event.playerName
                                        )
                                    } label: {
                                        timelineRow(event)
                                    }
                                    .buttonStyle(PressOpacityButtonStyle())
                                } else {
                                    timelineRow(event)
                                }
                            }
                        } header: {
                            sectionHeader(L("matches.detail.timeline"))
                        }
                        .listRowBackground(AppTheme.surface)
                    }
                    if !detail.videos.isEmpty {
                        Section {
                            ForEach(detail.videos) { video in
                                videoRow(video)
                            }
                        } header: {
                            sectionHeader(L("matches.detail.highlights"))
                        }
                        .listRowBackground(AppTheme.surface)
                    }
                    if let article = detail.article {
                        // Build 85 (sweep): the summary's own
                        // recap/preview article — headline and
                        // description verbatim; the row opens
                        // the publisher page in the Safari
                        // sheet when the payload carries a link.
                        Section {
                            Button {
                                articleURL = article.webURL
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(article.headline)
                                        .font(AppTheme.fontCardTitle)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(3)
                                    if let summary = article.summary, !summary.isEmpty {
                                        Text(summary)
                                            .font(AppTheme.fontMetadata)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(4)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressOpacityButtonStyle())
                            .disabled(article.webURL == nil)
                        } header: {
                            sectionHeader(L("matches.detail.recap"))
                        }
                        .listRowBackground(AppTheme.surface)
                    }
                } else if selectedTab == .lineups {
                    Section {
                        NavigationLink {
                            LineupsView(sport: sport, leaguePath: leaguePath, sides: detail.lineups)
                        } label: {
                            Label(L("matches.lineups"), systemImage: "sportscourt")
                                .font(AppTheme.fontCardTitle)
                        }
                    }
                    .listRowBackground(AppTheme.surface)
                } else if selectedTab == .stats {
                    Section {
                        ForEach(detail.stats) { line in
                            statsRow(line)
                        }
                    } header: {
                        sectionHeader(L("matches.detail.team_stats"))
                    }
                    .listRowBackground(AppTheme.surface)
                } else if selectedTab == .boxScore {
                    // Build 84 (item 11): the per-player box
                    // score (NBA/NFL payloads only).
                    Section {
                        BoxScoreRows(
                            teams: detail.boxScore, sport: sport, leaguePath: leaguePath
                        )
                    } header: {
                        sectionHeader(L("matches.box_score"))
                    }
                    .listRowBackground(AppTheme.surface)
                } else if selectedTab == .plays {
                    // Build 84 (item 19): the play-by-play feed,
                    // newest first; live games prepend on the
                    // existing detail refresh.
                    Section {
                        PlayByPlayRows(plays: detail.playsFeed)
                    } header: {
                        sectionHeader(L("matches.detail.play_by_play"))
                    }
                    .listRowBackground(AppTheme.surface)
                } else if selectedTab == .h2h {
                    // Build 80 (item 15): head-to-head — the
                    // payload's own series summary + past
                    // meetings with real scores and dates.
                    if let h2h = detail.h2h {
                        Section {
                            if let title = h2h.title {
                                Text(title)
                                    .font(AppTheme.fontCardTitle)
                            }
                            if let summary = h2h.summary {
                                Text(summary)
                                    .font(AppTheme.fontMetadata)
                                    .foregroundStyle(AppTheme.accent)
                            }
                            ForEach(h2h.meetings) { meeting in
                                h2hRow(meeting)
                            }
                        } header: {
                            sectionHeader(L("matches.detail.h2h"))
                        }
                        .listRowBackground(AppTheme.surface)
                    }
                    // Build 87 (item 12): the deeper history —
                    // meetings from the two previous seasons
                    // (core team-event intersection), rendered
                    // only when it found meetings the summary
                    // didn't already show.
                    if !deepMeetings.isEmpty {
                        Section {
                            ForEach(deepMeetings) { meeting in
                                h2hRow(meeting)
                            }
                        } header: {
                            sectionHeader(L("matches.h2h.more"))
                        }
                        .listRowBackground(AppTheme.surface)
                    }
                } else if selectedTab == .commentary {
                    Section {
                        ForEach(detail.commentary) { entry in
                            commentaryRow(entry)
                        }
                    } header: {
                        sectionHeader(L("matches.detail.commentary"))
                    }
                    .listRowBackground(AppTheme.surface)
                }
            }

            if let detail, detail.isEmpty {
                Section {
                    Text(L("matches.detail.no_details"))
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.fontBadge)
            .foregroundStyle(AppTheme.accent)
    }

    // MARK: Header

    /// Build 65 (Scoreboard Pro): the header is a scoreboard —
    /// big crests flanking ONE huge center score, with the
    /// state (LIVE + minute / FT / kickoff) as a pill beneath.
    /// Same real header data as before, scoreboard composition.
    private var headerView: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                teamColumn(home)
                scoreColumn
                teamColumn(away)
            }
            statePill
            scorersRow
        }
        .padding(.vertical, 8)
    }

    /// Build 80 (item 16): the scorers under the score header,
    /// FotMob-style — each team's goalscorers listed under their
    /// own side, derived from the timeline's goal events (soccer
    /// only; NBA/NFL scoring plays are baskets/plays, not a
    /// scorer list). Renders nothing when there are no goals.
    @ViewBuilder
    private var scorersRow: some View {
        let homeGoals = goalEvents(for: home)
        let awayGoals = goalEvents(for: away)
        if !homeGoals.isEmpty || !awayGoals.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                scorerColumn(homeGoals, trailing: false)
                Spacer(minLength: 0)
                scorerColumn(awayGoals, trailing: true)
            }
        }
    }

    private func goalEvents(for side: MatchTeamSide?) -> [MatchTimelineEvent] {
        guard sport == .soccer, let detail, let name = side?.name else { return [] }
        return detail.timeline.filter { $0.kind == .goal && $0.teamName == name }
    }

    private func scorerColumn(_ goals: [MatchTimelineEvent], trailing: Bool) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 3) {
            ForEach(goals) { goal in
                HStack(spacing: 4) {
                    Image(systemName: "soccerball")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(scorerText(goal))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }

    private func scorerText(_ goal: MatchTimelineEvent) -> String {
        let name = goal.playerName ?? goal.title
        guard let minute = goal.minuteText, !minute.isEmpty else { return name }
        return "\(name) \(minute)"
    }

    @ViewBuilder
    private var scoreColumn: some View {
        VStack(spacing: 2) {
            if state != .upcoming, let homeScore = home?.score, let awayScore = away?.score {
                Text("\(homeScore) – \(awayScore)")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if let start = seedMatch?.startDate ?? detail?.header?.startDate {
                Text(MatchesView.kickoffText(start))
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
            } else {
                Text("– : –")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 118)
    }

    /// Build 85: baseball's state text is the payload's own
    /// status detail ("Top 5th" live, "Final/11" finished) —
    /// its displayClock is a dummy "0:00" and its period is
    /// the inning, so neither shipped label applies.
    private var baseballStatusText: String? {
        guard sport == .mlb else { return nil }
        let raw = seedMatch?.statusDetail ?? detail?.header?.statusDetail
        let trimmed = raw?.trimmingCharacters(in: .whitespaces)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    @ViewBuilder
    private var statePill: some View {
        switch state {
        case .live:
            HStack(spacing: 5) {
                Circle().fill(Color.white).frame(width: 6, height: 6)
                Text(L("matches.live"))
                    .font(AppTheme.fontBadge)
                if let baseballStatusText {
                    Text(baseballStatusText)
                        .font(AppTheme.fontBadge)
                        .monospacedDigit()
                } else if let clock = seedMatch?.displayClock ?? detail?.header?.displayClock {
                    Text(clock)
                        .font(AppTheme.fontBadge)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(AppTheme.live))
        case .finished:
            Text(baseballStatusText ?? L("matches.final"))
                .font(AppTheme.fontBadge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.secondary.opacity(0.16)))
        case .upcoming, .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func teamColumn(_ side: MatchTeamSide?) -> some View {
        // Item 12a: tapping a team opens its team page.
        if let side, let teamId = side.teamId, !teamId.isEmpty, let name = side.name {
            NavigationLink {
                TeamPageView(team: TeamRef(
                    id: teamId, sport: sport, leaguePath: leaguePath,
                    name: name, logoURL: side.logoURL
                ))
            } label: {
                teamColumnContent(side)
            }
            .buttonStyle(.plain)
        } else {
            teamColumnContent(side)
        }
    }

    private func teamColumnContent(_ side: MatchTeamSide?) -> some View {
        // Build 65 (Scoreboard Pro): bigger crest, name under it;
        // the SCORE itself lives once, huge, in the center
        // score column — no longer repeated per team.
        VStack(spacing: 8) {
            CachedImage(
                url: side?.logoURL,
                width: 64, height: 64,
                cornerRadius: 32,
                iconName: "shield"
            )
            Text(side?.name ?? "")
                .font(AppTheme.fontCardTitle)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Reminder (item 10e)

    @ViewBuilder
    private var reminderSection: some View {
        if let seedMatch, seedMatch.state == .upcoming,
           let start = seedMatch.startDate, start.addingTimeInterval(-15 * 60) > Date() {
            Section {
                Toggle(isOn: Binding(
                    get: { reminderOn },
                    set: { newValue in
                        // Build 66 (item 18): NO optimistic ON —
                        // reminderOn is set only from the CONFIRMED
                        // state re-read after the async
                        // authorization/scheduling completes; on
                        // denial or a past fire date it stays false.
                        Task {
                            _ = await MatchReminderService.shared.setReminder(
                                match: seedMatch, leaguePath: leaguePath,
                                sport: sport, enabled: newValue
                            )
                            reminderOn = MatchReminderService.shared.isScheduled(eventId: eventId)
                        }
                    }
                )) {
                    Label(L("matches.reminder.title"), systemImage: "bell")
                        .font(AppTheme.fontCardTitle)
                }
                .tint(AppTheme.accent)
            }
            .listRowBackground(AppTheme.surface)
        }
    }

    // MARK: Kickoff push (build 84, item 15)

    /// Any-match kickoff push: ON stores the fixture in
    /// MatchKickoffPushStore and re-uploads the watcher
    /// registration (the `matches` array rides additively);
    /// the watcher fires ONE push at kickoff and drops it.
    /// Separate from the local 15-minute reminder above.
    @ViewBuilder
    private var kickoffPushSection: some View {
        if let seedMatch, seedMatch.state == .upcoming {
            Section {
                Toggle(isOn: Binding(
                    get: { kickoffPushOn },
                    set: { newValue in
                        kickoffPushOn = newValue
                        MatchKickoffPushStore.shared.set(
                            match: seedMatch, leaguePath: leaguePath,
                            sport: sport, enabled: newValue
                        )
                        // Same calls FollowedTeamsStore makes
                        // (both synchronous): enabling asks for
                        // authorization + registers (the token
                        // callback re-uploads), and uploads at
                        // once so an existing token's new
                        // `matches` set reaches the watcher now;
                        // disabling just re-uploads.
                        if newValue {
                            PushNotificationService.shared.ensureAuthorizationAndRegister()
                        }
                        PushNotificationService.shared.uploadRegistration()
                    }
                )) {
                    Label(L("matches.kickoff_push"), systemImage: "bell.badge")
                        .font(AppTheme.fontCardTitle)
                }
                .tint(AppTheme.accent)
            }
            .listRowBackground(AppTheme.surface)
        }
    }

    // MARK: Header extras (build 84, items 18/20)

    /// The win-probability curve and the linescore grid, in
    /// their own section under the header — each rendered
    /// only when the summary publishes it (NBA/NFL quarters;
    /// build 85: baseball's innings + win probability too).
    @ViewBuilder
    private var headerExtrasSection: some View {
        if let detail,
           detail.winProbability.count >= 2
            || !detail.homeLinescores.isEmpty || !detail.awayLinescores.isEmpty {
            Section {
                if detail.winProbability.count >= 2 {
                    WinProbabilityChart(
                        values: detail.winProbability,
                        homeName: detail.header?.home.name
                    )
                }
                if !detail.homeLinescores.isEmpty || !detail.awayLinescores.isEmpty {
                    linescoreGrid(detail)
                }
            }
            .listRowBackground(AppTheme.surface)
        }
    }

    /// Q1 Q2 Q3 Q4 (OT…) T per team, from the header
    /// competitors' payload linescores; T is the header score.
    /// Build 85: baseball renders its own grid (inning numbers
    /// + R/H/E) — see `baseballLinescoreGrid`.
    @ViewBuilder
    private func linescoreGrid(_ detail: MatchDetail) -> some View {
        if sport == .mlb {
            baseballLinescoreGrid(detail)
        } else {
            quarterLinescoreGrid(detail)
        }
    }

    private func quarterLinescoreGrid(_ detail: MatchDetail) -> some View {
        let periods = max(detail.homeLinescores.count, detail.awayLinescores.count)
        return VStack(spacing: 6) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 128, height: 16)
                ForEach(0..<periods, id: \.self) { index in
                    Text(index < 4 ? "Q\(index + 1)" : "OT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                }
                Text("T")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
            }
            linescoreRow(
                side: detail.header?.home, values: detail.homeLinescores, periods: periods
            )
            linescoreRow(
                side: detail.header?.away, values: detail.awayLinescores, periods: periods
            )
        }
        .padding(.vertical, 2)
    }

    /// Build 85: the baseball linescore — one column per
    /// inning (the header competitors' payload linescores),
    /// then R (the header score) / H / E from the same
    /// competitors' payload fields. Nine-plus innings never
    /// fit a phone width, so the grid scrolls horizontally;
    /// a team whose game hasn't started has no linescores
    /// and the section simply doesn't render (the caller's
    /// own condition).
    private func baseballLinescoreGrid(_ detail: MatchDetail) -> some View {
        let innings = max(detail.homeLinescores.count, detail.awayLinescores.count)
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 112, height: 16)
                    ForEach(0..<innings, id: \.self) { index in
                        Text("\(index + 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                    }
                    ForEach(["R", "H", "E"], id: \.self) { label in
                        Text(label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                    }
                }
                baseballLinescoreRow(
                    side: detail.header?.home, values: detail.homeLinescores,
                    innings: innings, hits: detail.homeHits, errors: detail.homeErrors
                )
                baseballLinescoreRow(
                    side: detail.header?.away, values: detail.awayLinescores,
                    innings: innings, hits: detail.awayHits, errors: detail.awayErrors
                )
            }
            .padding(.vertical, 2)
        }
    }

    private func baseballLinescoreRow(
        side: MatchTeamSide?, values: [String], innings: Int,
        hits: String?, errors: String?
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                CachedImage(url: side?.logoURL, width: 20, height: 20, cornerRadius: 10, iconName: "shield")
                Text(side?.name ?? "")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(width: 112, alignment: .leading)
            ForEach(0..<innings, id: \.self) { index in
                Text(index < values.count ? values[index] : "–")
                    .font(.caption.monospacedDigit())
                    .frame(width: 24)
            }
            Text(side?.score ?? "–")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 28)
            Text(hits ?? "–")
                .font(.caption.monospacedDigit())
                .frame(width: 28)
            Text(errors ?? "–")
                .font(.caption.monospacedDigit())
                .frame(width: 28)
        }
    }

    private func linescoreRow(side: MatchTeamSide?, values: [String], periods: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                CachedImage(url: side?.logoURL, width: 20, height: 20, cornerRadius: 10, iconName: "shield")
                Text(side?.name ?? "")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(width: 128, alignment: .leading)
            ForEach(0..<periods, id: \.self) { index in
                Text(index < values.count ? values[index] : "–")
                    .font(.caption.monospacedDigit())
                    .frame(width: 32)
            }
            Text(side?.score ?? "–")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 32)
        }
    }

    // MARK: Watch on your channels (item 10c)

    @ViewBuilder
    private var watchSection: some View {
        if state == .live || state == .upcoming {
            Section {
                if !watchLoaded {
                    HStack(spacing: 10) {
                        ProgressView().tint(AppTheme.accent)
                        Text(L("matches.watch.title"))
                            .font(AppTheme.fontMetadata)
                            .foregroundStyle(.secondary)
                    }
                } else if watchHits.isEmpty && broadcastHits.isEmpty {
                    Text(L("matches.watch.none"))
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                } else {
                    // Build 84 (item 3b): broadcaster hits lead;
                    // the name-search hits follow, de-duplicated
                    // by channel name.
                    ForEach(mergedWatchHits) { hit in
                        Button { playWatchHit(hit) } label: {
                            HStack(spacing: 10) {
                                CachedImage(
                                    url: hit.channelLogoURL,
                                    width: 34, height: 34,
                                    cornerRadius: 8,
                                    iconName: "tv"
                                )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(hit.channelName)
                                        .font(AppTheme.fontCardTitle)
                                        .lineLimit(1)
                                    Text(hit.playlistName)
                                        .font(AppTheme.fontMetadata)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                }
            } header: {
                sectionHeader(L("matches.watch.title"))
            }
            .listRowBackground(AppTheme.surface)
        }
    }

    /// Build 84 (item 3b): the watch section's rows — the
    /// broadcaster-pattern hits first, then the shipped
    /// name-search hits that don't duplicate a channel.
    private var mergedWatchHits: [WatchChannelHit] {
        let broadcastNames = Set(broadcastHits.map { $0.channelName.lowercased() })
        return broadcastHits + watchHits.filter {
            !broadcastNames.contains($0.channelName.lowercased())
        }
    }

    /// Plays a watch hit through the SAME overlay path every
    /// other play in the app uses (item 6's fixed path).
    private func playWatchHit(_ hit: WatchChannelHit) {
        switch hit.streamRef {
        case .m3u(let url, let name, let logoURL):
            playerOverlay.present(playlistId: hit.playlistId) {
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
                    playerOverlay.present(playlistId: playlist.id) {
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

    // MARK: Follow + notification preferences (item 9)

    @ViewBuilder
    private var followSection: some View {
        let followable = [home, away].compactMap { $0 }.filter {
            ($0.teamId?.isEmpty == false) && ($0.name?.isEmpty == false)
        }
        if !followable.isEmpty {
            Section {
                ForEach(followable, id: \.teamId) { side in
                    followRows(for: side)
                }
            } header: {
                sectionHeader(L("matches.notify.title"))
            }
            .listRowBackground(AppTheme.surface)
        }
    }

    @ViewBuilder
    private func followRows(for side: MatchTeamSide) -> some View {
        let teamId = side.teamId ?? ""
        let name = side.name ?? ""
        let followed = followStore.team(sport: sport, leaguePath: leaguePath, teamId: teamId)
        HStack(spacing: 10) {
            CachedImage(url: side.logoURL, width: 26, height: 26, cornerRadius: 13, iconName: "shield")
            Text(name)
                .font(AppTheme.fontCardTitle)
                .lineLimit(1)
            Spacer()
            Button {
                if followed != nil {
                    followStore.unfollow(sport: sport, leaguePath: leaguePath, teamId: teamId)
                } else {
                    followStore.follow(sport: sport, leaguePath: leaguePath, teamId: teamId, teamName: name)
                }
            } label: {
                Text(followed != nil ? L("matches.following") : L("matches.follow"))
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(followed != nil ? .secondary : AppTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().stroke(followed != nil ? Color.secondary.opacity(0.4) : AppTheme.accent, lineWidth: 1)
                    )
            }
            .buttonStyle(PressOpacityButtonStyle())
        }
        if let followed {
            preferenceToggle(
                title: L("matches.notify.goals"),
                isOn: Binding(
                    get: { followed.notifyGoals },
                    set: { var copy = followed; copy.notifyGoals = $0; followStore.updatePreferences(copy) }
                )
            )
            preferenceToggle(
                title: L("matches.notify.kickoff"),
                isOn: Binding(
                    get: { followed.notifyKickoff },
                    set: { var copy = followed; copy.notifyKickoff = $0; followStore.updatePreferences(copy) }
                )
            )
            preferenceToggle(
                title: L("matches.notify.fulltime"),
                isOn: Binding(
                    get: { followed.notifyFullTime },
                    set: { var copy = followed; copy.notifyFullTime = $0; followStore.updatePreferences(copy) }
                )
            )
        }
    }

    private func preferenceToggle(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(AppTheme.fontMetadata)
        }
        .tint(AppTheme.accent)
    }

    // MARK: Leaders (item 8c)

    private func leadersRow(_ leaders: [MatchLeaderEntry]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(leaders) { entry in
                    // Build 84 (item 4): a leader card opens
                    // the player page.
                    if let athleteId = entry.athleteId {
                        NavigationLink {
                            PlayerPageView(
                                sport: sport, leaguePath: leaguePath,
                                athleteId: athleteId, fallbackName: entry.athleteName
                            )
                        } label: {
                            leaderCard(entry)
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    } else {
                        leaderCard(entry)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Build 88 (F5): the Top Performers card, rebuilt. The
    /// build-87 card squeezed everything into an 84 pt column:
    /// the name truncated to one line ("Erling Haala…"), the
    /// photo was the ESPN-only disc (a monogram whenever ESPN
    /// had no headshot), and the value/category lines clipped
    /// into each other. Now: the photo runs the FULL photo
    /// chain (PlayerPhotoDisc with the soccer fallback), the
    /// name gets its own two lines at card width — never
    /// truncated — and the stat value and its category each
    /// sit on their own line inside a fixed-width card, so
    /// nothing can overflow or collide.
    private func leaderCard(_ entry: MatchLeaderEntry) -> some View {
        VStack(spacing: 6) {
            PlayerPhotoDisc(
                url: entry.headshotURL, name: entry.athleteName, size: 52,
                fallback: leaderFallback(entry)
            )
            Text(entry.athleteName)
                .font(AppTheme.fontCardTitle)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 118, height: 38, alignment: .top)
            if let value = entry.valueText {
                Text(value)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(entry.category)
                .font(AppTheme.fontMetadata)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 118)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .frame(width: 138)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.cardBorderColor, lineWidth: 1)
        )
    }

    /// Build 88 (F5): the soccer fallback query for a leader
    /// card — the same verified chain the squad/leaders
    /// surfaces use; nil for every other sport (their ESPN
    /// photos are complete) and without an athlete id.
    private func leaderFallback(_ entry: MatchLeaderEntry) -> SoccerPhotoQuery? {
        guard sport == .soccer, let athleteId = entry.athleteId else { return nil }
        return SoccerPhotoQuery(
            athleteId: athleteId, name: entry.athleteName,
            teamName: entry.teamName, leaguePath: leaguePath,
            citizenship: nil, dateOfBirth: nil
        )
    }

    // MARK: Timeline (item 8b/8c)

    private func timelineRow(_ event: MatchTimelineEvent) -> some View {
        HStack(spacing: 10) {
            Text(event.minuteText ?? "")
                .font(AppTheme.fontMetadata.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(event.kind == .goal || event.kind == .scoring ? AppTheme.accent : .secondary)
                .frame(width: 44, alignment: .trailing)
            kindIcon(event.kind)
                .frame(width: 18)
            PlayerPhotoView(url: event.headshotURL, name: event.playerName, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(AppTheme.fontCardTitle)
                    .lineLimit(2)
                if let detail = event.detail {
                    Text(detail)
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func kindIcon(_ kind: MatchTimelineEvent.Kind) -> some View {
        switch kind {
        case .goal, .scoring:
            Image(systemName: "soccerball")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
        case .yellowCard:
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.yellow)
                .frame(width: 11, height: 15)
        case .redCard:
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.red)
                .frame(width: 11, height: 15)
        case .other:
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Stats

    private func statsRow(_ line: MatchTeamStatLine) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(line.homeValue ?? "–")
                    .font(AppTheme.fontCardTitle)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .leading)
                Spacer()
                Text(line.label)
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                Text(line.awayValue ?? "–")
                    .font(AppTheme.fontCardTitle)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
            // Build 80 (item 16): FotMob-style dual comparison
            // bars under the values, only when BOTH values are
            // numeric — each bar's share is value / (home + away);
            // the leading side takes the accent.
            if let home = Self.numericValue(line.homeValue),
               let away = Self.numericValue(line.awayValue),
               home + away > 0 {
                HStack(spacing: 4) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(AppTheme.overlayFill(0.12))
                            Capsule()
                                .fill(home >= away ? AppTheme.accent : AppTheme.overlayFill(0.35))
                                .frame(width: proxy.size.width * CGFloat(home / (home + away)))
                        }
                    }
                    .frame(height: 4)
                    GeometryReader { proxy in
                        ZStack(alignment: .trailing) {
                            Capsule().fill(AppTheme.overlayFill(0.12))
                            Capsule()
                                .fill(away > home ? AppTheme.accent : AppTheme.overlayFill(0.35))
                                .frame(width: proxy.size.width * CGFloat(away / (home + away)))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
    }

    /// A stat's numeric magnitude for the comparison bars:
    /// "58%" → 58, "47.5" → 47.5; nil for non-numeric values
    /// (records, streaks) — those rows stay text-only.
    private static func numericValue(_ text: String?) -> Double? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    // MARK: Facts / H2H / Commentary rows (build 80, items 15/16)

    /// Match-info rows: only the fields the payload provided.
    @ViewBuilder
    private func infoRows(_ info: MatchInfo) -> some View {
        if let league = info.leagueName {
            infoRow(label: L("matches.info.competition"), value: league)
        }
        if let venue = info.venueText {
            infoRow(label: L("matches.info.venue"), value: venue)
        }
        if let attendance = info.attendance {
            infoRow(label: L("matches.info.attendance"), value: attendance.formatted())
        }
        if let referee = info.refereeText {
            infoRow(label: L("matches.info.referee"), value: referee)
        }
        // Build 84 (item 16): ESPN's own pre-match predictor,
        // labelled as exactly that — the payload's win
        // projections for both teams, shown only pre-match
        // (finished/live summaries publish no predictor).
        if let homePct = info.predictorHome, let awayPct = info.predictorAway,
           let header = detail?.header {
            let homeName = header.home.name ?? ""
            let awayName = header.away.name ?? ""
            infoRow(
                label: L("matches.info.prediction"),
                value: "\(homeName) \(homePct)% · \(awayName) \(awayPct)%"
            )
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(AppTheme.fontMetadata)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(AppTheme.fontMetadata)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    /// An official highlight/analysis video (item 15). Build 81
    /// (item 3, owner): tapping plays the video IN-APP — the
    /// payload's direct MP4 in an AVPlayer sheet — never out to
    /// ESPN's website.
    private func videoRow(_ video: MatchVideo) -> some View {
        Button {
            playingHighlight = video
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    CachedImage(
                        url: video.thumbnailURL,
                        width: 96, height: 54,
                        cornerRadius: 8,
                        contentMode: .fill,
                        iconName: "play.rectangle"
                    )
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.headline)
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let duration = video.durationSeconds, duration > 0 {
                        Text("\(duration / 60):\(String(format: "%02d", duration % 60))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    /// One past meeting (item 15): date, then the two teams with
    /// the real score between them.
    private func h2hRow(_ meeting: MatchH2HMeeting) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let date = meeting.date {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(meeting.homeName ?? "")
                    .font(AppTheme.fontMetadata)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(meeting.homeScore ?? "–") – \(meeting.awayScore ?? "–")")
                    .font(AppTheme.fontCardTitle)
                    .monospacedDigit()
                    .fixedSize()
                Text(meeting.awayName ?? "")
                    .font(AppTheme.fontMetadata)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// One commentary entry: the payload's minute + text.
    private func commentaryRow(_ entry: MatchCommentaryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.minuteText ?? "")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.accent)
                .monospacedDigit()
                .frame(width: 34, alignment: .leading)
            Text(entry.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}

/// Item 8c: a player's photo when the feed provides one; a clean
/// initials disc when it doesn't (or the load fails). Never a
/// broken-image box.
private struct PlayerPhotoView: View {
    let url: URL?
    let name: String?
    let size: CGFloat
    @State private var loadFailed = false

    private var initials: String {
        let parts = (name ?? "").split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0) }
        return letters.isEmpty ? "?" : letters.joined()
    }

    var body: some View {
        Group {
            if let url, !loadFailed {
                CachedImage(
                    url: url,
                    width: size, height: size,
                    cornerRadius: size / 2,
                    contentMode: .fill,
                    iconName: "person.fill",
                    onLoadFailed: { loadFailed = true }
                )
            } else {
                ZStack {
                    Circle().fill(AppTheme.elevated)
                    Text(initials)
                        .font(.system(size: size * 0.36, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Build 81 (item 3): the in-app highlight player — a plain
/// AVKit VideoPlayer over the payload's direct MP4, presented
/// full-screen from the Facts tab's Highlights rows. Autoplays
/// on appear, pauses and releases on dismiss; the standard
/// AVKit chrome (its own close via the X button) and nothing
/// else — no custom overlays, no web view.
struct HighlightPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
        .onAppear {
            let avPlayer = AVPlayer(url: url)
            player = avPlayer
            avPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
