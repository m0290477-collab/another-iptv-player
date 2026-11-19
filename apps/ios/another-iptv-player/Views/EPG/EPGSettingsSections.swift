import SwiftUI
import GRDB

// MARK: - Shared refresh status row

/// Refresh-now button, last-updated timestamp, and error footer — shared by the
/// M3U and Xtream EPG settings sections.
struct EPGRefreshStatusView: View {
    let playlist: Playlist
    var canRefresh: Bool = true
    @ObservedObject private var epgStore = EPGStore.shared
    /// Build 67 (W8, F5): the guide error the refresh coordinator
    /// last recorded on the playlist's EPG source record. The
    /// background loads (post-add continuation, scheduled
    /// refreshes) do not pass through `EPGStore.refreshState`, so
    /// without this read their failures were recorded in the
    /// database but never shown anywhere — a guide that failed
    /// silently looked identical to one still loading.
    @State private var recordedError: String?

    init(playlist: Playlist, canRefresh: Bool = true) {
        self.playlist = playlist
        self.canRefresh = canRefresh
    }

    private var state: EPGRefreshState { epgStore.refreshState[playlist.id] ?? .idle }

    var body: some View {
        Group {
        Button {
            Task { await epgStore.forceRefresh(playlist: playlist) }
        } label: {
            HStack {
                Label(L("epg.refresh"), systemImage: "arrow.clockwise")
                Spacer()
                if state.isRefreshing { ProgressView() }
            }
        }
        .disabled(!canRefresh || state.isRefreshing)

        if let last = epgStore.lastSuccess[playlist.id] {
            HStack {
                Text(L("epg.last_updated"))
                Spacer()
                Text(last, style: .relative).foregroundColor(.secondary)
            }
        } else {
            HStack {
                Text(L("epg.last_updated"))
                Spacer()
                Text(L("epg.never_updated")).foregroundColor(.secondary)
            }
        }

        if case .failed(let message) = state {
            Text(message)
                .font(.footnote)
                .foregroundColor(.red)
        } else if let recordedError {
            // Build 67 (W8, F5): a background guide load failed —
            // show the recorded error here, where the Refresh
            // button above is the retry. Never a silent state.
            Text(recordedError)
                .font(.footnote)
                .foregroundColor(.red)
        }
        }
        .task { await loadRecordedError() }
        .onChange(of: state) { _, _ in
            Task { await loadRecordedError() }
        }
    }

    /// Loads (and re-loads, whenever this playlist's live refresh
    /// state settles) the coordinator-recorded guide error.
    private func loadRecordedError() async {
        recordedError = try? await AppDatabase.shared.read { db in
            try DBEPGSource.fetchOne(db, key: playlist.id)?.lastError
        } ?? nil
    }
}

// MARK: - M3U section (editable XMLTV URL)

/// The M3U EPG rows without a `Section` wrapper, so the settings
/// screens can embed them inside a larger group (round 6). (The
/// standalone Section wrapper was removed in round 16, R2.)
struct M3UEPGSettingsRows: View {
    @State private var playlist: Playlist
    @State private var epgURLDraft: String
    @State private var saveError: String?

    init(playlist: Playlist) {
        _playlist = State(initialValue: playlist)
        _epgURLDraft = State(initialValue: playlist.epgURLOverride ?? playlist.m3uEpgURL ?? "")
    }

    var body: some View {
        Group {
            TextField(L("epg.settings.url_placeholder"), text: $epgURLDraft, axis: .vertical)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...3)

            Button(L("epg.settings.save_url")) {
                Task { await saveURL() }
            }

            EPGRefreshStatusView(playlist: playlist, canRefresh: !effectiveURLEmpty)

            if let saveError {
                Text(saveError).font(.footnote).foregroundColor(.red)
            }
        }
    }

    private var effectiveURLEmpty: Bool {
        epgURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveURL() async {
        let trimmed = epgURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = playlist
        updated.epgURLOverride = trimmed.isEmpty ? nil : trimmed
        do {
            try await AppDatabase.shared.write { db in try updated.save(db) }
            saveError = nil
            playlist = updated
            if !trimmed.isEmpty {
                await EPGStore.shared.forceRefresh(playlist: updated)
            }
        } catch {
            saveError = L("misc.save_setting_error", error.localizedDescription)
        }
    }
}

// Round 16 (R2): the orphaned M3UEPGSettingsSection wrapper is removed —
// zero call sites; the settings screens embed the Rows
// variant directly (the live path, unchanged).

// MARK: - Xtream section (enable toggle + refresh)

/// The Xtream EPG rows without a `Section` wrapper, so the settings
/// screens can embed them inside a larger group (round 6). (The
/// standalone Section wrapper was removed in round 16, R2.)
struct XtreamEPGSettingsRows: View {
    let playlist: Playlist
    @State private var epgEnabled: Bool
    @State private var matchedChannels: Int?
    @ObservedObject private var epgStore = EPGStore.shared

    init(playlist: Playlist) {
        self.playlist = playlist
        _epgEnabled = State(initialValue: playlist.epgEnabled)
    }

    var body: some View {
        Group {
            Toggle(L("epg.settings.enable"), isOn: $epgEnabled)
                .onChange(of: epgEnabled) { _, newValue in
                    Task { await saveEnabled(newValue) }
                }

            if epgEnabled {
                EPGRefreshStatusView(playlist: playlist)
                if let matched = matchedChannels {
                    HStack {
                        Text(L("epg.settings.matched_channels"))
                        Spacer()
                        Text(L("epg.settings.matched_channels_format", matched)).foregroundColor(.secondary)
                    }
                }
            }
        }
        .task { await loadMatchedChannels() }
        .onChange(of: epgStore.refreshState[playlist.id]) { oldValue, newValue in
            if oldValue?.isRefreshing == true, newValue?.isRefreshing != true {
                Task { await loadMatchedChannels() }
            }
        }
    }

    private func loadMatchedChannels() async {
        matchedChannels = try? await AppDatabase.shared.read { db in
            try DBEPGSource.fetchOne(db, key: playlist.id)?.channelCount
        } ?? nil
    }

    private func saveEnabled(_ enabled: Bool) async {
        var updated = playlist
        updated.epgEnabled = enabled
        try? await AppDatabase.shared.write { db in try updated.save(db) }
        if enabled {
            await EPGStore.shared.refreshIfStale(playlist: updated)
        }
    }
}

// Round 16 (R2): the orphaned XtreamEPGSettingsSection wrapper is removed —
// zero call sites; the settings screens embed the Rows
// variant directly (the live path, unchanged).
