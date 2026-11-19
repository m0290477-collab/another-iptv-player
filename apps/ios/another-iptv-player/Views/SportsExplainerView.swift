import SwiftUI

// MARK: - Sports-section first-entry explainer (build 66, item 12)
//
// Owner-approved design (mockup, 2026-11-19): a bottom sheet over
// the matches screen — flame mark, "Welcome to <sport>", four
// feature rows (red-orange rounded icon tile + bold title + one-line
// description), a full-width red-orange "Start exploring" button
// and a small "Skip" text button beneath.
//
// Shown ONCE per sport: the seen flag for a sport is set when its
// sheet is dismissed by EITHER button or by swipe (see
// `onDismiss` in MatchesView). HONESTY RULE: every row describes
// something the app actually does for THAT sport today — the rows
// are per-sport on purpose (no lineups/formations row for NFL/NBA:
// those tabs have no such screen; NFL/NBA notification wording
// follows the goal-push server's real per-sport policy).

/// The four feature rows for one sport, as localization keys.
/// Icons are SF Symbols that exist on every supported OS version.
struct SportsExplainerContent {
    struct Row {
        let icon: String
        let titleKey: String
        let detailKey: String
    }

    let titleKey: String
    let rows: [Row]

    static func content(for sport: MatchSport) -> SportsExplainerContent {
        switch sport {
        case .soccer:
            // Live scores: MatchesView scoreboard + 60 s auto-refresh.
            // Lineups & formations: LineupsView / PitchView fed by
            // MatchesService.fetchDetail (summary rosters).
            // Standings & top scorers: StandingsView (every soccer
            // league header) + TopScorersView (soccer-only).
            // Follow: FollowedTeamsStore + watcher sends every goal
            // (goals default ON).
            return SportsExplainerContent(
                titleKey: "matches.explainer.soccer.title",
                rows: [
                    Row(icon: "bolt.fill",
                        titleKey: "matches.explainer.soccer.live.title",
                        detailKey: "matches.explainer.soccer.live.detail"),
                    Row(icon: "person.3.fill",
                        titleKey: "matches.explainer.soccer.lineups.title",
                        detailKey: "matches.explainer.soccer.lineups.detail"),
                    Row(icon: "trophy.fill",
                        titleKey: "matches.explainer.soccer.table.title",
                        detailKey: "matches.explainer.soccer.table.detail"),
                    Row(icon: "bell.fill",
                        titleKey: "matches.explainer.soccer.follow.title",
                        detailKey: "matches.explainer.soccer.follow.detail")
                ]
            )
        case .nfl:
            // Live scores: NFL scoreboard tab in MatchesView.
            // Standings: StandingsView is linked from EVERY league
            // header, NFL included (MatchesStandingsService).
            // Stats & leaders: MatchDetailView stats tab + leaders
            // row, mapped sport-agnostically from the ESPN summary
            // (MatchesService.mapLeaders / mapStats).
            // Follow: same follow store; the watcher sends EVERY
            // NFL score change, and kickoff / full-time pushes are
            // per-team options in the match detail follow section.
            // NO lineups/formations row — the NFL tab has none.
            return SportsExplainerContent(
                titleKey: "matches.explainer.nfl.title",
                rows: [
                    Row(icon: "bolt.fill",
                        titleKey: "matches.explainer.nfl.live.title",
                        detailKey: "matches.explainer.nfl.live.detail"),
                    Row(icon: "chart.bar.fill",
                        titleKey: "matches.explainer.nfl.standings.title",
                        detailKey: "matches.explainer.nfl.standings.detail"),
                    Row(icon: "list.number",
                        titleKey: "matches.explainer.nfl.stats.title",
                        detailKey: "matches.explainer.nfl.stats.detail"),
                    Row(icon: "bell.fill",
                        titleKey: "matches.explainer.nfl.follow.title",
                        detailKey: "matches.explainer.nfl.follow.detail")
                ]
            )
        case .nba:
            // Live scores: NBA scoreboard tab in MatchesView.
            // Standings: StandingsView from the league header.
            // Stats & leaders: MatchDetailView stats tab + leaders
            // row from the ESPN summary, same as NFL.
            // Follow: the watcher's NBA policy sends score pushes
            // only in Q4/OT or on a lead change — worded here
            // simply as "close finishes". NO lineups row.
            return SportsExplainerContent(
                titleKey: "matches.explainer.nba.title",
                rows: [
                    Row(icon: "bolt.fill",
                        titleKey: "matches.explainer.nba.live.title",
                        detailKey: "matches.explainer.nba.live.detail"),
                    Row(icon: "chart.bar.fill",
                        titleKey: "matches.explainer.nba.standings.title",
                        detailKey: "matches.explainer.nba.standings.detail"),
                    Row(icon: "list.number",
                        titleKey: "matches.explainer.nba.stats.title",
                        detailKey: "matches.explainer.nba.stats.detail"),
                    Row(icon: "bell.fill",
                        titleKey: "matches.explainer.nba.follow.title",
                        detailKey: "matches.explainer.nba.follow.detail")
                ]
            )
        }
    }
}

/// The persisted "explainer already shown" flag key for a sport.
enum SportsExplainerFlag {
    static func key(for sport: MatchSport) -> String {
        "explainer.seen.\(sport.rawValue)"
    }
}

struct SportsExplainerView: View {
    let sport: MatchSport
    /// Build 67 (F6): Start and Skip are DISTINCT outcomes, not
    /// one finish. Start lands the user in this sport's Matches
    /// section AND continues to the follow-your-teams step the
    /// copy above promises (the presenter presents the existing
    /// team-follow picker once this sheet has dismissed). Skip
    /// lands in the section WITHOUT the picker. A swipe dismissal
    /// reaches neither closure — the sheet's `onDismiss` in
    /// MatchesView marks the sport seen instead, so every
    /// dismissal path counts as seen, exactly as in build 66.
    let onStart: () -> Void
    let onSkip: () -> Void

    @ObservedObject private var accentStore = AccentThemeStore.shared

    private var content: SportsExplainerContent {
        SportsExplainerContent.content(for: sport)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Brand flame mark (fixed Design-4 gradient, same
            // treatment as the splash / gate header).
            Image(systemName: "flame.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(AppTheme.brandGradient)
                .padding(.top, 26)

            Text(L(content.titleKey))
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .padding(.horizontal, AppTheme.spacingScreenMargin)

            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.horizontal, AppTheme.spacingScreenMargin)
                .padding(.vertical, 20)

            VStack(spacing: 20) {
                ForEach(Array(content.rows.enumerated()), id: \.offset) { _, row in
                    featureRow(row)
                }
            }
            .padding(.horizontal, AppTheme.spacingScreenMargin)

            Spacer(minLength: 24)

            Button {
                onStart()
            } label: {
                Text(L("matches.explainer.start"))
                    .font(AppTheme.fontCardTitle.weight(.bold))
                    .foregroundStyle(AppTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                            .fill(AppTheme.accent)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AppTheme.spacingScreenMargin)

            Button {
                onSkip()
            } label: {
                Text(L("matches.explainer.skip"))
                    .font(AppTheme.fontMetadata.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.background.ignoresSafeArea())
    }

    private func featureRow(_ row: SportsExplainerContent.Row) -> some View {
        HStack(spacing: 14) {
            Image(systemName: row.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.brandGradient)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(L(row.titleKey))
                    .font(AppTheme.fontCardTitle.weight(.bold))
                Text(L(row.detailKey))
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
