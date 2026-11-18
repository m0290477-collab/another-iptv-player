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
    @State private var selectedSport: MatchSport = .soccer

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedSport) {
                ForEach(MatchSport.allCases) { sport in
                    Text(L(sport.titleKey)).tag(sport)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppTheme.spacingScreenMargin)
            .padding(.vertical, 10)

            sportContent(model.state(for: selectedSport))
        }
        .cinematicBackground()
        .navigationTitle(L("matches.title"))
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: Tab content

    @ViewBuilder
    private func sportContent(_ state: MatchesViewModel.SportState) -> some View {
        if !state.hasLoaded && state.sections.allSatisfy({ !$0.failed }) {
            // First load in flight (or not started yet).
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedSport != .soccer, let only = state.sections.first, only.result == nil {
            // Single-league tab (NFL/NBA) with nothing to show:
            // full-screen empty vs error state (M5/O10 pattern).
            if only.failed {
                fullErrorState
            } else {
                fullEmptyState
            }
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
            if let result = section.result {
                if result.matches.isEmpty {
                    emptyRow
                } else {
                    ForEach(result.matches) { match in
                        MatchRowView(match: match, isStale: sportState.isStale)
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
                Text(name)
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(AppTheme.accent)
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

    private var fullEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(L("matches.empty"))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fullErrorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(L("matches.error"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Button(L("matches.retry")) {
                Task { await model.refresh(sport: selectedSport) }
            }
            .font(AppTheme.fontCardTitle)
            .foregroundStyle(AppTheme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .frame(width: 68, alignment: .trailing)
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
                Text(score)
                    .font(AppTheme.fontCardTitle)
                    .monospacedDigit()
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
                        Circle()
                            .fill(AppTheme.accent)
                            .frame(width: 6, height: 6)
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
                Text(MatchesView.timeText(start))
                    .font(AppTheme.fontMetadata.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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
