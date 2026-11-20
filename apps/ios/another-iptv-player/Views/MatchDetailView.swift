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
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    private enum DetailTab: Hashable {
        case facts, lineups, stats, h2h, commentary

        var title: String {
            switch self {
            case .facts: return L("matches.detail.facts")
            case .lineups: return L("matches.lineups")
            case .stats: return L("matches.stats")
            case .h2h: return L("matches.detail.h2h")
            case .commentary: return L("matches.detail.commentary")
            }
        }
    }

    private var hasTimeline: Bool { !(detail?.timeline.isEmpty ?? true) }
    private var hasLineups: Bool { !(detail?.lineups.isEmpty ?? true) }
    private var hasStats: Bool { !(detail?.stats.isEmpty ?? true) }
    /// Facts exists when any of its three groups has real data:
    /// the timeline, the payload's match info, or its videos.
    private var hasFacts: Bool {
        guard let detail else { return false }
        return hasTimeline || detail.info != nil || !detail.videos.isEmpty
    }
    private var hasH2H: Bool { !(detail?.h2h?.meetings.isEmpty ?? true) }
    private var hasCommentary: Bool { !(detail?.commentary.isEmpty ?? true) }

    /// The tabs that exist for THIS match, in display order.
    private var availableTabs: [DetailTab] {
        var tabs: [DetailTab] = []
        if hasFacts { tabs.append(.facts) }
        if hasLineups { tabs.append(.lineups) }
        if hasStats { tabs.append(.stats) }
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
    }

    private func load() async {
        reminderOn = MatchReminderService.shared.isScheduled(eventId: eventId)
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

            watchSection

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
                                timelineRow(event)
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

    @ViewBuilder
    private var statePill: some View {
        switch state {
        case .live:
            HStack(spacing: 5) {
                Circle().fill(Color.white).frame(width: 6, height: 6)
                Text(L("matches.live"))
                    .font(AppTheme.fontBadge)
                if let clock = seedMatch?.displayClock ?? detail?.header?.displayClock {
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
            Text(L("matches.final"))
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
                } else if watchHits.isEmpty {
                    Text(L("matches.watch.none"))
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(watchHits) { hit in
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
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                sectionHeader(L("matches.watch.title"))
            }
            .listRowBackground(AppTheme.surface)
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
            .buttonStyle(.plain)
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
                    VStack(spacing: 5) {
                        PlayerPhotoView(url: entry.headshotURL, name: entry.athleteName, size: 46)
                        Text(entry.athleteName)
                            .font(AppTheme.fontBadge)
                            .lineLimit(1)
                            .frame(width: 84)
                        if let value = entry.valueText {
                            Text(value)
                                .font(AppTheme.fontCardTitle)
                                .foregroundStyle(AppTheme.accent)
                                .monospacedDigit()
                        }
                        Text(entry.category)
                            .font(AppTheme.fontMetadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 84)
                    }
                }
            }
            .padding(.vertical, 4)
        }
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

    /// An official highlight/analysis video (item 15): thumbnail,
    /// the payload's own headline, duration; opens the payload's
    /// web link (the same Link path trailers use).
    private func videoRow(_ video: MatchVideo) -> some View {
        Link(destination: video.url) {
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
