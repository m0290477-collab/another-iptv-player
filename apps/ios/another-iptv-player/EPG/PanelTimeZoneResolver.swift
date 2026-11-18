import Foundation
import GRDB

/// Resolves the Xtream panel's timezone, needed to format timeshift `start`
/// params in the panel's local wall-clock. Chain: persisted IANA name → live
/// `verify()` (result persisted) → offset derived from `time_now` vs
/// `timestamp_now` → UTC.
enum PanelTimeZoneResolver {

    static func resolve(playlist: Playlist) async -> TimeZone {
        // 1. Persisted IANA name.
        if let tz = timeZone(fromIANA: playlist.serverTimezone) { return tz }

        // 2. Live verify() — capture and persist server_info.
        guard playlist.kind == .xtream else { return .gmt }
        let client = XtreamAPIClient(playlist: playlist)
        guard let response = try? await client.verify() else { return .gmt }
        let serverInfo = response.serverInfo

        if let tz = timeZone(fromIANA: serverInfo?.timezone) {
            await persist(timezone: serverInfo?.timezone, playlist: playlist)
            return tz
        }

        // 3. Derive a fixed offset from time_now vs timestamp_now.
        // C2 (Round 15): the fallback used to be a FIXED-offset zone, so
        // every future/past date inherited the offset in force at the
        // refresh moment — programmes after a DST transition landed an
        // hour off. Prefer a real IANA zone whose offset matches the
        // derived offset TODAY: that zone carries its own DST rules, so
        // per-date offset resolution stays correct across transitions.
        // Only when no known zone matches do we fall back to the fixed
        // offset (documented ambiguity: several zones share an offset;
        // the first match is a heuristic, still strictly better than a
        // frozen offset because its DST pattern is real).
        if let offset = derivedOffsetSeconds(timeNow: serverInfo?.timeNow, timestampNow: serverInfo?.timestampNow) {
            if let tz = dstAwareZone(matchingOffset: offset, at: Date()) {
                return tz
            }
            if let tz = TimeZone(secondsFromGMT: offset) {
                return tz
            }
        }

        // 4. UTC.
        return .gmt
    }

    /// C2 (Round 15): first known IANA zone whose GMT offset at `date`
    /// equals `offset`. Deterministic (identifier-sorted) so the choice
    /// is stable across launches.
    static func dstAwareZone(matchingOffset offset: Int, at date: Date) -> TimeZone? {
        for identifier in TimeZone.knownTimeZoneIdentifiers.sorted() {
            guard let tz = TimeZone(identifier: identifier) else { continue }
            if tz.secondsFromGMT(for: date) == offset { return tz }
        }
        return nil
    }

    static func timeZone(fromIANA raw: String?) -> TimeZone? {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return TimeZone(identifier: name)
    }

    /// offset = (time_now parsed as-if-UTC) − timestamp_now, rounded to 15 minutes.
    static func derivedOffsetSeconds(timeNow: String?, timestampNow: Int?) -> Int? {
        guard let timeNow, let timestampNow, timestampNow > 0 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let asUTC = f.date(from: timeNow.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let rawOffset = asUTC.timeIntervalSince1970 - Double(timestampNow)
        // Round to the nearest 15-minute step; ignore absurd values.
        guard abs(rawOffset) <= 15 * 3600 else { return nil }
        let quarter = (rawOffset / 900).rounded() * 900
        return Int(quarter)
    }

    private static func persist(timezone: String?, playlist: Playlist) async {
        guard let tz = timezone?.trimmingCharacters(in: .whitespacesAndNewlines), !tz.isEmpty,
              tz != playlist.serverTimezone else { return }
        var updated = playlist
        updated.serverTimezone = tz
        try? await AppDatabase.shared.write { db in try updated.save(db) }
    }
}
