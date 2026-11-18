import Foundation

/// Shared parser for Xtream rating strings ("7.5", "7,5", "N/A", "").
/// Missing/invalid → -1 so unrated items sort to the bottom.
nonisolated enum CatalogRatingValue {
    static func parse(_ raw: String?) -> Double {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return -1 }
        return Double(raw.replacingOccurrences(of: ",", with: ".")) ?? -1
    }
}

/// Live channel sort options. Live has no rating/added, so only name-based
/// sorting is data-backed.
nonisolated enum LiveSortOption: String, CaseIterable, Identifiable {
    /// Identity: preserve caller's ordering (sortIndex or search relevance).
    case defaultOrder
    case nameAsc
    case nameDesc
    /// Build 61 (B9, Q12): channels that actually play come first.
    case workingFirst

    var id: String { rawValue }

    static let storageKey = "live.sortOption"

    var titleKey: String {
        switch self {
        case .defaultOrder: return "sort.default"
        case .nameAsc: return "sort.name_asc"
        case .nameDesc: return "sort.name_desc"
        case .workingFirst: return "sort.working_first"
        }
    }

    var systemImage: String {
        switch self {
        case .defaultOrder: return "list.number"
        case .nameAsc: return "arrow.up"
        case .nameDesc: return "arrow.down"
        case .workingFirst: return "checkmark.circle"
        }
    }

    func apply(to items: [LiveStreamWithCategory]) -> [LiveStreamWithCategory] {
        switch self {
        case .defaultOrder:
            return items
        case .nameAsc:
            return items.sorted {
                $0.stream.name.localizedCaseInsensitiveCompare($1.stream.name) == .orderedAscending
            }
        case .nameDesc:
            return items.sorted {
                $0.stream.name.localizedCaseInsensitiveCompare($1.stream.name) == .orderedDescending
            }
        case .workingFirst:
            // Q12 composition (SPEC §4.5-O7): this sort replaces
            // ONLY tier 3 (custom order) — tiers 1–2 (pinned,
            // favorites) are applied by the list assembly before
            // this runs, and Swift's sort is STABLE, so items of
            // equal health keep their incoming (tiered) order.
            // Ranks are precomputed once per item (a sort must
            // never build content keys per comparison at 10k+
            // channels).
            let store = ChannelHealthStore.shared
            let ranks: [Int: Int] = Dictionary(uniqueKeysWithValues: items.map { item in
                (item.stream.streamId, store.healthRank(
                    ImportedSubtitleStore.contentKey(
                        playlistId: item.stream.playlistId,
                        type: "live",
                        streamId: String(item.stream.streamId)
                    )
                ))
            })
            return items.sorted {
                (ranks[$0.stream.streamId] ?? 0) < (ranks[$1.stream.streamId] ?? 0)
            }
        }
    }
}

/// Toggle filters for live channels, backed by fields present at import.
nonisolated struct LiveStreamFilter: OptionSet {
    let rawValue: Int
    static let catchup = LiveStreamFilter(rawValue: 1 << 0)   // tvArchive > 0
    static let hasEPG = LiveStreamFilter(rawValue: 1 << 1)    // epgChannelId present

    static func apply(_ items: [LiveStreamWithCategory], _ filter: LiveStreamFilter) -> [LiveStreamWithCategory] {
        guard !filter.isEmpty else { return items }
        return items.filter { item in
            if filter.contains(.catchup), item.stream.tvArchive <= 0 { return false }
            if filter.contains(.hasEPG), (item.stream.epgChannelId ?? "").isEmpty { return false }
            return true
        }
    }
}
