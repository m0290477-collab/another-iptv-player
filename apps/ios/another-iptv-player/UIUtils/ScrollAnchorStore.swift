import Foundation

/// Build 61 fixer (O9): scroll-position restoration for the three
/// main tab lists — Live shelves, Movies and Series.
///
/// Each surface persists the ID of its first-visible category shelf
/// (the shelf at the scroll view's top anchor) per playlist, in the
/// standard UserDefaults domain (the same store `@AppStorage`
/// writes). On return, the surface restores that shelf via
/// `.scrollPosition(id:)` — a jump, never an animated scroll. The
/// category grids, the category detail screens and every other
/// list are out of scope by design (bounded to the three tab
/// shelf lists).
enum ScrollAnchorStore {
    private static func key(surface: String, playlistId: UUID) -> String {
        "scrollanchor.\(surface).\(playlistId.uuidString)"
    }

    static func anchor(surface: String, playlistId: UUID) -> String? {
        let value = UserDefaults.standard.string(forKey: key(surface: surface, playlistId: playlistId))
        return (value?.isEmpty == false) ? value : nil
    }

    static func save(_ id: String, surface: String, playlistId: UUID) {
        UserDefaults.standard.set(id, forKey: key(surface: surface, playlistId: playlistId))
    }
}
