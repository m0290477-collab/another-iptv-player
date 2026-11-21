import SwiftUI

// MARK: - Build 87 views (items 1–13)
//
// The build-87 surfaces: the NHL section (item 1, the NHL
// official API behind NHLService), Formula 1 (item 2, Jolpica),
// tennis / golf / UFC (items 4–5, ESPN), the player compare
// (item 6), the sports calendar (item 7), the live wall
// (item 8), cross-league top scorers (item 11) and the
// per-section highlights page (item 13). Every surface uses
// the Matches design language — the same list style, section
// headers, row shapes, press styles and motion tokens as the
// shipped sections — and renders ONLY what its verified
// payload carries.

/// The MatchesExtras section-header treatment, shared by the
/// build-87 pages (the original is file-private there).
private func b87SectionHeader(_ text: String) -> some View {
    Text(text)
        .font(AppTheme.fontBadge)
        .foregroundStyle(AppTheme.accent)
}

// MARK: - NHL standings (item 1)

/// The FotMob-style table for hockey: division groups from
/// the NHL API's standings/now, Short/Full column modes like
/// the ESPN tables. Column labels come from the entries' own
/// stat labels (the NHL standard abbreviations NHLService
/// attached to its own fields — the API publishes no label
/// fields). A row opens the club page.
struct NHLStandingsView: View {
    var leagueName: String?

    @State private var groups: [StandingGroup] = []
    @State private var stamp: Date?
    @State private var loaded = false
    @State private var fullMode = false

    private struct Column: Identifiable {
        let key: String
        let width: CGFloat
        let bold: Bool
        var id: String { key }
    }

    private var columns: [Column] {
        fullMode
            ? [Column(key: "gamesPlayed", width: 30, bold: false),
               Column(key: "wins", width: 26, bold: false),
               Column(key: "losses", width: 26, bold: false),
               Column(key: "otLosses", width: 28, bold: false),
               Column(key: "pointsFor", width: 32, bold: false),
               Column(key: "pointsAgainst", width: 32, bold: false),
               Column(key: "pointDifferential", width: 38, bold: false),
               // Build 90 (SP18): Home / Road / Last-10 —
               // composed records ("6-0-2") need the width.
               Column(key: "homeRecord", width: 52, bold: false),
               Column(key: "roadRecord", width: 52, bold: false),
               Column(key: "lastTen", width: 52, bold: false),
               Column(key: "streak", width: 36, bold: false),
               Column(key: "winPercent", width: 42, bold: false),
               Column(key: "points", width: 34, bold: true)]
            : [Column(key: "gamesPlayed", width: 30, bold: false),
               Column(key: "wins", width: 28, bold: false),
               Column(key: "losses", width: 28, bold: false),
               Column(key: "otLosses", width: 30, bold: false),
               Column(key: "points", width: 36, bold: true)]
    }

    private func visibleColumns(for group: StandingGroup) -> [Column] {
        columns.filter { column in
            group.entries.contains { $0.stats[column.key] != nil }
        }
    }

    var body: some View {
        List {
            if loaded && groups.isEmpty {
                Text(L("matches.empty"))
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .listRowBackground(AppTheme.surface)
            }
            if !groups.isEmpty {
                Section {
                    Picker(L("matches.standings"), selection: $fullMode) {
                        Text(L("matches.table_short")).tag(false)
                        Text(L("matches.table_full")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    if let stamp {
                        LastUpdatedStamp(date: stamp)
                    }
                }
                .listRowBackground(AppTheme.surface)
                Section {
                    NavigationLink {
                        NHLLeadersView()
                    } label: {
                        Label(L("matches.leaders"), systemImage: "list.number")
                            .font(AppTheme.fontCardTitle)
                    }
                    .buttonStyle(PressOpacityButtonStyle())
                    // Build 90 (SP16): injuries + transactions
                    // — ESPN's hockey payloads verified live
                    // 2026-11-21 in the exact shapes the shipped
                    // services decode (injuries 200, 30 team
                    // groups; transactions 200, 25 entries), so
                    // the league's links mirror the ESPN tables.
                    NavigationLink {
                        LeagueInjuriesView(
                            sport: .nhl, leaguePath: "hockey/nhl", leagueName: leagueName
                        )
                    } label: {
                        Label(L("matches.injuries"), systemImage: "cross.case")
                            .font(AppTheme.fontCardTitle)
                    }
                    .buttonStyle(PressOpacityButtonStyle())
                    NavigationLink {
                        LeagueTransactionsView(leaguePath: "hockey/nhl", leagueName: leagueName)
                    } label: {
                        Label(L("matches.transactions"), systemImage: "arrow.left.arrow.right")
                            .font(AppTheme.fontCardTitle)
                    }
                    .buttonStyle(PressOpacityButtonStyle())
                }
                .listRowBackground(AppTheme.surface)
            }
            ForEach(groups) { group in
                Section {
                    headerRow(group: group)
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        NavigationLink {
                            NHLTeamPageView(
                                abbrev: entry.teamId ?? "",
                                name: entry.teamName,
                                logoURL: entry.logoURL
                            )
                        } label: {
                            standingRow(index: index, entry: entry, columns: visibleColumns(for: group))
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                        .disabled(entry.teamId == nil)
                    }
                } header: {
                    if !group.name.isEmpty { b87SectionHeader(group.name) }
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(leagueName ?? L("matches.standings"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if !loaded { BrandedLoader() } }
        .animation(Motion.animate(Motion.chipSwap), value: fullMode)
        .task {
            let result = await NHLService.standings()
            groups = result.groups
            stamp = result.stamp
            loaded = true
        }
    }

    private func headerRow(group: StandingGroup) -> some View {
        HStack(spacing: 6) {
            Text("#")
                .frame(width: 22, alignment: .trailing)
            Text(L("matches.team_label"))
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(visibleColumns(for: group)) { column in
                Text(group.entries.first(where: { $0.statLabels[column.key] != nil })?.statLabels[column.key] ?? "")
                    .frame(width: column.width)
            }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
    }

    private func standingRow(index: Int, entry: StandingEntry, columns: [Column]) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(AppTheme.fontMetadata.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)
            CachedImage(url: entry.logoURL, width: 24, height: 24, cornerRadius: 12, iconName: "shield")
            Text(entry.teamName)
                .font(AppTheme.fontTeamName)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { column in
                Text(entry.stats[column.key] ?? "–")
                    .font(AppTheme.fontMetadata.weight(column.bold ? .bold : .regular))
                    .monospacedDigit()
                    .fixedSize()
                    .frame(width: column.width)
            }
        }
    }
}

// MARK: - NHL leaders (item 1)

/// Skater + goalie leader categories from the NHL stats API —
/// the LeadersView shape, rows opening the player page.
struct NHLLeadersView: View {
    @State private var categories: [LeaderCategory84] = []
    @State private var rowsByCategory: [String: [LeaderRow84]] = [:]
    @State private var selectedCategory: String?
    @State private var didLoad = false

    private var rows: [LeaderRow84] {
        selectedCategory.flatMap { rowsByCategory[$0] } ?? []
    }

    var body: some View {
        List {
            if categories.count > 1 {
                Section {
                    Picker(L("matches.leaders"), selection: categorySelection) {
                        ForEach(categories) { category in
                            Text(category.displayName).tag(category.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
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
                                sport: .nhl, leaguePath: "nhl",
                                athleteId: row.athleteId, fallbackName: row.name
                            )
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .trailing)
                                PlayerPhotoDisc(url: row.headshotURL, name: row.name, size: 36)
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
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L("matches.leaders"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let result = await NHLService.leaders()
            categories = result.categories
            rowsByCategory = result.rows
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
}

// MARK: - NHL team page (item 1)

/// The club page for hockey: header + record (composed from
/// the standings entry's own W–L–OT stats), follow, the
/// TheSportsDB stadium/about (item 9, "Ice Hockey"), club
/// leaders, the full-season fixtures/results and the roster
/// with official headshots — the TeamPageView arrangement.
struct NHLTeamPageView: View {
    let abbrev: String
    let name: String
    let logoURL: URL?

    @State private var recordText: String?
    @State private var fixtures: [MatchEvent] = []
    @State private var squad: [SquadPlayer] = []
    @State private var clubLeaders: [(category: String, rows: [LeaderRow84])] = []
    @State private var teamDetails: SportsDBService.TeamDetails?
    @State private var loaded = false
    @ObservedObject private var followStore = FollowedTeamsStore.shared

    private var teamRef: TeamRef {
        TeamRef(id: abbrev, sport: .nhl, leaguePath: "nhl", name: name, logoURL: logoURL)
    }

    private var isFollowed: Bool {
        followStore.team(sport: .nhl, leaguePath: "nhl", teamId: abbrev) != nil
    }

    private var upcoming: [MatchEvent] {
        fixtures.filter { $0.state == .upcoming || $0.state == .live }
    }
    private var results: [MatchEvent] {
        Array(fixtures.filter { $0.state == .finished }.reversed())
    }
    /// The next upcoming fixture (for the SP18 countdown).
    private var nextFixture: MatchEvent? {
        upcoming.filter { $0.state == .upcoming }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            .first
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    CachedImage(url: logoURL, width: 52, height: 52, cornerRadius: 26, iconName: "shield")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(AppTheme.fontSectionTitle)
                            .lineLimit(2)
                        if let recordText {
                            Text(recordText)
                                .font(AppTheme.fontMetadata.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Spacer()
                    followButton
                }
                // Build 90 (SP18): the followed-team countdown
                // the ESPN team page has had since build 84 —
                // this page held the same fixtures + follow
                // state and simply never rendered it.
                if isFollowed, let next = nextFixture, let start = next.startDate {
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .foregroundStyle(AppTheme.accent)
                        Text(next.home.teamId == abbrev
                             ? "vs \(next.away.name ?? "")"
                             : "@ \(next.home.name ?? "")")
                            .font(AppTheme.fontMetadata)
                            .lineLimit(1)
                        Spacer()
                        CountdownText(target: start)
                            .font(AppTheme.fontMetadata.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                // Build 90 (SP18): the Compare entry — the
                // compare screen's .nhl key list existed since
                // build 87 with no navigation path reaching it.
                NavigationLink {
                    CompareTeamsView(team: teamRef)
                } label: {
                    Label(L("matches.compare"), systemImage: "arrow.left.arrow.right")
                        .font(AppTheme.fontCardTitle)
                }
                .buttonStyle(PressOpacityButtonStyle())
                if let stadium = teamDetails?.stadium {
                    HStack(spacing: 8) {
                        Image(systemName: "sportscourt")
                            .foregroundStyle(AppTheme.accent)
                        Text(stadium)
                            .font(AppTheme.fontCardTitle)
                            .lineLimit(1)
                        Spacer()
                        Text(L("matches.team.stadium"))
                            .font(AppTheme.fontMetadata)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(AppTheme.surface)

            if let about = teamDetails?.descriptionText {
                Section {
                    Text(about)
                        .font(.subheadline)
                } header: { b87SectionHeader(L("matches.team.about")) }
                .listRowBackground(AppTheme.surface)
            }

            if !upcoming.isEmpty {
                Section {
                    ForEach(upcoming) { match in
                        NavigationLink {
                            MatchDetailView(sport: .nhl, leaguePath: "nhl", match: match)
                        } label: {
                            MatchRowView(match: match, isStale: false, sport: .nhl)
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                } header: { b87SectionHeader(L("matches.team.next")) }
                .listRowBackground(AppTheme.surface)
            }
            if !results.isEmpty {
                Section {
                    ForEach(results) { match in
                        NavigationLink {
                            MatchDetailView(sport: .nhl, leaguePath: "nhl", match: match)
                        } label: {
                            MatchRowView(match: match, isStale: false, sport: .nhl)
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                } header: { b87SectionHeader(L("matches.team.recent")) }
                .listRowBackground(AppTheme.surface)
            }

            ForEach(Array(clubLeaders.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group.rows) { row in
                        NavigationLink {
                            PlayerPageView(
                                sport: .nhl, leaguePath: "nhl",
                                athleteId: row.athleteId, fallbackName: row.name
                            )
                        } label: {
                            HStack(spacing: 10) {
                                PlayerPhotoDisc(url: row.headshotURL, name: row.name, size: 30)
                                Text(row.name)
                                    .font(AppTheme.fontCardTitle)
                                    .lineLimit(1)
                                Spacer()
                                Text(row.valueText)
                                    .font(AppTheme.fontMetadata.weight(.semibold))
                                    .foregroundStyle(AppTheme.accent)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                } header: { b87SectionHeader("\(L("matches.team.leaders")) · \(group.category)") }
                .listRowBackground(AppTheme.surface)
            }

            if !squad.isEmpty {
                Section {
                    ForEach(squad) { player in
                        if let athleteId = player.athleteId {
                            NavigationLink {
                                PlayerPageView(
                                    sport: .nhl, leaguePath: "nhl",
                                    athleteId: athleteId, fallbackName: player.name
                                )
                            } label: {
                                squadRow(player)
                            }
                            .buttonStyle(PressOpacityButtonStyle())
                        } else {
                            squadRow(player)
                        }
                    }
                } header: { b87SectionHeader(L("matches.team.squad")) }
                .listRowBackground(AppTheme.surface)
            }

            if loaded && fixtures.isEmpty && squad.isEmpty {
                Text(L("matches.empty"))
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if !loaded { BrandedLoader() } }
        .task {
            async let schedule = NHLService.clubSchedule(abbrev: abbrev)
            async let roster = NHLService.roster(abbrev: abbrev)
            fixtures = await schedule
            squad = await roster
            // Build 88 (F13): the same page-open photo warm-up
            // as the ESPN team pages — the roster's official
            // headshots prefetch through the shared prefetcher
            // at the discs' exact render parameters, so they
            // are cache hits when the rows render.
            ListImagePrefetch.start(
                urls: squad.compactMap { player -> URL? in player.headshotURL },
                width: 32, height: 32, contentMode: .fill, loadProfile: .standard
            )
            loaded = true
            clubLeaders = await NHLService.clubLeaders(abbrev: abbrev)
            let standings = await NHLService.standings()
            if let entry = standings.groups.flatMap({ $0.entries })
                .first(where: { $0.teamId == abbrev }) {
                if let wins = entry.stats["wins"], let losses = entry.stats["losses"] {
                    if let ot = entry.stats["otLosses"] {
                        recordText = "\(wins)–\(losses)–\(ot)"
                    } else {
                        recordText = "\(wins)–\(losses)"
                    }
                }
            }
            teamDetails = await SportsDBService.teamDetails(
                teamName: name, expectedSport: "Ice Hockey"
            )
        }
    }

    private func squadRow(_ player: SquadPlayer) -> some View {
        HStack(spacing: 10) {
            PlayerPhotoDisc(url: player.headshotURL, name: player.name, size: 32)
            Text(player.name)
                .font(AppTheme.fontCardTitle)
                .lineLimit(1)
            Spacer()
            if let position = player.positionName {
                Text(position)
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var followButton: some View {
        let followed = isFollowed
        return Button {
            if followed {
                followStore.unfollow(sport: .nhl, leaguePath: "nhl", teamId: abbrev)
            } else {
                followStore.follow(sport: .nhl, leaguePath: "nhl", teamId: abbrev, teamName: name)
            }
        } label: {
            Text(followed ? L("matches.following") : L("matches.follow"))
                .font(AppTheme.fontBadge)
                .foregroundStyle(followed ? .secondary : AppTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().stroke(followed ? Color.secondary.opacity(0.4) : AppTheme.accent, lineWidth: 1))
        }
        .buttonStyle(PressOpacityButtonStyle())
    }
}

// MARK: - NHL match page (item 1)

/// The game page for hockey: the seed header, Watch, the
/// local reminder + watcher kickoff toggles (the exact
/// MatchDetailView contracts, sport .nhl), the venue, the
/// scoring by period (scorer headshot, assists, strength,
/// time, running score), the payload's three stars, and the
/// per-team skater lines (G/A/P/TOI — hockey's standard
/// abbreviations for the payload's own fields; the NHL API
/// publishes no column labels).
struct NHLMatchDetailView: View {
    let leaguePath: String
    let eventId: String
    let seedMatch: MatchEvent?

    @State private var detail: NHLService.GameDetail?
    @State private var plays: [NHLService.PlayItem] = []
    @State private var didLoad = false
    @State private var kickoffPushOn = false
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    /// Build 90 (SP19): the match the header / Watch /
    /// reminder sections render from — the seed when the page
    /// was opened from a list, otherwise the match the
    /// landing payload itself carries. Build 87 gated all
    /// three sections on the seed, so a push tap (seedless)
    /// landed on a page with no header at all.
    private var effectiveMatch: MatchEvent? {
        seedMatch ?? detail?.matchEvent
    }

    var body: some View {
        List {
            if let effectiveMatch {
                Section {
                    headerView(effectiveMatch)
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    WatchPlayButton(sport: .nhl, leaguePath: leaguePath, match: effectiveMatch)
                }
                .listRowBackground(AppTheme.surface)

                kickoffPushSection(effectiveMatch)
            }

            if let detail {
                if let venue = detail.venue {
                    Section {
                        infoRow(L("matches.info.venue"), venue)
                    } header: { b87SectionHeader(L("matches.detail.match_info")) }
                    .listRowBackground(AppTheme.surface)
                }
                ForEach(Array(detail.scoring.enumerated()), id: \.offset) { _, period in
                    Section {
                        ForEach(period.goals) { goal in
                            // Build 90 (SP18): scorer rows open
                            // the player page, like every ESPN
                            // box-score row (build 87 left them
                            // plain, though the pages exist).
                            if let scorerId = goal.scorerId {
                                NavigationLink {
                                    PlayerPageView(
                                        sport: .nhl, leaguePath: leaguePath,
                                        athleteId: scorerId, fallbackName: goal.scorerName
                                    )
                                } label: {
                                    goalRow(goal)
                                }
                                .buttonStyle(PressOpacityButtonStyle())
                            } else {
                                goalRow(goal)
                            }
                        }
                    } header: { b87SectionHeader(period.period) }
                    .listRowBackground(AppTheme.surface)
                }
                if !detail.stars.isEmpty {
                    Section {
                        ForEach(detail.stars) { star in
                            NavigationLink {
                                PlayerPageView(
                                    sport: .nhl, leaguePath: leaguePath,
                                    athleteId: star.id, fallbackName: star.name
                                )
                            } label: {
                                HStack(spacing: 10) {
                                    PlayerPhotoDisc(url: star.headshotURL, name: star.name, size: 34)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(star.name)
                                            .font(AppTheme.fontCardTitle)
                                            .lineLimit(1)
                                        Text(star.lineText)
                                            .font(AppTheme.fontMetadata)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(String(repeating: "★", count: star.star))
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(AppTheme.ratingGold)
                                }
                            }
                            .buttonStyle(PressOpacityButtonStyle())
                        }
                    } header: { b87SectionHeader(L("matches.detail.top_performers")) }
                    .listRowBackground(AppTheme.surface)
                }
                ForEach(Array(detail.skaterLines.enumerated()), id: \.offset) { index, group in
                    Section {
                        skaterHeader
                        ForEach(group.lines) { line in
                            NavigationLink {
                                PlayerPageView(
                                    sport: .nhl, leaguePath: leaguePath,
                                    athleteId: line.id, fallbackName: line.name
                                )
                            } label: {
                                skaterRow(line)
                            }
                            .buttonStyle(PressOpacityButtonStyle())
                        }
                    } header: {
                        b87SectionHeader(teamLabel(for: index) ?? L("matches.box_score"))
                    }
                    .listRowBackground(AppTheme.surface)
                }
                // Build 90 (SP13): the goalie lines — under
                // each team's skaters, same away/home order.
                ForEach(Array(detail.goalieLines.enumerated()), id: \.offset) { index, group in
                    Section {
                        goalieHeader
                        ForEach(group.lines) { line in
                            NavigationLink {
                                PlayerPageView(
                                    sport: .nhl, leaguePath: leaguePath,
                                    athleteId: line.id, fallbackName: line.name
                                )
                            } label: {
                                goalieRow(line)
                            }
                            .buttonStyle(PressOpacityButtonStyle())
                        }
                    } header: {
                        b87SectionHeader(
                            (teamLabel(for: index) ?? L("matches.box_score"))
                                + " · " + L("matches.detail.goalies")
                        )
                    }
                    .listRowBackground(AppTheme.surface)
                }
                // Build 90 (SP18): the play-by-play feed.
                if !plays.isEmpty {
                    Section {
                        ForEach(plays) { play in
                            playRow(play)
                        }
                    } header: { b87SectionHeader(L("matches.detail.play_by_play")) }
                    .listRowBackground(AppTheme.surface)
                }
            } else if didLoad {
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
        .cinematicBackground()
        .navigationTitle(L("matches.title"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if !didLoad { BrandedLoader() } }
        // Build 90 (SP21, NHL half): pull-to-refresh, and the
        // existing 60-second cadence re-loads the page while
        // the match is live (build 87 loaded once, forever).
        .refreshable { await load() }
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                guard effectiveMatch?.state == .live else { break }
                await load()
            }
        }
    }

    private func load() async {
        // Build 90 (SP22, NHL half): both reminder stores
        // prune their past matches on the way in — the same
        // contract the ESPN match page carries (armed
        // fixtures whose kickoff has passed stop re-uploading
        // to the watcher and stop reporting as scheduled).
        MatchKickoffPushStore.shared.prunePast()
        await MatchReminderService.shared.prunePast()
        kickoffPushOn = MatchKickoffPushStore.shared.contains(eventId: eventId)
        async let detailFetch = NHLService.gameDetail(eventId: eventId)
        async let playsFetch = NHLService.playByPlay(eventId: eventId)
        detail = await detailFetch
        plays = await playsFetch
        didLoad = true
    }

    /// Skater-line groups arrive away-first, home-second (the
    /// service's documented order); the effective match names
    /// them (the seed, or the SP19 landing-rebuilt match).
    private func teamLabel(for index: Int) -> String? {
        guard let effectiveMatch else { return nil }
        return index == 0 ? effectiveMatch.away.name : effectiveMatch.home.name
    }

    private func headerView(_ match: MatchEvent) -> some View {
        HStack(spacing: 10) {
            teamSide(match.home)
            VStack(spacing: 2) {
                Text(scoreLine(match))
                    .font(.title3.weight(.black))
                    .monospacedDigit()
                    .fixedSize()
                Text(stateText(match))
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(match.state == .live ? AppTheme.live : .secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 64)
            teamSide(match.away)
        }
        .padding(.vertical, 6)
    }

    private func teamSide(_ side: MatchTeamSide) -> some View {
        VStack(spacing: 6) {
            CachedImage(url: side.logoURL, width: 44, height: 44, cornerRadius: 22, iconName: "shield")
            Text(side.name ?? "")
                .font(AppTheme.fontTeamName)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    private func scoreLine(_ match: MatchEvent) -> String {
        "\(match.home.score ?? "0") – \(match.away.score ?? "0")"
    }

    private func stateText(_ match: MatchEvent) -> String {
        if let detail = match.statusDetail?.trimmingCharacters(in: .whitespaces), !detail.isEmpty {
            return detail
        }
        switch match.state {
        case .live: return L("matches.live")
        case .finished: return L("matches.final")
        case .upcoming:
            if let start = match.startDate {
                return MatchesView.kickoffText(start)
            }
            return ""
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

    private func goalRow(_ goal: NHLService.Goal) -> some View {
        HStack(spacing: 10) {
            PlayerPhotoDisc(url: goal.headshotURL, name: goal.scorerName, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(goal.scorerName)
                        .font(AppTheme.fontCardTitle)
                        .lineLimit(1)
                    if let strength = goal.strength {
                        Text(strength)
                            .font(AppTheme.fontBadge)
                            .foregroundStyle(AppTheme.accent)
                    }
                    if let team = goal.teamAbbrev {
                        Text(team)
                            .font(AppTheme.fontBadge)
                            .foregroundStyle(.secondary)
                    }
                }
                if let assists = goal.assistsText {
                    Text(assists)
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                if let time = goal.timeText {
                    Text(time)
                        .font(AppTheme.fontMetadata.weight(.semibold))
                        .monospacedDigit()
                }
                if let score = goal.scoreText {
                    Text(score)
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var skaterHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 150, height: 20)
            ForEach(["G", "A", "P", "TOI"], id: \.self) { label in
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
            }
        }
    }

    private func skaterRow(_ line: NHLService.SkaterLine) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                PlayerPhotoDisc(url: line.headshotURL, name: line.name, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(line.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let position = line.position {
                        Text(position)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 150, alignment: .leading)
            ForEach(Array([String(line.goals), String(line.assists), String(line.points), line.toi ?? "–"].enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(.caption.monospacedDigit())
                    .frame(width: 40)
            }
            Spacer(minLength: 0)
        }
    }

    // Build 90 (SP13): goalie columns — hockey's standard
    // abbreviations for the payload's own fields (saves,
    // shots against, goals against, save percentage, time on
    // ice), the skater grid's layout.
    private var goalieHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 150, height: 20)
            ForEach(["SV", "SA", "GA", "SV%", "TOI"], id: \.self) { label in
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
            }
        }
    }

    private func goalieRow(_ line: NHLService.GoalieLine) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                PlayerPhotoDisc(url: line.headshotURL, name: line.name, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(line.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("G")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if line.starter {
                            Text("• \(L("matches.detail.starter"))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let decision = line.decision {
                            Text("• \(decision)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                }
            }
            .frame(width: 150, alignment: .leading)
            ForEach(Array([
                String(line.saves), String(line.shotsAgainst),
                String(line.goalsAgainst), line.savePctgText ?? "–",
                line.toi ?? "–"
            ].enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(.caption.monospacedDigit())
                    .frame(width: 40)
            }
            Spacer(minLength: 0)
        }
    }

    // Build 90 (SP18): one play-by-play row — period + time,
    // the play type (the payload's own taxonomy, labelled),
    // the composed line, and the running score on goals.
    private func playRow(_ play: NHLService.PlayItem) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 1) {
                Text(play.periodLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if let time = play.timeText {
                    Text(time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(playTypeLabel(play.typeKey))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(play.isGoal ? AppTheme.accent : .primary)
                if let text = play.text {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let score = play.scoreText {
                Text(score)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 1)
    }

    private func playTypeLabel(_ typeKey: String) -> String {
        switch typeKey {
        case "goal": return L("matches.pbp.goal")
        case "penalty": return L("matches.pbp.penalty")
        case "shot-on-goal": return L("matches.pbp.shot")
        case "missed-shot": return L("matches.pbp.missed_shot")
        case "blocked-shot": return L("matches.pbp.blocked_shot")
        case "hit": return L("matches.pbp.hit")
        default: return typeKey
        }
    }

    /// The watcher kickoff push — the same generic matches
    /// contract the ESPN sports use. Build 90 (SP22, NHL
    /// half): this is the page's ONLY reminder toggle — the
    /// local 15-minute reminder that duplicated it is
    /// removed, mirroring the ESPN match page.
    @ViewBuilder
    private func kickoffPushSection(_ match: MatchEvent) -> some View {
        if match.state == .upcoming {
            Section {
                Toggle(isOn: Binding(
                    get: { kickoffPushOn },
                    set: { newValue in
                        MatchKickoffPushStore.shared.set(
                            match: match, leaguePath: leaguePath,
                            sport: .nhl, enabled: newValue
                        )
                        if newValue {
                            PushNotificationService.shared.ensureAuthorizationAndRegister()
                        }
                        PushNotificationService.shared.uploadRegistration()
                        // Build 90 (SP22): CONFIRMED state
                        // only — the toggle re-reads the store
                        // after the write (the build-66 rule),
                        // never the optimistic value it was
                        // handed. Mirrors the ESPN match page.
                        kickoffPushOn = MatchKickoffPushStore.shared
                            .contains(eventId: eventId)
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
}

// MARK: - Formula 1 (item 2)

/// The F1 page: the season's race schedule (each race
/// opening its own weekend page), the next-race header, and
/// the driver + constructor standings — all from the free
/// Jolpica/Ergast API, text rows only (the API publishes no
/// photos and none are invented).
///
/// Build 90 (SP26): the build-87 standalone "Results"
/// segment — bound forever to the last race only — is
/// REMOVED. Results, qualifying and sprint now attach to
/// each race (the per-round endpoints verified live), the
/// standings show the wins the payload always carried, race
/// rows show the start TIME, and the next race gets an
/// emphasised header with a countdown.
struct F1View: View {
    private enum Segment: Hashable {
        case races, drivers, constructors
    }

    @State private var segment: Segment = .races
    @State private var races: [F1Race] = []
    @State private var drivers: [F1DriverStanding] = []
    @State private var constructors: [F1ConstructorStanding] = []
    @State private var stamp: Date?
    @State private var didLoad = false

    /// The next race still to run (the schedule's first
    /// future start) — the header's subject.
    private var nextRace: F1Race? {
        races.filter { ($0.date ?? .distantPast) > Date() }
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
            .first
    }

    var body: some View {
        List {
            Section {
                Picker(L("matches.f1"), selection: $segment) {
                    Text(L("matches.f1.races")).tag(Segment.races)
                    Text(L("matches.f1.drivers")).tag(Segment.drivers)
                    Text(L("matches.f1.constructors")).tag(Segment.constructors)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            .listRowBackground(Color.clear)

            if let stamp {
                Section {
                    LastUpdatedStamp(date: stamp)
                }
                .listRowBackground(Color.clear)
            }

            switch segment {
            case .races:
                if let nextRace {
                    Section {
                        NavigationLink {
                            F1RaceDetailView(race: nextRace)
                        } label: {
                            nextRaceHeader(nextRace)
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                    .listRowBackground(AppTheme.surface)
                }
                Section {
                    if races.isEmpty {
                        emptyRow
                    }
                    ForEach(races) { race in
                        NavigationLink {
                            F1RaceDetailView(race: race)
                        } label: {
                            raceRow(race, isNext: race.round == nextRace?.round)
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                }
                .listRowBackground(AppTheme.surface)
            case .drivers:
                Section {
                    if drivers.isEmpty {
                        emptyRow
                    }
                    ForEach(drivers) { row in
                        resultRow(
                            position: row.position, name: row.driverName,
                            sub: row.constructorName,
                            detail: winsText(row.wins),
                            value: row.points.map { "\($0) \(L("matches.points"))" }
                        )
                    }
                }
                .listRowBackground(AppTheme.surface)
            case .constructors:
                Section {
                    if constructors.isEmpty {
                        emptyRow
                    }
                    ForEach(constructors) { row in
                        resultRow(
                            position: row.position, name: row.name,
                            sub: nil,
                            detail: winsText(row.wins),
                            value: row.points.map { "\($0) \(L("matches.points"))" }
                        )
                    }
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(L("matches.f1"))
        .navigationBarTitleDisplayMode(.inline)
        .animation(Motion.animate(Motion.chipSwap), value: segment)
        // Build 90 (SP30): pull-to-refresh + the 60-second
        // cadence (results land after sessions end; the page
        // itself never pretends to be live timing — Jolpica
        // is results-only).
        .refreshable { await load() }
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await load()
            }
        }
    }

    private func load() async {
        let overview = await F1Service.overview()
        races = overview.races
        drivers = overview.drivers
        constructors = overview.constructors
        stamp = overview.stamp
        didLoad = true
    }

    private func winsText(_ wins: String?) -> String? {
        guard let wins, wins != "0" else { return nil }
        return "\(wins) \(L("matches.f1.wins"))"
    }

    private func nextRaceHeader(_ race: F1Race) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("matches.f1.next_race"))
                .font(AppTheme.fontBadge)
                .foregroundStyle(AppTheme.accent)
            Text(race.name)
                .font(.headline.weight(.bold))
                .lineLimit(2)
            if let circuit = race.circuit {
                Text([circuit, race.locality, race.country]
                    .compactMap { $0 }.joined(separator: " • "))
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let date = race.date {
                HStack(spacing: 8) {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(AppTheme.fontMetadata.weight(.semibold))
                    Spacer()
                    CountdownText(target: date)
                        .font(AppTheme.fontMetadata.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func raceRow(_ race: F1Race, isNext: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("\(race.round)")
                    .font(AppTheme.fontMetadata.weight(.bold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 22, alignment: .trailing)
                Text(race.name)
                    .font(AppTheme.fontCardTitle)
                    .lineLimit(2)
                if isNext {
                    Text(L("matches.f1.next_race"))
                        .font(AppTheme.fontBadge)
                        .foregroundStyle(AppTheme.accent)
                }
                Spacer()
                if let date = race.date {
                    // Build 90 (SP26): date AND start time —
                    // build 87 omitted the time it had decoded.
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                }
            }
            if let circuit = race.circuit {
                Text([circuit, race.locality, race.country]
                    .compactMap { $0 }.joined(separator: " • "))
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 30)
            }
        }
        .cardEntrance(index: race.round)
    }

    private var emptyRow: some View {
        Text(didLoad ? L("matches.empty") : L("common.loading"))
            .foregroundStyle(.secondary)
    }

    private func resultRow(
        position: String, name: String, sub: String?,
        detail: String? = nil, value: String?
    ) -> some View {
        HStack(spacing: 10) {
            Text(position)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let sub {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if let value {
                Text(value)
                    .font(AppTheme.fontMetadata.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - F1 race page (build 90, SP26)

/// One race weekend: the session schedule decoded from the
/// season payload, and — for a completed round — its race
/// classification, qualifying table and (on sprint weekends)
/// sprint classification from the per-round endpoints. A
/// future race shows its weekend only; nothing is rendered
/// for data the API hasn't published yet.
struct F1RaceDetailView: View {
    let race: F1Race

    @State private var results: [F1ResultRow] = []
    @State private var qualifying: [F1QualifyingRow] = []
    @State private var sprint: [F1ResultRow] = []
    @State private var didLoad = false

    private var isFuture: Bool {
        (race.date ?? .distantPast) > Date()
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    if let circuit = race.circuit {
                        Text([circuit, race.locality, race.country]
                            .compactMap { $0 }.joined(separator: " • "))
                            .font(AppTheme.fontMetadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let date = race.date {
                        HStack(spacing: 8) {
                            Text(date.formatted(date: .complete, time: .shortened))
                                .font(AppTheme.fontMetadata.weight(.semibold))
                            if isFuture {
                                Spacer()
                                CountdownText(target: date)
                                    .font(AppTheme.fontMetadata.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listRowBackground(AppTheme.surface)

            if !race.sessions.isEmpty {
                Section {
                    ForEach(race.sessions) { session in
                        HStack(spacing: 10) {
                            Text(session.label)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            if let date = session.date {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(AppTheme.fontMetadata)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { b87SectionHeader(L("matches.f1.sessions")) }
                .listRowBackground(AppTheme.surface)
            }

            if !results.isEmpty {
                Section {
                    ForEach(results) { row in
                        classificationRow(row)
                    }
                } header: { b87SectionHeader(L("matches.f1.results")) }
                .listRowBackground(AppTheme.surface)
            }
            if !sprint.isEmpty {
                Section {
                    ForEach(sprint) { row in
                        classificationRow(row)
                    }
                } header: { b87SectionHeader(L("matches.f1.sprint")) }
                .listRowBackground(AppTheme.surface)
            }
            if !qualifying.isEmpty {
                Section {
                    ForEach(qualifying) { row in
                        qualifyingRow(row)
                    }
                } header: { b87SectionHeader(L("matches.f1.qualifying")) }
                .listRowBackground(AppTheme.surface)
            }
            if didLoad && results.isEmpty && sprint.isEmpty && qualifying.isEmpty && !isFuture {
                Section {
                    Text(L("matches.empty"))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(race.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let raceResults = F1Service.raceResults(round: race.round)
            async let raceQualifying = F1Service.raceQualifying(round: race.round)
            async let raceSprint = F1Service.raceSprint(round: race.round)
            results = await raceResults
            qualifying = await raceQualifying
            sprint = await raceSprint
            didLoad = true
        }
    }

    /// A classification row: position (the payload's
    /// positionText when it isn't a plain number — a retired
    /// driver reads "R", not a fake classified position),
    /// grid + laps under the constructor, the fastest-lap
    /// marker, and time-or-status + points on the right.
    private func classificationRow(_ row: F1ResultRow) -> some View {
        HStack(spacing: 10) {
            Text(row.positionText.flatMap { Int($0) == nil ? $0 : nil } ?? row.position)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.driverName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if row.fastestLap {
                        Text("FL")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(AppTheme.accent)
                    }
                }
                let subParts = [
                    row.constructorName,
                    row.grid.map { "\(L("matches.f1.grid")) \($0)" },
                    row.laps.map { "\($0) \(L("matches.f1.laps"))" }
                ].compactMap { $0 }
                if !subParts.isEmpty {
                    Text(subParts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                if let value = row.timeText ?? row.status {
                    Text(value)
                        .font(AppTheme.fontMetadata.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if let points = row.points {
                    Text("\(points) \(L("matches.points"))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func qualifyingRow(_ row: F1QualifyingRow) -> some View {
        HStack(spacing: 10) {
            Text(row.position)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.driverName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let constructor = row.constructorName {
                    Text(constructor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                if let best = row.q3 ?? row.q2 ?? row.q1 {
                    Text(best)
                        .font(AppTheme.fontMetadata.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Text([row.q1.map { "Q1 \($0)" }, row.q2.map { "Q2 \($0)" }, row.q3.map { "Q3 \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Tennis (item 4)

/// ATP / WTA tournaments from ESPN's tennis scoreboards:
/// each tournament's groups (Men's/Women's Singles, Doubles…)
/// with their matches — names, per-set scores from the
/// payload's linescores, the winner bolded, state chips.
struct TennisView: View {
    /// Build 90 (SP27): the page gains its rankings — the
    /// sport's staple, absent since build 87.
    private enum Mode: Hashable {
        case matches, rankings
    }

    @State private var tourPath = TennisService.tours[0].path
    @State private var mode: Mode = .matches
    @State private var tournaments: [TennisTournament] = []
    @State private var rankings: [TennisRankingRow] = []
    @State private var stamp: Date?
    @State private var didLoad = false

    var body: some View {
        List {
            Section {
                Picker(L("matches.tennis"), selection: $tourPath) {
                    ForEach(TennisService.tours, id: \.path) { tour in
                        Text(tour.label).tag(tour.path)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                Picker(L("matches.tennis"), selection: $mode) {
                    Text(L("matches.title")).tag(Mode.matches)
                    Text(L("matches.rankings")).tag(Mode.rankings)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            .listRowBackground(Color.clear)

            if let stamp {
                Section {
                    LastUpdatedStamp(date: stamp)
                }
                .listRowBackground(Color.clear)
            }

            switch mode {
            case .matches:
                if tournaments.isEmpty {
                    Section {
                        Text(didLoad ? L("matches.empty") : L("common.loading"))
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(AppTheme.surface)
                }
                ForEach(tournaments) { tournament in
                    Section {
                        ForEach(Array(tournament.groups.enumerated()), id: \.offset) { _, group in
                            if let title = group.title {
                                Text(title)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(group.matches) { match in
                                tennisRow(match)
                            }
                        }
                    } header: { b87SectionHeader(tournament.name) }
                    .listRowBackground(AppTheme.surface)
                }
            case .rankings:
                Section {
                    if rankings.isEmpty {
                        Text(didLoad ? L("matches.empty") : L("common.loading"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rankings) { row in
                        rankingRow(row)
                    }
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(L("matches.tennis"))
        .navigationBarTitleDisplayMode(.inline)
        .animation(Motion.animate(Motion.chipSwap), value: tourPath)
        .animation(Motion.animate(Motion.chipSwap), value: mode)
        // Build 90 (SP30): pull-to-refresh + the 60-second
        // cadence while the page is open (a live match's sets
        // no longer freeze at page-open).
        .refreshable { await load() }
        .task(id: "\(tourPath)|\(mode == .rankings)") {
            didLoad = false
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await load()
            }
        }
    }

    private func load() async {
        switch mode {
        case .matches:
            let result = await TennisService.tournamentsStamped(tourPath: tourPath)
            tournaments = result.tournaments
            stamp = result.stamp
        case .rankings:
            let result = await TennisService.rankings(tourPath: tourPath)
            rankings = result.rows
            stamp = result.stamp
        }
        didLoad = true
    }

    private func rankingRow(_ row: TennisRankingRow) -> some View {
        HStack(spacing: 10) {
            Text("\(row.rank)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
            Text(row.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trend = row.trend, trend != "-" {
                Text(trend)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let points = row.pointsText {
                Text(points)
                    .font(AppTheme.fontMetadata.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }

    private func tennisRow(_ match: TennisMatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let round = match.roundText {
                    Text(round)
                        .font(AppTheme.fontBadge)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                // Build 90 (SP27): an upcoming match shows WHEN
                // it starts — startDate was decoded since build
                // 87 and never rendered, so an upcoming match
                // was two names and no time at all.
                if match.state == .upcoming, let start = match.startDate {
                    Text(start.formatted(date: .abbreviated, time: .shortened))
                        .font(AppTheme.fontBadge)
                        .foregroundStyle(.secondary)
                } else {
                    stateChip(match.state)
                }
            }
            playerLine(name: match.name1, rank: match.rank1, sets: match.sets1, isWinner: match.winnerIndex == 0)
            playerLine(name: match.name2, rank: match.rank2, sets: match.sets2, isWinner: match.winnerIndex == 1)
        }
        .padding(.vertical, 2)
    }

    private func playerLine(name: String, rank: Int?, sets: [String], isWinner: Bool) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(AppTheme.fontTeamName.weight(isWinner ? .bold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Build 90 (SP27): the payload's own curatedRank.
            if let rank {
                Text("#\(rank)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ForEach(Array(sets.enumerated()), id: \.offset) { _, set in
                Text(set)
                    .font(AppTheme.fontMetadata.weight(isWinner ? .bold : .regular))
                    .monospacedDigit()
                    .frame(width: 22, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func stateChip(_ state: MatchState) -> some View {
        switch state {
        case .live:
            Text(L("matches.live"))
                .font(AppTheme.fontBadge)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(AppTheme.live))
        case .finished:
            Text(L("matches.final"))
                .font(AppTheme.fontBadge)
                .foregroundStyle(.secondary)
        case .upcoming:
            EmptyView()
        }
    }
}

// MARK: - Golf (item 5)

/// The current tournament's leaderboard for the picked tour
/// (PGA / DP World / LPGA — the tours whose ESPN scoreboards
/// verify; the Champions Tour answers 400 and is not
/// offered): position, player, total score and per-round
/// scores, all from the payload in its own order.
struct GolfView: View {
    @State private var tourPath = GolfService.tours[0].path
    @State private var board: GolfLeaderboard?
    @State private var stamp: Date?
    @State private var didLoad = false

    var body: some View {
        List {
            Section {
                Picker(L("matches.golf"), selection: $tourPath) {
                    ForEach(GolfService.tours, id: \.path) { tour in
                        Text(tour.label).tag(tour.path)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            .listRowBackground(Color.clear)

            if let stamp {
                Section {
                    LastUpdatedStamp(date: stamp)
                }
                .listRowBackground(Color.clear)
            }

            if let board {
                Section {
                    if board.rows.isEmpty {
                        Text(L("matches.empty"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(board.rows) { row in
                        if row.rounds.contains(where: { !$0.holes.isEmpty }) {
                            NavigationLink {
                                GolfScorecardView(playerName: row.name, rounds: row.rounds)
                            } label: {
                                boardRow(row)
                            }
                            .buttonStyle(PressOpacityButtonStyle())
                        } else {
                            boardRow(row)
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        if let event = board.eventName { b87SectionHeader(event) }
                        // Build 90 (SP29): the board's own
                        // status line ("Round 3 - Suspended") —
                        // computed since build 87, never shown.
                        if let stateText = board.stateText {
                            Text(stateText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(AppTheme.surface)
            } else {
                Section {
                    Text(didLoad ? L("matches.empty") : L("common.loading"))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(L("matches.golf"))
        .navigationBarTitleDisplayMode(.inline)
        .animation(Motion.animate(Motion.chipSwap), value: tourPath)
        // Build 90 (SP30): pull-to-refresh + 60-second cadence.
        .refreshable { await load() }
        .task(id: tourPath) {
            didLoad = false
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await load()
            }
        }
    }

    private func load() async {
        let result = await GolfService.leaderboardStamped(tourPath: tourPath)
        board = result.board
        stamp = result.stamp
        didLoad = true
    }

    private func boardRow(_ row: GolfRow) -> some View {
        HStack(spacing: 10) {
            // Build 90 (SP29): the tie-aware label (T3, T3, 5…)
            // instead of the payload's raw sequential order.
            Text(row.positionText)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
            Text(row.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !row.roundScores.isEmpty {
                // Build 90 (SP29): rounds are LABELLED now
                // (R1/R2/R3/R4), not one anonymous joined string.
                Text(row.roundScores.enumerated()
                    .map { "R\($0.offset + 1) \($0.element)" }
                    .joined(separator: " · "))
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if let score = row.scoreText {
                Text(score)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Golf scorecard (build 90, SP29)

/// One player's hole-by-hole card: per round, the 18 holes
/// in two nines — hole number, strokes, and the payload's
/// own score-type mark where it carries one. The payload
/// check PASSED live (2026-11-21: every round linescore
/// nests 18 hole linescores), so the standalone golf page
/// stays and gains the card (audit S4's B2 removal lapses).
struct GolfScorecardView: View {
    let playerName: String
    let rounds: [GolfRound]

    var body: some View {
        List {
            ForEach(rounds) { round in
                Section {
                    nineRow(holes: Array(round.holes.prefix(9)))
                    if round.holes.count > 9 {
                        nineRow(holes: Array(round.holes.dropFirst(9)))
                    }
                } header: {
                    HStack(spacing: 8) {
                        b87SectionHeader("\(L("matches.golf.round")) \(round.number)")
                        Spacer()
                        if let score = round.scoreText {
                            Text(score)
                                .font(AppTheme.fontMetadata.weight(.bold))
                                .foregroundStyle(AppTheme.accent)
                                .monospacedDigit()
                        }
                    }
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(playerName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func nineRow(holes: [GolfHole]) -> some View {
        HStack(spacing: 0) {
            ForEach(holes) { hole in
                VStack(spacing: 2) {
                    Text("\(hole.number)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(hole.scoreText ?? "–")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text(hole.scoreTypeText ?? " ")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - UFC (item 5)

/// UFC cards from ESPN's MMA scoreboard: each card's fights
/// with both athletes, their payload record summaries, the
/// winner bolded once a fight is final, and the payload's
/// own result text ("Final - KO/TKO").
struct UFCView: View {
    @State private var cards: [UFCCard] = []
    @State private var stamp: Date?
    @State private var didLoad = false
    // Build 90 (SP28): the divisional rankings — lists load
    // lazily, only the opened division resolves its fighters.
    @State private var rankingLists: [UFCRankingListRef] = []
    @State private var selectedRankingSlug: String?
    @State private var rankingRows: [UFCRankRow] = []
    @State private var rankingsLoaded = false

    var body: some View {
        List {
            if let stamp {
                Section {
                    LastUpdatedStamp(date: stamp)
                }
                .listRowBackground(Color.clear)
            }
            if !rankingLists.isEmpty {
                Section {
                    Picker(L("matches.rankings"), selection: rankingSelection) {
                        Text("—").tag(String?.none)
                        ForEach(rankingLists) { list in
                            Text(list.title).tag(String?.some(list.slug))
                        }
                    }
                    .pickerStyle(.menu)
                    if selectedRankingSlug != nil {
                        if rankingRows.isEmpty {
                            Text(rankingsLoaded ? L("matches.empty") : L("common.loading"))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(rankingRows) { row in
                            HStack(spacing: 10) {
                                Text("\(row.rank)")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 26, alignment: .trailing)
                                Text(row.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let trend = row.trend, trend != "-" {
                                    Text(trend)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                } header: { b87SectionHeader(L("matches.rankings")) }
                .listRowBackground(AppTheme.surface)
            }
            if cards.isEmpty {
                Section {
                    Text(didLoad ? L("matches.empty") : L("common.loading"))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)
            }
            ForEach(cards) { card in
                Section {
                    ForEach(card.fights) { fight in
                        VStack(alignment: .leading, spacing: 3) {
                            // Build 90 (SP28): the weight class —
                            // the context of a fight, carried by
                            // the payload all along.
                            if let weightClass = fight.weightClass {
                                Text(weightClass)
                                    .font(AppTheme.fontBadge)
                                    .foregroundStyle(AppTheme.accent)
                            }
                            fighterLine(name: fight.name1, record: fight.record1, isWinner: fight.winnerIndex == 0)
                            fighterLine(name: fight.name2, record: fight.record2, isWinner: fight.winnerIndex == 1)
                            if let detail = fight.detailText, fight.state != .upcoming {
                                Text(detail)
                                    .font(AppTheme.fontBadge)
                                    .foregroundStyle(fight.state == .live ? AppTheme.live : .secondary)
                            } else if fight.state == .live {
                                Text(L("matches.live"))
                                    .font(AppTheme.fontBadge)
                                    .foregroundStyle(AppTheme.live)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(card.name)
                            .font(AppTheme.fontBadge)
                            .foregroundStyle(AppTheme.accent)
                            .lineLimit(1)
                        Spacer()
                        if let date = card.date {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(AppTheme.fontBadge)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(L("matches.ufc"))
        .navigationBarTitleDisplayMode(.inline)
        // Build 90 (SP30): pull-to-refresh + 60-second cadence.
        .refreshable { await load() }
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await load()
            }
        }
        .task(id: selectedRankingSlug) {
            guard let slug = selectedRankingSlug else {
                rankingRows = []
                return
            }
            rankingsLoaded = false
            rankingRows = await UFCService.rankingList(slug: slug)
            rankingsLoaded = true
        }
    }

    private func load() async {
        async let cardsFetch = UFCService.cardsStamped()
        async let listsFetch = UFCService.rankingLists()
        let cardsResult = await cardsFetch
        cards = cardsResult.cards
        stamp = cardsResult.stamp
        if rankingLists.isEmpty {
            rankingLists = await listsFetch
        }
        didLoad = true
    }

    private var rankingSelection: Binding<String?> {
        Binding(
            get: { selectedRankingSlug },
            set: { newValue in
                withAnimation(Motion.animate(Motion.chipSwap)) { selectedRankingSlug = newValue }
            }
        )
    }

    private func fighterLine(name: String, record: String?, isWinner: Bool) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(AppTheme.fontTeamName.weight(isWinner ? .bold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let record {
                Text(record)
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Sports calendar (item 7)

/// Build 88 (F10): a REAL calendar, not a second copy of the
/// fixtures list. The build-87 version showed only today,
/// grouped by league — indistinguishable from Today's Matches.
/// Now the page is grouped BY DAY: one sticky-headed section
/// per day (yesterday → +7 days), every sport's events for
/// that day inside it, and each row carries a sport tag, so
/// the page reads as a calendar of the week ahead. League
/// events come from the same per-day scoreboard service the
/// Matches tabs read; tennis / UFC / F1 events are bucketed
/// by the dates their own payloads carry; the live golf
/// leaderboard belongs to today only. Days fill in
/// chronologically as their fetches land.
struct SportsCalendarView: View {
    /// One day's events: league matches (with their
    /// competition, for the tag + detail routing) and the
    /// payload-dated events of the other sports.
    private struct CalendarDay: Identifiable {
        let date: Date
        var leagueMatches: [(group: LiveNowGroup, match: MatchEvent)] = []
        var tennis: [TennisMatch] = []
        var ufc: [UFCCard] = []
        var f1: [F1Race] = []
        var golf: GolfLeaderboard?
        var id: Date { date }
        var isEmpty: Bool {
            leagueMatches.isEmpty && tennis.isEmpty && ufc.isEmpty
                && f1.isEmpty && golf == nil
        }
    }

    @State private var days: [CalendarDay] = []
    @State private var didLoad = false

    private var visibleDays: [CalendarDay] { days.filter { !$0.isEmpty } }

    var body: some View {
        List {
            if didLoad && visibleDays.isEmpty {
                Section {
                    Text(L("matches.empty"))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)
            }
            ForEach(visibleDays) { day in
                Section {
                    ForEach(Array(day.leagueMatches.enumerated()), id: \.offset) { _, entry in
                        NavigationLink {
                            MatchDetailView(
                                sport: entry.group.sport, leaguePath: entry.group.leaguePath,
                                match: entry.match, leagueName: entry.group.leagueName
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    sportTag(entry.group.sport)
                                    if let name = entry.group.leagueName {
                                        Text(name)
                                            .font(AppTheme.fontMetadata)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                MatchRowView(match: entry.match, isStale: false, sport: entry.group.sport)
                            }
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                    ForEach(day.tennis) { match in
                        VStack(alignment: .leading, spacing: 5) {
                            sportTag(nil, titleKey: "matches.tennis")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(match.name1) – \(match.name2)")
                                    .font(AppTheme.fontTeamName)
                                    .lineLimit(2)
                                Text(match.tournamentName)
                                    .font(AppTheme.fontMetadata)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    ForEach(day.ufc) { card in
                        VStack(alignment: .leading, spacing: 5) {
                            sportTag(nil, titleKey: "matches.ufc")
                            Text(card.name)
                                .font(AppTheme.fontMetadata.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            ForEach(card.fights) { fight in
                                Text("\(fight.name1) – \(fight.name2)")
                                    .font(AppTheme.fontTeamName)
                                    .lineLimit(2)
                            }
                        }
                    }
                    ForEach(day.f1) { race in
                        VStack(alignment: .leading, spacing: 5) {
                            sportTag(nil, titleKey: "matches.f1")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(race.name)
                                    .font(AppTheme.fontTeamName)
                                    .lineLimit(2)
                                if let circuit = race.circuit {
                                    Text(circuit)
                                        .font(AppTheme.fontMetadata)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    if let golf = day.golf, golf.state == .live {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                sportTag(nil, titleKey: "matches.golf")
                                Text(golf.eventName ?? "")
                                    .font(AppTheme.fontMetadata)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            ForEach(golf.rows.prefix(10)) { row in
                                HStack(spacing: 10) {
                                    Text("\(row.position)")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .frame(width: 30, alignment: .trailing)
                                    Text(row.name)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    if let score = row.scoreText {
                                        Text(score)
                                            .font(.headline.weight(.bold))
                                            .foregroundStyle(AppTheme.accent)
                                            .monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                        Text(Self.dayHeaderText(day.date))
                            .font(AppTheme.fontCardTitle)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(Self.dayCountText(day))
                            .font(AppTheme.fontMetadata.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(L("matches.calendar"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// The row's sport tag: a small accent capsule naming the
    /// sport (symbol + title for the league sports; title only
    /// for the payload sports, which have no MatchSport case).
    private func sportTag(_ sport: MatchSport?, titleKey: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let sport {
                Image(systemName: MatchesView.sportSymbolName(sport))
                    .font(.system(size: 9, weight: .bold))
            }
            Text(L(titleKey ?? sport?.titleKey ?? ""))
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(AppTheme.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(AppTheme.accent.opacity(0.14), in: Capsule())
    }

    /// "Today" / "Tomorrow" / "Yesterday" where the locale's
    /// relative formatting knows them, else the full date —
    /// formatter output only, in the app locale.
    static func dayHeaderText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppTheme.appLocale
        formatter.timeZone = TimeZone.current
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    private static func dayCountText(_ day: CalendarDay) -> String {
        let count = day.leagueMatches.count + day.tennis.count
            + day.ufc.reduce(0) { $0 + $1.fights.count } + day.f1.count
        return count > 0 ? "\(count)" : ""
    }

    private static func dayParameter(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private func load() async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Build 90 (SP25): the window starts TOMORROW —
        // yesterday and today are already covered twice over
        // (the Matches tab's own day pages, Live Now's
        // Live/Today switch), so the Calendar's unique value
        // is the week ahead; trimming two days also cuts
        // ~2/9 of this screen's fetch storm (S5 B4/A4). The
        // golf board was a today-only live board — with no
        // today bucket it is no longer fetched here (the
        // CalendarDay golf slot stays for any future host).
        let window = (1...7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today)
        }
        // The payload-dated sports are fetched ONCE and then
        // bucketed by their own dates.
        let allTennis = await TennisService.allMatches()
        let allCards = await UFCService.cards()
        let allRaces = await F1Service.schedule()

        // Build 90 (SP25): every day's competitions fetch
        // CONCURRENTLY — the old loop awaited each day before
        // starting the next, up to ~189 serial scoreboard
        // fetches on a cold open. Bucketing below still runs
        // in day order, so the cross-day de-dup keeps its
        // first-day-wins semantics exactly.
        let order = Dictionary(uniqueKeysWithValues: SportsHubService.allCompetitions.enumerated().map { ($0.element.leaguePath, $0.offset) })
        let groupsByDay = await withTaskGroup(of: (Date, [LiveNowGroup]).self) { group in
            for day in window {
                group.addTask {
                    let parameter = Self.dayParameter(for: day)
                    let groups = await withTaskGroup(of: LiveNowGroup?.self) { inner in
                        for competition in SportsHubService.allCompetitions {
                            inner.addTask {
                                guard let result = try? await MatchesService.fetchLeague(
                                    path: competition.leaguePath, dateParameter: parameter
                                ), !result.matches.isEmpty else { return nil }
                                return LiveNowGroup(
                                    leagueName: result.leagueName,
                                    leaguePath: competition.leaguePath,
                                    sport: competition.sport,
                                    matches: result.matches
                                )
                            }
                        }
                        var out: [LiveNowGroup] = []
                        for await item in inner { if let item { out.append(item) } }
                        return out
                    }
                    return (day, groups)
                }
            }
            var map: [Date: [LiveNowGroup]] = [:]
            for await (day, groups) in group { map[day] = groups }
            return map
        }

        days = []
        // A league's day response can span neighbouring days;
        // the date filter pins each dated event to its own day,
        // and this set keeps an undated event (or any repeat)
        // from surfacing in two day sections.
        var seenMatches = Set<String>()
        for day in window {
            var bucket = CalendarDay(date: day)
            bucket.leagueMatches = (groupsByDay[day] ?? [])
                .sorted { (order[$0.leaguePath] ?? 0) < (order[$1.leaguePath] ?? 0) }
                .flatMap { group in
                    group.matches
                        .filter { match in
                            // An event with no parseable date
                            // belongs to the day it was queried
                            // for — the feed returned it in that
                            // day's query (the Matches tab's own
                            // convention).
                            guard let start = match.startDate else { return true }
                            return calendar.isDate(start, inSameDayAs: day)
                        }
                        .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
                        .map { (group: group, match: $0) }
                }
            bucket.leagueMatches = bucket.leagueMatches.filter { entry in
                seenMatches.insert("\(entry.group.leaguePath)|\(entry.match.id)").inserted
            }
            bucket.tennis = allTennis.filter { match in
                guard let start = match.startDate else { return false }
                return calendar.isDate(start, inSameDayAs: day)
            }
            bucket.ufc = allCards.filter { card in
                guard let date = card.date else { return false }
                return calendar.isDate(date, inSameDayAs: day)
            }
            bucket.f1 = allRaces.filter { race in
                guard let date = race.date else { return false }
                return calendar.isDate(date, inSameDayAs: day)
            }
            days.append(bucket)
        }
        didLoad = true
    }
}

// MARK: - Cross-league top scorers (item 11)

/// The goals leaders of all 17 soccer leagues on one page —
/// the per-league scorers service fanned out and merged,
/// ranked by the payloads' own goal counts, each row naming
/// its league and opening the player page in that league.
struct CrossLeagueScorersView: View {
    /// Build 90 (SP35): one merged race row — a leaders row
    /// plus the league it came from (LeaderRow84 itself
    /// carries neither the league's name nor its path; both
    /// ride along from the catalog entry at merge time).
    private struct RaceRow: Identifiable {
        let entry: LeaderRow84
        let leagueName: String
        let leaguePath: String
        var id: String { "\(leaguePath)|\(entry.athleteId)" }
    }

    /// One league's leaders payload, as fetchAll returns it.
    private typealias LeagueLeaders = (
        categories: [LeaderCategory84],
        rows: [String: [LeaderRow84]],
        stamp: Date?
    )

    @State private var goalsRows: [RaceRow] = []
    @State private var assistsRows: [RaceRow] = []
    /// The visible race: 0 = goals, 1 = assists.
    @State private var race = 0
    /// The payloads' own category names, captured from the
    /// first league that answers — the segmented switch's
    /// labels are the same display names LeadersView shows.
    /// The literals are only the pre-first-answer defaults.
    @State private var goalsLabel = "Goals"
    @State private var assistsLabel = "Assists"
    @State private var didLoad = false
    /// Build 88 (F1): leagues that have reported back so far —
    /// the loading line names real progress instead of an
    /// indefinite spinner.
    @State private var settledLeagues = 0
    /// At least one league's leaders payload answered (even
    /// with no rows for a race). When every league failed or
    /// timed out, the page shows the failure state with
    /// Retry — never an endless load.
    @State private var anyLeagueAnswered = false
    /// Bumped by Retry to re-run the load task.
    @State private var loadGeneration = 0

    private var leagueCount: Int { MatchSport.soccerLeagueCatalog.count }
    private var activeRows: [RaceRow] { race == 0 ? goalsRows : assistsRows }

    var body: some View {
        List {
            if !goalsRows.isEmpty || !assistsRows.isEmpty {
                Section {
                    Picker("", selection: $race) {
                        Text(goalsLabel).tag(0)
                        Text(assistsLabel).tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
            }
            Section {
                if activeRows.isEmpty {
                    if !didLoad {
                        progressRow
                    } else if anyLeagueAnswered {
                        Text(L("matches.empty"))
                            .foregroundStyle(.secondary)
                    } else {
                        retryRow
                    }
                } else {
                    ForEach(Array(activeRows.enumerated()), id: \.element.id) { index, row in
                        raceRowLink(row, rank: index + 1)
                    }
                }
            }
            .listRowBackground(AppTheme.surface)
            // While later leagues are still landing, a quiet
            // progress line under the rows (build 88 F1).
            if !activeRows.isEmpty, !didLoad {
                Section { progressRow }
                    .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .cinematicBackground()
        .navigationTitle(L("matches.scorers"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadGeneration) { await load() }
    }

    private var progressRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(L("common.loading"))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(settledLeagues)/\(leagueCount)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private var retryRow: some View {
        HStack {
            Label(L("matches.error"), systemImage: "exclamationmark.triangle")
                .font(AppTheme.fontMetadata)
                .foregroundStyle(.secondary)
            Spacer()
            Button(L("matches.retry")) { loadGeneration += 1 }
                .font(AppTheme.fontMetadata.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
        }
    }

    private func raceRowLink(_ row: RaceRow, rank: Int) -> some View {
        NavigationLink {
            PlayerPageView(
                sport: .soccer, leaguePath: row.leaguePath,
                athleteId: row.entry.athleteId, fallbackName: row.entry.name
            )
        } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
                PlayerPhotoDisc(
                    url: row.entry.headshotURL, name: row.entry.name, size: 36,
                    fallback: SoccerPhotoQuery(
                        athleteId: row.entry.athleteId, name: row.entry.name,
                        teamName: row.entry.teamName, leaguePath: row.leaguePath,
                        citizenship: nil, dateOfBirth: nil
                    )
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.entry.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text([row.entry.teamName, row.leagueName]
                        .compactMap { $0 }.joined(separator: " \u{2022} "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(row.entry.valueText)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressOpacityButtonStyle())
    }

    /// Build 90 (SP35): the races now ride the SAME payload
    /// the per-league Leaders page reads —
    /// MatchesLeadersService.fetchAll returns each league's
    /// rows WITH names already resolved. The old
    /// CrossLeagueScorersService re-implemented the fetch and
    /// dereferenced up to 30 athlete $refs per league just to
    /// learn names (the build-88 F1 hang's fuel), and could
    /// only ever surface goals. Both races merge from that
    /// one payload now: goalsLeaders feeds the goals race,
    /// assistsLeaders the assists race this page never had.
    /// Merging stays progressive per league (build 88 F1):
    /// each landed league re-sorts both races by the
    /// payload's numeric value (LeaderRow84.value), capped
    /// at the merged top 40, and each league races a
    /// 15-second timer so the page always terminates.
    private func load() async {
        goalsRows = []
        assistsRows = []
        settledLeagues = 0
        anyLeagueAnswered = false
        didLoad = false
        await withTaskGroup(of: (SoccerLeague, LeagueLeaders?).self) { group in
            for league in MatchSport.soccerLeagueCatalog {
                group.addTask {
                    let result = await Self.fetchLeagueRaced(league)
                    return (league, result)
                }
            }
            for await pair in group {
                let league = pair.0
                let result = pair.1
                settledLeagues += 1
                guard let result else { continue }
                if !result.categories.isEmpty { anyLeagueAnswered = true }
                if let display = result.categories.first(where: { $0.name == "goalsLeaders" })?.displayName {
                    goalsLabel = display
                }
                if let display = result.categories.first(where: { $0.name == "assistsLeaders" })?.displayName {
                    assistsLabel = display
                }
                let goals = result.rows["goalsLeaders"] ?? []
                if !goals.isEmpty {
                    let incoming = goals.map {
                        RaceRow(entry: $0, leagueName: league.name, leaguePath: league.leaguePath)
                    }
                    goalsRows = Self.merge(goalsRows, incoming)
                }
                let assists = result.rows["assistsLeaders"] ?? []
                if !assists.isEmpty {
                    let incoming = assists.map {
                        RaceRow(entry: $0, leagueName: league.name, leaguePath: league.leaguePath)
                    }
                    assistsRows = Self.merge(assistsRows, incoming)
                }
            }
        }
        didLoad = true
    }

    private static func merge(_ existing: [RaceRow], _ incoming: [RaceRow]) -> [RaceRow] {
        let combined = existing + incoming
        let sorted = combined.sorted { lhs, rhs in
            let lhsValue = lhs.entry.value
            let rhsValue = rhs.entry.value
            if lhsValue != rhsValue { return lhsValue > rhsValue }
            return lhs.entry.name < rhs.entry.name
        }
        return Array(sorted.prefix(40))
    }

    /// One league's leaders payload under the build-88 F1
    /// 15-second ceiling: the fetch races a timer and the
    /// loser is cancelled, so a hung league can never hold
    /// the page hostage.
    private static func fetchLeagueRaced(_ league: SoccerLeague) async -> LeagueLeaders? {
        await withTaskGroup(of: LeagueLeaders?.self) { group in
            group.addTask {
                await MatchesLeadersService.fetchAll(sport: .soccer, leaguePath: league.leaguePath)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Player compare (item 6)

/// Player vs player, same sport + league: the two profiles
/// the player page renders (identity rows + the payloads'
/// own season stat lines), side by side. Candidates are the
/// league's verified leaders — a player outside the leaders
/// lists simply isn't offered, never invented.
struct PlayerCompareView: View {
    let sport: MatchSport
    let leaguePath: String
    let firstAthleteId: String

    @State private var candidates: [LeaderRow84] = []
    @State private var secondId: String?
    @State private var firstProfile: PlayerProfile?
    @State private var secondProfile: PlayerProfile?

    var body: some View {
        List {
            Section {
                compareHeader(firstProfile, name: candidateName(firstAthleteId))
                Picker(L("matches.compare.pick_player"), selection: secondSelection) {
                    Text("—").tag(String?.none)
                    ForEach(candidates.filter { $0.athleteId != firstAthleteId }) { row in
                        Text(row.name).tag(String?.some(row.athleteId))
                    }
                }
                .pickerStyle(.menu)
                if let secondProfile {
                    compareHeader(secondProfile, name: secondProfile.name)
                }
            }
            .listRowBackground(AppTheme.surface)

            if let firstProfile, let secondProfile {
                Section {
                    compareRow(label: L("matches.compare.position"),
                               left: firstProfile.positionName, right: secondProfile.positionName)
                    compareRow(label: L("matches.player.age"),
                               left: firstProfile.age.map(String.init),
                               right: secondProfile.age.map(String.init))
                    compareRow(label: L("matches.player.number"),
                               left: firstProfile.jersey, right: secondProfile.jersey)
                    compareRow(label: L("matches.player.nationality"),
                               left: firstProfile.citizenship, right: secondProfile.citizenship)
                    ForEach(statLabels(firstProfile, secondProfile), id: \.self) { label in
                        compareRow(
                            label: label,
                            left: firstProfile.statLines.first(where: { $0.label == label })?.value,
                            right: secondProfile.statLines.first(where: { $0.label == label })?.value
                        )
                    }
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(L("matches.compare_players"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if sport == .nhl {
                let result = await NHLService.leaders()
                candidates = deduped(result.rows.values.flatMap { $0 })
            } else {
                let result = await MatchesLeadersService.fetchAll(sport: sport, leaguePath: leaguePath)
                candidates = deduped(result.rows.values.flatMap { $0 })
            }
            firstProfile = await PlayerProfileService.fetch(
                sport: sport, leaguePath: leaguePath, athleteId: firstAthleteId
            )
        }
        .task(id: secondId) {
            guard let secondId else {
                secondProfile = nil
                return
            }
            secondProfile = await PlayerProfileService.fetch(
                sport: sport, leaguePath: leaguePath, athleteId: secondId
            )
        }
    }

    private var secondSelection: Binding<String?> {
        Binding(
            get: { secondId },
            set: { newValue in
                withAnimation(Motion.animate(Motion.chipSwap)) { secondId = newValue }
            }
        )
    }

    private func deduped(_ rows: [LeaderRow84]) -> [LeaderRow84] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.athleteId).inserted }
            .sorted { $0.name < $1.name }
    }

    private func candidateName(_ athleteId: String) -> String? {
        candidates.first(where: { $0.athleteId == athleteId })?.name
    }

    private func statLabels(_ first: PlayerProfile, _ second: PlayerProfile) -> [String] {
        var labels: [String] = []
        for line in first.statLines + second.statLines where !labels.contains(line.label) {
            labels.append(line.label)
        }
        return labels
    }

    private func compareHeader(_ profile: PlayerProfile?, name: String?) -> some View {
        HStack(spacing: 12) {
            PlayerPhotoDisc(
                url: profile?.headshotURL, name: profile?.name ?? name ?? "", size: 44,
                fallback: sport == .soccer
                    ? SoccerPhotoQuery(
                        athleteId: profile?.athleteId ?? firstAthleteId,
                        name: profile?.name ?? name ?? "",
                        teamName: profile?.teamName, leaguePath: leaguePath,
                        citizenship: nil, dateOfBirth: nil
                    )
                    : nil
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(profile?.name ?? name ?? L("common.loading"))
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                if let teamName = profile?.teamName {
                    Text(teamName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func compareRow(label: String, left: String?, right: String?) -> some View {
        HStack(spacing: 8) {
            Text(left ?? "–")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            Text(label)
                .font(AppTheme.fontBadge)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 92)
            Text(right ?? "–")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(2)
        }
    }
}

// MARK: - Per-section highlights (item 13)

/// ONE section's own highlights — a league page's league, a
/// sport section's competitions — from the same ESPN summary
/// videos the hub aggregates, scoped by the caller. Rows are
/// the hub's rows; playback is the same in-app MP4 sheet.
struct SectionHighlightsView: View {
    let competitions: [(sport: MatchSport, leaguePath: String)]
    let title: String

    @State private var highlights: [HubHighlight] = []
    @State private var didLoad = false
    @State private var selected: MatchVideo?

    var body: some View {
        List {
            Section {
                if highlights.isEmpty {
                    Text(didLoad ? L("matches.empty") : L("common.loading"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(highlights) { item in
                        Button {
                            selected = item.video
                        } label: {
                            HighlightRow87(item: item)
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                }
            }
            .listRowBackground(AppTheme.surface)
        }
        .listStyle(.insetGrouped)
        // Build 88 (F14): same shared chrome as the hub.
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { video in
            HighlightPlayerView(url: video.url)
        }
        .task {
            highlights = await SportsHubService.highlights(competitions: competitions)
            didLoad = true
        }
    }
}

/// The hub's highlight row (thumbnail + play badge, the two
/// teams, the video's own headline, league + date).
struct HighlightRow87: View {
    let item: HubHighlight

    var body: some View {
        HStack(spacing: 12) {
            HighlightThumb(url: item.video.thumbnailURL)
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
