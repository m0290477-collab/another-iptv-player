import SwiftUI

// Build 61 fix round: the List content is split into three
// @ViewBuilder groups — the single ~130-line List builder timed
// out the compiler's type checker. Same sections, same order.
/// Build 61 fix round 3: those three groups are now standalone
/// structs in this file — DownloadsView's own file kept stalling
/// the type checker even after the in-file splits (247 → 370/699
/// → 806). Every input arrives as an explicit stored property;
/// the section bodies are the former @ViewBuilder properties'
/// contents, unchanged.

struct DownloadsHeaderSections: View {
    @ObservedObject var manager: DownloadManager
    @Binding var storageCapGB: Int
    let totalDownloadsBytes: Int64
    let watchedDownloads: [DBDownloadedItem]
    @Binding var showDeleteWatchedAlert: Bool
    let inProgress: [DBDownloadedItem]
    let queued: [DBDownloadedItem]

    @ViewBuilder
    var body: some View {
        // B2 (build 61, T4): Wi-Fi-only pause state +
        // storage cap. The Wi-Fi-only TOGGLE itself
        // stays in Settings (O6 single-instance) — this
        // is the visible STATE of the pause, plus the
        // cap picker whose only home is here.
        if manager.isWaitingForWifi {
            Section {
                Label(L("download.wifi_waiting"), systemImage: "wifi.slash")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
        Section {
            Picker(L("downloadcap.title"), selection: $storageCapGB) {
                ForEach([2, 5, 10, 20], id: \.self) { gb in
                    Text("\(gb) GB").tag(gb)
                }
            }
            HStack {
                Text(L("downloadcap.used"))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: StorageService.downloadsSizeBytes(), countStyle: .file))
                    .foregroundStyle(.secondary)
            }
        }

        // Round 14 (B3): total size + delete-watched.
        Section {
            HStack {
                Text(L("download.storage_used"))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: totalDownloadsBytes, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            if !watchedDownloads.isEmpty {
                Button(role: .destructive) {
                    showDeleteWatchedAlert = true
                } label: {
                    Text(L("download.delete_watched"))
                }
            }
        }

        // B2 (build 61, Z9): queue controls — Pause All
        // suspends the active transfers in place and
        // blocks the queue; Resume All restarts them in
        // queue order. Shown only when there is something
        // to pause or resume.
        if !inProgress.isEmpty || !queued.isEmpty {
            Section(L("queue.title")) {
                if manager.queuePaused {
                    Label(L("queue.paused"), systemImage: "pause.circle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Button {
                        manager.resumeAll()
                    } label: {
                        Label(L("queue.resume_all"), systemImage: "play.fill")
                    }
                } else {
                    Button {
                        manager.pauseAll()
                    } label: {
                        Label(L("queue.pause_all"), systemImage: "pause.fill")
                    }
                }
            }
        }
    }
}

struct DownloadsTransferSections: View {
    let inProgress: [DBDownloadedItem]
    let queued: [DBDownloadedItem]
    let failed: [DBDownloadedItem]
    @ObservedObject var manager: DownloadManager
    @ObservedObject var recorder: LiveRecordingService
    let justCompletedIDs: Set<String>
    let onPrimaryAction: (DBDownloadedItem) -> Void

    @ViewBuilder
    var body: some View {
        if !inProgress.isEmpty {
            Section(L("download.status.downloading")) {
                ForEach(inProgress) { item in
                    if item.type == "recording" {
                        DownloadRecordingRow(item: item, recorder: recorder)
                    } else {
                        DownloadActionableRow(item: item, manager: manager, justCompletedIDs: justCompletedIDs, onPrimaryAction: onPrimaryAction)
                    }
                }
            }
        }
        if !queued.isEmpty {
            Section(L("download.status.queued")) {
                ForEach(queued) { item in
                    DownloadActionableRow(item: item, manager: manager, justCompletedIDs: justCompletedIDs, onPrimaryAction: onPrimaryAction)
                }
                // Z9: drag-to-reprioritize (in Edit
                // mode). The new order is written back
                // as the rows' queue order — the exact
                // order DownloadManager's pump consumes.
                .onMove { offsets, destination in
                    var reordered = queued
                    reordered.move(fromOffsets: offsets, toOffset: destination)
                    let ids = reordered.map(\.id)
                    Task { await manager.reprioritize(orderedIds: ids) }
                }
            }
        }
        if !failed.isEmpty {
            Section(L("download.status.failed")) {
                ForEach(failed) { item in
                    DownloadActionableRow(item: item, manager: manager, justCompletedIDs: justCompletedIDs, onPrimaryAction: onPrimaryAction)
                }
            }
        }
    }
}

struct DownloadsCompletedSections: View {
    let completedMovies: [DBDownloadedItem]
    let completedRecordings: [DBDownloadedItem]
    let completedEpisodeGroups: [(title: String, episodes: [DBDownloadedItem])]
    @ObservedObject var manager: DownloadManager
    let justCompletedIDs: Set<String>
    let onPrimaryAction: (DBDownloadedItem) -> Void

    @ViewBuilder
    var body: some View {
        if !completedMovies.isEmpty {
            Section(L("dashboard.movies")) {
                ForEach(completedMovies) { item in
                    DownloadActionableRow(item: item, manager: manager, justCompletedIDs: justCompletedIDs, onPrimaryAction: onPrimaryAction)
                }
            }
        }
        if !completedRecordings.isEmpty {
            Section(L("record.title")) {
                ForEach(completedRecordings) { item in
                    DownloadActionableRow(item: item, manager: manager, justCompletedIDs: justCompletedIDs, onPrimaryAction: onPrimaryAction)
                }
            }
        }

        ForEach(completedEpisodeGroups, id: \.title) { group in
            Section(group.title) {
                ForEach(group.episodes) { item in
                    DownloadActionableRow(item: item, manager: manager, justCompletedIDs: justCompletedIDs, onPrimaryAction: onPrimaryAction)
                }
            }
        }
    }
}
