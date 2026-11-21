import Foundation

// Build 85: the free-ESPN sweep's new league surfaces —
// injuries and transactions — plus the MLB data-layer
// notes. Every endpoint below was verified live on
// 2026-11-21 against real ESPN payloads before any UI was
// wired to it (the build-85 report carries the per-endpoint
// evidence, including the exclusions: the NFL injuries
// payload weighs 8.8 MB and soccer's injuries endpoint
// answers an empty shell, so neither ships).
//
// Both services read through the sports disk cache
// (SportsDiskCache.espnData): one fetch per page open, the
// last real payload re-served offline with its stamp.

// MARK: - League injuries (sweep)

struct InjuryEntry85: Identifiable {
    let id: String
    let athleteId: String?
    let athleteName: String
    let headshotURL: URL?
    /// The payload's own status word ("Out", "Day-To-Day", …).
    let status: String?
    /// The payload's own comment (shortComment, falling back
    /// to longComment).
    let comment: String?
    /// The payload's injury description, composed ONLY from
    /// its details fields (type / detail / side — e.g.
    /// "Elbow · Surgery · Right").
    let detailText: String?
    /// The payload's expected-return date string, verbatim.
    let returnDate: String?
    let date: Date?
}

struct InjuryTeamGroup85: Identifiable {
    let teamName: String
    let entries: [InjuryEntry85]
    var id: String { teamName }
}

/// League-wide injuries from the site/v2 injuries endpoint —
/// verified live 2026-11-21 for MLB (200, grouped by team:
/// athlete / status / date / comments / details{type,
/// detail, side, returnDate}) and the NBA (same family,
/// same grouping). Surfaced ONLY for those two leagues:
/// the NFL payload is 8.8 MB (a phone-hostile fetch the
/// performance guard forbids) and soccer's endpoint returns
/// a 192-byte shell with no injuries at all.
enum LeagueInjuriesService {
    private struct Wire: Decodable {
        let injuries: [TeamGroup]?
        struct TeamGroup: Decodable {
            let displayName: String?
            let injuries: [Entry]?
        }
        struct Entry: Decodable {
            let id: String?
            let athlete: Athlete?
            let status: String?
            let date: String?
            let shortComment: String?
            let longComment: String?
            let details: Details?
        }
        struct Athlete: Decodable {
            let id: String?
            let displayName: String?
            let headshot: Headshot?
        }
        struct Headshot: Decodable { let href: String? }
        struct Details: Decodable {
            let type: String?
            let detail: String?
            let side: String?
            let returnDate: String?
        }
    }

    static func fetch(
        sport: MatchSport, leaguePath: String
    ) async -> (groups: [InjuryTeamGroup85], stamp: Date?) {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(leaguePath)/injuries"),
              let result = await SportsDiskCache.espnData(
                url: url, cacheKey: "inj|\(leaguePath)"
              ),
              let wire = try? JSONDecoder().decode(Wire.self, from: result.data)
        else { return ([], nil) }
        let groups = (wire.injuries ?? []).compactMap { group -> InjuryTeamGroup85? in
            guard let teamName = group.displayName, !teamName.isEmpty else { return nil }
            let entries = (group.injuries ?? []).compactMap { entry -> InjuryEntry85? in
                guard let name = entry.athlete?.displayName, !name.isEmpty else { return nil }
                let detailParts = [entry.details?.type, entry.details?.detail, entry.details?.side]
                    .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return InjuryEntry85(
                    id: entry.id ?? "\(teamName)|\(name)",
                    athleteId: entry.athlete?.id,
                    athleteName: name,
                    headshotURL: entry.athlete?.headshot?.href.flatMap { URL(string: $0) }
                        ?? CoreCoordinates.headshotURL(
                            sport: sport, athleteId: entry.athlete?.id, href: nil
                        ),
                    status: entry.status,
                    comment: entry.shortComment ?? entry.longComment,
                    detailText: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
                    returnDate: entry.details?.returnDate,
                    date: entry.date.flatMap { MatchesService.parseEventDate($0) }
                )
            }
            guard !entries.isEmpty else { return nil }
            return InjuryTeamGroup85(teamName: teamName, entries: Array(entries.prefix(25)))
        }
        return (groups, result.stamp)
    }
}

// MARK: - League transactions (sweep)

struct TransactionEntry85: Identifiable {
    let id: String
    let date: Date?
    /// The payload's own description, verbatim.
    let description: String
    let teamName: String?
    let teamLogoURL: URL?
}

/// League transactions from the site/v2 transactions
/// endpoint — verified live 2026-11-21 for MLB, the NBA and
/// the NFL (identical item shape in all three: date /
/// description / team{displayName, logos}). Newest first,
/// exactly as the payload orders them; capped so the page
/// stays light.
enum LeagueTransactionsService {
    private struct Wire: Decodable {
        let transactions: [Entry]?
        struct Entry: Decodable {
            let date: String?
            let description: String?
            let team: Team?
        }
        struct Team: Decodable {
            let displayName: String?
            let logos: [Logo]?
            let logo: String?
        }
        struct Logo: Decodable { let href: String? }
    }

    static func fetch(leaguePath: String) async -> (entries: [TransactionEntry85], stamp: Date?) {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(leaguePath)/transactions"),
              let result = await SportsDiskCache.espnData(
                url: url, cacheKey: "trx|\(leaguePath)"
              ),
              let wire = try? JSONDecoder().decode(Wire.self, from: result.data)
        else { return ([], nil) }
        let entries = (wire.transactions ?? []).compactMap { entry -> TransactionEntry85? in
            guard let description = entry.description, !description.isEmpty else { return nil }
            let date = entry.date.flatMap { MatchesService.parseEventDate($0) }
            let logo = entry.team?.logos?.first?.href ?? entry.team?.logo
            return TransactionEntry85(
                id: "\(entry.date ?? "")|\(description)",
                date: date,
                description: description,
                teamName: entry.team?.displayName,
                teamLogoURL: logo.flatMap { URL(string: $0) }
            )
        }
        return (Array(entries.prefix(60)), result.stamp)
    }
}
