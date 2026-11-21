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
    /// Build 83 (item 2): FotMob's Short / Full column modes.
    @State private var fullMode = false
    /// Build 84 (item 23): when the table on screen came from
    /// the disk cache, the time it was really fetched.
    @State private var stamp: Date?
    /// Build 84 (item 6): the as-it-stands live table.
    @State private var liveMode = false
    @State private var liveMatches: [MatchEvent] = []
    /// Build 84 (item 5): derived last-5 form per teamId,
    /// loaded lazily the first time Full mode opens.
    @State private var form: [String: [String]] = [:]

    /// The groups actually rendered: the official table, or —
    /// in live mode — each group re-ranked with the live
    /// scores applied (LiveTableAdjuster). Zone bars/legend
    /// belong to the OFFICIAL table and are suppressed live.
    private var displayGroups: [StandingGroup] {
        guard liveMode else { return groups }
        return groups.map { group in
            StandingGroup(
                name: group.name,
                entries: LiveTableAdjuster.adjusted(
                    entries: group.entries, liveMatches: liveMatches, sport: sport
                ),
                legend: group.legend
            )
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
                    // Build 84 (item 6): the Live toggle exists
                    // only while a match in this league is
                    // actually in progress right now.
                    if !liveMatches.isEmpty {
                        Toggle(isOn: $liveMode) {
                            HStack(spacing: 6) {
                                Circle().fill(AppTheme.live).frame(width: 7, height: 7)
                                Text(L("matches.table_live"))
                                    .font(AppTheme.fontCardTitle)
                                Text(L("matches.live"))
                                    .font(AppTheme.fontBadge)
                                    .foregroundStyle(AppTheme.live)
                            }
                        }
                        .tint(AppTheme.live)
                    }
                }
                .listRowBackground(AppTheme.surface)
                // Build 84 (items 7/8): the league's leaders
                // and news live one tap from its table.
                Section {
                    NavigationLink {
                        LeadersView(sport: sport, leaguePath: leaguePath, leagueName: leagueName)
                    } label: {
                        Label(L("matches.leaders"), systemImage: "list.number")
                            .font(AppTheme.fontCardTitle)
                    }
                    .buttonStyle(PressOpacityButtonStyle())
                    NavigationLink {
                        LeagueNewsView(leaguePath: leaguePath, leagueName: leagueName)
                    } label: {
                        Label(L("matches.news"), systemImage: "newspaper")
                            .font(AppTheme.fontCardTitle)
                    }
                    .buttonStyle(PressOpacityButtonStyle())
                }
                .listRowBackground(AppTheme.surface)
            }
            ForEach(displayGroups) { group in
                Section {
                    columnHeaderRow(group: group)
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        NavigationLink {
                            TeamPageView(team: TeamRef(
                                id: entry.teamId ?? "", sport: sport,
                                leaguePath: leaguePath, name: entry.teamName,
                                logoURL: entry.logoURL
                            ))
                        } label: {
                            standingRow(index: index, entry: entry, columns: visibleColumns(for: group))
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                        .disabled(entry.teamId == nil)
                    }
                    if !group.legend.isEmpty && !liveMode {
                        legendRow(group: group)
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
        // Build 83 (item 5): the Short/Full swap crossfades on
        // the shared chip token (nil — instant — under Reduce
        // Motion / reduced effects, as everywhere). Build 84:
        // the live-table swap rides the same token.
        .animation(Motion.animate(Motion.chipSwap), value: fullMode)
        .animation(Motion.animate(Motion.chipSwap), value: liveMode)
        .task {
            let result = await MatchesStandingsService.fetch(sport: sport, leaguePath: leaguePath)
            groups = result.groups
            stamp = result.stamp
            loaded = true
            // Item 6: today's live matches in THIS league (the
            // shared day cache — no extra fetch when Matches
            // already loaded the day).
            if let today = try? await MatchesService.fetchLeague(
                path: leaguePath, dateParameter: MatchesService.todayParameter()
            ) {
                liveMatches = today.matches.filter { $0.state == .live }
            }
        }
        .onChange(of: fullMode) { _, isFull in
            // Item 5: form derives lazily — only when the user
            // actually opens the Full set.
            if isFull, form.isEmpty {
                Task { form = await TeamFormService.form(sport: sport, leaguePath: leaguePath) }
            }
        }
    }

    // MARK: Columns (build 83, item 2)

    /// One table column: the ESPN stat it reads and the fixed
    /// cell width that fits its values without wrapping. The
    /// header label is NOT stored here — it resolves from the
    /// payload's own stat labels at render time
    /// (`columnLabel`), so a column can never be titled with a
    /// word ESPN didn't publish. A nil statName is the combined
    /// goals for–against column (soccer Full), whose value and
    /// label are composed from the payload's pointsFor /
    /// pointsAgainst stats.
    private struct StandingColumn: Identifiable {
        let statName: String?
        let width: CGFloat
        let bold: Bool
        var id: String { statName ?? "goalsForAgainst" }
    }

    /// The column SETS, FotMob-style. Soccer Short = played,
    /// goal difference, points; Full adds W/D/L and the
    /// goals for–against column. NBA/NFL sets are built from
    /// the stats those feeds actually return (verified live
    /// 2026-11-20): `pointDifferential` is the TOTAL
    /// differential (PF−PA) in both feeds — the NBA feed's
    /// `differential` is a per-game average and is deliberately
    /// NOT used. Short = the record core; Full adds PF/PA/DIFF.
    private var columns: [StandingColumn] {
        switch sport {
        case .soccer:
            return fullMode
                ? [StandingColumn(statName: "gamesPlayed", width: 28, bold: false),
                   StandingColumn(statName: "wins", width: 24, bold: false),
                   StandingColumn(statName: "ties", width: 24, bold: false),
                   StandingColumn(statName: "losses", width: 24, bold: false),
                   StandingColumn(statName: nil, width: 48, bold: false),
                   StandingColumn(statName: "pointDifferential", width: 34, bold: false),
                   StandingColumn(statName: "points", width: 30, bold: true)]
                : [StandingColumn(statName: "gamesPlayed", width: 30, bold: false),
                   StandingColumn(statName: "pointDifferential", width: 36, bold: false),
                   StandingColumn(statName: "points", width: 32, bold: true)]
        case .nba:
            // Build 84 (items 17/21): the Full set gains the
            // payload's own Home / Road record splits and its
            // streak stat — both verified in the live payload
            // 2026-11-21 (a split TABLE does not exist in any
            // ESPN standings variant, so the splits ship as the
            // columns the payload itself carries). PF/PA leave
            // the Full set to keep the row fittable — the
            // differential column carries their net, and PF/PA
            // remain on the Compare screen.
            return fullMode
                ? [StandingColumn(statName: "wins", width: 26, bold: false),
                   StandingColumn(statName: "losses", width: 26, bold: false),
                   StandingColumn(statName: "winPercent", width: 42, bold: false),
                   StandingColumn(statName: "gamesBehind", width: 34, bold: false),
                   StandingColumn(statName: "Home", width: 38, bold: false),
                   StandingColumn(statName: "Road", width: 38, bold: false),
                   StandingColumn(statName: "pointDifferential", width: 40, bold: false),
                   StandingColumn(statName: "streak", width: 36, bold: false)]
                : [StandingColumn(statName: "wins", width: 28, bold: false),
                   StandingColumn(statName: "losses", width: 28, bold: false),
                   StandingColumn(statName: "winPercent", width: 44, bold: false),
                   StandingColumn(statName: "gamesBehind", width: 36, bold: false)]
        case .nfl:
            return fullMode
                ? [StandingColumn(statName: "wins", width: 26, bold: false),
                   StandingColumn(statName: "losses", width: 26, bold: false),
                   StandingColumn(statName: "ties", width: 24, bold: false),
                   StandingColumn(statName: "winPercent", width: 42, bold: false),
                   StandingColumn(statName: "gamesBehind", width: 34, bold: false),
                   StandingColumn(statName: "Home", width: 38, bold: false),
                   StandingColumn(statName: "Road", width: 38, bold: false),
                   StandingColumn(statName: "pointDifferential", width: 38, bold: false),
                   StandingColumn(statName: "streak", width: 36, bold: false)]
                : [StandingColumn(statName: "wins", width: 28, bold: false),
                   StandingColumn(statName: "losses", width: 28, bold: false),
                   StandingColumn(statName: "ties", width: 26, bold: false),
                   StandingColumn(statName: "winPercent", width: 44, bold: false)]
        }
    }

    /// A column renders for a group only when the group's
    /// entries actually carry its stat — a group missing a
    /// stat drops the column instead of printing a column of
    /// dashes under a borrowed label.
    private func visibleColumns(for group: StandingGroup) -> [StandingColumn] {
        columns.filter { column in
            guard let statName = column.statName else {
                return group.entries.contains { $0.stats["pointsFor"] != nil && $0.stats["pointsAgainst"] != nil }
            }
            return group.entries.contains { $0.stats[statName] != nil }
        }
    }

    /// The header label for a column, from the payload's own
    /// stat abbreviations (e.g. gamesPlayed → "GP",
    /// pointDifferential → "GD", points → "P" in the soccer
    /// feed; winPercent → "PCT", gamesBehind → "GB" in the
    /// NBA feed). The combined goals column composes its
    /// label from the payload's for/against abbreviations
    /// ("F" / "A" → "F–A").
    private func columnLabel(_ column: StandingColumn, for group: StandingGroup) -> String {
        if let statName = column.statName {
            return group.entries.first(where: { $0.statLabels[statName] != nil })?.statLabels[statName] ?? ""
        }
        let goalsFor = group.entries.first(where: { $0.statLabels["pointsFor"] != nil })?.statLabels["pointsFor"]
        let goalsAgainst = group.entries.first(where: { $0.statLabels["pointsAgainst"] != nil })?.statLabels["pointsAgainst"]
        if let goalsFor, let goalsAgainst { return "\(goalsFor)–\(goalsAgainst)" }
        return ""
    }

    private func columnValue(_ column: StandingColumn, for entry: StandingEntry) -> String {
        if let statName = column.statName {
            return entry.stats[statName] ?? "–"
        }
        if let goalsFor = entry.stats["pointsFor"], let goalsAgainst = entry.stats["pointsAgainst"] {
            return "\(goalsFor)-\(goalsAgainst)"
        }
        return "–"
    }

    // MARK: Rows

    /// The labeled header row (build 83, item 2): every column
    /// named, in the exact slots the data rows use, so labels
    /// and values can never drift apart.
    private func columnHeaderRow(group: StandingGroup) -> some View {
        let cols = visibleColumns(for: group)
        return HStack(spacing: 6) {
            Color.clear.frame(width: 3)
            Text("#")
                .frame(width: 20, alignment: .trailing)
            Color.clear.frame(width: 22)
            Text(L("matches.team_label"))
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(cols) { column in
                Text(columnLabel(column, for: group))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: column.width, alignment: .trailing)
            }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
    }

    /// Build 83 (item 2): the FotMob row — zone bar (payload
    /// note color only), rank, crest, the FULL team name (two
    /// lines when it needs them — never clipped to fragments
    /// by fixed stat cells again), then one aligned,
    /// never-wrapping cell per labeled column. Values are
    /// `fixedSize` inside fixed-width frames: a value that
    /// somehow exceeds its cell overflows invisibly into its
    /// own padding rather than wrapping mid-number (the old
    /// "-20/7" defect).
    private func standingRow(index: Int, entry: StandingEntry, columns: [StandingColumn]) -> some View {
        HStack(spacing: 6) {
            zoneBar(for: entry)
            Text("\(index + 1)")
                .font(AppTheme.fontMetadata.weight(.bold))
                .monospacedDigit()
                .frame(width: 20, alignment: .trailing)
            CachedImage(url: entry.logoURL, width: 22, height: 22, cornerRadius: 11, iconName: "shield")
            // Build 84 (item 5): in Full mode the derived
            // last-results chips ride under the name — the
            // count shown is exactly the count the scoreboard
            // derivation found (never padded to five).
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.teamName)
                    .font(AppTheme.fontCardTitle)
                    .lineLimit(2)
                if fullMode, let teamId = entry.teamId,
                   let results = form[teamId], !results.isEmpty {
                    FormChipsRow(results: results)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { column in
                Text(columnValue(column, for: entry))
                    .font(column.bold ? AppTheme.fontCardTitle : AppTheme.fontMetadata)
                    .foregroundStyle(column.bold ? .primary : .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: column.width, alignment: .trailing)
            }
        }
    }

    /// The zone bar: rendered ONLY when the payload attached
    /// a note with a parseable color to this entry. Leagues
    /// whose feed carries no notes (NBA, NFL, some soccer
    /// leagues) get an empty slot of the same width — never a
    /// bar inferred from the rank.
    @ViewBuilder
    private func zoneBar(for entry: StandingEntry) -> some View {
        // Build 84 (item 6): in live mode the notes describe
        // OFFICIAL positions — no zone bars on the live table.
        if !liveMode, let hex = entry.noteColorHex, let color = zoneColor(hex) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 3, height: 26)
        } else {
            Color.clear.frame(width: 3)
        }
    }

    /// The group's legend: the payload's own zone descriptions
    /// with their colors, in table order.
    private func legendRow(group: StandingGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(group.legend) { item in
                if let color = zoneColor(item.colorHex) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color)
                            .frame(width: 10, height: 10)
                        Text(item.text)
                            .font(AppTheme.fontMetadata)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Parses the payload's "#RRGGBB" note color. Anything
    /// else → nil (no bar, no legend swatch).
    private func zoneColor(_ hex: String) -> Color? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
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
            PitchView(side: side, lines: lines, sport: sport, leaguePath: leaguePath)
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

    @ViewBuilder
    private func playerRow(_ player: MatchLineupPlayer) -> some View {
        // Build 84 (item 4): lineup rows open the player page.
        if let athleteId = player.athleteId {
            NavigationLink {
                PlayerPageView(
                    sport: sport, leaguePath: leaguePath,
                    athleteId: athleteId, fallbackName: player.name
                )
            } label: {
                playerRowContent(player)
            }
            .buttonStyle(PressOpacityButtonStyle())
        } else {
            playerRowContent(player)
        }
    }

    private func playerRowContent(_ player: MatchLineupPlayer) -> some View {
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
    /// Build 84 (item 4): pitch markers + bench rows open the
    /// player page — the surface needs its sport/league scope.
    let sport: MatchSport
    let leaguePath: String
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
                        // Build 84 (item 4): bench rows open
                        // the player page too.
                        if let athleteId = player.athleteId {
                            NavigationLink {
                                PlayerPageView(
                                    sport: sport, leaguePath: leaguePath,
                                    athleteId: athleteId, fallbackName: player.name
                                )
                            } label: {
                                benchRow(player)
                            }
                            .buttonStyle(PressOpacityButtonStyle())
                        } else {
                            benchRow(player)
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

    private func benchRow(_ player: MatchLineupPlayer) -> some View {
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

    @ViewBuilder
    private func marker(_ player: MatchLineupPlayer) -> some View {
        let flatIndex = lines.flatMap { $0 }.firstIndex(of: player) ?? 0
        let content = VStack(spacing: 2) {
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
        // Build 84 (item 4): a pitch marker opens the player
        // page (the entrance stagger above is untouched).
        if let athleteId = player.athleteId {
            NavigationLink {
                PlayerPageView(
                    sport: sport, leaguePath: leaguePath,
                    athleteId: athleteId, fallbackName: player.name
                )
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
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
    /// Build 84 (item 12): the team's own leaders from the
    /// verified core team-leaders endpoint.
    @State private var teamLeaders: [(category: String, rows: [LeaderRow84])] = []
    @ObservedObject private var followStore = FollowedTeamsStore.shared

    private var isFollowed: Bool {
        followStore.team(sport: team.sport, leaguePath: team.leaguePath, teamId: team.id) != nil
    }

    /// The next upcoming fixture (for the item-10 countdown).
    private var nextFixture: MatchEvent? {
        upcoming.filter { $0.state == .upcoming }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            .first
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
                    CachedImage(url: team.logoURL, width: 52, height: 52, cornerRadius: 26, iconName: "shield")
                    Text(team.name)
                        .font(AppTheme.fontSectionTitle)
                        .lineLimit(2)
                    Spacer()
                    followButton
                }
                // Build 84 (item 10): a followed team's next
                // match carries a live countdown to kickoff.
                if isFollowed, let next = nextFixture, let start = next.startDate {
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .foregroundStyle(AppTheme.accent)
                        Text(next.home.teamId == team.id
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
                // Build 84 (item 22): compare this team with
                // another from the same league.
                NavigationLink {
                    CompareTeamsView(team: team)
                } label: {
                    Label(L("matches.compare"), systemImage: "arrow.left.arrow.right")
                        .font(AppTheme.fontCardTitle)
                }
                .buttonStyle(PressOpacityButtonStyle())
            }
            .listRowBackground(AppTheme.surface)

            // Build 84 (item 12): the FULL season lists — the
            // build-63 prefix(8) caps are gone; the schedule
            // endpoint returns the whole season (verified).
            if !upcoming.isEmpty {
                Section {
                    ForEach(upcoming) { match in
                        NavigationLink {
                            MatchDetailView(sport: team.sport, leaguePath: team.leaguePath, match: match)
                        } label: {
                            TeamFixtureRow(match: match, focusTeamId: team.id)
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                } header: { extrasSectionHeader(L("matches.team.next")) }
                .listRowBackground(AppTheme.surface)
            }
            if !results.isEmpty {
                Section {
                    ForEach(results) { match in
                        NavigationLink {
                            MatchDetailView(sport: team.sport, leaguePath: team.leaguePath, match: match)
                        } label: {
                            TeamFixtureRow(match: match, focusTeamId: team.id)
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                } header: { extrasSectionHeader(L("matches.team.recent")) }
                .listRowBackground(AppTheme.surface)
            }
            // Build 84 (item 12): the team's own leaders, from
            // the verified core team-leaders endpoint — each
            // category the payload returns, its top players,
            // tapping through to the player page.
            ForEach(Array(teamLeaders.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group.rows) { row in
                        NavigationLink {
                            PlayerPageView(
                                sport: team.sport, leaguePath: team.leaguePath,
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
                } header: { extrasSectionHeader("\(L("matches.team.leaders")) · \(group.category)") }
                .listRowBackground(AppTheme.surface)
            }
            if !squad.isEmpty {
                Section {
                    ForEach(squad) { player in
                        // Build 84 (item 1, owner — supersedes
                        // build 81's picture removal for THIS
                        // surface): squad rows carry the
                        // player's ESPN photo again (the disc's
                        // initials render only where ESPN has
                        // no photo), and a row with a known
                        // athlete id opens the player page.
                        if let athleteId = player.athleteId {
                            NavigationLink {
                                PlayerPageView(
                                    sport: team.sport, leaguePath: team.leaguePath,
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
            teamLeaders = await MatchesLeadersService.fetchTeam(
                sport: team.sport, leaguePath: team.leaguePath, teamId: team.id
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
        .buttonStyle(PressOpacityButtonStyle())
    }
}

private struct TeamFixtureRow: View {
    let match: MatchEvent
    let focusTeamId: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // Build 80 (item 8): each team on its OWN line —
                // the build-79 combined "Home – Away" line still
                // truncated the away name for long pairings (the
                // same one-row squeeze as the old Home card). The
                // trailing combined score display is unchanged.
                Text(match.home.name ?? "")
                    .font(AppTheme.fontTeamName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(match.away.name ?? "")
                    .font(AppTheme.fontTeamName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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
/// load once from the feed) and opens its team page. Build 84
/// (item 9): players are searchable too — ESPN's public search
/// (verified) — grouped under their own Players section, each
/// opening the player page.
struct TeamSearchView: View {
    @State private var query = ""
    @State private var allTeams: [TeamRef] = []
    @State private var loaded = false
    @State private var playerHits: [PlayerSearchHit] = []
    @Environment(\.dismiss) private var dismiss

    private var results: [TeamRef] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return allTeams.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            if !results.isEmpty {
                Section {
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
                } header: { extrasSectionHeader(L("matches.team_label")) }
                .listRowBackground(AppTheme.surface)
            }
            if !playerHits.isEmpty {
                Section {
                    ForEach(playerHits) { hit in
                        NavigationLink {
                            PlayerPageView(
                                sport: hit.sport, leaguePath: hit.leaguePath,
                                athleteId: hit.athleteId, fallbackName: hit.name
                            )
                        } label: {
                            HStack(spacing: 10) {
                                PlayerPhotoDisc(
                                    url: CoreCoordinates.headshotURL(
                                        sport: hit.sport, athleteId: hit.athleteId, href: nil
                                    ),
                                    name: hit.name, size: 28
                                )
                                Text(hit.name)
                                    .font(AppTheme.fontCardTitle)
                                    .lineLimit(1)
                                Spacer()
                                Text(L(hit.sport.titleKey))
                                    .font(AppTheme.fontMetadata)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                } header: { extrasSectionHeader(L("matches.search.players")) }
                .listRowBackground(AppTheme.surface)
            }
        }
        .task(id: query) {
            // Debounced remote player search (3+ characters).
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else { playerHits = []; return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            playerHits = await PlayerSearchService.search(query: trimmed)
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

// MARK: - League browser (build 83, item 3)

/// The FotMob-style league browser: a search field over the
/// verified league catalog (`MatchSport.soccerLeagueCatalog`),
/// one row per league with its payload logo and name. Opening
/// the browser fires NO network calls — the catalog is local
/// data verified at build time; a league's standings and
/// fixtures load only when its page opens.
struct LeagueBrowserView: View {
    @State private var query = ""

    private var leagues: [SoccerLeague] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return MatchSport.soccerLeagueCatalog }
        return MatchSport.soccerLeagueCatalog.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        List {
            if leagues.isEmpty {
                Text(L("matches.leagues_empty"))
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .listRowBackground(AppTheme.surface)
            }
            ForEach(leagues) { league in
                NavigationLink {
                    LeaguePageView(league: league)
                } label: {
                    HStack(spacing: 12) {
                        CachedImage(
                            url: league.logoURL,
                            width: 30, height: 30,
                            cornerRadius: 6,
                            contentMode: .fit,
                            iconName: "trophy"
                        )
                        Text(league.name)
                            .font(AppTheme.fontCardTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(PressOpacityButtonStyle())
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(L("matches.leagues"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: L("matches.search_leagues"))
    }
}

/// One league's page: its standings and top scorers (the same
/// destinations the Matches home section headers open) plus
/// its fixtures/results for the shared day window, fetched
/// through the existing per-league plumbing
/// (`MatchesService.matches(sport:leaguePath:day:)` — the
/// shared day cache, so a league visited here and a followed
/// team's league share one fetch). Rows are the Matches
/// home's own `MatchRowView` and open the same match detail.
struct LeaguePageView: View {
    let league: SoccerLeague
    private let scheduleDays = MatchesService.windowDays()
    @State private var selectedDayIndex = 3
    @State private var matches: [MatchEvent] = []
    @State private var loaded = false

    private var selectedDay: Date {
        scheduleDays[min(max(selectedDayIndex, 0), scheduleDays.count - 1)]
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    StandingsView(
                        sport: .soccer,
                        leaguePath: league.leaguePath,
                        leagueName: league.name
                    )
                } label: {
                    Label(L("matches.standings"), systemImage: "chart.bar.fill")
                        .font(AppTheme.fontCardTitle)
                }
                .buttonStyle(PressOpacityButtonStyle())
                NavigationLink {
                    LeadersView(
                        sport: .soccer,
                        leaguePath: league.leaguePath,
                        leagueName: league.name
                    )
                } label: {
                    Label(L("matches.leaders"), systemImage: "list.number")
                        .font(AppTheme.fontCardTitle)
                }
                .buttonStyle(PressOpacityButtonStyle())
                NavigationLink {
                    LeagueNewsView(
                        leaguePath: league.leaguePath,
                        leagueName: league.name
                    )
                } label: {
                    Label(L("matches.news"), systemImage: "newspaper")
                        .font(AppTheme.fontCardTitle)
                }
                .buttonStyle(PressOpacityButtonStyle())
            } header: {
                HStack(spacing: 8) {
                    CachedImage(
                        url: league.logoURL,
                        width: 20, height: 20,
                        cornerRadius: 4,
                        contentMode: .fit,
                        iconName: "trophy"
                    )
                    Text(league.name)
                        .font(AppTheme.fontBadge)
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .listRowBackground(AppTheme.surface)

            Section {
                if loaded && matches.isEmpty {
                    Label(L("matches.empty"), systemImage: "calendar.badge.exclamationmark")
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                }
                ForEach(matches) { match in
                    NavigationLink {
                        MatchDetailView(
                            sport: .soccer,
                            leaguePath: league.leaguePath,
                            match: match,
                            leagueName: league.name
                        )
                    } label: {
                        MatchRowView(
                            match: match, isStale: false,
                            watchContext: (sport: .soccer, leaguePath: league.leaguePath)
                        )
                    }
                    .buttonStyle(PressOpacityButtonStyle())
                }
            }
            .listRowBackground(AppTheme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(league.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if !loaded { BrandedLoader() } }
        // The day strip rides ABOVE the list, the Matches
        // home's own arrangement.
        .safeAreaInset(edge: .top, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(scheduleDays.indices, id: \.self) { index in
                        dayChip(day: scheduleDays[index], isSelected: index == selectedDayIndex) {
                            selectedDayIndex = index
                        }
                    }
                }
                .padding(.horizontal, AppTheme.spacingScreenMargin)
                .padding(.vertical, 6)
            }
            .background(AppTheme.background)
        }
        .task(id: selectedDayIndex) {
            loaded = false
            matches = await MatchesService.matches(
                sport: .soccer, leaguePath: league.leaguePath, day: selectedDay
            )
            loaded = true
        }
    }

    /// The Matches home's day chip, same shape and tokens
    /// (weekday/day text from MatchesView's own formatters).
    private func dayChip(day: Date, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let isToday = Calendar.current.isDateInToday(day)
        return Button(action: action) {
            VStack(spacing: 2) {
                Text(MatchesView.weekdayText(day))
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(isSelected ? AppTheme.onAccent : (isToday ? AppTheme.accent : .secondary))
                Text(MatchesView.dayNumberText(day))
                    .font(AppTheme.fontCardTitle)
                    .foregroundStyle(isSelected ? AppTheme.onAccent : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? AppTheme.accent : AppTheme.surface)
            )
        }
        .buttonStyle(PressOpacityButtonStyle())
        .accessibilityLabel(MatchesView.dayAccessibilityText(day))
    }
}
