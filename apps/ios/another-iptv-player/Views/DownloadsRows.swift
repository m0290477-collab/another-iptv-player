import SwiftUI

/// Build 61 fix round 3: DownloadsView's row builders as
/// standalone structs (part of the DownloadsView decomposition —
/// see DownloadsSections.swift). Bodies are the former
/// @ViewBuilder helper functions' contents, unchanged; the row's
/// primary action arrives as an explicit closure property.

/// Tek tap = birincil aksiyon (tekrar dene/oynat),
/// trailing swipe = delete/cancel. This pattern is applied to all download statuses.
struct DownloadActionableRow: View {
    let item: DBDownloadedItem
    @ObservedObject var manager: DownloadManager
    let justCompletedIDs: Set<String>
    let onPrimaryAction: (DBDownloadedItem) -> Void

    var body: some View {
        Button {
            onPrimaryAction(item)
        } label: {
            DownloadRowContent(item: item, manager: manager, justCompletedIDs: justCompletedIDs)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            switch item.downloadStatus {
            case .downloading, .queued:
                Button(role: .destructive) {
                    manager.cancel(id: item.id)
                } label: {
                    Label(L("download.cancel"), systemImage: "xmark")
                }
            case .completed, .failed:
                Button(role: .destructive) {
                    Task { await manager.delete(id: item.id) }
                } label: {
                    Label(L("download.delete"), systemImage: "trash")
                }
            }
        }
        // B2 (build 61, item 10): open the stream in an external
        // player from a completed row (the remote URL — external
        // players cannot read the app sandbox).
        .contextMenu {
            if item.downloadStatus == .completed, let url = URL(string: item.remoteURL) {
                ExternalPlayerMenuItems(streamURL: url)
            }
        }
    }
}

/// B2 (build 61, item 2): an in-progress recording row — elapsed
/// time + size so far (driven by `LiveRecordingService.now`,
/// which ticks once a second while recording) and the two real
/// controls: Stop (keep the file) and Cancel (discard it). Not
/// wrapped in the row Button — the controls are the actions.
struct DownloadRecordingRow: View {
    let item: DBDownloadedItem
    @ObservedObject var recorder: LiveRecordingService

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(
                url: item.imageURL.flatMap { URL(string: $0) },
                width: 56, height: 56,
                iconName: "record.circle",
                loadProfile: .grid
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let active = recorder.active[item.id] {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text(L("record.status_format",
                               Self.elapsedText(since: active.startedAt, now: recorder.now),
                               ByteCountFormatter.string(fromByteCount: active.bytesWritten, countStyle: .file)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Text(L("record.recording"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                recorder.stop(id: item.id)
            } label: {
                Label(L("record.stop"), systemImage: "stop.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(role: .destructive) {
                recorder.cancel(id: item.id)
            } label: {
                Label(L("common.cancel"), systemImage: "xmark.circle")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    /// mm:ss (or h:mm:ss) elapsed formatting for a recording.
    private static func elapsedText(since start: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct DownloadRowContent: View {
    let item: DBDownloadedItem
    @ObservedObject var manager: DownloadManager
    let justCompletedIDs: Set<String>

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(
                url: item.imageURL.flatMap { URL(string: $0) },
                width: 56, height: 56,
                iconName: item.type == "episode" ? "play.tv" : (item.type == "recording" ? "record.circle" : "film"),
                loadProfile: .grid
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let sub = item.secondaryTitle, !sub.isEmpty {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                footer(for: item)
            }
            Spacer()
            primaryActionIcon(for: item)
        }
        .padding(.vertical, 2)
    }

    /// Visually signals the row's primary action (not tappable — the whole row is the button).
    @ViewBuilder
    private func primaryActionIcon(for item: DBDownloadedItem) -> some View {
        switch item.downloadStatus {
        case .downloading:
            ProgressView()
                .controlSize(.small)
        case .queued:
            Image(systemName: "clock")
                .font(.title2)
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.orange)
        case .completed:
            // X7 (fixer): a download that just transitioned to
            // completed shows the shared drawn check (the same
            // component as the playlist-add success) for a beat,
            // then settles back to the play affordance.
            if justCompletedIDs.contains(item.id) {
                AnimatedCheckView(size: 26)
            } else {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.accent)
            }
        }
    }

    @ViewBuilder
    private func footer(for item: DBDownloadedItem) -> some View {
        switch item.downloadStatus {
        case .downloading:
            let p = manager.progress[item.id]
            let fraction = p?.fraction ?? 0
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text(L("download.downloading_format", Int(fraction * 100)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let p, p.totalBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: p.totalBytes, countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .queued:
            Text(L("download.status.queued"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .completed:
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.totalBytes), countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed:
            Text(item.errorMessage ?? L("common.unknown_error"))
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
