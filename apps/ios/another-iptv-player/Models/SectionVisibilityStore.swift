import Foundation
import Combine

/// Build 61 (B13, F6): the ONE section-visibility store behind the
/// Settings ▸ Appearance "Show sections" toggles.
///
/// Hidable sections: Movies / Series / Matches / Library. Home and
/// Live can NEVER be hidden — they have no case-toggling API and
/// no toggle in Settings (the `Section` enum lists exactly the
/// four hidable sections).
///
/// Persistence convention (shared with B12's Matches Home entry):
/// one UserDefaults Bool per section under the key
/// `sections.hidden.<section>` — `true` means hidden; a missing
/// key means visible. B12 reads `sections.hidden.matches` for its
/// Home entry; the tab bar and Home shelves read through this
/// store.
final class SectionVisibilityStore: ObservableObject {
    static let shared = SectionVisibilityStore()

    enum Section: String, CaseIterable {
        case movies
        case series
        case matches
        case library

        /// The shared persistence key for this section.
        var storageKey: String { "sections.hidden.\(rawValue)" }
    }

    /// The current hidden set; mutated only through `setHidden`.
    @Published private(set) var hiddenSections: Set<Section> = []

    private init() {
        hiddenSections = Set(Section.allCases.filter {
            UserDefaults.standard.bool(forKey: $0.storageKey)
        })
    }

    func isHidden(_ section: Section) -> Bool {
        hiddenSections.contains(section)
    }

    func isVisible(_ section: Section) -> Bool {
        !isHidden(section)
    }

    func setHidden(_ hidden: Bool, _ section: Section) {
        UserDefaults.standard.set(hidden, forKey: section.storageKey)
        if hidden {
            hiddenSections.insert(section)
        } else {
            hiddenSections.remove(section)
        }
    }

    /// Non-observable read for one-off consumers (e.g. B12's Home
    /// entry) that already observe something else.
    static func isHidden(section: Section) -> Bool {
        UserDefaults.standard.bool(forKey: section.storageKey)
    }
}
