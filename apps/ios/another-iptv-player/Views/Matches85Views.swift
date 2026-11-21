import SwiftUI

// Build 85: the free-ESPN sweep's surfaces — the league
// injuries page and the league transactions page. Both
// render ONLY payload-verified data (see Matches85.swift);
// an empty source renders the honest empty state. The
// injuries rows follow the app's player convention: a row
// with a known athlete id opens the player page, with the
// shared press feedback; nothing here animates over
// playback.

// MARK: - League injuries (sweep)

/// Every team's injury list for the league, grouped by team
/// exactly as the payload groups it: player photo, the
/// payload's own status word, its injury description and
/// its expected-return date when it publishes one. Linked
/// from the standings page for the leagues whose endpoint
/// verified (MLB + NBA — see the service note for why the
/// NFL and soccer stay out).
struct LeagueInjuriesView: View {
    let sport: MatchSport
    let leaguePath: String
    var leagueName: String?

    @State private var groups: [InjuryTeamGroup85] = []
    @State private var stamp: Date?
    @State private var didLoad = false

    var body: some View {
        List {
            if let stamp {
                Section {
                    LastUpdatedStamp(date: stamp)
                }
                .listRowBackground(Color.clear)
            }
            if didLoad && groups.isEmpty {
                Section {
                    Text(L("matches.empty"))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        if let athleteId = entry.athleteId {
                            NavigationLink {
                                PlayerPageView(
                                    sport: sport, leaguePath: leaguePath,
                                    athleteId: athleteId, fallbackName: entry.athleteName
                                )
                            } label: {
                                injuryRow(entry)
                            }
                            .buttonStyle(PressOpacityButtonStyle())
                        } else {
                            injuryRow(entry)
                        }
                    }
                } header: {
                    Text(group.teamName)
                        .font(AppTheme.fontBadge)
                        .foregroundStyle(AppTheme.accent)
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(L("matches.injuries"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if !didLoad { BrandedLoader() } }
        .task {
            let result = await LeagueInjuriesService.fetch(sport: sport, leaguePath: leaguePath)
            groups = result.groups
            stamp = result.stamp
            didLoad = true
        }
    }

    private func injuryRow(_ entry: InjuryEntry85) -> some View {
        HStack(alignment: .top, spacing: 10) {
            PlayerPhotoDisc(url: entry.headshotURL, name: entry.athleteName, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.athleteName)
                        .font(AppTheme.fontCardTitle)
                        .lineLimit(1)
                    if let status = entry.status, !status.isEmpty {
                        Text(status)
                            .font(AppTheme.fontBadge)
                            .foregroundStyle(AppTheme.live)
                    }
                }
                if let detail = entry.detailText {
                    Text(detail)
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let comment = entry.comment, !comment.isEmpty {
                    Text(comment)
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let returnDate = entry.returnDate, !returnDate.isEmpty {
                    Text("\(L("matches.injuries.expected_return")): \(returnDate)")
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - League transactions (sweep)

/// The league's transactions, newest first as the payload
/// orders them: team crest + name, the payload's own
/// description verbatim, and its date. Linked from the
/// standings page for the US leagues (MLB / NBA / NFL —
/// the three payloads verified with the identical shape).
struct LeagueTransactionsView: View {
    let leaguePath: String
    var leagueName: String?

    @State private var entries: [TransactionEntry85] = []
    @State private var stamp: Date?
    @State private var didLoad = false

    var body: some View {
        List {
            if let stamp {
                Section {
                    LastUpdatedStamp(date: stamp)
                }
                .listRowBackground(Color.clear)
            }
            Section {
                if entries.isEmpty {
                    Text(didLoad ? L("matches.empty") : L("common.loading"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        transactionRow(entry)
                    }
                }
            }
            .listRowBackground(AppTheme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .cinematicBackground()
        .navigationTitle(L("matches.transactions"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let result = await LeagueTransactionsService.fetch(leaguePath: leaguePath)
            entries = result.entries
            stamp = result.stamp
            didLoad = true
        }
    }

    private func transactionRow(_ entry: TransactionEntry85) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CachedImage(
                url: entry.teamLogoURL,
                width: 30, height: 30, cornerRadius: 15, iconName: "shield"
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let teamName = entry.teamName {
                        Text(teamName)
                            .font(AppTheme.fontCardTitle)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let date = entry.date {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(AppTheme.fontMetadata)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(entry.description)
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(.vertical, 2)
    }
}
