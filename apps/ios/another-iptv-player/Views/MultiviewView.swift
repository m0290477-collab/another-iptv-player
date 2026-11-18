import SwiftUI
import UIKit

/// B5 (build 61), Item 11 — Multiview.
///
/// Up to four independent live panes on one screen. Each pane owns a
/// `KSPlayerEngine` (the same engine the main player uses) and renders
/// it through a surface host that mirrors the app's own
/// `KSPlayerVideoSurfaceHost` attach pattern (the hero preview in
/// HomeComponents uses the identical pattern for its secondary
/// surface). Panes coexist as separate engine instances; nothing is
/// shared between them except the catalog they pick from.
///
/// Audio focus: exactly one pane is focused. The focused pane plays
/// at full volume (`engine.setVolume(100)` — the engine's own volume
/// control, the same call `VideoPlayerController.setVolume` makes);
/// every other pane is muted with `engine.setVolume(0)`. Tapping a
/// pane moves the focus. Channel picking is per pane, from the loaded
/// live categories/channels of the active playlist
/// (`PlaylistContentStore`), and playback URLs are built with the
/// same `PlaybackURLBuilder.liveURL` the Live tab uses.
///
/// Limits (honest): panes are Xtream live channels from
/// LiveStreamsView's catalog (the entry point lives there); playback
/// is foreground-only, and a pane whose stream fails shows the
/// engine's failure state as an empty pane with a re-pick action —
/// panes fail independently and never take the others down.
struct MultiviewView: View {
    let playlist: Playlist

    @ObservedObject private var contentStore = PlaylistContentStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var panes: [MultiviewPane] = [
        MultiviewPane(), MultiviewPane(), MultiviewPane(), MultiviewPane(),
    ]
    @State private var paneCount = 2
    @State private var focusedIndex = 0
    @State private var pickerPaneIndex: Int?

    private var visiblePanes: ArraySlice<MultiviewPane> {
        panes.prefix(paneCount)
    }

    var body: some View {
        NavigationStack {
            Group {
                if contentStore.liveCategories.isEmpty {
                    emptyState
                } else {
                    paneGrid
                }
            }
            .background(Color.black)
            .navigationTitle(L("multiview.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel(L("common.close"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        togglePaneCount()
                    } label: {
                        Image(systemName: paneCount == 2
                            ? "rectangle.grid.2x2"
                            : "rectangle.split.2x1")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel(L(paneCount == 2
                        ? "multiview.four_panes"
                        : "multiview.two_panes"))
                }
            }
            .sheet(item: pickerBinding) { target in
                MultiviewChannelPicker(
                    playlist: playlist,
                    categories: contentStore.liveCategories,
                    streamsByCategoryId: contentStore.liveStreamsByCategoryId
                ) { stream in
                    select(stream, forPaneAt: target.index)
                }
            }
            // Build 61 (B9, P1): channel pre-warming stands down
            // while Multiview is on screen — the panes' own
            // engines own the network here.
            .onAppear {
                PlaybackPrewarmService.shared.multiviewActive = true
            }
            .onDisappear {
                PlaybackPrewarmService.shared.multiviewActive = false
                for pane in panes { pane.stop() }
            }
        }
    }

    // MARK: - Layout

    private var paneGrid: some View {
        VStack(spacing: 2) {
            if paneCount == 2 {
                paneView(at: 0)
                paneView(at: 1)
            } else {
                HStack(spacing: 2) {
                    paneView(at: 0)
                    paneView(at: 1)
                }
                HStack(spacing: 2) {
                    paneView(at: 2)
                    paneView(at: 3)
                }
            }
        }
    }

    private func paneView(at index: Int) -> some View {
        MultiviewPaneView(
            pane: panes[index],
            isFocused: focusedIndex == index,
            onTap: { focus(index) },
            onPickChannel: { pickerPaneIndex = index }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
            Text(L("multiview.no_channels"))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func togglePaneCount() {
        if paneCount == 2 {
            paneCount = 4
        } else {
            // Panes beyond the visible two stop, so shrinking back to
            // two never leaves hidden streams consuming connections.
            panes[2].stop()
            panes[3].stop()
            paneCount = 2
            if focusedIndex > 1 { focus(1) }
        }
    }

    private func focus(_ index: Int) {
        focusedIndex = index
        for (offset, pane) in visiblePanes.enumerated() {
            pane.applyAudioFocus(offset == index)
        }
    }

    private func select(_ stream: DBLiveStream, forPaneAt index: Int) {
        pickerPaneIndex = nil
        guard let url = PlaybackURLBuilder(playlist: playlist)
            .liveURL(streamId: stream.streamId)
        else { return }
        // Build 61 (FA, G2): pass the playlist's trimmed User-Agent
        // to the pane load — the same fix B7 applied to the hero
        // call sites; panes previously loaded with no UA at all.
        panes[index].play(stream: stream, url: url, userAgent: playlist.trimmedUserAgent)
        // Selecting a channel focuses its pane — the user just chose
        // what to watch and hear.
        focus(index)
    }

    private var pickerBinding: Binding<MultiviewPickerTarget?> {
        Binding(
            get: { pickerPaneIndex.map(MultiviewPickerTarget.init) },
            set: { pickerPaneIndex = $0?.index }
        )
    }
}

private struct MultiviewPickerTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - Pane controller

/// One multiview pane: its own engine + the channel it plays.
/// (Plain ObservableObject like the hero preview's controller —
/// all calls into it come from the main-actor SwiftUI layer.)
final class MultiviewPane: ObservableObject {
    let engine = KSPlayerEngine()

    @Published private(set) var stream: DBLiveStream?
    private var isFocused = false

    func play(stream: DBLiveStream, url: URL, userAgent: String?) {
        self.stream = stream
        engine.load(
            url,
            play: true,
            startSeconds: nil,
            liveLowLatency: true,
            userAgent: userAgent
        )
        applyAudioFocus(isFocused)
    }

    /// The engine's existing volume control is the mute switch:
    /// focused pane at full volume, every other pane at zero (the
    /// same `setVolume(0)` the hero preview uses to stay silent).
    func applyAudioFocus(_ focused: Bool) {
        isFocused = focused
        engine.setVolume(focused ? 100 : 0)
    }

    func stop() {
        stream = nil
        engine.stopPlayback()
    }

    deinit {
        engine.dispose()
    }
}

// MARK: - Pane view

private struct MultiviewPaneView: View {
    @ObservedObject var pane: MultiviewPane
    let isFocused: Bool
    let onTap: () -> Void
    let onPickChannel: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if pane.stream != nil {
                MultiviewSurface(engine: pane.engine)
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: onPickChannel) {
                        Image(systemName: "list.bullet")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel(L("multiview.select_channel"))
                }
                Spacer()
                if let stream = pane.stream {
                    HStack(spacing: 6) {
                        if isFocused {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                        }
                        Text(stream.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.65)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            if pane.stream == nil {
                Button(action: onPickChannel) {
                    VStack(spacing: 8) {
                        Image(systemName: "plus.rectangle.on.rectangle")
                            .font(.title3)
                        Text(L("multiview.select_channel"))
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                }
                .accessibilityLabel(L("multiview.select_channel"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .overlay {
            if isFocused {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .clipped()
    }
}

// MARK: - Surface host (mirrors KSPlayerVideoSurfaceHost's attach pattern)

private struct MultiviewSurface: View {
    @ObservedObject var engine: KSPlayerEngine

    var body: some View {
        MultiviewSurfaceHost(engine: engine, surfaceRevision: engine.surfaceRevision)
    }
}

private struct MultiviewSurfaceHost: UIViewRepresentable {
    let engine: KSPlayerEngine
    /// Passed as a parameter so a change re-runs `updateUIView` (the
    /// engine swaps its video view on fallback).
    let surfaceRevision: Int

    func makeUIView(context: Context) -> MultiviewContainerView {
        let view = MultiviewContainerView()
        view.attach(engine.videoView)
        return view
    }

    func updateUIView(_ uiView: MultiviewContainerView, context: Context) {
        uiView.attach(engine.videoView)
    }
}

private final class MultiviewContainerView: UIView {
    private weak var hostedView: UIView?

    func attach(_ videoView: UIView?) {
        guard let videoView else { return }
        if hostedView === videoView, videoView.superview === self { return }
        hostedView?.removeFromSuperview()
        hostedView = videoView
        videoView.isUserInteractionEnabled = false
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

// MARK: - Channel picker

/// Per-pane channel picker over the loaded live catalog: categories
/// as sections, channels as rows (same data the Live tab shelves).
private struct MultiviewChannelPicker: View {
    let playlist: Playlist
    let categories: [DBCategory]
    let streamsByCategoryId: [String: [LiveStreamWithCategory]]
    let onSelect: (DBLiveStream) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(categories, id: \.id) { category in
                    let channels = filteredChannels(for: category)
                    if !channels.isEmpty {
                        Section(category.name) {
                            ForEach(channels, id: \.stream.streamId) { item in
                                Button {
                                    onSelect(item.stream)
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(item.stream.name)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "play.circle")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("multiview.select_channel"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: Text(L("multiview.search_channels")))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel(L("common.close"))
                }
            }
        }
    }

    private func filteredChannels(for category: DBCategory) -> [LiveStreamWithCategory] {
        let all = streamsByCategoryId[category.id] ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.stream.name.localizedCaseInsensitiveContains(query)
        }
    }
}
