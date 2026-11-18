import SwiftUI
import WidgetKit

/// Round 15 (C3): Super X home-screen widget — Continue Watching,
/// favorite channels and what's on now, all read from the App
/// Group snapshot the app writes (`WidgetSnapshot`). No snapshot
/// (or an all-empty one) renders the honest "Open Super X" state;
/// the widget never invents rows.
struct SuperXEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SuperXProvider: TimelineProvider {
    func placeholder(in context: Context) -> SuperXEntry {
        SuperXEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (SuperXEntry) -> Void) {
        completion(SuperXEntry(date: Date(), snapshot: .load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SuperXEntry>) -> Void) {
        let entry = SuperXEntry(date: Date(), snapshot: .load())
        // The app reloads timelines explicitly after every snapshot
        // write; the 30-minute policy is only a staleness backstop
        // (e.g. an "On Now" programme ending).
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct SuperXWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SuperXEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        Group {
            if snapshot.isEmpty {
                emptyState
            } else if family == .systemSmall {
                smallBody
            } else {
                mediumBody
            }
        }
        .containerBackground(for: .widget) {
            Color(red: 0.043, green: 0.043, blue: 0.063) // #0B0B10, the app's background token
        }
    }

    // MARK: - Honest empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.tv")
                .font(.title2)
                .foregroundStyle(.white)
            Text(WidgetLabels.text("openSuperX"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Small: top Continue Watching item, else first On Now

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = snapshot.continueWatching.first {
                sectionTitle("continueWatching")
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                ProgressView(value: item.progress)
                    .tint(.white)
            } else if let now = snapshot.onNow.first {
                sectionTitle("onNow")
                Text(now.programme)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(now.channel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            } else if let channel = snapshot.favoriteChannels.first {
                sectionTitle("favoriteChannels")
                Text(channel.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Medium: Continue Watching + favorites / on-now

    private var mediumBody: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("continueWatching")
                if snapshot.continueWatching.isEmpty {
                    placeholderLine
                } else {
                    ForEach(Array(snapshot.continueWatching.prefix(3).enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            ProgressView(value: item.progress)
                                .tint(.white)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if !snapshot.onNow.isEmpty {
                    sectionTitle("onNow")
                    ForEach(Array(snapshot.onNow.prefix(3).enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.programme)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(item.channel)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                } else {
                    sectionTitle("favoriteChannels")
                    if snapshot.favoriteChannels.isEmpty {
                        placeholderLine
                    } else {
                        ForEach(Array(snapshot.favoriteChannels.prefix(3).enumerated()), id: \.offset) { _, channel in
                            Text(channel.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(WidgetLabels.text(key))
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white.opacity(0.55))
            .textCase(.uppercase)
    }

    private var placeholderLine: some View {
        Text("—")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.4))
    }
}

struct SuperXWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SuperXWidget", provider: SuperXProvider()) { entry in
            SuperXWidgetView(entry: entry)
        }
        .configurationDisplayName("Super X")
        .description(WidgetLabels.text("openSuperX"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct SuperXWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SuperXWidget()
    }
}
