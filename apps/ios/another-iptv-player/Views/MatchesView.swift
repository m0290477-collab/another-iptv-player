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

        // Build 90 (SP6): publish each league as its window
        // lands instead of one publish after the whole pass —
        // a single hung league (20 s timeout) no longer delays
        // every other league's first paint. Same fetches, same
        // per-league outcome semantics as the old fetchSport
        // fan-out (which Home still uses unchanged).
        var anyFailureWithKeptData = false
        let paths = sport.leaguePaths
        await withTaskGroup(of: (Int, MatchLeagueOutcome).self) { group in
            for (index, path) in paths.enumerated() {
                group.addTask {
                    (index, await MatchesService.fetchLeagueWindow(path: path))
                }
            }
            for await (index, outcome) in group {
                var current = state(for: sport)
                guard current.sections.indices.contains(index) else { continue }
                switch outcome {
                case .loaded(let result):
                    current.sections[index].result = result
                    current.sections[index].failed = false
                    current.hasLoaded = true
                    current.lastUpdated = Date()
                case .failed:
                    if current.sections[index].result != nil {
                        // Keep the old data; the sport is marked stale below.
                        anyFailureWithKeptData = true
                    } else {
                        current.sections[index].failed = true
                    }
                }
                states[sport] = current
            }
        }

        working = state(for: sport)
        working.isStale = anyFailureWithKeptData
        // Build 84 (item 23): if any of this sport's scoreboards
        // was served from the sports disk cache during this
        // refresh (network down), the on-screen data is stale
        // with the cache's real timestamp — the banner's time
        // is that timestamp, not now.
        if let diskStamp = MatchesService.diskServedStamp(for: sport) {
            working.isStale = true
            working.lastUpdated = diskStamp
        }
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

    /// Build 66 (item 12): sports-section first-entry explainer —
    /// shown ONCE per sport. The literal keys are
    /// `SportsExplainerFlag.key(for:)` ("explainer.seen." + the
    /// sport's raw value); @AppStorage needs literals, so the two
    /// must stay in step.
    @AppStorage("explainer.seen.soccer") private var explainerSeenSoccer = false
    @AppStorage("explainer.seen.nfl") private var explainerSeenNFL = false
    @AppStorage("explainer.seen.nba") private var explainerSeenNBA = false
    /// Build 85: the MLB tab's first-entry explainer flag.
    @AppStorage("explainer.seen.mlb") private var explainerSeenMLB = false
    /// Build 87: the NHL tab's first-entry explainer flag.
    @AppStorage("explainer.seen.nhl") private var explainerSeenNHL = false
    /// The sport whose explainer sheet is currently presented.
    @State private var explainerSport: MatchSport?
    /// The last sport the explainer was presented for — by the
    /// time a sheet's `onDismiss` runs the item binding is already
    /// nil, so a swipe dismissal recovers its sport from here.
    @State private var lastExplainerSport: MatchSport?
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

            // Build 88 (sports look, owner-approved mockup): the
            // segmented control gives way to the mockup's chip
            // strip — one pill per sport with its symbol, the
            // selected chip filled with the accent and glowing,
            // the rest quiet surface pills. Same selection, same
            // tabs; only the control's skin changed.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MatchSport.allCases) { sport in
                        sportChip(sport)
                    }
                }
                .padding(.horizontal, AppTheme.spacingScreenMargin)
                .padding(.vertical, 10)
            }

            dayStrip

            hubRow

            sportContent(model.state(for: selectedSport))
        }
        // Build 81 (item 8): sport/day switches ease instead of
        // snapping (contentIn token; stilled by Reduce Motion /
        // intensity via Motion.animate).
        .animation(Motion.animate(Motion.contentIn), value: selectedSport)
        .animation(Motion.animate(Motion.contentIn), value: selectedDayIndex)
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
        // Build 66 (item 12): the first-entry explainer sheet for
        // the selected sport. EVERY dismissal path marks the sport
        // seen: both buttons call `markExplainerSeen` directly, and
        // a swipe lands in `onDismiss`, which marks the last
        // presented sport seen (marking twice is harmless).
        .sheet(item: $explainerSport, onDismiss: {
            if let sport = lastExplainerSport {
                markExplainerSeen(sport)
            }
        }) { sport in
            SportsExplainerView(sport: sport) {
                markExplainerSeen(sport)
                explainerSport = nil
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onAppear { presentExplainerIfNeeded(for: selectedSport) }
        .onChange(of: selectedSport) { _, newSport in
            presentExplainerIfNeeded(for: newSport)
        }
        .task(id: followStore.teams) { await loadMyTeams() }
        // Auto-refresh of the VISIBLE tab only: `.task(id:)` restarts
        // when the tab changes and is cancelled when the view
        // disappears — no timer outlives the screen (M3).
        .task(id: selectedSport) {
            await model.loadIfNeeded(sport: selectedSport)
            liveNowCount = await SportsHubService.liveCount()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await model.refresh(sport: selectedSport)
                liveNowCount = await SportsHubService.liveCount()
            }
        }
    }

    // MARK: Sport chips (build 88)

    /// One sport pill: symbol + title. Selected = accent fill
    /// with a soft accent glow (the mockup's lit chip); the swap
    /// springs on the shared chip token, stilled by Reduce
    /// Motion via Motion.animate like every other swap.
    private func sportChip(_ sport: MatchSport) -> some View {
        let isSelected = sport == selectedSport
        return Button {
            withAnimation(Motion.animate(Motion.chipSwap)) { selectedSport = sport }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Self.sportSymbolName(sport))
                    .font(.system(size: 13, weight: .semibold))
                Text(L(sport.titleKey))
                    .font(AppTheme.fontCardTitle)
            }
            .foregroundStyle(isSelected ? AppTheme.onAccent : .primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isSelected ? AppTheme.accent : AppTheme.surface)
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.clear : AppTheme.cardBorderColor, lineWidth: 1
                )
            )
            .shadow(
                color: isSelected ? AppTheme.accent.opacity(0.45) : .clear,
                radius: isSelected ? 10 : 0, y: isSelected ? 3 : 0
            )
        }
        .buttonStyle(PressOpacityButtonStyle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// THE sport-symbol map (build 90, SP33): the ONE shared
    /// map for every surface — the Matches chips, the Home
    /// sports cards (build 90 deleted Home's private copy) and
    /// the hub pages all resolve through here, so the build-82
    /// drift class (a bad SF Symbol name fixed in one copy
    /// only) cannot recur. Canonical SF Symbols names only; an
    /// unknown name renders zero-size, the build-82
    /// collapsed-card defect.
    static func sportSymbolName(_ sport: MatchSport) -> String {
        switch sport {
        case .soccer: return "soccerball"
        case .nfl: return "american.football.fill"
        case .nba: return "basketball.fill"
        case .mlb: return "baseball.fill"
        case .nhl: return "hockey.puck.fill"
        }
    }

    // MARK: Hub entries (build 84, items 13/14)

    /// Build 84 (item 13): the count of matches live right now
    /// across all 19 competitions, refreshed on the same
    /// 60-second cadence as the tab itself (the aggregation
    /// reads the shared day cache — no extra polling).
    @State private var liveNowCount = 0

    /// Build 87 (items 7/8/11/13/14): the hub row is ONE
    /// horizontally scrolling chip strip in a fixed order —
    /// Live Now (+count), Calendar, Highlights, Top Scorers
    /// — the same destinations from every sport tab, no
    /// duplicated entries anywhere else on the tab. (Build
    /// 90 (SP32): the Live Wall chip is gone — its
    /// sport-grouped today programme folded into Live Now
    /// as the Live/Today switch.)
    /// Build 88 (F1): Top Scorers is a SOCCER page (cross-league
    /// goals leaders) — its chip renders only on the soccer
    /// tab; offering it inside the NFL/NBA/MLB/NHL tabs put a
    /// soccer page in another sport's context.
    private var hubRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                NavigationLink {
                    LiveNowView()
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(AppTheme.live).frame(width: 7, height: 7)
                        Text(L("matches.live_now"))
                            .font(AppTheme.fontCardTitle)
                        if liveNowCount > 0 {
                            Text("\(liveNowCount)")
                                .font(AppTheme.fontBadge)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(AppTheme.live, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(AppTheme.cardBorderColor, lineWidth: 1))
                }
                .buttonStyle(PressOpacityButtonStyle())
                hubChip(systemImage: "calendar", titleKey: "matches.calendar") {
                    SportsCalendarView()
                }
                hubChip(systemImage: "play.rectangle.on.rectangle", titleKey: "matches.highlights_hub") {
                    HighlightsHubView()
                }
                if selectedSport == .soccer {
                    hubChip(systemImage: "list.number", titleKey: "matches.scorers") {
                        CrossLeagueScorersView()
                    }
                }
            }
            .padding(.horizontal, AppTheme.spacingScreenMargin)
            .padding(.vertical, 6)
        }
    }

    /// One hub chip (icon + title in the shared capsule).
    private func hubChip<Destination: View>(
        systemImage: String, titleKey: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                Text(L(titleKey))
                    .font(AppTheme.fontCardTitle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(AppTheme.cardBorderColor, lineWidth: 1))
        }
        .buttonStyle(PressOpacityButtonStyle())
    }

    // MARK: First-entry explainer (build 66, item 12)

    private func explainerSeen(_ sport: MatchSport) -> Bool {
        switch sport {
        case .soccer: return explainerSeenSoccer
        case .nfl: return explainerSeenNFL
        case .nba: return explainerSeenNBA
        case .mlb: return explainerSeenMLB
        case .nhl: return explainerSeenNHL
        }
    }

    private func markExplainerSeen(_ sport: MatchSport) {
        switch sport {
        case .soccer: explainerSeenSoccer = true
        case .nfl: explainerSeenNFL = true
        case .nba: explainerSeenNBA = true
        case .mlb: explainerSeenMLB = true
        case .nhl: explainerSeenNHL = true
        }
    }

    /// Present the explainer for `sport` when it has never been
    /// shown for that sport. Called on first appearance and on
    /// every sport-tab switch. NEVER during playback: presentation
    /// requires the player-overlay snapshot to be empty (the same
    /// static count the goal-celebration suppression reads —
    /// `PlayerOverlayController.presentationActiveCount`), checked
    /// both now and again after the settle delay.
    private func presentExplainerIfNeeded(for sport: MatchSport) {
        guard !explainerSeen(sport), explainerSport == nil else { return }
        guard PlayerOverlayController.presentationActiveCount == 0 else { return }
        // Small delay so the screen settles first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !explainerSeen(sport), explainerSport == nil,
                  !showTeamSearch,
                  PlayerOverlayController.presentationActiveCount == 0
            else { return }
            lastExplainerSport = sport
            explainerSport = sport
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
                            .buttonStyle(PressOpacityButtonStyle())
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
                    // Build 84 (item 10): the My Teams strip is
                    // followed teams only — the kickoff line is
                    // a live countdown (switching to LIVE at
                    // kickoff) instead of a static time.
                    CountdownText(target: start)
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
        // Build 83 (item 5): press feedback on the day chips
        // (the shared opacity press token; instant under
        // Reduce Motion, as everywhere).
        .buttonStyle(PressOpacityButtonStyle())
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
                    featuredLiveSection(state)
                    // Build 83 (item 3): the league browser
                    // entry rides at the top of the Soccer tab
                    // only. The home's own loading is untouched —
                    // the browser fetches nothing until a league
                    // page opens.
                    if selectedSport == .soccer {
                        leagueBrowserEntry
                    }
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

    // MARK: Featured live match (build 88, owner-approved mockup)

    /// The mockup's hero: while the selected sport has a match
    /// live, the first live one is featured above the league
    /// sections as a large glass card — a pulsing LIVE badge,
    /// both crests with their FULL names, the score huge and
    /// glowing between them, and the Watch action under the
    /// score. Tapping the card opens the match page. Renders
    /// nothing when nothing is live.
    @ViewBuilder
    private func featuredLiveSection(_ state: MatchesViewModel.SportState) -> some View {
        if let featured = featuredLiveMatch(state) {
            Section {
                NavigationLink {
                    MatchDetailView(
                        sport: selectedSport,
                        leaguePath: selectedSport.leaguePaths[featured.sectionIndex],
                        match: featured.match,
                        leagueName: state.sections[featured.sectionIndex].result?.leagueName
                    )
                } label: {
                    featuredLiveCard(featured)
                }
                .buttonStyle(PressOpacityButtonStyle())
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .listRowBackground(Color.clear)
        }
    }

    private func featuredLiveMatch(
        _ state: MatchesViewModel.SportState
    ) -> (sectionIndex: Int, match: MatchEvent)? {
        for section in state.sections {
            if let match = dayMatches(in: section).first(where: { $0.state == .live }) {
                return (section.index, match)
            }
        }
        return nil
    }

    private func featuredLiveCard(
        _ featured: (sectionIndex: Int, match: MatchEvent)
    ) -> some View {
        let match = featured.match
        return VStack(spacing: 12) {
            HStack(spacing: 6) {
                LivePulseDot()
                Text(L("matches.live"))
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(.white)
                if let clock = featuredClockText(match) {
                    Text(clock)
                        .font(AppTheme.fontBadge)
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(AppTheme.live, in: Capsule())
            HStack(alignment: .top, spacing: 8) {
                featuredSide(match.home)
                // Build 90 (SP34): the featured score rolls +
                // flashes on a goal like every other score in
                // the app (RollingScoreView) — the card's static
                // text was the third, inconsistent presentation.
                RollingScoreView(text: "\(match.home.score ?? "0") – \(match.away.score ?? "0")")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundStyle(AppTheme.accent)
                    .shadow(color: AppTheme.accent.opacity(0.55), radius: 14)
                    .fixedSize()
                    .padding(.top, 8)
                featuredSide(match.away)
            }
            WatchPlayButton(
                sport: selectedSport,
                leaguePath: selectedSport.leaguePaths[featured.sectionIndex],
                match: match
            )
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [AppTheme.accent.opacity(0.65), AppTheme.cardBorderColor],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: AppTheme.accent.opacity(0.22), radius: 18, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func featuredSide(_ side: MatchTeamSide) -> some View {
        VStack(spacing: 7) {
            CachedImage(
                url: side.logoURL,
                width: 54, height: 54, cornerRadius: 27, iconName: "shield"
            )
            Text(side.name ?? "")
                .font(AppTheme.fontTeamName)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    /// The featured card's clock, from payload fields only:
    /// the display clock where the feed carries one (soccer /
    /// NBA / NFL), else the payload's own status text (MLB's
    /// inning, NHL's period line) — the same sources the match
    /// rows read.
    private func featuredClockText(_ match: MatchEvent) -> String? {
        let clock = match.displayClock?.trimmingCharacters(in: .whitespaces)
        if let clock, !clock.isEmpty, clock != "0.0" { return clock }
        let detail = match.statusDetail?.trimmingCharacters(in: .whitespaces)
        return (detail?.isEmpty == false) ? detail : nil
    }

    /// Build 83 (item 3): the league browser entry — one row
    /// opening the FotMob-style browser (search + every
    /// verified league with its payload logo). The count is
    /// the catalog's own count, computed, never typed.
    private var leagueBrowserEntry: some View {
        Section {
            NavigationLink {
                LeagueBrowserView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    Text(L("matches.leagues"))
                        .font(AppTheme.fontCardTitle)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(MatchSport.soccerLeagueCatalog.count)")
                        .font(AppTheme.fontMetadata.weight(.bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(AppTheme.surface)
    }

    @ViewBuilder
    private func leagueSection(
        _ section: MatchesViewModel.LeagueSection,
        sportState: MatchesViewModel.SportState
    ) -> some View {
        Section {
            if section.result != nil {
                let dayList = dayMatches(in: section)
                // Build 90 (SP31): the featured live card above
                // IS this match's one presentation on the screen
                // — its league section keeps every OTHER match
                // (the same duplication the owner removed from
                // Home in build 89).
                let featured = featuredLiveMatch(sportState)
                let matches = dayList.filter { match in
                    guard let featured, featured.sectionIndex == section.index
                    else { return true }
                    return match.id != featured.match.id
                }
                if dayList.isEmpty {
                    emptyRow
                } else if !matches.isEmpty {
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
                            MatchRowView(
                                match: match, isStale: sportState.isStale,
                                sport: selectedSport,
                                watchContext: (
                                    sport: selectedSport,
                                    leaguePath: selectedSport.leaguePaths[section.index]
                                )
                            )
                        }
                        .buttonStyle(PressOpacityButtonStyle())
                    }
                }
            } else if section.failed {
                errorRow
            } else if sportState.isLoading {
                // Build 90 (SP6): this league's window is still
                // in flight while its landed neighbours already
                // render — a quiet progress row, never the
                // "No matches" line for a league that simply
                // hasn't answered yet.
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L("common.loading"))
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                }
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
                    // Build 87 (item 1): hockey's standings and
                    // leaders are the NHL API's own pages — the
                    // ESPN-core views never see the .nhl sport.
                    if selectedSport == .nhl {
                        NavigationLink {
                            NHLStandingsView(leagueName: name)
                        } label: {
                            Image(systemName: "chart.bar.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(L("matches.standings"))
                        NavigationLink {
                            NHLLeadersView()
                        } label: {
                            Image(systemName: "list.number")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(L("matches.leaders"))
                    } else {
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
                        // Build 84 (item 7): the leaders page (all
                        // verified categories for the sport) —
                        // every sport now, not soccer only.
                        NavigationLink {
                            LeadersView(
                                sport: selectedSport,
                                leaguePath: selectedSport.leaguePaths[section.index],
                                leagueName: name
                            )
                        } label: {
                            Image(systemName: "list.number")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(L("matches.leaders"))
                        // Build 87 (item 13): THIS league's own
                        // highlights, inside its section.
                        NavigationLink {
                            SectionHighlightsView(
                                competitions: [(
                                    sport: selectedSport,
                                    leaguePath: selectedSport.leaguePaths[section.index]
                                )],
                                title: name
                            )
                        } label: {
                            Image(systemName: "play.rectangle.on.rectangle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(L("matches.highlights_hub"))
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

/// Build 83 (item 3): internal (was private) — the league
/// browser's league page renders its fixtures with this exact
/// row, so a match looks and behaves identically wherever it
/// is listed. Its helpers (LivePulseDot / RollingScoreView)
/// live at the bottom of this file; they are only used inside
/// this view and the featured card above it.
struct MatchRowView: View {
    let match: MatchEvent
    let isStale: Bool
    /// Build 85: the row's sport when the caller knows it —
    /// baseball's live label is the payload's own status text
    /// (inning + half), not a composed quarter/clock.
    var sport: MatchSport? = nil
    /// Build 84 (item 3b): when a surface provides its sport +
    /// league, the row carries the Watch action under the
    /// teams (rendered only when the active playlist has a
    /// channel broadcasting this match).
    var watchContext: (sport: MatchSport, leaguePath: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 8) {
                    teamRow(match.home)
                    teamRow(match.away)
                }
                stateColumn
                    .frame(width: 92, alignment: .trailing)
            }
            if let watchContext {
                WatchPlayButton(
                    sport: watchContext.sport, leaguePath: watchContext.leaguePath,
                    match: match
                )
            }
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
            // Build 79: the smaller team-name font so the FULL name
            // fits on one line; the scale factor is only a safety
            // net for extreme outliers on narrow screens.
            Text(side.name ?? "")
                .font(AppTheme.fontTeamName)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer()
            if match.state != .upcoming, let score = side.score {
                // Build 90 (SP34): the score is the shared
                // RollingScoreView — the same digit-roll + one
                // accent flash the Home Match Results cards use,
                // under the same Motion gating (the row's old
                // FlashScoreText ran a second, differently-gated
                // effect and is retired).
                // Build 84 (item 3a audit): the score is pinned —
                // fixed intrinsic size + top layout priority, so
                // the flexible team name always yields first and
                // the score can never be squeezed or clipped.
                RollingScoreView(text: score)
                    .font(AppTheme.fontCardTitle)
                    .fixedSize()
                    .layoutPriority(1)
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
                        .fixedSize()
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
            // Build 85: baseball's payload text carries the
            // extra-inning truth ("Final/11") — show it
            // verbatim instead of the generic Final word.
            Text(finishedText)
                .font(AppTheme.fontMetadata.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var finishedText: String {
        if sport == .mlb || sport == .nhl,
           let detail = match.statusDetail?.trimmingCharacters(in: .whitespaces),
           !detail.isEmpty {
            return detail
        }
        return L("matches.final")
    }

    /// Live clock label built ONLY from payload fields: soccer's
    /// displayClock already reads like "67'"; NFL/NBA pair a period
    /// with a game clock ("Q3 2:14", period 5+ = "OT").
    /// Build 85: baseball's period is the INNING and its
    /// displayClock is a dummy "0:00" — the label is the
    /// payload's own status text ("Top 5th"), verbatim.
    private var liveClockText: String? {
        if sport == .mlb || sport == .nhl {
            let detail = match.statusDetail?.trimmingCharacters(in: .whitespaces)
            return (detail?.isEmpty == false) ? detail : nil
        }
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
/// nothing runs off-screen. Build 90 (SP34): the pulse obeys
/// the FULL motion regime — EffectsGate (Reduce Motion + the
/// reduce-effects setting) AND the Settings motion intensity
/// via Motion.animate — not Reduce Motion alone, so "motion
/// off" in Settings stills it like every other effect.
struct LivePulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var pulses: Bool {
        EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion)
            && Motion.animate(.easeInOut(duration: 1.1)) != nil
    }

    var body: some View {
        Circle()
            .fill(AppTheme.accent)
            .frame(width: 6, height: 6)
            .opacity(pulses && pulsing ? 0.35 : 1)
            .onAppear {
                guard pulses else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

/// Build 90 (SP34): THE live-score effect — digits roll on a
/// change (numeric content transition) and the changed score
/// gets ONE brief accent flash, then settles. Nothing loops;
/// the flash is driven solely by an actual score change in
/// the data, and Motion.animate gates it (system Reduce
/// Motion + the Settings intensity), so a user who turned
/// motion off gets a static score everywhere. This is the
/// shared implementation the Home Match Results cards
/// introduced in build 88/89, now serving the Matches rows,
/// the featured card and Home's Match Results cards too
/// (Home's file-private copy from build 89 was deleted in
/// build 90 — this one is the single canonical home).
/// It replaces the retired FlashScoreText, whose background
/// flash ran under Reduce Motion only and ignored the
/// Settings intensity — two goal effects, two rulebooks.
struct RollingScoreView: View {
    let text: String
    @State private var flash = false

    var body: some View {
        Text(text)
            .fontWeight(.bold)
            .monospacedDigit()
            .fixedSize()
            .contentTransition(.numericText())
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(AppTheme.accent.opacity(flash ? 0.35 : 0))
            )
            .animation(Motion.animate(.easeOut(duration: 0.65)), value: flash)
            .onChange(of: text) { _, _ in
                guard Motion.animate(.easeOut(duration: 0.3)) != nil else { return }
                flash = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(650))
                    flash = false
                }
            }
    }
}
