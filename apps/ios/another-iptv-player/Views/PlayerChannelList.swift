import SwiftUI

/// Build 88 (Part 2-A — the owner's Playra pick): the in-player
/// channel list. The CURRENT GROUP's channels as one sequential
/// list under the video: every row carries the channel's
/// POSITIONAL number in the group (the provider supplies no
/// channel numbers — Playra's numbers are positional too), its
/// logo and FULL name; the playing row is highlighted; the header's
/// up/down arrows jump to the previous/next channel in the list;
/// tapping a row selects that channel.
///
/// Standalone component: it owns no playback state. The host
/// passes the group's channels in display order, the playing
/// channel's `streamId`, and a selection callback.
///
/// INTEGRATION POINT (for the main agent): `LivePlayerShell.body`
/// in Views/LiveStreamsView.swift — the ZStack over `PlayerView`
/// where `LiveChannelSidePanel` is presented today
/// (`if showChannelSidePanel, !sections.isEmpty`). Feed it:
///   channels: the section of `sections` containing
///     `session.stream` (fallback: `queue`),
///   currentChannelId: `session.stream.streamId`,
///   onSelect: `{ stream in switchTo(stream: stream, resumeTimeMs: nil) }`
/// — `switchTo` is `LivePlayerShell`'s own private method, and the
/// toggle plumbing (`isLiveChannelSidePanelVisible` /
/// `onToggleLiveChannelSidePanel` into PlayerView) is already
/// wired, so no PlayerView.swift change is needed.
struct PlayerChannelList: View {
    let channels: [DBLiveStream]
    let currentChannelId: Int
    var onSelect: (DBLiveStream) -> Void

    private var currentIndex: Int? {
        channels.firstIndex(where: { $0.streamId == currentChannelId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(channels.enumerated()), id: \.element.streamId) { index, channel in
                            row(channel: channel, position: index + 1)
                                .id(channel.streamId)
                            if index < channels.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(height: 0.5)
                                    .padding(.leading, 92)
                            }
                        }
                    }
                }
                .frame(maxHeight: 288)
                .onAppear {
                    if let currentIndex {
                        proxy.scrollTo(channels[currentIndex].streamId, anchor: .center)
                    }
                }
                .onChange(of: currentChannelId) { _, _ in
                    if let currentIndex {
                        withAnimation(Motion.animate(Motion.liveSwap)) {
                            proxy.scrollTo(channels[currentIndex].streamId, anchor: .center)
                        }
                    }
                }
            }
        }
        // The player chrome treatment the existing side panel uses:
        // material + black scrim + hairline — the player is dark in
        // every scheme, so this panel is too.
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.55))
        .overlay(alignment: .top) {
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(Color.white.opacity(0.18))
        }
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L("player.channel_list.title"))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(L("home.count_channels", CatalogCountFormatter.string(channels.count)))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                if let currentIndex, currentIndex > 0 {
                    onSelect(channels[currentIndex - 1])
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled((currentIndex ?? 0) == 0)
            .opacity((currentIndex ?? 0) == 0 ? 0.35 : 1)
            .accessibilityLabel(L("player.a11y.previous_channel"))
            Button {
                if let currentIndex, currentIndex < channels.count - 1 {
                    onSelect(channels[currentIndex + 1])
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(currentIndex == nil || (currentIndex ?? 0) >= channels.count - 1)
            .opacity(currentIndex == nil || (currentIndex ?? 0) >= channels.count - 1 ? 0.35 : 1)
            .accessibilityLabel(L("player.a11y.next_channel"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func row(channel: DBLiveStream, position: Int) -> some View {
        let isCurrent = channel.streamId == currentChannelId
        return Button {
            onSelect(channel)
        } label: {
            HStack(spacing: 12) {
                Text(String(position))
                    .font(.callout.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? AppTheme.accent : .white.opacity(0.55))
                    .frame(width: 30, alignment: .trailing)
                CachedImage(
                    url: channel.streamIcon.flatMap { URL(string: $0) },
                    width: 62,
                    height: 38,
                    cornerRadius: AppTheme.smallCornerRadius,
                    iconName: "tv",
                    loadProfile: .shelf
                )
                Text(channel.name)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if isCurrent {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2.weight(.bold))
                        Text(L("channels.preview.now"))
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(AppTheme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isCurrent ? AppTheme.accent.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
