import Foundation

/// Build 61 (B8, Z6): empty provider categories are HIDDEN BY
/// DEFAULT everywhere (Live/Movies/Series category shelves, lists
/// and pickers). The Settings → Appearance toggle "Show empty
/// categories" (`appearance.showEmptyCategories`, default OFF)
/// brings them back.
///
/// This is a pure visibility filter layered over the existing
/// category pipeline: it composes with `HiddenCategoryStore` and the
/// parental locks because it only ever REMOVES categories from a
/// display set that those layers already filtered — an empty
/// category that is also hidden or locked stays hidden regardless of
/// this toggle, and turning the toggle ON never un-hides or unlocks
/// anything.
nonisolated enum EmptyCategoryVisibility {
    static let defaultsKey = "appearance.showEmptyCategories"

    static var showEmpty: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Filters a category list to those with at least one item,
    /// unless the user opted to show empty categories. `count` is the
    /// caller''s real per-category item count.
    static func visible<T>(_ categories: [T], count: (T) -> Int) -> [T] {
        guard !showEmpty else { return categories }
        return categories.filter { count($0) > 0 }
    }
}
