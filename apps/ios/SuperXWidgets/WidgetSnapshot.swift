import Foundation

/// The widget's copy of the App Group snapshot contract.
///
/// The app (`Models/WidgetSnapshotStore.swift`) writes this as JSON
/// to `widget-snapshot.json` in the `group.com.irqus.superx`
/// container, built ONLY from real local data (watch history,
/// favorites, the EPG now/next snapshot). Keep this definition in
/// sync with the app-side one — the JSON is the interface.
struct WidgetSnapshot: Codable, Equatable {
    struct ContinueItem: Codable, Equatable {
        var title: String
        var subtitle: String?
        var progress: Double
    }
    struct FavoriteChannel: Codable, Equatable {
        var name: String
        var logoURL: String?
    }
    struct OnNowItem: Codable, Equatable {
        var channel: String
        var programme: String
    }

    var generatedAt: Date
    var continueWatching: [ContinueItem]
    var favoriteChannels: [FavoriteChannel]
    var onNow: [OnNowItem]

    static let empty = WidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        continueWatching: [], favoriteChannels: [], onNow: [])

    var isEmpty: Bool {
        continueWatching.isEmpty && favoriteChannels.isEmpty && onNow.isEmpty
    }

    static func load() -> WidgetSnapshot {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.irqus.superx")?
            .appendingPathComponent("widget-snapshot.json"),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }
}
