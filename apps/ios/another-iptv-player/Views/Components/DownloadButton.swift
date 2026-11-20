import SwiftUI
import Combine
import GRDB
import GRDBQuery

/// The 4-state download button shown on content detail screens.
/// The states are derived from the DB + DownloadManager progress; as items drop/arrive
/// diye view'da state tutmaya gerek yok.
struct DownloadButton: View {
    /// Produce it with `DownloadManager.idFor(vod:streamId:)` or `.idFor(episode:episodeId:)`.
    let id: String
    let playlistId: UUID
    let streamId: String
    let type: String // "vod" veya "episode"
    let title: String
    let secondaryTitle: String?
    let imageURL: String?
    let remoteURL: URL
    let containerExtension: String?
    var seriesId: String? = nil
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil

    /// Compact variant — for narrow areas like series episode rows.
    var compact: Bool = false

    /// Build 78 (Style 1): glass-circle variant — the detail pages'
    /// round glass action trio. Presentation only: the state
    /// machine, primary action, alerts and context menu are the
    /// pill form's, unchanged.
    var glassCircle: Bool = false

    @ObservedObject private var manager = DownloadManager.shared
    @Query<DownloadedItemByIDRequest> private var item: DBDownloadedItem?
    /// Round 8 (F-3): the primary tap in the downloading/queued and
    /// completed states used to be a dead `break` (cancel/delete hid in
    /// the context menu only). The tap now asks first — these two flags
    /// drive the confirmation dialogs on `body`.
    @SwiftUI.State private var showCancelConfirm = false
    @SwiftUI.State private var showDeleteConfirm = false

    init(
        id: String,
        playlistId: UUID,
        streamId: String,
        type: String,
        title: String,
        secondaryTitle: String?,
        imageURL: String?,
        remoteURL: URL,
        containerExtension: String?,
        seriesId: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        compact: Bool = false,
        glassCircle: Bool = false
    ) {
        self.id = id
        self.playlistId = playlistId
        self.streamId = streamId
        self.type = type
        self.title = title
        self.secondaryTitle = secondaryTitle
        self.imageURL = imageURL
        self.remoteURL = remoteURL
        self.containerExtension = containerExtension
        self.seriesId = seriesId
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.compact = compact
        self.glassCircle = glassCircle
        _item = Query(DownloadedItemByIDRequest(id: id), in: \.appDatabase)
    }

    private var progress: DownloadProgress? { manager.progress[id] }

    private enum State { case idle, queued, downloading(Double), completed, failed }
    private var state: State {
        if let item = item {
            switch item.downloadStatus {
            case .completed: return .completed
            case .failed: return .failed
            case .queued: return .queued
            case .downloading:
                return .downloading(progress?.fraction ?? 0)
            }
        }
        return .idle
    }

    var body: some View {
        Button(action: primaryAction) {
            if glassCircle {
                glassLabelContent
            } else {
                labelContent
            }
        }
        .buttonStyle(.plain)
        // Round 15 (C1): dynamic accessibility label + value for
        // all five states — the label names the title + action,
        // the value states the progress and what a tap does.
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(accessibilityValueText)
        // Round 15 (C12): the download-complete UI sound, fired on
        // this button's own transition into the completed state
        // (detail screens); DownloadsView covers its own surface.
        .onChange(of: item?.downloadStatus) { _, newStatus in
            if newStatus == .completed {
                AppSound.play(.downloadComplete)
            }
        }
        .contextMenu { contextMenuItems }
        // Round 14 (A3): centered alerts replace the bottom-anchored
        // confirmation dialogs (owner's round-13 point 3).
        .alert(
            L("download.cancel.title"),
            isPresented: $showCancelConfirm
        ) {
            Button(L("download.cancel"), role: .destructive) {
                manager.cancel(id: id)
            }
            Button(L("download.keep"), role: .cancel) {}
        } message: {
            Text(L("download.cancel.message"))
        }
        .alert(
            L("download.delete.title"),
            isPresented: $showDeleteConfirm
        ) {
            Button(L("download.delete"), role: .destructive) {
                Task { await manager.delete(id: id) }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("download.delete.message"))
        }
    }

    // MARK: - Accessibility (round 15, C1)

    private var accessibilityLabelText: String {
        switch state {
        case .idle: return "\(title) — \(L("download.action"))"
        case .queued: return "\(title) — \(L("download.status.queued"))"
        case .downloading: return "\(title) — \(L("download.status.downloading"))"
        case .completed: return "\(title) — \(L("download.completed"))"
        case .failed: return "\(title) — \(L("download.retry"))"
        }
    }

    private var accessibilityValueText: String {
        switch state {
        case .idle:
            return L("download.a11y.tap_download")
        case .queued:
            return L("download.a11y.queued_value")
        case .downloading(let p):
            return L("download.a11y.downloading_value", Int((p * 100).rounded()))
        case .completed:
            return L("download.a11y.completed_value")
        case .failed:
            return L("download.a11y.failed_value")
        }
    }

    /// Build 78 (Style 1): the glass-circle label — icon-only, the
    /// same five states as the pill form (the downloading state
    /// keeps its real progress: ring + percent, through the same
    /// localized "%d%%" format the pill's text uses).
    @ViewBuilder
    private var glassLabelContent: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            switch state {
            case .idle:
                Image(systemName: "arrow.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
            case .queued:
                Image(systemName: "clock")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
            case .downloading(let p):
                VStack(spacing: 1) {
                    ProgressView(value: max(0, min(1, p)))
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                    Text(L("download.downloading_format", Int((p * 100).rounded())))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 56, height: 56)
    }

    @ViewBuilder
    private var labelContent: some View {
        switch state {
        case .idle:
            button(icon: "arrow.down.circle", title: L("download.action"))
        case .queued:
            button(icon: "clock", title: L("download.status.queued"))
        case .downloading(let p):
            downloadingLabel(progress: p)
        case .completed:
            button(icon: "checkmark.circle.fill", title: L("download.completed"), accent: .green)
        case .failed:
            button(icon: "exclamationmark.triangle.fill", title: L("download.retry"), accent: .orange)
        }
    }

    private func button(icon: String, title: String, accent: Color = .primary) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            Image(systemName: icon)
                .font(compact ? .footnote.weight(.semibold) : .footnote.weight(.semibold))
            if !compact {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(accent)
        .frame(maxWidth: compact ? nil : .infinity)
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, compact ? 6 : 11)
        .background(
            RoundedRectangle(cornerRadius: compact ? AppTheme.smallCornerRadius : AppTheme.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? AppTheme.smallCornerRadius : AppTheme.cornerRadius, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func downloadingLabel(progress: Double) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            ProgressView(value: max(0, min(1, progress)))
                .progressViewStyle(.circular)
                .controlSize(.mini)
            Text(L("download.downloading_format", Int(progress * 100)))
                .font(compact ? .caption2.weight(.semibold) : .footnote.weight(.semibold))
                .lineLimit(1)
                .monospacedDigit()
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: compact ? nil : .infinity)
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, compact ? 6 : 11)
        .background(
            RoundedRectangle(cornerRadius: compact ? AppTheme.smallCornerRadius : AppTheme.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        switch state {
        case .idle:
            Button { primaryAction() } label: {
                Label(L("download.action"), systemImage: "arrow.down.circle")
            }
        case .downloading, .queued:
            Button(role: .destructive) {
                manager.cancel(id: id)
            } label: {
                Label(L("download.cancel"), systemImage: "xmark")
            }
        case .completed:
            Button(role: .destructive) {
                Task { await manager.delete(id: id) }
            } label: {
                Label(L("download.delete"), systemImage: "trash")
            }
        case .failed:
            Button { primaryAction() } label: {
                Label(L("download.retry"), systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                Task { await manager.delete(id: id) }
            } label: {
                Label(L("download.delete"), systemImage: "trash")
            }
        }
        // B2 (build 61, item 10): open this title in an external
        // player — offered in every state; the URL is the stream's
        // remote URL regardless of download state.
        ExternalPlayerMenuItems(streamURL: remoteURL)
    }

    private func primaryAction() {
        switch state {
        case .idle, .failed:
            Task {
                await manager.enqueue(
                    id: id,
                    playlistId: playlistId,
                    streamId: streamId,
                    type: type,
                    title: title,
                    secondaryTitle: secondaryTitle,
                    imageURL: imageURL,
                    remoteURL: remoteURL,
                    containerExtension: containerExtension,
                    seriesId: seriesId,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber
                )
            }
        case .downloading, .queued:
            // Round 8 (F-3): was a dead `break` — the tap now opens the
            // cancel confirmation (the manager has no pause/resume; the
            // context menu keeps the same direct cancel).
            showCancelConfirm = true
        case .completed:
            // Round 8 (F-3): was a dead `break` — the tap now opens the
            // delete confirmation for the downloaded file.
            showDeleteConfirm = true
        }
    }
}

// MARK: - M3U context-menu items

/// The download item used in the M3U channel card's context menu.
/// Shows a single button by state: idle → "Download", downloading/queued → "Cancel",
/// completed/failed → "Delete". Because it is only evaluated when the contextMenu opens,
/// the per-card @Query cost is practically zero.
struct M3UDownloadMenuItems: View {
    let id: String
    let playlistId: UUID
    let streamId: String
    let title: String
    let secondaryTitle: String?
    let imageURL: String?
    let remoteURL: URL
    let containerExtension: String?

    @ObservedObject private var manager = DownloadManager.shared
    @Query<DownloadedItemByIDRequest> private var item: DBDownloadedItem?

    init(
        id: String,
        playlistId: UUID,
        streamId: String,
        title: String,
        secondaryTitle: String?,
        imageURL: String?,
        remoteURL: URL,
        containerExtension: String?
    ) {
        self.id = id
        self.playlistId = playlistId
        self.streamId = streamId
        self.title = title
        self.secondaryTitle = secondaryTitle
        self.imageURL = imageURL
        self.remoteURL = remoteURL
        self.containerExtension = containerExtension
        _item = Query(DownloadedItemByIDRequest(id: id), in: \.appDatabase)
    }

    var body: some View {
        if let item = item {
            switch item.downloadStatus {
            case .downloading, .queued:
                Button(role: .destructive) {
                    manager.cancel(id: id)
                } label: {
                    Label(L("download.cancel"), systemImage: "xmark")
                }
            case .completed, .failed:
                Button(role: .destructive) {
                    Task { await manager.delete(id: id) }
                } label: {
                    Label(L("download.delete"), systemImage: "trash")
                }
            }
        } else {
            Button {
                Task {
                    await manager.enqueue(
                        id: id,
                        playlistId: playlistId,
                        streamId: streamId,
                        type: "vod",
                        title: title,
                        secondaryTitle: secondaryTitle,
                        imageURL: imageURL,
                        remoteURL: remoteURL,
                        containerExtension: containerExtension
                    )
                }
            } label: {
                Label(L("download.action"), systemImage: "arrow.down.circle")
            }
        }
    }
}

// MARK: - DB Requests

struct DownloadedItemByIDRequest: Queryable, Equatable {
    static var defaultValue: DBDownloadedItem? { nil }
    let id: String
    func publisher(in appDatabase: AppDatabase) -> AnyPublisher<DBDownloadedItem?, Never> {
        ValueObservation
            .tracking { db in
                try DBDownloadedItem.filter(Column("id") == id).fetchOne(db)
            }
            .publisher(in: appDatabase.reader)
            .catch { _ in Just(nil) }
            .eraseToAnyPublisher()
    }
}

struct AllDownloadsRequest: Queryable, Equatable {
    static var defaultValue: [DBDownloadedItem] { [] }
    let playlistId: UUID
    func publisher(in appDatabase: AppDatabase) -> AnyPublisher<[DBDownloadedItem], Never> {
        ValueObservation
            .tracking { db in
                try DBDownloadedItem
                    .filter(Column("playlistId") == playlistId)
                    .order(Column("createdAt").desc)
                    .fetchAll(db)
            }
            .publisher(in: appDatabase.reader)
            .catch { _ in Just([]) }
            .eraseToAnyPublisher()
    }
}
