import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PlaybackTrackSettingsSheet: View {
    @ObservedObject var player: VideoPlayerController
    @Binding var showDebugOverlay: Bool
    let streamURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var didCopyURL = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var showSubtitleImporter = false
    @State private var showSubtitleImportError = false
    @State private var audioDelaySeconds = AudioDelayPersistence.load()

    private static let subtitleContentTypes: [UTType] =
        ["srt", "ass", "ssa", "vtt", "sub", "smi"].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        NavigationStack {
            List {
                trackSection(
                    title: L("player.tracks.video"),
                    items: player.videoTracks,
                    currentId: player.currentVideoTrackId,
                    emptyLabel: L("player.tracks.empty.video"),
                    select: { player.selectVideoTrack(id: $0) }
                )
                trackSection(
                    title: L("player.tracks.audio"),
                    items: player.audioTracks,
                    currentId: player.currentAudioTrackId,
                    emptyLabel: L("player.tracks.empty.audio"),
                    select: { player.selectAudioTrack(id: $0) }
                )
                audioDelaySection
                trackSection(
                    title: L("player.tracks.subtitle"),
                    items: player.subtitleTracks,
                    currentId: player.currentSubtitleTrackId,
                    emptyLabel: L("player.tracks.empty.subtitle"),
                    select: { player.selectSubtitleTrack(id: $0) }
                )
                if !player.isLiveStream {
                    importedSubtitlesSection
                }
                // Build 61 (B14, V1): B4's speed + sleep sections were REMOVED
                // from this sheet — both controls now live ONLY in the player's
                // bottom control row (single instance). The PlaybackSleepTimer
                // engine below is unchanged and is driven from the player row.
                nightAudioSection
                Section(L("player.dev_section")) {
                    Toggle(L("player.show_debug_overlay"), isOn: $showDebugOverlay)
                }
                Section(L("player.stream_url.title")) {
                    Button(action: copyStreamURL) {
                        HStack(alignment: .top, spacing: 10) {
                            Text(streamURL.absoluteString)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Image(systemName: didCopyURL ? "checkmark" : "doc.on.doc")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(didCopyURL ? Color.accentColor : .secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(
                        didCopyURL ? L("player.stream_url.copied") : L("player.stream_url.copy")
                    )
                }
            }
            .navigationTitle(L("player.tracks.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
            }
        }
        .onAppear { player.updateTracks() }
        .onDisappear { copyResetTask?.cancel() }
        .onChange(of: audioDelaySeconds) { _, new in
            player.applyAudioDelaySeconds(new)
        }
        .fileImporter(
            isPresented: $showSubtitleImporter,
            allowedContentTypes: Self.subtitleContentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let picked = urls.first else { return }
            do {
                try player.importSubtitleFile(at: picked)
            } catch {
                showSubtitleImportError = true
            }
        }
        .alert(L("player.subtitle_import.failed"), isPresented: $showSubtitleImportError) {
            Button(L("common.close"), role: .cancel) {}
        }
    }

    /// Imported files are stored for this content and loaded automatically on future playbacks.
    private var importedSubtitlesSection: some View {
        Section {
            ForEach(player.importedSubtitleFiles, id: \.self) { file in
                Label(file.lastPathComponent, systemImage: "doc.text")
                    .foregroundStyle(.primary)
            }
            .onDelete { offsets in
                for index in offsets {
                    player.deleteImportedSubtitle(player.importedSubtitleFiles[index])
                }
            }
            Button {
                showSubtitleImporter = true
            } label: {
                Label(L("player.subtitle_import.button"), systemImage: "plus")
            }
        } header: {
            Text(L("player.subtitle_import.section"))
        } footer: {
            Text(L("player.subtitle_import.footer"))
        }
    }

    // MARK: - Build 61 (B10, Q5): dialogue / night audio mode
    //
    // ONE additive section beside B4's speed/sleep sections. The
    // toggle writes the persisted preference the engine reads in
    // `KSPlayerEngine.makeOptions` (NightAudioMode): dynamic-range
    // compression via KSOptions' FFmpeg audio filters, so quiet
    // dialogue stays clear at low volume. It takes effect from
    // the next stream start (KSOptions are consumed at load) and
    // only on the FFmpeg decode path — the footer says both.

    @State private var nightAudioEnabled = NightAudioMode.isEnabled

    private var nightAudioSection: some View {
        Section {
            Toggle(isOn: $nightAudioEnabled) {
                Text(L("nightmode.title"))
            }
            .onChange(of: nightAudioEnabled) { _, newValue in
                NightAudioMode.setEnabled(newValue)
            }
        } header: {
            Text(L("nightmode.section"))
        } footer: {
            Text(L("nightmode.footer"))
        }
    }

    private var audioDelaySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("player.audio_delay.label"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(audioDelayDisplay)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $audioDelaySeconds,
                    in: AudioDelayPersistence.range,
                    step: AudioDelayPersistence.step
                )
            }
            .padding(.vertical, 4)
        } header: {
            Text(L("player.audio_delay.section"))
        } footer: {
            Text(L("player.audio_delay.footer"))
        }
    }

    private var audioDelayDisplay: String {
        let ms = Int((audioDelaySeconds * 1000).rounded())
        if ms == 0 { return L("subtitle.no_delay") }
        return ms > 0 ? "+\(ms) ms" : "\(ms) ms"
    }

    private func copyStreamURL() {
        UIPasteboard.general.string = streamURL.absoluteString
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        didCopyURL = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { didCopyURL = false }
        }
    }

    @ViewBuilder
    private func trackSection(
        title: String,
        items: [TrackMenuOption],
        currentId: Int,
        emptyLabel: String,
        select: @escaping (Int) -> Void
    ) -> some View {
        Section(title) {
            if items.isEmpty {
                Text(emptyLabel)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    Button {
                        select(item.id)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                if let detail = item.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 8)
                            if item.id == currentId {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Sleep timer behind the sheet's Sleep Timer section. Shared instance, so an
/// armed timer keeps running after the sheet is dismissed; when it fires it
/// pauses the player it was armed from (the controller is held weakly — if
/// that player goes away first, the timer simply cancels itself).
@MainActor
final class PlaybackSleepTimer: ObservableObject {
    static let shared = PlaybackSleepTimer()

    enum Mode: Equatable {
        case off
        case minutes(Int)
        case endOfEpisode
    }

    @Published private(set) var mode: Mode = .off
    /// Countdown for `.minutes` mode, shown in the sheet footer; nil otherwise.
    @Published private(set) var remainingSeconds: Int?

    private weak var player: VideoPlayerController?
    private var tickTask: Task<Void, Never>?
    /// Set once the armed item reaches `.ended`: the player's auto-advance
    /// starts the next episode a few seconds later, and that start is what
    /// this timer exists to stop.
    private var endedWatchDeadline: Date?

    private init() {}

    func arm(minutes: Int, player: VideoPlayerController) {
        self.player = player
        mode = .minutes(minutes)
        remainingSeconds = minutes * 60
        endedWatchDeadline = nil
        startTicking()
    }

    func armEndOfEpisode(player: VideoPlayerController) {
        self.player = player
        mode = .endOfEpisode
        remainingSeconds = nil
        endedWatchDeadline = nil
        startTicking()
    }

    func cancel() {
        mode = .off
        remainingSeconds = nil
        endedWatchDeadline = nil
        tickTask?.cancel()
        tickTask = nil
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let player else { cancel(); return }
        switch mode {
        case .off:
            cancel()
        case .minutes:
            guard let remaining = remainingSeconds else { cancel(); return }
            if remaining <= 1 {
                pausePlayback()
                cancel()
            } else {
                remainingSeconds = remaining - 1
            }
        case .endOfEpisode:
            tickEndOfEpisode(player)
        }
    }

    private func tickEndOfEpisode(_ player: VideoPlayerController) {
        if player.state == .ended, endedWatchDeadline == nil {
            endedWatchDeadline = Date().addingTimeInterval(10)
        }
        if let deadline = endedWatchDeadline {
            if player.isPlaying {
                // Auto-advance started the next episode inside the watch window.
                pausePlayback()
                cancel()
            } else if Date() > deadline {
                cancel()
            }
            return
        }
        // Pause just before the item's end, so the player's post-end
        // auto-advance countdown never starts.
        guard player.isPlaying, player.durationMs > 0 else { return }
        let remaining = Double(player.durationMs - player.timeMs) / 1000
        if remaining <= 1.5 {
            pausePlayback()
            cancel()
        }
    }

    private func pausePlayback() {
        guard let player, player.isPlaying else { return }
        player.togglePlayPause()
    }
}
