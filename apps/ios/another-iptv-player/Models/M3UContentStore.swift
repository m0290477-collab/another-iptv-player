import Foundation
import GRDB
import Combine

/// Keeps the active channels for an M3U playlist in memory. Separate from Xtream's PlaylistContentStore.
///
/// Grouping is done in a `Task.detached` so grouping 310K+ channels does not stall the main thread;
/// with `loadToken`, of concurrent load requests only the last one is applied to the store.
@MainActor
final class M3UContentStore: ObservableObject {
    static let shared = M3UContentStore()

    @Published private(set) var activePlaylistId: UUID?
    @Published var isLoading = false
    @Published var loadError: String?

    @Published private(set) var channels: [DBM3UChannel] = []
    @Published private(set) var channelsByGroup: [String: [DBM3UChannel]] = [:]
    @Published private(set) var groupNames: [String] = []

    /// The CANONICAL key used for channels with an empty `group-title`. Lookups
    /// (queue, panel, hidden-category ids) must always use this key;
    /// it is localized with `displayName(forGroup:)` when shown to the user.
    /// Note: because HiddenCategoryStore persists this value as an id, changing it
    /// would break existing users' hidden-category choices — it must stay "Diğer".
    nonisolated static let ungroupedLabel = "Diğer"

    /// Display name: the canonical ungrouped key is translated into the active language; others are returned as-is.
    /// nonisolated because the panel builders run in detached tasks.
    nonisolated static func displayName(forGroup group: String) -> String {
        group == ungroupedLabel ? L("m3u.ungrouped_label") : group
    }

    /// The active playlist's filter flag — updated when the toggle changes and applied on the next load.
    private var filterAdultContent: Bool = false

    private var loadToken: UUID?

    private init() {}

    // MARK: - Public API

    func loadPlaylist(_ playlist: Playlist) async {
        let token = UUID()
        loadToken = token
        loadError = nil

        if activePlaylistId != playlist.id {
            clearLists()
            activePlaylistId = playlist.id
        }
        filterAdultContent = playlist.filterAdultContent

        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await fetchChannels(playlistId: playlist.id)
            guard loadToken == token else { return }
            let visible = applyAdultFilter(fetched, enabled: filterAdultContent)
            let grouped = await groupOffMain(visible)
            guard loadToken == token else { return }
            apply(channels: visible, grouping: grouped)
        } catch {
            guard loadToken == token else { return }
            loadError = error.localizedDescription
        }
    }

    /// So 310K+ channel copies do not stay in the singleton after leaving the dashboard (see
    /// PlaylistContentStore.unload).
    func unload() {
        loadToken = nil
        activePlaylistId = nil
        clearLists()
        loadError = nil
        isLoading = false
    }

    func reloadIfActive(playlist: Playlist) async {
        guard activePlaylistId == playlist.id else { return }
        filterAdultContent = playlist.filterAdultContent
        do {
            let fetched = try await fetchChannels(playlistId: playlist.id)
            let visible = applyAdultFilter(fetched, enabled: filterAdultContent)
            let grouped = await groupOffMain(visible)
            apply(channels: visible, grouping: grouped)
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Search

    func search(_ query: String) -> [DBM3UChannel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        // Build 61 (B10, Q13): typo-tolerant, like the Xtream store's global search.
        return channels.filter { CatalogTextSearch.matchesFuzzy(search: q, text: $0.name) }
    }

    // MARK: - Internal

    private func clearLists() {
        channels = []
        channelsByGroup = [:]
        groupNames = []
    }

    private func apply(channels: [DBM3UChannel], grouping: Grouping) {
        self.channels = channels
        self.channelsByGroup = grouping.byGroup
        self.groupNames = grouping.names
        // Build 61 (B8, R1): first-seen recording for M3U channels.
        // `apply` is the single funnel for loads and post-reimport
        // reloads; the store's baseline rule keeps the first-ever
        // batch silent, and unchanged reloads record nothing new.
        if let playlistId = activePlaylistId {
            FirstSeenStore.shared.record(
                playlistId: playlistId,
                itemKeys: channels.map { "m3u:\($0.id)" }
            )
        }
    }

    private func fetchChannels(playlistId: UUID) async throws -> [DBM3UChannel] {
        try await AppDatabase.shared.read { db in
            try DBM3UChannel
                .filter(Column("playlistId") == playlistId)
                .order(Column("sortIndex"))
                .fetchAll(db)
        }
    }

    /// Grouping 310K channels on the main thread causes 100-500ms stalls; send it to a detached task.
    private func groupOffMain(_ channels: [DBM3UChannel]) async -> Grouping {
        let label = Self.ungroupedLabel
        return await Task.detached(priority: .userInitiated) {
            Self.group(channels: channels, ungroupedLabel: label)
        }.value
    }

    private struct Grouping: Sendable {
        var byGroup: [String: [DBM3UChannel]]
        var names: [String]
    }

    /// Drops the channel if its name or group-title contains an adult keyword.
    /// Does not modify the DB — only filters the visible set. The toggle takes effect instantly.
    nonisolated private func applyAdultFilter(_ channels: [DBM3UChannel], enabled: Bool) -> [DBM3UChannel] {
        guard enabled else { return channels }
        return channels.filter { ch in
            if AdultContentFilter.isAdultCategoryName(ch.name) { return false }
            if let group = ch.groupTitle, AdultContentFilter.isAdultCategoryName(group) { return false }
            return true
        }
    }

    nonisolated private static func group(channels: [DBM3UChannel], ungroupedLabel: String) -> Grouping {
        var byGroup: [String: [DBM3UChannel]] = [:]
        var names: [String] = []
        byGroup.reserveCapacity(min(channels.count / 8, 4096))
        for ch in channels {
            let raw = ch.groupTitle?.trimmingCharacters(in: .whitespaces)
            let key = (raw?.isEmpty == false ? raw! : ungroupedLabel)
            if byGroup[key] == nil { names.append(key) }
            byGroup[key, default: []].append(ch)
        }
        return Grouping(byGroup: byGroup, names: names)
    }
}
