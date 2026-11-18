import SwiftUI

/// A shared category/group picker — used by both the M3U and Xtream screens.
/// A searchable list, with a content-count chip on every row. `onSelect(id)` is called on selection.
/// If `playlistId` + `type` are given, the hide/show swipe action on rows becomes active and
/// hidden categories are displayed in a separate section.
struct CategoryPickerSheet: View {
    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let count: Int
    }

    let title: String
    let entries: [Entry]
    /// Both must be given to enable the hiding feature (e.g. it can be left nil in the M3U group picker).
    var playlistId: UUID? = nil
    var type: String? = nil
    let onSelect: (String) -> Void

    @ObservedObject private var locale = LocalizationManager.shared
    @ObservedObject private var hiddenStore = HiddenCategoryStore.shared
    @ObservedObject private var orderStore = CategoryOrderStore.shared

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    /// Drag-reorder edit mode (spec section 2.3). Only offered when the
    /// hide/show feature is on, no search filter is active, and there
    /// is more than one visible category to order.
    @State private var editMode: EditMode = .inactive

    private var hidingEnabled: Bool { playlistId != nil && type != nil }

    private var hiddenIds: Set<String> {
        guard let pid = playlistId, let t = type else { return [] }
        return hiddenStore.hiddenIds(playlistId: pid, type: t)
    }

    /// Filter + separate hidden/visible in a single pass. Reading the `visibleEntries`/`hiddenEntries`
    /// computed properties separately in the body was normalizing and scanning the whole list twice
    /// on every keystroke (a visible stall with thousands of M3U groups).
    private func partitionedEntries() -> (visible: [Entry], hidden: [Entry]) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let ids = hiddenIds
        var visible: [Entry] = []
        var hidden: [Entry] = []
        for entry in entries {
            if !q.isEmpty, !CatalogTextSearch.matches(search: q, text: entry.name) { continue }
            if hidingEnabled, ids.contains(entry.id) {
                hidden.append(entry)
            } else {
                visible.append(entry)
            }
        }
        // Saved drag order (CategoryOrderStore) applies to both
        // partitions whenever this sheet manages a playlist/type.
        if let pid = playlistId, let t = type {
            visible = orderStore.applyOrder(visible, playlistId: pid, type: t) { $0.id }
            hidden = orderStore.applyOrder(hidden, playlistId: pid, type: t) { $0.id }
        }
        return (visible, hidden)
    }

    /// Persists a drag move of the visible partition: the new visible
    /// order first, then any previously saved ids that are not visible
    /// right now (hidden categories, filtered-out rows) in their
    /// previous relative order — the spec's merged-order rule.
    private func moveVisible(fromOffsets: IndexSet, toOffset: Int, currentVisible: [Entry]) {
        guard let pid = playlistId, let t = type else { return }
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var newVisible = currentVisible
        newVisible.move(fromOffsets: fromOffsets, toOffset: toOffset)
        let visibleIds = newVisible.map(\.id)
        let visibleSet = Set(visibleIds)
        let remainder = orderStore.orderedIds(playlistId: pid, type: t)
            .filter { !visibleSet.contains($0) }
        orderStore.setOrder(visibleIds + remainder, playlistId: pid, type: t)
    }

    var body: some View {
        let (visibleEntries, hiddenEntries) = partitionedEntries()
        NavigationStack {
            Group {
                if visibleEntries.isEmpty && hiddenEntries.isEmpty {
                    ContentUnavailableView(
                        L("category_picker.not_found.title"),
                        systemImage: "magnifyingglass",
                        description: Text(L("category_picker.not_found.message"))
                    )
                } else {
                    List {
                        if !visibleEntries.isEmpty {
                            Section {
                                ForEach(visibleEntries) { entry in
                                    row(entry, isHidden: false)
                                }
                                .onMove { offsets, destination in
                                    moveVisible(fromOffsets: offsets, toOffset: destination, currentVisible: visibleEntries)
                                }
                            }
                        }

                        if !hiddenEntries.isEmpty {
                            Section(L("category_picker.hidden_section")) {
                                ForEach(hiddenEntries) { entry in
                                    row(entry, isHidden: true)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .environment(\.editMode, $editMode)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L("category_picker.search_placeholder")
            )
            .onChange(of: query) { _, newValue in
                // Reorder is defined over the full, unfiltered list.
                if !newValue.trimmingCharacters(in: .whitespaces).isEmpty, editMode == .active {
                    editMode = .inactive
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
                if hidingEnabled, query.trimmingCharacters(in: .whitespaces).isEmpty, visibleEntries.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(editMode == .active ? L("common.done") : L("common.edit")) {
                            withAnimation { editMode = editMode == .active ? .inactive : .active }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func row(_ entry: Entry, isHidden: Bool) -> some View {
        Button {
            // While reordering, row taps are inert (the drag handles
            // own the row); the jump action returns when edit mode ends.
            guard editMode != .active else { return }
            // Round 14 (B1): a hidden category is NOT a jump target —
            // tapping its row in the management section must not
            // scroll the (hidden) shelf into view. Unhiding stays on
            // the swipe action below; the management UI is unchanged.
            guard !isHidden else { return }
            onSelect(entry.id)
        } label: {
            HStack {
                Text(entry.name)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                Text("\(entry.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(AppTheme.smallCornerRadius)
            }
        }
        .opacity(isHidden ? 0.55 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if hidingEnabled, editMode != .active, let pid = playlistId, let t = type {
                Button {
                    hiddenStore.setHidden(!isHidden, playlistId: pid, type: t, categoryId: entry.id)
                } label: {
                    if isHidden {
                        Label(L("category_picker.unhide"), systemImage: "eye")
                    } else {
                        Label(L("category_picker.hide"), systemImage: "eye.slash")
                    }
                }
                .tint(isHidden ? AppTheme.accent : .gray)
            }
        }
    }
}
