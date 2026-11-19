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
    /// Build 65 (Match detail style 1 'Scoreboard Pro'): the
    /// detail sections below the scoreboard are TABBED —
    /// Timeline / Lineups / Stats — each tab existing ONLY when
    /// the feed actually carries that data. (No H2H tab: the
    /// ESPN summary payload has no head-to-head data, and an
    /// empty invented tab would be fake UI.)
    @State private var detailTab = 0
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    private enum DetailTab: Hashable {
        case timeline, lineups, stats

        var title: String {
            switch self {
            case .timeline: return L("matches.detail.timeline")
            case .lineups: return L("matches.lineups")
            case .stats: return L("matches.stats")
            }
        }
    }

    private var hasTimeline: Bool { !(detail?.timeline.isEmpty ?? true) }
    private var hasLineups: Bool { !(detail?.lineups.isEmpty ?? true) }
    private var hasStats: Bool { !(detail?.stats.isEmpty ?? true) }

    /// The tabs that exist for THIS match, in display order.
    private var availableTabs: [DetailTab] {
        var tabs: [DetailTab] = []
        if hasTimeline { tabs.append(.timeline) }
        if hasLineups { tabs.append(.lineups) }
        if hasStats { tabs.append(.stats) }
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

                if selectedTab == .timeline {
                    Section {
                        ForEach(detail.timeline) { event in
                            timelineRow(event)
                        }
                    }
                    .listRowBackground(AppTheme.surface)
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
        }
        .padding(.vertical, 8)
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
                                    Text(hit.programmeTitle ?? hit.playlistName)
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

    // MARK: Leaders (item 8c; build 67 F8/S9 Glass Cards)
    //
    // Owner pick (performers styles v1, panel 1): TWO frosted
    // glass cards side by side — one per team — each with the
    // team's top performer's big photo, name, and that athlete's
    // REAL leader stats stacked vertically inside the card
    // (category + value, exactly as the payload labels them).
    // Further athletes of the same team follow as compact rows
    // inside the same card. Nothing scrolls horizontally and
    // nothing can run off the screen edge (the build-66 overflow
    // the owner screenshotted): every text element is width-bound
    // by the card, stats stack, and names truncate at the tail
    // only after layout priority is exhausted.

    private func leadersRow(_ leaders: [MatchLeaderEntry]) -> some View {
        // Group by team, preserving payload order (home group
        // first as the feed emits it). Entries without a team
        // name form their own trailing group rather than being
        // dropped.
        var groups: [(team: String?, entries: [MatchLeaderEntry])] = []
        for entry in leaders {
            if let index = groups.firstIndex(where: { $0.team == entry.teamName }) {
                groups[index].entries.append(entry)
            } else {
                groups.append((team: entry.teamName, entries: [entry]))
            }
        }
        return HStack(alignment: .top, spacing: 10) {
            ForEach(Array(groups.prefix(2).enumerated()), id: \.offset) { _, group in
                performerCard(team: group.team, entries: group.entries)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
    }

    private func performerCard(team: String?, entries: [MatchLeaderEntry]) -> some View {
        // The card's headline athlete is the team's first leader
        // entry; their stat lines are every leader entry FOR THAT
        // ATHLETE (real categories only). Other athletes of the
        // team keep their own primary entry as a compact row.
        let headline = entries.first
        let headlineStats = entries.filter { $0.athleteName == headline?.athleteName }
        var seen = Set<String>()
        let others = entries.filter { entry in
            guard entry.athleteName != headline?.athleteName else { return false }
            return seen.insert(entry.athleteName).inserted
        }
        return VStack(spacing: 8) {
            if let team, !team.isEmpty {
                Text(team)
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(AppTheme.accent)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            if let headline {
                PlayerPhotoView(url: headline.headshotURL, name: headline.athleteName, size: 72)
                Text(headline.athleteName)
                    .font(AppTheme.fontCardTitle.weight(.bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .layoutPriority(1)
                VStack(spacing: 5) {
                    ForEach(headlineStats) { stat in
                        HStack(spacing: 6) {
                            Text(stat.category)
                                .font(AppTheme.fontMetadata)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            if let value = stat.valueText {
                                Text(value)
                                    .font(AppTheme.fontCardTitle)
                                    .foregroundStyle(AppTheme.accent)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if !others.isEmpty {
                Divider().overlay(AppTheme.cardBorderColor)
                ForEach(others.prefix(2)) { entry in
                    HStack(spacing: 7) {
                        PlayerPhotoView(url: entry.headshotURL, name: entry.athleteName, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.athleteName)
                                .font(AppTheme.fontBadge)
                                .lineLimit(1)
                            Text(entry.category)
                                .font(AppTheme.fontMetadata)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 2)
                        if let value = entry.valueText {
                            Text(value)
                                .font(AppTheme.fontMetadata.weight(.bold))
                                .foregroundStyle(AppTheme.accent)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(AppTheme.elevated.opacity(0.55))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.cardBorderColor, lineWidth: 1)
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
