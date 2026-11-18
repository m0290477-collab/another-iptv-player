import SwiftUI

// MARK: - Environment distribution

private struct EPGSnapshotKey: EnvironmentKey {
    static let defaultValue: EPGSnapshot? = nil
}

extension EnvironmentValues {
    /// Now/next index for the active playlist, published once per minute by
    /// `EPGStore`. Injected once at the dashboard root so every card and the player
    /// overlay read it without per-card store observation. Its `Equatable` is a
    /// version compare, so environment invalidation is O(1).
    var epgSnapshot: EPGSnapshot? {
        get { self[EPGSnapshotKey.self] }
        set { self[EPGSnapshotKey.self] = newValue }
    }
}

// MARK: - Channel key resolution

/// Resolves a playlist channel to the key used to look up EPG now/next in the
/// snapshot. Prefers the explicit EPG id, falling back to the channel name (the
/// store publishes both id and name aliases for display-name-matched channels).
/// `nonisolated` so the M3U player-panel builders (which are `nonisolated`) can
/// call it.
nonisolated enum EPGChannelKey {
    static func forXtream(_ stream: DBLiveStream) -> String? {
        EPGConstants.normalizeChannelKey(stream.epgChannelId) ?? EPGConstants.normalizeChannelKey(stream.name)
    }

    static func forM3U(_ channel: DBM3UChannel) -> String? {
        EPGConstants.normalizeChannelKey(channel.tvgId) ?? EPGConstants.normalizeChannelKey(channel.tvgName ?? channel.name)
    }
}

// MARK: - Now/Next line (channel cards, side panel)

/// One compact line: current programme title + a thin progress capsule. Renders
/// nothing (or reserved blank space) when there's no now-playing programme.
struct EPGNowNextLine: View {
    let nowNext: EPGNowNext?
    let width: CGFloat
    var reserveSpace: Bool = false
    var tint: Color = .accentColor
    var textColor: Color = .secondary

    /// Keep the placeholder and populated state exactly the same height. The old
    /// 16pt placeholder was shorter than caption + spacing + bar, so shelves that
    /// were laid out before EPG arrived could clip the progress capsule.
    private var reservedHeight: CGFloat { 22 }

    var body: some View {
        if let now = nowNext?.now {
            VStack(alignment: .leading, spacing: 3) {
                Text(now.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundColor(textColor)
                    .frame(width: width, alignment: .leading)
                progressCapsule(for: now)
            }
            .frame(width: width, height: reservedHeight, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("epg.a11y.now_playing_format", now.title))
        } else if reserveSpace {
            Color.clear.frame(width: width, height: reservedHeight)
        }
    }

    @ViewBuilder
    private func progressCapsule(for programme: EPGProgramme) -> some View {
        // F1 (B13): progress is measured against the offset-shifted
        // "now" so the bar matches the displayed times.
        let fraction = programme.progress(at: EPGOffsetStore.lookupNow()) ?? 0
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.18)).frame(width: width, height: 3)
            Capsule().fill(tint).frame(width: max(0, width * fraction), height: 3)
        }
        .frame(width: width, height: 3)
    }
}

// MARK: - Player programme strip (top chrome)

/// Programme title stacked above its "HH:mm – HH:mm" range and a progress capsule,
/// shown while watching a live channel.
struct PlayerProgrammeStrip: View {
    let programme: EPGProgramme
    var tint: Color = .white

    /// Width the progress capsule fills within the strip.
    private let barWidth: CGFloat = 188

    var body: some View {
        // F1 (B13): offset-shifted "now", matching the displayed range.
        let fraction = programme.progress(at: EPGOffsetStore.lookupNow()) ?? 0

        VStack(alignment: .leading, spacing: 5) {
            Text(programme.title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(EPGTimeFormat.range(programme.start, programme.stop))
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.72))

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(width: barWidth, height: 3)
                Capsule().fill(tint).frame(width: max(0, barWidth * fraction), height: 3)
            }
            .frame(width: barWidth, height: 3)
        }
        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
    }
}

// MARK: - Time formatting

enum EPGTimeFormat {
    /// "20:30" in the APP's chosen language (C9 one-locale law,
    /// finisher wiring): the formatter binds to `AppTheme.appLocale`,
    /// never the device locale (24h or 12h per that locale).
    ///
    /// F1 (B13): the F1 EPG time offset is applied HERE, at the
    /// single formatting choke point, so every displayed programme
    /// time in the app (guide axis + cells, programme details,
    /// channel schedules, search results, Home shelves, the player
    /// programme strip) shifts by the same amount. Callers always
    /// pass RAW provider times.
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppTheme.appLocale
        // "j" = the locale's own hour cycle (12h with AM/PM or 24h).
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: EPGOffsetStore.displayDate(date))
    }

    /// "20:30 – 21:00"
    static func range(_ start: Date, _ stop: Date) -> String {
        "\(time(start)) – \(time(stop))"
    }
}

// MARK: - Guide layout metrics

struct EPGGuideMetrics: Equatable {
    var hourWidth: CGFloat
    var rowHeight: CGFloat
    var channelColumnWidth: CGFloat
    var axisHeight: CGFloat
    var headerHeight: CGFloat

    var dayWidth: CGFloat { hourWidth * 24 }

    init(compact: Bool) {
        hourWidth = compact ? 150 : 180
        rowHeight = 56
        channelColumnWidth = compact ? 104 : 172
        axisHeight = 28
        headerHeight = 34
    }

    /// X offset (points from midnight) for a given instant on the selected day.
    func x(for date: Date, dayStart: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(dayStart) / 3600) * hourWidth
    }
}
