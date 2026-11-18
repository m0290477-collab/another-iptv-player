import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PlaybackTrackSettingsSheet: View {
    /// Round 8: the player's Audio / Subtitles quick-action buttons
    /// deep-link into this sheet — `.audio` / `.subtitle` open it
    /// already scrolled to that section. The gear button keeps `.all`
    /// (opens at the top, exactly as before).
    enum SectionFocus {
        case all
        case audio
        case subtitle
    }

    @ObservedObject var player: VideoPlayerController
    let streamURL: URL
    var focus: SectionFocus = .all
    /// Round 12 (point 2): the panel's close action, injected by the
    /// player (the panel is an in-player overlay now, not a sheet).
    /// Falls back to the environment dismiss when not provided.
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var didCopyURL = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var showSubtitleImporter = false
    @State private var showSubtitleImportError = false
    @State private var audioDelaySeconds = AudioDelayPersistence.load()

    private static let subtitleContentTypes: [UTType] =
        ["srt", "ass", "ssa", "vtt", "sub", "smi"].compactMap { UTType(filenameExtension: $0) }

    /// Round 8: ScrollViewReader anchors for the focus deep-links.
    private static let audioAnchor = "tracks.audio"
    private static let subtitleAnchor = "tracks.subtitle"

    /// Round 12 (point 2): header replicating the old sheet chrome
    /// (leading Close, centered title) without a navigation stack —
    /// the panel floats over the video, so it carries its own bar.
    private var panelHeader: some View {
        ZStack {
            Text(L("player.tracks.title"))
                .font(.headline)
            HStack {
                Button(L("common.close")) { closePanel() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func closePanel() {
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            ScrollViewReader { proxy in
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
                .id(Self.audioAnchor)
                audioDelaySection
                trackSection(
                    title: L("player.tracks.subtitle"),
                    items: player.subtitleTracks,
                    currentId: player.currentSubtitleTrackId,
                    emptyLabel: L("player.tracks.empty.subtitle"),
                    select: { player.selectSubtitleTrack(id: $0) }
                )
                .id(Self.subtitleAnchor)
                if !player.isLiveStream {
                    importedSubtitlesSection
                }
                // Round 14 (B1): the Debug row is REMOVED from this
                // panel. Round 16 (R6): the dead debug overlay in
                // PlayerView is removed too — its toggle died with
                // that row. Round 15 (C3): in its
                // place, a Stats section with REAL engine values —
                // each row renders only when the engine actually
                // reports that value, and the whole section hides
                // when nothing is available (no fake/placeholder
                // numbers anywhere).
                statsSection
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
                                .foregroundStyle(didCopyURL ? AppTheme.accent : .secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(
                        didCopyURL ? L("player.stream_url.copied") : L("player.stream_url.copy")
                    )
                }
            }
            // Round 12 (point 2): the panel behind is translucent —
            // hide the List's own opaque background (rows keep
            // theirs) and pin the style the sheet used to get from
            // its presentation context.
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .onAppear {
                // Round 8: deep-link scroll for the player's Audio /
                // Subtitles quick actions. A short delay lets the List
                // lay out its sections before the jump.
                let anchor: String?
                switch focus {
                case .all: anchor = nil
                case .audio: anchor = Self.audioAnchor
                case .subtitle: anchor = Self.subtitleAnchor
                }
                if let anchor {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation { proxy.scrollTo(anchor, anchor: .top) }
                    }
                }
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

    /// Round 15 (C3): live playback stats from the controller's
    /// engine diagnostics (`KSPlayerEngine` via
    /// `VideoPlayerController`). Every row is conditional on a
    /// real, non-empty value; the section itself disappears when
    /// the engine has reported nothing yet.
    @ViewBuilder
    private var statsSection: some View {
        let hasResolution = player.videoWidth > 0 && player.videoHeight > 0
        let hasBitrate = player.videoBitrate > 0
        let hasBuffer = player.cacheAheadSeconds > 0
        if hasResolution || hasBitrate || hasBuffer {
            Section(L("player.stats.title")) {
                if hasResolution {
                    statsRow(label: L("player.stats.resolution"),
                             value: "\(player.videoWidth)×\(player.videoHeight)")
                }
                if hasBitrate {
                    statsRow(label: L("player.stats.bitrate"),
                             value: Self.formatBitrate(player.videoBitrate))
                }
                if hasBuffer {
                    statsRow(label: L("player.stats.buffer"),
                             value: String(format: "%.0f s", player.cacheAheadSeconds))
                }
            }
        }
    }

    private func statsRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private static func formatBitrate(_ bps: Double) -> String {
        let mbps = bps / 1_000_000
        if mbps >= 1 { return String(format: "%.2f Mbps", mbps) }
        return String(format: "%.0f kbps", bps / 1_000)
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
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                    }
                }
            }
        }
    }
}
