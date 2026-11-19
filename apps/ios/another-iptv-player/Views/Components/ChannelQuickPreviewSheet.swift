import SwiftUI

/// Build 61 (B8, C8): channel quick preview — presented from the
/// channel card/row long-press menu. Shows the channel and a Play
/// button. (Build 68: the NOW/NEXT programme lines went with the
/// TV Guide removal — the app is a player, it has no guide.)
///
/// Play uses the EXISTING player path only: the full Xtream live
/// queue via `LiveChannelCategorySection.xtreamLiveQueue()` into
/// `LivePlayerShell`. No player file is touched.
struct ChannelQuickPreviewSheet: View {
    let playlist: Playlist
    let stream: DBLiveStream

    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @Environment(\.dismiss) private var dismiss

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
                            Text(L("channels.number_format", String(number)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
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
