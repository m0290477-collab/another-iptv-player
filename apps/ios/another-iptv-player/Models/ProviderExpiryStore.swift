import Foundation

/// The provider (panel) subscription expiry, persisted per playlist
/// so playback can be gated on it.
///
/// The expiry date itself comes from the panel's auth response
/// (`user_info.exp_date`) — the SAME value the Settings account card
/// and the Notifications page parse. It is recorded whenever an auth
/// verify succeeds (Settings, Notifications, and a staleness-checked
/// verify when a dashboard opens), and read by the ONE playback gate
/// in `PlayerOverlayController.present`.
///
/// Round 14 (A1, superseding round 12's day rule): the ONE verdict
/// everywhere is the provider's exp_date TIMESTAMP — expired ⇔
/// now > exp_date. The provider cuts the account at the exact
/// timestamp (round 13, fault 1: the card said "Expired" while the
/// day-math gate still let dead streams start and spin forever), so
/// the gate, the Settings card and Notifications all share
/// `isExpired(expDateString:)`. A playlist with no recorded expiry
/// date is never blocked.
enum ProviderExpiryStore {
    private static let datesKey = "provider_expiry.dates.v1"
    private static let verifiedKey = "provider_expiry.verified_at.v1"
    /// A dashboard open re-verifies in the background once the last
    /// successful verify is older than this, so the gate's data
    /// cannot silently rot while the user never opens Settings.
    private static let stalenessInterval: TimeInterval = 6 * 60 * 60

    /// Round 14 (B2): serializes every read-modify-write of the two
    /// stored dictionaries. `record` is called from Settings,
    /// Notifications and dashboard background verifies, potentially
    /// concurrently; UserDefaults itself is thread-safe, but the
    /// load-modify-store cycle is not.
    private static let queue = DispatchQueue(label: "superx.provider-expiry-store")

    // MARK: - Parsing (the account card's rule, shared)

    /// The panel's `exp_date` as a real date; nil for the no-expiry
    /// cases (absent, timestamp 0, unparseable) — identical rule to
    /// `PlaylistSettingsView.providerExpiryDate`.
    static func parseExpiryDate(_ expDate: String?) -> Date? {
        guard let expDate, let timestamp = TimeInterval(expDate), timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    // MARK: - The ONE expiry verdict (round 14, A1)

    /// Expired ⇔ now is past the exp_date TIMESTAMP. Nil or
    /// unparseable input (the no-expiry cases) is NEVER expired.
    /// This is the shared contract: the playback gate
    /// (`blockedExpiry`), Notifications and the Settings account
    /// card all derive their verdict from here.
    static func isExpired(expDateString: String?) -> Bool {
        isExpired(expiryDate: parseExpiryDate(expDateString))
    }

    /// Date form of the same verdict, for callers that already hold
    /// a parsed/recorded expiry date.
    static func isExpired(expiryDate: Date?, now: Date = Date()) -> Bool {
        guard let expiryDate else { return false }
        return now > expiryDate
    }

    // MARK: - Recording

    /// Records the outcome of a successful auth verify: the parsed
    /// expiry date (or its absence — a verify that reports no
    /// `exp_date` means the account has no expiry, so any older
    /// record is cleared) plus the verify time.
    static func record(playlistId: UUID, expDate: String?) {
        queue.sync {
            let defaults = UserDefaults.standard
            var dates = storedDates()
            if let expiry = parseExpiryDate(expDate) {
                dates[playlistId.uuidString] = expiry.timeIntervalSince1970
            } else {
                dates.removeValue(forKey: playlistId.uuidString)
            }
            defaults.set(dates, forKey: datesKey)
            var verified = storedVerified()
            verified[playlistId.uuidString] = Date().timeIntervalSince1970
            defaults.set(verified, forKey: verifiedKey)
        }
    }

    static func clearAll() {
        queue.sync {
            UserDefaults.standard.removeObject(forKey: datesKey)
            UserDefaults.standard.removeObject(forKey: verifiedKey)
        }
    }

    /// Round 17 (R17-5): drop ONE playlist's records (shared
    /// account-data deletion path — removing a saved account must
    /// not leave its expiry verdict behind for the gate to read).
    static func remove(playlistId: UUID) {
        queue.sync {
            var dates = storedDates()
            var verified = storedVerified()
            let key = playlistId.uuidString
            if dates.removeValue(forKey: key) != nil {
                UserDefaults.standard.set(dates, forKey: datesKey)
            }
            if verified.removeValue(forKey: key) != nil {
                UserDefaults.standard.set(verified, forKey: verifiedKey)
            }
        }
    }

    // MARK: - Reading

    /// The recorded provider expiry for a playlist, if any.
    static func expiryDate(playlistId: UUID) -> Date? {
        queue.sync {
            guard let ts = storedDates()[playlistId.uuidString] else { return nil }
            return Date(timeIntervalSince1970: ts)
        }
    }

    /// Non-nil when playback must be blocked for this playlist right
    /// now: an expiry date exists AND its timestamp has passed
    /// (round 14 A1 — the same `isExpired` verdict Notifications and
    /// the account card use; no day-math anywhere). Returns the
    /// expiry date for display in the blocked state.
    static func blockedExpiry(playlistId: UUID, now: Date = Date()) -> Date? {
        guard let expiry = expiryDate(playlistId: playlistId) else { return nil }
        return isExpired(expiryDate: expiry, now: now) ? expiry : nil
    }

    // MARK: - Background refresh

    static func isStale(playlistId: UUID) -> Bool {
        queue.sync {
            guard let ts = storedVerified()[playlistId.uuidString] else { return true }
            return Date().timeIntervalSince1970 - ts > stalenessInterval
        }
    }

    /// Xtream playlists only (M3U carries no account/expiry data).
    /// Runs the same lightweight `verify()` the account card uses and
    /// records the result. Failures are silent: the last recorded
    /// state (or no state) keeps governing the gate.
    static func refreshIfStale(playlist: Playlist) async {
        guard playlist.kind == .xtream, isStale(playlistId: playlist.id) else { return }
        let client = XtreamAPIClient(playlist: playlist)
        guard let response = try? await client.verify() else { return }
        record(playlistId: playlist.id, expDate: response.userInfo?.expDate)
    }

    // MARK: - Storage

    private static func storedDates() -> [String: TimeInterval] {
        UserDefaults.standard.dictionary(forKey: datesKey) as? [String: TimeInterval] ?? [:]
    }

    private static func storedVerified() -> [String: TimeInterval] {
        UserDefaults.standard.dictionary(forKey: verifiedKey) as? [String: TimeInterval] ?? [:]
    }
}
