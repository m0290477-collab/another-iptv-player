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
    @State private var didLoad = false
    @State private var reminderOn = false
    @State private var kickoffPushOn = false
    @EnvironmentObject private var playerOverlay: PlayerOverlayController

    var body: some View {
        List {
            if let seedMatch {
                Section {
                    headerView(seedMatch)
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    WatchPlayButton(sport: .nhl, leaguePath: leaguePath, match: seedMatch)
                }
                .listRowBackground(AppTheme.surface)

                reminderSection(seedMatch)
                kickoffPushSection(seedMatch)
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
                            goalRow(goal)
                        }
                    } header: { b87SectionHeader(period.period) }
                    .listRowBackground(AppTheme.surface)
                }
                if !detail.stars.isEmpty {
                    Section {
                        ForEach(detail.stars) { star in
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
                    } header: { b87SectionHeader(L("matches.detail.top_performers")) }
                    .listRowBackground(AppTheme.surface)
                }
                ForEach(Array(detail.skaterLines.enumerated()), id: \.offset) { index, group in
                    Section {
                        skaterHeader
                        ForEach(group.lines) { line in
                            skaterRow(line)
                        }
                    } header: {
                        b87SectionHeader(teamLabel(for: index) ?? L("matches.box_score"))
                    }
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
        .task {
            reminderOn = MatchReminderService.shared.isScheduled(eventId: eventId)
            kickoffPushOn = MatchKickoffPushStore.shared.contains(eventId: eventId)
            detail = await NHLService.gameDetail(eventId: eventId)
            didLoad = true
        }
    }

    /// Skater-line groups arrive away-first, home-second (the
    /// service's documented order); the seed names them.
    private func teamLabel(for index: Int) -> String? {
        guard let seedMatch else { return nil }
        return index == 0 ? seedMatch.away.name : seedMatch.home.name
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

    /// The local 15-minute reminder — the MatchDetailView
    /// contract verbatim (no optimistic ON).
    @ViewBuilder
    private func reminderSection(_ match: MatchEvent) -> some View {
        if match.state == .upcoming,
           let start = match.startDate, start.addingTimeInterval(-15 * 60) > Date() {
            Section {
                Toggle(isOn: Binding(
                    get: { reminderOn },
                    set: { newValue in
                        Task {
                            _ = await MatchReminderService.shared.setReminder(
                                match: match, leaguePath: leaguePath,
                                sport: .nhl, enabled: newValue
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

    /// The watcher kickoff push — the same generic matches
    /// contract the ESPN sports use.
    @ViewBuilder
    private func kickoffPushSection(_ match: MatchEvent) -> some View {
        if match.state == .upcoming {
            Section {
                Toggle(isOn: Binding(
                    get: { kickoffPushOn },
                    set: { newValue in
                        kickoffPushOn = newValue
                        MatchKickoffPushStore.shared.set(
                            match: match, leaguePath: leaguePath,
                            sport: .nhl, enabled: newValue
                        )
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
}

// MARK: - Formula 1 (item 2)

/// The F1 page: the season's race schedule, the last race's
/// full result, and the driver + constructor standings —
/// all from the free Jolpica/Ergast API, text rows only (the
/// API publishes no photos and none are invented).
struct F1View: View {
    private enum Segment: Hashable {
        case races, results, drivers, constructors
    }

    @State private var segment: Segment = .races
    @State private var races: [F1Race] = []
    @State private var lastRaceName: String?
    @State private var lastResults: [F1ResultRow] = []
    @State private var drivers: [F1DriverStanding] = []
    @State private var constructors: [F1ConstructorStanding] = []
    @State private var didLoad = false

    var body: some View {
        List {
            Section {
                Picker(L("matches.f1"), selection: $segment) {
                    Text(L("matches.f1.races")).tag(Segment.races)
                    Text(L("matches.f1.results")).tag(Segment.results)
                    Text(L("matches.f1.drivers")).tag(Segment.drivers)
                    Text(L("matches.f1.constructors")).tag(Segment.constructors)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            .listRowBackground(Color.clear)

            switch segment {
            case .races:
                Section {
                    if races.isEmpty {
                        emptyRow
                    }
                    ForEach(races) { race in
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
                                Spacer()
                                if let date = race.date {
                                    Text(date.formatted(date: .abbreviated, time: .omitted))
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
                }
                .listRowBackground(AppTheme.surface)
            case .results:
                Section {
                    if lastResults.isEmpty {
                        emptyRow
                    }
                    ForEach(lastResults) { row in
                        resultRow(
                            position: row.position, name: row.driverName,
                            sub: row.constructorName,
                            value: row.timeText ?? row.status
                        )
                    }
                } header: {
                    if let lastRaceName { b87SectionHeader(lastRaceName) }
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
        .task {
            async let schedule = F1Service.schedule()
            async let results = F1Service.lastResults()
            async let driverStandings = F1Service.driverStandings()
            async let constructorStandings = F1Service.constructorStandings()
            races = await schedule
            let last = await results
            lastRaceName = last.raceName
            lastResults = last.rows
            drivers = await driverStandings
            constructors = await constructorStandings
            didLoad = true
        }
    }

    private var emptyRow: some View {
        Text(didLoad ? L("matches.empty") : L("common.loading"))
            .foregroundStyle(.secondary)
    }

    private func resultRow(position: String, name: String, sub: String?, value: String?) -> some View {
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

// MARK: - Tennis (item 4)

/// ATP / WTA tournaments from ESPN's tennis scoreboards:
/// each tournament's groups (Men's/Women's Singles, Doubles…)
/// with their matches — names, per-set scores from the
/// payload's linescores, the winner bolded, state chips.
struct TennisView: View {
    @State private var tourPath = TennisService.tours[0].path
    @State private var tournaments: [TennisTournament] = []
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
            }
            .listRowBackground(Color.clear)

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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(L("matches.tennis"))
        .navigationBarTitleDisplayMode(.inline)
        .animation(Motion.animate(Motion.chipSwap), value: tourPath)
        .task(id: tourPath) {
            didLoad = false
            tournaments = await TennisService.tournaments(tourPath: tourPath)
            didLoad = true
        }
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
                stateChip(match.state)
            }
            playerLine(name: match.name1, sets: match.sets1, isWinner: match.winnerIndex == 0)
            playerLine(name: match.name2, sets: match.sets2, isWinner: match.winnerIndex == 1)
        }
        .padding(.vertical, 2)
    }

    private func playerLine(name: String, sets: [String], isWinner: Bool) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(AppTheme.fontTeamName.weight(isWinner ? .bold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
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

            if let board {
                Section {
                    if board.rows.isEmpty {
                        Text(L("matches.empty"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(board.rows) { row in
                        HStack(spacing: 10) {
                            Text("\(row.position)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 30, alignment: .trailing)
                            Text(row.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !row.roundScores.isEmpty {
                                Text(row.roundScores.joined(separator: " · "))
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
                } header: {
                    if let event = board.eventName { b87SectionHeader(event) }
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
        .task(id: tourPath) {
            didLoad = false
            board = await GolfService.leaderboard(tourPath: tourPath)
            didLoad = true
        }
    }
}

// MARK: - UFC (item 5)

/// UFC cards from ESPN's MMA scoreboard: each card's fights
/// with both athletes, their payload record summaries, the
/// winner bolded once a fight is final, and the payload's
/// own result text ("Final - KO/TKO").
struct UFCView: View {
    @State private var cards: [UFCCard] = []
    @State private var didLoad = false

    var body: some View {
        List {
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
        .task {
            cards = await UFCService.cards()
            didLoad = true
        }
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
        let window = (-1...7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today)
        }
        // The payload-dated sports are fetched ONCE and then
        // bucketed by their own dates; golf is a live board and
        // belongs to today only.
        let allTennis = await TennisService.allMatches()
        let allCards = await UFCService.cards()
        let allRaces = await F1Service.schedule()
        let golfBoard = await GolfService.leaderboard(tourPath: GolfService.tours[0].path)

        days = []
        // A league's day response can span neighbouring days;
        // the date filter pins each dated event to its own day,
        // and this set keeps an undated event (or any repeat)
        // from surfacing in two day sections.
        var seenMatches = Set<String>()
        for day in window {
            let parameter = Self.dayParameter(for: day)
            let groups = await withTaskGroup(of: LiveNowGroup?.self) { group in
                for competition in SportsHubService.allCompetitions {
                    group.addTask {
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
                for await item in group { if let item { out.append(item) } }
                return out
            }
            let order = Dictionary(uniqueKeysWithValues: SportsHubService.allCompetitions.enumerated().map { ($0.element.leaguePath, $0.offset) })
            var bucket = CalendarDay(date: day)
            bucket.leagueMatches = groups
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
            if calendar.isDateInToday(day), let golfBoard, golfBoard.state == .live {
                bucket.golf = golfBoard
            }
            days.append(bucket)
        }
        didLoad = true
    }
}

// MARK: - Live wall (item 8)

/// Build 88 (F11): the wall is now TODAY'S FULL SCHEDULE —
/// every match of the day (live, upcoming, finished), grouped
/// by SPORT in the app's sport order, each sport's matches in
/// kickoff order. Build 87's wall showed only live matches
/// grouped by league, which made it a near-twin of Live Now
/// (same data, same shape, same empty line); now Live Now is
/// the live filter and the wall is the day's programme, useful
/// even when nothing is live. Refresh rides the SAME
/// 60-second loop pattern LiveNowView uses — no new polling.
/// The sport sections are display buckets only: each row
/// keeps its own competition group, so detail routing and
/// Watch matching use the match's REAL leaguePath.
struct LiveWallView: View {
    @State private var sections: [TodaySportSchedule] = []
    @State private var didLoad = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if sections.isEmpty {
                    Text(didLoad ? L("matches.empty") : L("common.loading"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 7) {
                                Image(systemName: MatchesView.sportSymbolName(section.sport))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AppTheme.accent)
                                Text(L(section.sport.titleKey))
                                    .font(AppTheme.fontSectionTitle)
                            }
                            .padding(.horizontal, 16)
                            VStack(spacing: 0) {
                                ForEach(Array(section.entries.enumerated()), id: \.offset) { index, entry in
                                    VStack(alignment: .leading, spacing: 6) {
                                        NavigationLink {
                                            MatchDetailView(
                                                sport: entry.group.sport, leaguePath: entry.group.leaguePath,
                                                match: entry.match, leagueName: entry.group.leagueName
                                            )
                                        } label: {
                                            MatchRowView(match: entry.match, isStale: false, sport: entry.group.sport)
                                        }
                                        .buttonStyle(PressOpacityButtonStyle())
                                        WatchPlayButton(
                                            sport: entry.group.sport, leaguePath: entry.group.leaguePath,
                                            match: entry.match
                                        )
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    if index < section.entries.count - 1 {
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
        .navigationTitle(L("matches.live_wall"))
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
        sections = await SportsHubService.todaySchedule()
        didLoad = true
    }
}

// MARK: - Cross-league top scorers (item 11)

/// The goals leaders of all 17 soccer leagues on one page —
/// the per-league scorers service fanned out and merged,
/// ranked by the payloads' own goal counts, each row naming
/// its league and opening the player page in that league.
struct CrossLeagueScorersView: View {
    @State private var rows: [CrossScorerRow] = []
    @State private var didLoad = false
    /// Build 88 (F1): leagues that have reported back so far —
    /// the loading line names real progress instead of an
    /// indefinite spinner.
    @State private var settledLeagues = 0
    /// At least one league answered (even with no leaders).
    /// When every league failed or timed out, the page shows
    /// the failure state with Retry — never an endless load.
    @State private var anyLeagueAnswered = false
    /// Bumped by Retry to re-run the load task.
    @State private var loadGeneration = 0

    private var leagueCount: Int { MatchSport.soccerLeagueCatalog.count }

    var body: some View {
        List {
            Section {
                if rows.isEmpty {
                    if !didLoad {
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
                    } else if anyLeagueAnswered {
                        Text(L("matches.empty"))
                            .foregroundStyle(.secondary)
                    } else {
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
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        NavigationLink {
                            PlayerPageView(
                                sport: .soccer, leaguePath: row.leaguePath,
                                athleteId: row.entry.athleteId, fallbackName: row.entry.name
                            )
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
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
                                        .compactMap { $0 }.joined(separator: " • "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text("\(row.entry.goals)")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(AppTheme.accent)
                                    .monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L("matches.scorers"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadGeneration) { await load() }
    }

    /// Build 88 (F1): leagues are consumed AS THEY LAND — each
    /// finished league merges into the ranked list immediately
    /// (re-sorted, capped at the merged top 40), so the page
    /// fills in progressively and the wait is bounded by the
    /// service's per-league timeout, never by the slowest
    /// league holding the rest hostage.
    private func load() async {
        rows = []
        settledLeagues = 0
        anyLeagueAnswered = false
        didLoad = false
        await withTaskGroup(of: CrossLeagueFetchOutcome.self) { group in
            for league in MatchSport.soccerLeagueCatalog {
                group.addTask { await CrossLeagueScorersService.fetchLeague(league) }
            }
            for await result in group {
                settledLeagues += 1
                if result.ok { anyLeagueAnswered = true }
                if !result.rows.isEmpty {
                    rows = Array(
                        (rows + result.rows)
                            .sorted { $0.entry.goals > $1.entry.goals }
                            .prefix(40)
                    )
                }
            }
        }
        didLoad = true
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
