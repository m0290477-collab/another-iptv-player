import SwiftUI

/// Build 61 (B8, C8): channel quick preview — presented from the
/// channel card/row long-press menu. Shows the channel, its NOW and
/// NEXT programmes from the already-loaded EPG snapshot (no fetch —
/// absent EPG simply omits the programme lines), and a Play button.
///
/// Play uses the EXISTING player path only: the full Xtream live
/// queue via `LiveChannelCategorySection.xtreamLiveQueue()` into
/// `LivePlayerShell`, exactly as `EPGProgrammeDetailSheet.playLiveChannel`
/// does. No player file is touched.
struct ChannelQuickPreviewSheet: View {
    let playlist: Playlist
    let stream: DBLiveStream

    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @Environment(\.epgSnapshot) private var epgSnapshot
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var audioOnlyStore = AudioOnlyStore.shared

    private var nowNext: EPGNowNext? {
        epgSnapshot?[EPGChannelKey.forXtream(stream)]
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    CachedImage(
                        url: stream.streamIcon.flatMap { URL(string: $0) },
                        width: 56, height: 56,
                        cornerRadius: AppTheme.smallCornerRadius,
                        iconName: "tv"
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stream.name)
                            .font(.headline)
                            .lineLimit(2)
                        if let number = stream.channelNumber {
                            Text(L("channels.number_format", number))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if audioOnlyStore.isEnabled(playlistId: playlist.id, streamId: stream.streamId) {
                            Label(L("audioonly.badge"), systemImage: "waveform")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let now = nowNext?.now {
                    programmeLine(label: L("channels.preview.now"), programme: now)
                }
                if let next = nowNext?.next {
                    programmeLine(label: L("channels.preview.next"), programme: next)
                }

                Button {
                    dismiss()
                    play()
                } label: {
                    Label(L("channels.preview.play"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle(L("channels.preview.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.close")) { dismiss() }
                }
            }
        }
    }

    private func programmeLine(label: String, programme: EPGProgramme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.accent)
            Text(programme.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Text(EPGTimeFormat.range(programme.start, programme.stop))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func play() {
        FirstSeenStore.shared.markOpened(playlistId: playlist.id, itemKey: "live:\(stream.streamId)")
        let live = LiveChannelCategorySection.xtreamLiveQueue()
        playerOverlay.present(playlistId: playlist.id) {
            LivePlayerShell(
                playlist: playlist,
                queue: live.queue,
                sections: live.sections,
                initialStream: stream,
                initialHistory: nil,
                subtitle: nil
            )
        }
    }
}
