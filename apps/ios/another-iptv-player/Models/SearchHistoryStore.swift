import Foundation
import GRDB

/// Build 61 (B10, Q14 + F2): the ONE persisted search-history
/// store. Recent global-search queries, newest first, capped.
/// The in-search "clear" affordance and the Settings ▸ Storage
/// "Clear search history" row (F2) both call `clear()` here —
/// single instance, per the O6 rule.
enum SearchHistoryStore {
    private static let key = "search.history.queries.v1"
    private static let cap = 12

    static var queries: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Records a submitted query (deduped case-insensitively,
    /// moved to the front). Queries under 2 characters are not
    /// recorded — the search itself ignores them too.
    static func record(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return }
        var list = queries.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        list.insert(query, at: 0)
        UserDefaults.standard.set(Array(list.prefix(cap)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Build 61 (B10, F2): the ONE watch-history clear used by the
/// Settings ▸ Storage row. Continue Watching / Continue Series /
/// Recent Channels all derive from the `watchHistory` table, so
/// emptying the table empties all three (verified against
/// `PlaylistContentStore` / Home row sources). The per-playlist
/// clear in each playlist's own settings predates this and scopes
/// to one playlist; this one is the global Storage-group action
/// the F2 spec asks for.
enum WatchHistoryClearing {
    static func clearAll() async {
        _ = try? await AppDatabase.shared.write { db in
            try db.execute(sql: "DELETE FROM watchHistory")
        }
    }
}
