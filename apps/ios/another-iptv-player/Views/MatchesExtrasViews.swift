import SwiftUI

// Build 63 (items 10/12): standings, top scorers, lineups,
// team pages and the in-app goal celebration card. All data
// comes from MatchesExtras / TeamService (free ESPN feed) —
// every screen has an honest empty state when the feed
// publishes nothing for that league.

// MARK: - Shared bits

struct PlayerPhotoDisc: View {
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

private func extrasSectionHeader(_ text: String) -> some View {
    Text(text)
        .font(AppTheme.fontBadge)
        .foregroundStyle(AppTheme.accent)
}

// MARK: - 10a Standings

struct StandingsView: View {
    let sport: MatchSport
    let leaguePath: String
    let leagueName: String?
    @State private var groups: [StandingGroup] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && groups.isEmpty {
                Text(L("matches.empty"))
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .listRowBackground(AppTheme.surface)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        NavigationLink {
                            TeamPageView(team: TeamRef(
                                id: entry.teamId ?? "", sport: sport,
                                leaguePath: leaguePath, name: entry.teamName,
                                logoURL: entry.logoURL
                            ))
                        } label: {
                            standingRow(index: index, entry: entry)
                        }
                        .disabled(entry.teamId == nil)
                    }
                } header: {
                    if !group.name.isEmpty { extrasSectionHeader(group.name) }
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
        .task {
            groups = await MatchesStandingsService.fetch(sport: sport, leaguePath: leaguePath)
            loaded = true
        }
    }

    private func standingRow(index: Int, entry: StandingEntry) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(AppTheme.fontMetadata.weight(.bold))
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)
            CachedImage(url: entry.logoURL, width: 24, height: 24, cornerRadius: 12, iconName: "shield")
            Text(entry.teamName)
                .font(AppTheme.fontCardTitle)
                .lineLimit(1)
            Spacer()
            statCell(entry.stats["gamesPlayed"])
            statCell(entry.stats["wins"])
            statCell(entry.stats["ties"])
            statCell(entry.stats["losses"])
            statCell(entry.stats["pointDifferential"])
            Text(entry.stats["points"] ?? "–")
                .font(AppTheme.fontCardTitle)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func statCell(_ value: String?) -> some View {
        Text(value ?? "–")
            .font(AppTheme.fontMetadata)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(width: 24, alignment: .trailing)
    }
}

// MARK: - 10b Top scorers

struct TopScorersView: View {
    let leaguePath: String
    let leagueName: String?
    @State private var scorers: [ScorerEntry] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && scorers.isEmpty {
                Text(L("matches.empty"))
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .listRowBackground(AppTheme.surface)
            }
            ForEach(Array(scorers.enumerated()), id: \.element.id) { index, scorer in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(AppTheme.fontMetadata.weight(.bold))
                        .monospacedDigit()
                        .frame(width: 22, alignment: .trailing)
                    PlayerPhotoDisc(url: scorer.headshotURL, name: scorer.name, size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(scorer.name)
                            .font(AppTheme.fontCardTitle)
                            .lineLimit(1)
                        if let team = scorer.teamName {
                            Text(team)
                                .font(AppTheme.fontMetadata)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text("\(scorer.goals)")
                        .font(.title3.weight(.black))
                        .foregroundStyle(AppTheme.accent)
                        .monospacedDigit()
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(leagueName ?? L("matches.scorers"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if !loaded { BrandedLoader() } }
        .task {
            scorers = await MatchesScorersService.fetch(leaguePath: leaguePath)
            loaded = true
        }
    }
}

// MARK: - 10f Lineups

struct LineupsView: View {
    let sport: MatchSport
    let leaguePath: String
    let sides: [MatchLineupSide]
    @State private var selectedSide = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if sides.count > 1 {
                    Picker("", selection: $selectedSide) {
                        ForEach(Array(sides.enumerated()), id: \.offset) { index, side in
                            Text(side.teamName ?? "").tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if sides.indices.contains(selectedSide) {
                    sideView(sides[selectedSide])
                }
            }
            .padding(16)
        }
        .cinematicBackground()
        .navigationTitle(L("matches.lineups"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func sideView(_ side: MatchLineupSide) -> some View {
        if sport == .soccer, let lines = pitchLines(side) {
            PitchView(side: side, lines: lines)
        } else {
            groupedList(side)
        }
    }

    /// Lays starters out by the feed's formation ("4-3-3",
    /// "3-4-2-1", …): formation digits are the outfield lines
    /// front-to-back counts; players fill lines by position
    /// class (GK / defenders / holding mids / mids / forwards).
    /// Returns nil — the grouped-list fallback — when the
    /// formation is missing, unparseable, or its counts don't
    /// match the starters the feed lists. Nothing is invented.
    private func pitchLines(_ side: MatchLineupSide) -> [[MatchLineupPlayer]]? {
        guard let formation = side.formation else { return nil }
        let counts = formation.split(separator: "-").map { Int($0) }
        guard counts.allSatisfy({ $0 != nil }) else { return nil }
        let lineCounts = counts.compactMap { $0 }
        let starters = side.starters
        guard lineCounts.reduce(0, +) + 1 == starters.count, starters.count >= 5 else { return nil }

        func posClass(_ player: MatchLineupPlayer) -> Int {
            let abbr = (player.positionAbbreviation ?? "").uppercased()
            if abbr.hasPrefix("G") { return 0 }
            if abbr.contains("B") || abbr.hasPrefix("CD") || abbr.hasPrefix("SW") { return 1 }
            if abbr.hasPrefix("DM") { return 2 }
            if abbr.contains("M") || abbr.hasPrefix("AM") { return 3 }
            return 4 // forwards / strikers / wingers
        }
        let keeper = starters.filter { posClass($0) == 0 }
        guard keeper.count == 1 else { return nil }
        var pool = starters.filter { posClass($0) != 0 }
        var lines: [[MatchLineupPlayer]] = [keeper]
        // Line classes in order: defenders, then (for 4-part
        // formations) holding mids, then mids, then forwards.
        // Each line takes its class members first (overflow
        // stays in the pool for the next line), then fills any
        // shortfall from what remains, in feed order.
        let classOrder: [Int] = lineCounts.count >= 4 ? [1, 2, 3, 4] : [1, 3, 4]
        for (index, count) in lineCounts.enumerated() {
            let wanted = classOrder[min(index, classOrder.count - 1)]
            var line = Array(pool.filter { posClass($0) == wanted }.prefix(count))
            if line.count < count {
                line += pool.filter { !line.contains($0) }.prefix(count - line.count)
            }
            pool.removeAll { line.contains($0) }
            lines.append(line)
        }
        guard pool.isEmpty, lines.allSatisfy({ !$0.isEmpty }) else { return nil }
        return lines
    }

    private func groupedList(_ side: MatchLineupSide) -> some View {
        let groups: [(String, [MatchLineupPlayer])] = [
            ("GK", side.starters.filter { ($0.positionAbbreviation ?? "").hasPrefix("G") }),
            ("DEF", side.starters.filter { p in
                let a = p.positionAbbreviation ?? ""
                return a.contains("B") || a.hasPrefix("CD")
            }),
            ("MID", side.starters.filter { p in
                let a = p.positionAbbreviation ?? ""
                return a.contains("M")
            }),
            ("FWD", side.starters.filter { p in
                let a = p.positionAbbreviation ?? ""
                return !a.hasPrefix("G") && !a.contains("B") && !a.hasPrefix("CD") && !a.contains("M")
            })
        ]
        return VStack(alignment: .leading, spacing: 14) {
            if let formation = side.formation {
                Text(formation)
                    .font(AppTheme.fontCardTitle)
                    .foregroundStyle(AppTheme.accent)
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                if !group.1.isEmpty {
                    ForEach(group.1) { playerRow($0) }
                }
            }
            if !side.bench.isEmpty {
                Divider().background(AppTheme.cardBorderColor)
                ForEach(side.bench) { playerRow($0) }
            }
        }
    }

    private func playerRow(_ player: MatchLineupPlayer) -> some View {
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
}

/// The pitch: a dark field with line markings; each formation
/// line is a row of player markers (photo/initials + short
/// name). Markers animate in with a short stagger on open —
/// item 11(4) — unless Reduce Motion is on.
private struct PitchView: View {
    let side: MatchLineupSide
    let lines: [[MatchLineupPlayer]]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                CachedImage(url: side.logoURL, width: 26, height: 26, cornerRadius: 13, iconName: "shield")
                Text(side.teamName ?? "")
                    .font(AppTheme.fontCardTitle)
                    .lineLimit(1)
                Spacer()
                if let formation = side.formation {
                    Text(formation)
                        .font(AppTheme.fontMetadata.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .fill(Color(red: 0.07, green: 0.16, blue: 0.10))
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    .frame(width: 74, height: 74)
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 0) {
                            ForEach(line) { player in
                                marker(player)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.vertical, 10)
            }
            .aspectRatio(0.78, contentMode: .fit)
            if !side.bench.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(side.bench) { player in
                        HStack(spacing: 10) {
                            PlayerPhotoDisc(url: player.headshotURL, name: player.name, size: 28)
                            Text(player.name)
                                .font(AppTheme.fontMetadata)
                                .lineLimit(1)
                            Spacer()
                            if let position = player.positionName {
                                Text(position)
                                    .font(AppTheme.fontMetadata)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(.easeOut(duration: 0.35)) { appeared = true } }
        }
    }

    private func marker(_ player: MatchLineupPlayer) -> some View {
        let flatIndex = lines.flatMap { $0 }.firstIndex(of: player) ?? 0
        return VStack(spacing: 2) {
            PlayerPhotoDisc(url: player.headshotURL, name: player.name, size: 34)
            Text(shortName(player.name))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 62)
                .shadow(color: .black.opacity(0.6), radius: 2)
        }
        .frame(maxWidth: .infinity)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.3).delay(Double(flatIndex) * 0.04),
            value: appeared
        )
    }

    private func shortName(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard let last = parts.last else { return name }
        return parts.count > 1 ? String(last) : name
    }
}

// MARK: - 12a Team page

struct TeamPageView: View {
    let team: TeamRef
    @State private var fixtures: [MatchEvent] = []
    @State private var squad: [SquadPlayer] = []
    @State private var loaded = false
    @ObservedObject private var followStore = FollowedTeamsStore.shared

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
                    CachedImage(url: team.logoURL, width: 52, height: 52, cornerRadius: 26, iconName: "shield")
                    Text(team.name)
                        .font(AppTheme.fontSectionTitle)
                        .lineLimit(2)
                    Spacer()
                    followButton
                }
            }
            .listRowBackground(AppTheme.surface)

            if !upcoming.isEmpty {
                Section {
                    ForEach(upcoming.prefix(8)) { match in
                        NavigationLink {
                            MatchDetailView(sport: team.sport, leaguePath: team.leaguePath, match: match)
                        } label: {
                            TeamFixtureRow(match: match, focusTeamId: team.id)
                        }
                    }
                } header: { extrasSectionHeader(L("matches.team.next")) }
                .listRowBackground(AppTheme.surface)
            }
            if !results.isEmpty {
                Section {
                    ForEach(results.prefix(8)) { match in
                        NavigationLink {
                            MatchDetailView(sport: team.sport, leaguePath: team.leaguePath, match: match)
                        } label: {
                            TeamFixtureRow(match: match, focusTeamId: team.id)
                        }
                    }
                } header: { extrasSectionHeader(L("matches.team.recent")) }
                .listRowBackground(AppTheme.surface)
            }
            if !squad.isEmpty {
                Section {
                    ForEach(squad) { player in
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
                } header: { extrasSectionHeader(L("matches.team.squad")) }
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
        .navigationTitle(team.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if !loaded { BrandedLoader() } }
        .task {
            async let schedule = TeamService.schedule(sport: team.sport, leaguePath: team.leaguePath, teamId: team.id)
            async let roster = TeamService.squad(sport: team.sport, leaguePath: team.leaguePath, teamId: team.id)
            fixtures = await schedule
            squad = await roster
            loaded = true
        }
    }

    private var followButton: some View {
        let followed = followStore.team(sport: team.sport, leaguePath: team.leaguePath, teamId: team.id) != nil
        return Button {
            if followed {
                followStore.unfollow(sport: team.sport, leaguePath: team.leaguePath, teamId: team.id)
            } else {
                followStore.follow(sport: team.sport, leaguePath: team.leaguePath, teamId: team.id, teamName: team.name)
            }
        } label: {
            Text(followed ? L("matches.following") : L("matches.follow"))
                .font(AppTheme.fontBadge)
                .foregroundStyle(followed ? .secondary : AppTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().stroke(followed ? Color.secondary.opacity(0.4) : AppTheme.accent, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct TeamFixtureRow: View {
    let match: MatchEvent
    let focusTeamId: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(match.home.name ?? "") – \(match.away.name ?? "")")
                    .font(AppTheme.fontCardTitle)
                    .lineLimit(1)
                if let start = match.startDate {
                    Text(MatchesView.kickoffText(start))
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch match.state {
            case .live:
                Text("\(match.home.score ?? "") – \(match.away.score ?? "")")
                    .font(AppTheme.fontCardTitle)
                    .foregroundStyle(AppTheme.accent)
                    .monospacedDigit()
            case .finished:
                Text("\(match.home.score ?? "") – \(match.away.score ?? "")")
                    .font(AppTheme.fontCardTitle)
                    .monospacedDigit()
            case .upcoming:
                EmptyView()
            }
        }
    }
}

// MARK: - 12d Goal celebration (browsing only)

/// The celebration card host. Rendered by the dashboards ABOVE
/// browsing content but BELOW the player overlay (the player
/// host renders after it), and the presenter itself drops every
/// alert while a player presentation is active — so this can
/// never appear over playback (item 12d corrected rule).
struct GoalAlertHostView: View {
    @ObservedObject private var presenter = GoalAlertPresenter.shared

    var body: some View {
        ZStack {
            if let alert = presenter.current {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "soccerball")
                            .foregroundStyle(AppTheme.accent)
                        Text(L("matches.goal"))
                            .font(AppTheme.fontSectionTitle)
                            .foregroundStyle(AppTheme.accent)
                        Spacer()
                        Button { presenter.dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    PlayerPhotoDisc(url: alert.headshotURL, name: alert.scorerName, size: 56)
                    if let scorer = alert.scorerName {
                        Text(scorer + (alert.minuteText.map { "  \($0)" } ?? ""))
                            .font(AppTheme.fontCardTitle)
                            .multilineTextAlignment(.center)
                    }
                    Text(alert.scoreText)
                        .font(AppTheme.fontMetadata.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .frame(maxWidth: 300)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                        .fill(AppTheme.surface)
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                        .stroke(AppTheme.accent.opacity(0.5), lineWidth: 1)
                )
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: presenter.current?.id)
        .allowsHitTesting(presenter.current != nil)
    }
}

// MARK: - 12c Team search

/// Finds any team across the three sports (the full team lists
/// load once from the feed) and opens its team page.
struct TeamSearchView: View {
    @State private var query = ""
    @State private var allTeams: [TeamRef] = []
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    private var results: [TeamRef] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return allTeams.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            ForEach(results) { team in
                NavigationLink {
                    TeamPageView(team: team)
                } label: {
                    HStack(spacing: 10) {
                        CachedImage(url: team.logoURL, width: 28, height: 28, cornerRadius: 14, iconName: "shield")
                        Text(team.name)
                            .font(AppTheme.fontCardTitle)
                            .lineLimit(1)
                        Spacer()
                        Text(L(team.sport.titleKey))
                            .font(AppTheme.fontMetadata)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(AppTheme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(L("matches.search.placeholder"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: L("matches.search.placeholder"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L("common.done")) { dismiss() }
            }
        }
        .overlay { if !loaded { BrandedLoader() } }
        .task {
            var teams: [TeamRef] = []
            for sport in MatchSport.allCases {
                teams += await TeamService.allTeams(sport: sport)
            }
            allTeams = teams
            loaded = true
        }
    }
}
