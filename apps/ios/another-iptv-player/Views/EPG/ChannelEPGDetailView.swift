import SwiftUI
import GRDBQuery

/// Day-grouped programme schedule for one channel. Live-updates via GRDBQuery.
struct ChannelEPGDetailView: View {
    let playlist: Playlist
    let channelKey: String
    let displayName: String
    let iconURL: URL?
    let liveStream: DBLiveStream?

    @Query<ChannelEPGRequest> private var rows: [DBEPGProgramme]
    @State private var selected: EPGProgramme?
    @State private var hasScrolledToNow = false
    @Environment(\.epgSnapshot) private var epgSnapshot

    init(playlist: Playlist, channelKey: String, displayName: String, iconURL: URL?, liveStream: DBLiveStream?) {
        self.playlist = playlist
        self.channelKey = channelKey
        self.displayName = displayName
        self.iconURL = iconURL
        self.liveStream = liveStream
        let now = Date()
        let from = Int64(now.addingTimeInterval(-2 * 86_400).timeIntervalSince1970)
        let to = Int64(now.addingTimeInterval(8 * 86_400).timeIntervalSince1970)
        _rows = Query(ChannelEPGRequest(playlistId: playlist.id, channelKey: channelKey, fromTs: from, toTs: to), in: \.appDatabase)
    }

    private var programmes: [EPGProgramme] { rows.map(EPGProgramme.init(from:)) }

    private var days: [(day: Date, items: [EPGProgramme])] {
        let cal = Calendar.current
        // F1 (B13): group by the DISPLAYED day (raw start + the one
        // EPG offset) so a programme shown as "01:30" sits under the
        // day its displayed time belongs to.
        let grouped = Dictionary(grouping: programmes) { cal.startOfDay(for: EPGOffsetStore.displayDate($0.start)) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.start < $1.start }) }
    }

    var body: some View {
        Group {
            if programmes.isEmpty {
                ContentUnavailableView(L("epg.no_data.channel"), systemImage: "calendar.badge.exclamationmark")
            } else {
                scheduleList
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { programme in
            EPGProgrammeDetailSheet(playlist: playlist, programme: programme,
                                    channelName: displayName, channelIcon: iconURL, liveStream: liveStream)
                .presentationDetents([.medium, .large])
        }
        .cinematicBackground()
    }

    private var scheduleList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(days, id: \.day) { group in
                    Section(header: Text(dayLabel(group.day))) {
                        ForEach(group.items) { programme in
                            row(programme)
                                .id(rowID(programme))
                                .contentShape(Rectangle())
                                .onTapGesture { selected = programme }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .cinematicScrollBackground()
            .onAppear {
                scrollToNowIfNeeded(proxy)
            }
            .onChange(of: rows) { _, _ in
                scrollToNowIfNeeded(proxy)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let current = programmes.first(where: { $0.isCurrent(at: EPGOffsetStore.lookupNow()) }) {
                            withAnimation { proxy.scrollTo(rowID(current), anchor: .center) }
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel(L("epg.jump_to_now"))
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ programme: EPGProgramme) -> some View {
        let now = Date()
        // F1 (B13): on-air/past state as DISPLAYED (offset-shifted
        // "now"); catch-up availability below keeps the real `now`
        // because playback resolves against raw provider times.
        let displayNow = EPGOffsetStore.lookupNow(now)
        let isCurrent = programme.isCurrent(at: displayNow)
        let isPast = programme.isPast(at: displayNow)
        HStack(alignment: .top, spacing: 12) {
            Text(EPGTimeFormat.time(programme.start))
                .font(.subheadline.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(programme.title).font(.body).lineLimit(1)
                    if isCurrent {
                        Text(L("epg.now")).font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                }
                if let desc = programme.desc, !desc.isEmpty {
                    Text(desc).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                if isCurrent, let fraction = programme.progress(at: displayNow) {
                    // C12: the on-air progress bar animates on the
                    // minute tick instead of snapping.
                    ProgressView(value: fraction).tint(AppTheme.accent)
                        .animation(Motion.animate(.linear(duration: 0.6)), value: fraction)
                }
            }
            Spacer(minLength: 0)
            if isPast, isCatchupPlayable(programme, now: now) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.accentColor)
                    .accessibilityLabel(L("epg.catchup.available"))
            }
        }
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(Color.accentColor).frame(width: 3).padding(.vertical, 2)
                    .padding(.leading, -8)
            }
        }
        .opacity(isPast && !isCatchupPlayable(programme, now: now) ? 0.55 : 1)
    }

    private func isCatchupPlayable(_ programme: EPGProgramme, now: Date) -> Bool {
        guard let s = liveStream, s.tvArchive == 1 else { return false }
        return CatchupAvailability.isPlayable(tvArchive: s.tvArchive, tvArchiveDurationDays: s.tvArchiveDuration,
                                              programmeStart: programme.start, now: now)
    }

    private func rowID(_ programme: EPGProgramme) -> String { programme.id }

    /// Deferred a tick so the target row (often ~2 days into the list) has been laid out before scrolling.
    private func scrollToNowIfNeeded(_ proxy: ScrollViewProxy) {
        guard !hasScrolledToNow, let current = programmes.first(where: { $0.isCurrent(at: EPGOffsetStore.lookupNow()) }) else { return }
        hasScrolledToNow = true
        DispatchQueue.main.async {
            proxy.scrollTo(rowID(current), anchor: .center)
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return L("epg.day.today") }
        if cal.isDateInTomorrow(day) { return L("epg.day.tomorrow") }
        if cal.isDateInYesterday(day) { return L("epg.day.yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month())
    }
}

// Round 16 (R3): the orphaned ChannelEPGSheet wrapper is removed
// (zero call sites — the guide presents ChannelEPGDetailView
// directly).
