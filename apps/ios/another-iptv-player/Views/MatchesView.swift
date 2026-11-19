import Combine
import SwiftUI

// MARK: - Today's Matches (build 61, B12 / M1, M3–M5)
//
// Owner's words: "مجرد لايف ونتيجة" — live + result ONLY. A row shows
// team logos, team names (exactly as the ESPN payload provides them),
// the score, and the match state. NOTHING else: no statistics, news,
// lineups, tables or commentary, and rows do not tap through anywhere
// (M4). Data comes from MatchesService (ESPN public scoreboard JSON).
//
// Freshness (M3/M5): while this screen is open, the VISIBLE tab
// auto-refreshes every ~60 s via the `.task(id:)` loop below — the
// task is cancelled automatically on tab switch and on disappear.
// Pull-to-refresh is available too. If a refresh fails after a
// successful load, the previous data stays on screen but is marked
// STALE with its last-updated time (and live markers lose their live
// styling) — stale scores are never presented as current. A league
// that loaded with zero events shows "No matches today"; a league
// that failed shows an error with Retry. The two are distinct (M5).

@MainActor
final class MatchesViewModel: ObservableObject {
    struct LeagueSection: Identifiable {
        let index: Int
        var id: Int { index }
        /// Last successfully loaded payload for this league; nil when
        /// nothing has loaded yet (or every attempt so far failed).
        var result: MatchLeagueResult?
        /// The latest attempt for this league failed AND there is no
        /// data to show for it.
        var failed: Bool = false
    }

    struct SportState {
        var sections: [LeagueSection] = []
        var hasLoaded = false
        var isLoading = false
        var lastUpdated: Date?
        /// A refresh failed while older data is on screen.
        var isStale = false
    }

    @Published private(set) var states: [MatchSport: SportState] = [:]

    func state(for sport: MatchSport) -> SportState {
        states[sport] ?? SportState()
    }

    func loadIfNeeded(sport: MatchSport) async {
        guard !state(for: sport).hasLoaded else { return }
        await refresh(sport: sport)
    }

    func refresh(sport: MatchSport) async {
        var working = state(for: sport)
        guard !working.isLoading else { return }
        working.isLoading = true
        if working.sections.isEmpty {
            working.sections = sport.leaguePaths.indices.map { LeagueSection(index: $0) }
        }
        states[sport] = working

        let outcomes = await MatchesService.fetchSport(
            sport,
            dateParameter: MatchesService.todayParameter()
        )

        working = state(for: sport)
        var anySuccess = false
        var anyFailureWithKeptData = false
        for (index, outcome) in outcomes.enumerated() {
            guard working.sections.indices.contains(index) else { continue }
            switch outcome {
            case .loaded(let result):
                working.sections[index].result = result
                working.sections[index].failed = false
                anySuccess = true
            case .failed:
                if working.sections[index].result != nil {
                    // Keep the old data; the sport is marked stale below.
                    anyFailureWithKeptData = true
                } else {
                    working.sections[index].failed = true
                }
            }
        }
        if anySuccess {
            working.hasLoaded = true
            working.lastUpdated = Date()
        }
        working.isStale = anyFailureWithKeptData
        working.isLoading = false
        states[sport] = working
    }
}

struct MatchesView: View {
    @StateObject private var model = MatchesViewModel()
    @State private var selectedSport: MatchSport

    /// Build 63 (owner, item 7): the Home sport shortcuts land on
    /// their own tab directly. Default keeps every existing
    /// `MatchesView()` call site on Soccer, as before.
    init(initialSport: MatchSport = .soccer) {
        _selectedSport = State(initialValue: initialSport)
    }

    /// Build 63 (item 8d): the schedule window (recent past →
    /// today → +7 days) and the day the user is browsing. Today
    /// (index 3) is the default landing day.
    private let scheduleDays = MatchesService.windowDays()
    @State private var selectedDayIndex = 3

    private var selectedDay: Date {
        scheduleDays[min(max(selectedDayIndex, 0), scheduleDays.count - 1)]
    }

    /// Matches of one league section that belong to the selected
    /// day. An event with no parseable date is shown under TODAY
    /// rather than vanishing (the feed returned it in a day query;
    /// its exact day is the only thing unknown).
    private func dayMatches(in section: MatchesViewModel.LeagueSection) -> [MatchEvent] {
        guard let result = section.result else { return [] }
        return result.matches.filter { match in
            guard let start = match.startDate else {
                return Calendar.current.isDateInToday(selectedDay)
            }
            return Calendar.current.isDate(start, inSameDayAs: selectedDay)
        }
    }

    /// Item 12c: team search sheet.
    @State private var showTeamSearch = false
    /// Item 10d: the My Teams strip data.
    @State private var myTeams: [MyTeamEntry] = []
    @ObservedObject private var followStore = FollowedTeamsStore.shared

    private struct MyTeamEntry: Identifiable {
        var id: String { team.id + "|" + match.id }
        let team: FollowedTeam
        let match: MatchEvent
        let sport: MatchSport
    }

    var body: some View {
        VStack(spacing: 0) {
            myTeamsStrip

            Picker("", selection: $selectedSport) {
                ForEach(MatchSport.allCases) { sport in
                    Text(L(sport.titleKey)).tag(sport)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppTheme.spacingScreenMargin)
            .padding(.vertical, 10)

            dayStrip

            sportContent(model.state(for: selectedSport))
        }
        .cinematicBackground()
        .navigationTitle(L("matches.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showTeamSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel(L("matches.search.placeholder"))
            }
        }
        .sheet(isPresented: $showTeamSearch) {
            NavigationStack { TeamSearchView() }
        }
        .task(id: followStore.teams) { await loadMyTeams() }
        // Auto-refresh of the VISIBLE tab only: `.task(id:)` restarts
        // when the tab changes and is cancelled when the view
        // disappears — no timer outlives the screen (M3).
        .task(id: selectedSport) {
            await model.loadIfNeeded(sport: selectedSport)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await model.refresh(sport: selectedSport)
            }
        }
    }

    // MARK: My Teams strip (item 10d)

    /// Followed teams' matches only — live first, then the next
    /// upcoming, then the latest result — across all three
    /// sports, from the item-9 follow set. Renders nothing when
    /// the user follows nobody or no followed team plays in the
    /// checked window (yesterday → tomorrow).
    @ViewBuilder
    private var myTeamsStrip: some View {
        if !myTeams.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("matches.myteams"))
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, AppTheme.spacingScreenMargin)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(myTeams) { entry in
                            NavigationLink {
                                MatchDetailView(
                                    sport: entry.sport,
                                    leaguePath: entry.team.leaguePath,
                                    match: entry.match
                                )
                            } label: {
                                myTeamCard(entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, AppTheme.spacingScreenMargin)
                }
            }
            .padding(.vertical, 10)
            .background(AppTheme.surface.opacity(0.5))
        }
    }

    private func myTeamCard(_ entry: MyTeamEntry) -> some View {
        let match = entry.match
        let opponent = match.home.teamId == entry.team.teamId ? match.away : match.home
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CachedImage(
                    url: (match.home.teamId == entry.team.teamId ? match.home : match.away).logoURL,
                    width: 22, height: 22, cornerRadius: 11, iconName: "shield"
                )
                Text(entry.team.teamName)
                    .font(AppTheme.fontCardTitle)
                    .lineLimit(1)
                if match.state == .live {
                    LivePulseDot()
                }
            }
            Text("vs \(opponent.name ?? "")")
                .font(AppTheme.fontMetadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            switch match.state {
            case .live, .finished:
                Text("\(match.home.score ?? "") – \(match.away.score ?? "")")
                    .font(AppTheme.fontCardTitle)
                    .foregroundStyle(match.state == .live ? AppTheme.accent : .primary)
                    .monospacedDigit()
            case .upcoming:
                if let start = match.startDate {
                    Text(Self.kickoffText(start))
                        .font(AppTheme.fontMetadata.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(width: 168, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                .fill(AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                .stroke(AppTheme.cardBorderColor, lineWidth: 1)
        )
    }

    private func loadMyTeams() async {
        let follows = followStore.teams
        guard !follows.isEmpty else { myTeams = []; return }
        let calendar = Calendar.current
        let today = Date()
        let days = [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        var entries: [MyTeamEntry] = []
        for team in follows {
            guard let sport = MatchSport(rawValue: team.sportRaw) else { continue }
            var candidates: [MatchEvent] = []
            for day in days {
                let events = await MatchesService.matches(sport: sport, leaguePath: team.leaguePath, day: day)
                candidates += events.filter {
                    $0.home.teamId == team.teamId || $0.away.teamId == team.teamId
                }
            }
            let pick = candidates.first { $0.state == .live }
                ?? candidates.filter { $0.state == .upcoming }
                    .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }.first
                ?? candidates.filter { $0.state == .finished }
                    .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }.first
            if let pick {
                entries.append(MyTeamEntry(team: team, match: pick, sport: sport))
            }
        }
        entries.sort { a, b in
            (a.match.state == .live ? 0 : 1) < (b.match.state == .live ? 0 : 1)
        }
        myTeams = entries
    }

    // MARK: Day strip (item 8d)

    private var dayStrip: some View {
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
    }

    private func dayChip(day: Date, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let isToday = Calendar.current.isDateInToday(day)
        return Button(action: action) {
            VStack(spacing: 2) {
                Text(Self.weekdayText(day))
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(isSelected ? AppTheme.onAccent : (isToday ? AppTheme.accent : .secondary))
                Text(Self.dayNumberText(day))
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
        .buttonStyle(.plain)
        .accessibilityLabel(Self.dayAccessibilityText(day))
    }

    static func weekdayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppTheme.appLocale
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    static func dayNumberText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppTheme.appLocale
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    static func dayAccessibilityText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppTheme.appLocale
        formatter.timeZone = TimeZone.current
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: Tab content

    @ViewBuilder
    private func sportContent(_ state: MatchesViewModel.SportState) -> some View {
        if !state.hasLoaded && state.sections.allSatisfy({ !$0.failed }) {
            // First load in flight (or not started yet).
            // X6 (B7): branded loader view swap only.
            BrandedLoader()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedSport != .soccer, let only = state.sections.first, only.result == nil {
            // Single-league tab (NFL/NBA) with nothing loaded:
            // full-screen empty vs error state (M5/O10 pattern).
            if only.failed {
                fullErrorState
            } else {
                fullEmptyState
            }
        } else if selectedSport != .soccer, let only = state.sections.first,
                  only.result != nil, dayMatches(in: only).isEmpty, !only.failed {
            // Build 63 (8d): loaded, but the SELECTED DAY has no
            // fixtures in this league — the honest day empty state.
            fullEmptyState
        } else {
            VStack(spacing: 0) {
                if state.isStale, let updated = state.lastUpdated {
                    staleBanner(updated)
                }
                List {
                    ForEach(state.sections) { section in
                        leagueSection(section, sportState: state)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .refreshable {
                    await model.refresh(sport: selectedSport)
                }
            }
        }
    }

    @ViewBuilder
    private func leagueSection(
        _ section: MatchesViewModel.LeagueSection,
        sportState: MatchesViewModel.SportState
    ) -> some View {
        Section {
            if section.result != nil {
                let matches = dayMatches(in: section)
                if matches.isEmpty {
                    emptyRow
                } else {
                    ForEach(matches) { match in
                        // Build 63 (item 8b): rows open the match
                        // detail (timeline + stats + leaders).
                        NavigationLink {
                            MatchDetailView(
                                sport: selectedSport,
                                leaguePath: selectedSport.leaguePaths[section.index],
                                match: match,
                                leagueName: section.result?.leagueName
                            )
                        } label: {
                            MatchRowView(match: match, isStale: sportState.isStale)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if section.failed {
                errorRow
            } else {
                emptyRow
            }
        } header: {
            if let name = section.result?.leagueName, !name.isEmpty {
                // League name EXACTLY as the payload provides it (M6).
                HStack(spacing: 12) {
                    Text(name)
                        .font(AppTheme.fontBadge)
                        .foregroundStyle(AppTheme.accent)
                    Spacer()
                    // Items 10a/10b: standings for every league;
                    // top scorers for soccer leagues.
                    NavigationLink {
                        StandingsView(
                            sport: selectedSport,
                            leaguePath: selectedSport.leaguePaths[section.index],
                            leagueName: name
                        )
                    } label: {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(L("matches.standings"))
                    if selectedSport == .soccer {
                        NavigationLink {
                            TopScorersView(
                                leaguePath: selectedSport.leaguePaths[section.index],
                                leagueName: name
                            )
                        } label: {
                            Image(systemName: "list.number")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(L("matches.scorers"))
                    }
                }
            }
        }
    }

    // MARK: States (O10 pattern: icon + one-line message + one action)

    private var emptyRow: some View {
        Label(L("matches.empty"), systemImage: "calendar.badge.exclamationmark")
            .font(AppTheme.fontMetadata)
            .foregroundStyle(.secondary)
    }

    private var errorRow: some View {
        HStack {
            Label(L("matches.error"), systemImage: "exclamationmark.triangle")
                .font(AppTheme.fontMetadata)
                .foregroundStyle(.secondary)
            Spacer()
            Button(L("matches.retry")) {
                Task { await model.refresh(sport: selectedSport) }
            }
            .font(AppTheme.fontMetadata.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
        }
    }

    // O10 (B7): the full-screen states render through the ONE
    // shared EmptyStateView — same icon, same localized text, same
    // Retry action as B12's hand-built versions.
    private var fullEmptyState: some View {
        EmptyStateView(iconName: "calendar.badge.exclamationmark", message: L("matches.empty"))
    }

    private var fullErrorState: some View {
        EmptyStateView(
            iconName: "exclamationmark.triangle",
            message: L("matches.error"),
            actionTitle: L("matches.retry"),
            action: { Task { await model.refresh(sport: selectedSport) } }
        )
    }

    private func staleBanner(_ updated: Date) -> some View {
        Label(
            L("matches.stale", Self.timeText(updated)),
            systemImage: "clock.badge.exclamationmark"
        )
        .font(AppTheme.fontBadge)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.spacingScreenMargin)
        .padding(.vertical, 8)
        .background(AppTheme.surface)
    }

    // MARK: Formatting (payload values only — nothing invented)

    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppTheme.appLocale
        formatter.timeZone = TimeZone.current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// Build 63: kickoff label for upcoming rows — today's matches
    /// show the local kickoff time only; later days add the day
    /// (short date + time, app locale, user timezone).
    static func kickoffText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return timeText(date)
        }
        let formatter = DateFormatter()
        formatter.locale = AppTheme.appLocale
        formatter.timeZone = TimeZone.current
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Match row (M3: logo + name + score + state, nothing else)

private struct MatchRowView: View {
    let match: MatchEvent
    let isStale: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 8) {
                teamRow(match.home)
                teamRow(match.away)
            }
            stateColumn
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func teamRow(_ side: MatchTeamSide) -> some View {
        HStack(spacing: 10) {
            CachedImage(
                url: side.logoURL,
                width: 26,
                height: 26,
                cornerRadius: 13,
                iconName: "shield"
            )
            // Team name EXACTLY as the payload provides it (M6).
            Text(side.name ?? "")
                .font(AppTheme.fontCardTitle)
                .lineLimit(1)
            Spacer()
            if match.state != .upcoming, let score = side.score {
                // Item 11(2): a live score change flashes once
                // (goal moment) — see FlashScoreText.
                FlashScoreText(text: score, isLive: match.state == .live)
            }
        }
    }

    @ViewBuilder
    private var stateColumn: some View {
        switch match.state {
        case .live:
            VStack(alignment: .trailing, spacing: 3) {
                if !isStale {
                    HStack(spacing: 4) {
                        // Item 11(1): the LIVE dot gently pulses
                        // (static under Reduce Motion).
                        LivePulseDot()
                        Text(L("matches.live"))
                            .font(AppTheme.fontBadge)
                            .foregroundStyle(AppTheme.accent)
                    }
                }
                if let clock = liveClockText {
                    Text(clock)
                        .font(AppTheme.fontMetadata.weight(.semibold))
                        .foregroundStyle(isStale ? .secondary : AppTheme.accent)
                        .monospacedDigit()
                }
            }
        case .upcoming:
            if let start = match.startDate {
                // Build 63: with the multi-day window an upcoming
                // row can be days away — show the day alongside the
                // kickoff time (formatter output only, no copy).
                // Today's fixtures keep the time-only form.
                Text(MatchesView.kickoffText(start))
                    .font(AppTheme.fontMetadata.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        case .finished:
            Text(L("matches.final"))
                .font(AppTheme.fontMetadata.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// Live clock label built ONLY from payload fields: soccer's
    /// displayClock already reads like "67'"; NFL/NBA pair a period
    /// with a game clock ("Q3 2:14", period 5+ = "OT").
    private var liveClockText: String? {
        let clock = match.displayClock?.trimmingCharacters(in: .whitespaces)
        let hasClock = clock != nil && clock != "0.0" && !(clock?.isEmpty ?? true)
        guard let period = match.period, period > 0 else {
            return hasClock ? clock : nil
        }
        let periodLabel = period <= 4 ? "Q\(period)" : "OT"
        return hasClock ? "\(periodLabel) \(clock!)" : periodLabel
    }
}

// MARK: - Item 11 effects (light; Reduce Motion = static)

/// The LIVE dot: a gentle 1.1 s opacity pulse while the row is
/// on screen. SwiftUI tears the animation down with the view —
/// nothing runs off-screen. Reduce Motion renders it static.
private struct LivePulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(AppTheme.accent)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1 : (pulsing ? 0.35 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

/// A score that flashes ONCE when it changes during a live
/// match (the goal moment): a red-orange highlight that fades
/// over ~1 s. Not fired by ordinary refreshes (the value must
/// actually change), not fired for finished matches, and static
/// under Reduce Motion.
private struct FlashScoreText: View {
    let text: String
    let isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = false
    @State private var lastText: String?

    var body: some View {
        Text(text)
            .font(AppTheme.fontCardTitle)
            .monospacedDigit()
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(AppTheme.accent.opacity(flash ? 0.45 : 0))
            )
            .onAppear { lastText = text }
            .onChange(of: text) { _, newValue in
                defer { lastText = newValue }
                guard isLive, !reduceMotion,
                      let lastText, lastText != newValue else { return }
                flash = true
                withAnimation(.easeOut(duration: 1.0)) { flash = false }
            }
    }
}
