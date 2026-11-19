import SwiftUI

/// Build 65 (inside-sections design, owner-picked): the category
/// chips row under a section's featured hero — "All" plus one chip
/// per REAL provider category currently on display (the caller's
/// `displayCategories`, which already excludes hidden and — unless
/// the user opted in — empty categories). Selecting a category
/// swaps the section's shelf stack for that category's poster
/// grid; "All" restores the shelves. Shared by Movies and Series
/// so the two sections speak one language (Live keeps its own
/// grid/list modes and gains the same row wired to its filter).
struct SectionCategoryChips: View {
    let categories: [DBCategory]
    @Binding var selectedCategoryId: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PillChipButton(title: L("search.all"), isSelected: selectedCategoryId == nil) {
                    selectedCategoryId = nil
                }
                ForEach(categories) { category in
                    PillChipButton(title: category.name, isSelected: selectedCategoryId == category.id) {
                        selectedCategoryId = category.id
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
    }
}
