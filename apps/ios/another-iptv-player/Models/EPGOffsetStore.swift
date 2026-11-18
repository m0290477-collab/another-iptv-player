import Foundation
import Combine

/// Build 61 (B13, F1): the ONE EPG time-offset store — per-APP
/// (not per-playlist), −12…+12 hours in 0.5 h steps, default 0.
///
/// Providers sometimes ship guide times shifted from reality; the
/// user corrects that here once and EVERY consumer of programme
/// times reads the same offset, so the guide, the details and the
/// reminders can never disagree:
///
///  - DISPLAY: `EPGTimeFormat` formats `displayDate(_:)` (raw +
///    offset), which shifts the guide axis + cells, programme
///    details, channel schedules, search results and Home shelves
///    in one place.
///  - NOW/NEXT: lookups compare against `lookupNow(_:)` (real
///    now − offset) — `EPGStore.tick`, the guide now-line, the
///    detail/channel sheets' on-air checks and progress bars.
///  - REMINDERS: `NotificationScheduler.scheduleProgrammeReminder`
///    shifts the fire date by the same offset.
///
/// Playback itself (catch-up URL resolution, timeshift) always
/// uses the RAW provider times — the offset is a display and
/// scheduling correction only, never a playback change.
final class EPGOffsetStore: ObservableObject {
    static let shared = EPGOffsetStore()

    /// UserDefaults key (hours, Double). Also read statically by
    /// non-observable consumers (`EPGTimeFormat`, the scheduler).
    static let storageKey = "epg.timeOffsetHours"

    @Published var offsetHours: Double {
        didSet {
            let clamped = Self.clamp(offsetHours)
            if clamped != offsetHours { offsetHours = clamped; return }
            UserDefaults.standard.set(offsetHours, forKey: Self.storageKey)
        }
    }

    private init() {
        offsetHours = Self.clamp(UserDefaults.standard.double(forKey: Self.storageKey))
    }

    /// Steps of 0.5 h inside −12…+12; anything else snaps to the
    /// nearest legal value so a corrupt stored value can never
    /// produce a fractional-minute shift.
    static func clamp(_ hours: Double) -> Double {
        let stepped = (hours * 2).rounded() / 2
        return min(12, max(-12, stepped))
    }

    // MARK: - Static consumers (single source of truth)

    static var offsetSeconds: TimeInterval {
        clamp(UserDefaults.standard.double(forKey: storageKey)) * 3_600
    }

    /// A raw provider time as it should be DISPLAYED.
    static func displayDate(_ raw: Date) -> Date {
        raw.addingTimeInterval(offsetSeconds)
    }

    /// The instant to compare RAW programme windows against so
    /// "current programme" means the one the user SEES as current.
    static func lookupNow(_ now: Date = Date()) -> Date {
        now.addingTimeInterval(-offsetSeconds)
    }
}
