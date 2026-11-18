import Foundation
import Combine

/// Build 61 (B3, item 5): PIN-locked categories, layered on top of
/// the existing `AdultContentFilter` and the Keychain `PINStore`.
///
/// The adult filter decides what is HIDDEN at import; this store is
/// the separate, user-chosen lock: any category (live / vod /
/// series / m3u groups) can be locked, and a locked category cannot
/// be opened — category picker selection and live playback from it
/// are blocked — until the parental PIN is entered. A successful
/// PIN entry unlocks that category for the rest of the app session
/// (in-memory only; a relaunch re-locks everything).
///
/// Persistence mirrors `HiddenCategoryStore`: a UserDefaults string
/// array per playlist + content type, with a `@Published version`
/// bump on every mutation so SwiftUI surfaces refresh. The PIN
/// itself never lives here — verification is `PINStore.verify`.
@MainActor
final class ParentalControlStore: ObservableObject {
    static let shared = ParentalControlStore()

    @Published private(set) var version: Int = 0

    /// Categories unlocked by PIN during this app session, keyed
    /// "\(playlistId)|\(type)|\(categoryId)".
    private var sessionUnlocked: Set<String> = []

    private init() {}

    private static func storageKey(playlistId: UUID, type: String) -> String {
        "parental.locked.\(playlistId.uuidString).\(type)"
    }

    private static func sessionKey(playlistId: UUID, type: String, categoryId: String) -> String {
        "\(playlistId.uuidString)|\(type)|\(categoryId)"
    }

    // MARK: - Locked set

    func lockedIds(playlistId: UUID, type: String) -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: Self.storageKey(playlistId: playlistId, type: type)) ?? []
        return Set(arr)
    }

    func isLocked(playlistId: UUID, type: String, categoryId: String) -> Bool {
        lockedIds(playlistId: playlistId, type: type).contains(categoryId)
    }

    func setLocked(_ locked: Bool, playlistId: UUID, type: String, categoryId: String) {
        var current = lockedIds(playlistId: playlistId, type: type)
        let changed: Bool
        if locked {
            changed = current.insert(categoryId).inserted
        } else {
            changed = current.remove(categoryId) != nil
        }
        guard changed else { return }
        UserDefaults.standard.set(Array(current), forKey: Self.storageKey(playlistId: playlistId, type: type))
        if !locked {
            // Re-locking later must not inherit a stale session pass.
            sessionUnlocked.remove(Self.sessionKey(playlistId: playlistId, type: type, categoryId: categoryId))
        }
        version &+= 1
    }

    /// Any category locked for this playlist, across all types —
    /// drives the settings section's "unlock for this session" row.
    func hasAnyLock(playlistId: UUID) -> Bool {
        ["live", "vod", "series", "m3u"].contains {
            !lockedIds(playlistId: playlistId, type: $0).isEmpty
        }
    }

    // MARK: - Session unlock (PIN verified by the caller)

    func unlockForSession(playlistId: UUID, type: String, categoryId: String) {
        sessionUnlocked.insert(Self.sessionKey(playlistId: playlistId, type: type, categoryId: categoryId))
        version &+= 1
    }

    func unlockAllForSession(playlistId: UUID) {
        for type in ["live", "vod", "series", "m3u"] {
            for categoryId in lockedIds(playlistId: playlistId, type: type) {
                sessionUnlocked.insert(Self.sessionKey(playlistId: playlistId, type: type, categoryId: categoryId))
            }
        }
        version &+= 1
    }

    func isSessionUnlocked(playlistId: UUID, type: String, categoryId: String) -> Bool {
        sessionUnlocked.contains(Self.sessionKey(playlistId: playlistId, type: type, categoryId: categoryId))
    }

    // MARK: - The one blocking verdict

    /// True when opening this category's content must be blocked
    /// right now: it is locked, a PIN exists to unlock it with,
    /// and it has not been session-unlocked. (With NO PIN set a
    /// lock cannot be enforced — the settings UI only offers
    /// locking once a PIN exists, and this verdict mirrors that.)
    func isBlocked(playlistId: UUID, type: String, categoryId: String?) -> Bool {
        guard let categoryId, PINStore.hasPIN else { return false }
        return isLocked(playlistId: playlistId, type: type, categoryId: categoryId)
            && !isSessionUnlocked(playlistId: playlistId, type: type, categoryId: categoryId)
    }

    // MARK: - Cleanup

    /// Drop one playlist's locks (playlist deletion / sign-out).
    func removeAll(playlistId: UUID) {
        var changed = false
        for type in ["live", "vod", "series", "m3u"] {
            let key = Self.storageKey(playlistId: playlistId, type: type)
            if UserDefaults.standard.object(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
                changed = true
            }
        }
        let prefix = "\(playlistId.uuidString)|"
        sessionUnlocked = sessionUnlocked.filter { !$0.hasPrefix(prefix) }
        if changed { version &+= 1 }
    }

    /// Drop EVERY playlist's locks (erase-all-data path).
    func removeAllEverywhere() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("parental.locked.") {
            defaults.removeObject(forKey: key)
        }
        sessionUnlocked.removeAll()
        version &+= 1
    }
}
