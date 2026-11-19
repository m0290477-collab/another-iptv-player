import SwiftUI

// MARK: - Build 67 (W6, S8): Categories-First section landings
//
// Shared building blocks for the restructured Movies / Series /
// Live TV / M3U landings (owner pick: sections style 1,
// "Categories First"). The tiles carry REAL category names and
// REAL item counts from the synced catalog — the caller builds the
// items from its display buckets; nothing is derived or invented
// here. Selecting a tile filters the section to that category via
// the caller's existing selection state (the build-65 chip state);
// the "All" tile restores the full section.

/// One category tile's data: the category id (the selection value),
/// its display name and its REAL item count.
struct SectionCategoryTileItem: Identifiable, Equatable {
    let id: String
    let name: String
    let count: Int
}

/// The frosted-glass tile surface (build 67, S2 language):
/// ultraThinMaterial over the AppTheme surface tint, hairline
/// border; the selected tile takes the accent border + tint.
private struct SectionGlassTileModifier: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                            .fill(AppTheme.surface.opacity(isSelected ? 0.35 : 0.6))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(isSelected ? AppTheme.accent : AppTheme.cardBorderColor, lineWidth: isSelected ? 1.5 : 1)
            )
            .shadow(color: AppTheme.cardShadowColor, radius: AppTheme.cardShadowRadius, y: AppTheme.cardShadowY)
    }
}

extension View {
    /// Build 67 (W6): the Cinematic Glass tile surface shared by the
    /// category tiles and the channel cards.
    func sectionGlassTile(isSelected: Bool = false) -> some View {
        modifier(SectionGlassTileModifier(isSelected: isSelected))
    }
}

/// "Categories" header in the section-header language (small-caps
/// accent title, matching `CinematicSectionHeader`'s title styling)
/// — without a See-all link, because the tiles ARE the navigation.
struct SectionCategoriesHeader: View {
    var body: some View {
        Text("• \(L("b67w6.categories").uppercased()) •")
            .font(AppFont.font(.subheadline, weight: .bold))
            .foregroundStyle(AppTheme.accent)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }
}

/// One tile: name + real count. Used by both layouts below.
private struct SectionCategoryTile: View {
    let title: String
    let count: Int
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? AppTheme.accent : .secondary)
                Text(title)
                    .font(AppTheme.fontCardTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(CatalogCountFormatter.string(count))
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .sectionGlassTile(isSelected: isSelected)
        }
        .buttonStyle(PressScaleButtonStyle())
    }
}

/// Categories-First landing block for Movies / Series: the header
/// plus a two-column tile grid — an "All" tile (the section's real
/// total) followed by one tile per real category.
struct SectionCategoryTilesGrid: View {
    let items: [SectionCategoryTileItem]
    let totalCount: Int
    let systemImage: String
    @Binding var selectedCategoryId: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCategoriesHeader()

            LazyVGrid(columns: columns, spacing: 12) {
                SectionCategoryTile(
                    title: L("search.all"),
                    count: totalCount,
                    systemImage: systemImage,
                    isSelected: selectedCategoryId == nil
                ) {
                    selectedCategoryId = nil
                }
                ForEach(items) { item in
                    SectionCategoryTile(
                        title: item.name,
                        count: item.count,
                        systemImage: systemImage,
                        isSelected: selectedCategoryId == item.id
                    ) {
                        selectedCategoryId = item.id
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// Compact horizontal variant for the Live TV grid header and the
/// M3U shelves: glass tiles in a scrolling row (name + real count),
/// wired to the same selection state as the grid layout.
struct SectionCategoryTilesRow: View {
    let items: [SectionCategoryTileItem]
    @Binding var selectedCategoryId: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                rowTile(id: nil, title: L("search.all"), count: nil)
                ForEach(items) { item in
                    rowTile(id: item.id, title: item.name, count: item.count)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
    }

    private func rowTile(id: String?, title: String, count: Int?) -> some View {
        let isSelected = selectedCategoryId == id
        return Button {
            selectedCategoryId = id
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if let count {
                    Text(CatalogCountFormatter.string(count))
                        .font(AppTheme.fontBadge)
                        .foregroundStyle(isSelected ? AppTheme.onAccent : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(isSelected ? AppTheme.accent : AppTheme.elevated))
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .sectionGlassTile(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

/// Plain year header for the By Year rails — styled like the
/// section headers, with no See-all (the rail itself is the year's
/// real poster row; no separate year screen exists to link to).
struct SectionYearHeader: View {
    let year: Int

    var body: some View {
        Text("• \(String(year)) •")
            .font(AppFont.font(.subheadline, weight: .bold))
            .foregroundStyle(AppTheme.accent)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }
}
