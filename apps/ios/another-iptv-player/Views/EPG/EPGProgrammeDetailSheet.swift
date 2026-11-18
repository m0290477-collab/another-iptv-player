import SwiftUI
import UserNotifications

/// Programme detail popover: title, time, description, and context-appropriate
/// play actions (play the live channel, watch-from-start, or catch-up playback).
/// Self-contained — owns the live/catch-up presentation so both the guide and the
/// channel-detail list can present it with just the programme + channel data.
struct EPGProgrammeDetailSheet: View {
    let playlist: Playlist
    let programme: EPGProgramme
    let channelName: String
    let channelIcon: URL?
    /// Xtream live stream for this channel — enables live play + catch-up. nil for M3U.
    let liveStream: DBLiveStream?
    /// Supplied by presenters that HAVE a channel-detail destination
    /// (the guide pushes `ChannelEPGDetailView`); left nil by
    /// presenters that are already showing that destination
    /// (ChannelEPGDetailView itself). Build 60: no longer forwarded
    /// into catch-up playback — the catch-up player's title tap is
    /// inert, exactly as in pristine build 33, whose
    /// `CatchupPlayerShell`/`CatchupPlaybackController` have no
    /// navigation forwarding. The property is kept so existing
    /// presenters (EPGGuideView) still compile unchanged.
    var onNavigateToChannelDetail: ((DBLiveStream) -> Void)? = nil

    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @StateObject private var catchup = CatchupPlaybackController()
    @Environment(\.dismiss) private var dismiss

    // B3 (Round 14): programme reminders. The two AppStorage keys are
    // owned by Settings (reminders toggle + lead-time picker live
    // there); this sheet only READS them. Defaults: enabled, 10 min.
    @AppStorage("reminders.enabled") private var remindersEnabled = true
    @AppStorage("reminders.leadTimeMinutes") private var reminderLeadMinutes = 10
    @State private var reminderSet = false
    /// C12 (Round 15): staggered sheet entrance (transform/opacity only).
    @State private var entranceShown = false

    private var reminderIdentifier: String {
        "epg.reminder.\(programme.channelKey)|\(Int(programme.start.timeIntervalSince1970))"
    }
    /// A reminder only makes sense for a programme that has not
    /// started yet, with the lead time still in the future.
    private var canRemind: Bool {
        remindersEnabled
            && programme.start.addingTimeInterval(-Double(reminderLeadMinutes) * 60) > Date()
    }

    private var now: Date { Date() }
    private var isCurrent: Bool { programme.isCurrent(at: now) }

    private var catchupPlayable: Bool {
        guard let s = liveStream, s.tvArchive == 1 else { return false }
        if isCurrent {
            return CatchupAvailability.isWatchFromStart(programmeStart: programme.start, programmeStop: programme.stop, now: now)
        }
        return CatchupAvailability.isPlayable(tvArchive: s.tvArchive, tvArchiveDurationDays: s.tvArchiveDuration,
                                              programmeStart: programme.start, now: now)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        CachedImage(url: channelIcon, width: 44, height: 44, cornerRadius: AppTheme.smallCornerRadius, iconName: "tv")
                        Text(channelName).font(.headline)
                    }
                    .opacity(entranceShown ? 1 : 0)
                    .offset(y: entranceShown ? 0 : 10)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(programme.title).font(.title3.bold())
                        HStack(spacing: 8) {
                            Text(timeLine).font(.subheadline).foregroundColor(.secondary)
                            if isCurrent {
                                Text(L("epg.detail.live_badge"))
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                            }
                        }
                        if isCurrent, let fraction = programme.progress(at: now) {
                            ProgressView(value: fraction).tint(.accentColor)
                        }
                    }

                    if let desc = programme.desc, !desc.isEmpty {
                        Text(desc).font(.body).foregroundColor(.primary.opacity(0.9))
                    }

                    playButtons
                        .opacity(entranceShown ? 1 : 0)
                        .offset(y: entranceShown ? 0 : 10)

                    if let error = catchup.errorMessage {
                        Text(error).font(.footnote).foregroundColor(.red)
                    }
                }
                .padding()
            }
            .task {
                let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
                reminderSet = pending.contains { $0.identifier == reminderIdentifier }
                // C12: staggered entrance — header, then body, then actions.
                withAnimation(.easeOut(duration: 0.3).delay(0.05)) { entranceShown = true }
            }
            .navigationTitle(L("epg.programme_detail.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.close")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var playButtons: some View {
        VStack(spacing: 10) {
            // B3: "Remind me" — a real local notification at
            // programme start minus the Settings lead time. Tapping
            // again removes it. Authorization is requested at first
            // use, never at launch.
            if canRemind {
                Button {
                    Task { await toggleReminder() }
                } label: {
                    Label(reminderSet ? L("epg.reminder.set") : L("epg.reminder.action"),
                          systemImage: reminderSet ? "bell.fill" : "bell")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if liveStream != nil {
                Button {
                    dismiss()
                    playLiveChannel()
                } label: {
                    Label(L("epg.detail.play_channel"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if catchupPlayable, let stream = liveStream {
                Button {
                    let programmeBridge = CatchupProgramme(title: programme.title, description: programme.desc,
                                                           startUTC: programme.start, stopUTC: programme.stop)
                    Task {
                        await catchup.play(
                            playlist: playlist, stream: stream, programme: programmeBridge, overlay: playerOverlay
                        )
                        // Only close once playback actually resolved; keep the sheet open to show the error otherwise.
                        if catchup.errorMessage == nil {
                            dismiss()
                        }
                    }
                } label: {
                    if catchup.isResolving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label(isCurrent ? L("epg.detail.watch_from_start") : L("epg.detail.play_catchup"),
                              systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(catchup.isResolving)
            }
        }
    }

    private var timeLine: String {
        let minutes = max(1, Int(programme.duration / 60))
        return "\(EPGTimeFormat.range(programme.start, programme.stop)) · \(L("epg.detail.minutes_format", minutes))"
    }

    private func playLiveChannel() {
        guard let stream = liveStream else { return }
        // Full live catalog so prev/next channel and the side panel stay enabled.
        let live = LiveChannelCategorySection.xtreamLiveQueue()
        playerOverlay.present(playlistId: playlist.id) {
            LivePlayerShell(playlist: playlist, queue: live.queue, sections: live.sections,
                            initialStream: stream, initialHistory: nil, subtitle: channelName)
        }
    }
}

// MARK: - B3 programme reminder scheduling

private extension EPGProgrammeDetailSheet {
    func toggleReminder() async {
        let center = UNUserNotificationCenter.current()
        if reminderSet {
            center.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])
            reminderSet = false
            return
        }
        // First use: ask. A denial leaves the button a no-op rather
        // than scheduling into the void.
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let refreshed = await center.notificationSettings()
        guard refreshed.authorizationStatus == .authorized
                || refreshed.authorizationStatus == .provisional else { return }

        let fireDate = programme.start.addingTimeInterval(-Double(reminderLeadMinutes) * 60)
        let interval = fireDate.timeIntervalSinceNow
        guard interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = programme.title
        content.body = channelName
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: reminderIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        do {
            try await center.add(request)
            reminderSet = true
        } catch {
            reminderSet = false
        }
    }
}
