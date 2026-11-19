import SwiftUI
import GRDB
import GRDBQuery

// MARK: - My Playlists (round 10)
//
// The playlist manager the STRONG recording models: every saved
// playlist as a card (name, type badge, an "Active" badge on the
// current one), a per-playlist "…" menu (Activate / Edit / Delete),
// a refresh button for the active playlist's content, and a "+"
// button opening the add sheet whose save activates the new
// playlist. Reached from Settings ▸ Playlists in BOTH dashboards;
// it is the ONE playlist-management surface inside a dashboard (the
// gate remains the first-run surface).
//
// Round 15 (C13): per-playlist health dot from the last persisted
// verify/sync result; "Make default" + drag reorder (the order and
// the default persist in PlaylistLibraryStore; ContentView's
// auto-enter follows them); "Change server address" as a NAMED
// quick action (the existing edit flow — same record, so favorites,
// history and progress are preserved); and a dead-playlist recovery
// card when the active playlist's last check was refused.
// Build 66 (W2, item 2): QR generation for a saved playlist's
// get.php link is REMOVED (it printed the plain-text password into
// a shareable code) — the view, its link builder and its menu
// entry are gone.
struct MyPlaylistsView: View {
    let activePlaylistId: UUID
    let onActivate: (Playlist) -> Void
    /// Deleting the ACTIVE playlist leaves the dashboard without a
    /// playlist — the caller exits to the gate in that case.
    let onExitToGate: () -> Void

    @Query<PlaylistRequest> private var playlists: [Playlist]?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase

    @State private var playlistToEdit: Playlist?
    @State private var playlistToDelete: Playlist?
    @State private var showAddSheet = false
    @State private var isRefreshing = false
    @State private var refreshError: String?
    @State private var showRefreshError = false
    @State private var editMode: EditMode = .inactive
    /// Health values are UserDefaults-backed (not reactive), so the
    /// cards re-read them whenever this token changes.
    @State private var healthRefreshToken = 0

    init(activePlaylistId: UUID, onActivate: @escaping (Playlist) -> Void, onExitToGate: @escaping () -> Void) {
        self.activePlaylistId = activePlaylistId
        self.onActivate = onActivate
        self.onExitToGate = onExitToGate
        _playlists = Query(PlaylistRequest(), in: \.appDatabase)
    }

    private var activePlaylist: Playlist? {
        playlists?.first(where: { $0.id == activePlaylistId })
    }

    /// The library in the user's saved drag order (C13).
    private var displayedPlaylists: [Playlist] {
        PlaylistLibraryStore.sorted(playlists ?? [])
    }

    var body: some View {
        Group {
            if playlists != nil {
                List {
                    // C13: dead-playlist recovery card — shown when
                    // the active playlist's last verify/sync was
                    // refused. Every action is an existing path.
                    if let active = activePlaylist,
                       PlaylistHealthStore.health(for: active.id) == .refused {
                        recoveryCard(active)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(displayedPlaylists) { playlist in
                        playlistCard(playlist)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onMove(perform: movePlaylists)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                BrandedLoader()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(L("settings.my_playlists"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
                    .accessibilityLabel(L("playlists.reorder"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshActivePlaylist() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing || activePlaylist == nil)
                .accessibilityLabel(L("home.refresh.action"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L("playlists.empty.add_button"))
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddPlaylistSheetView { created in
                showAddSheet = false
                activate(created)
            }
        }
        .sheet(item: $playlistToEdit) { playlist in
            if playlist.kind == .m3u {
                AddM3UPlaylistView(editingPlaylist: playlist)
            } else {
                AddPlaylistView(editingPlaylist: playlist)
            }
        }
        .alert(L("playlists.delete.title"), isPresented: Binding(
            get: { playlistToDelete != nil },
            set: { if !$0 { playlistToDelete = nil } }
        )) {
            Button(L("common.delete"), role: .destructive) {
                if let target = playlistToDelete {
                    performDelete(target)
                }
                playlistToDelete = nil
            }
            Button(L("common.cancel"), role: .cancel) {
                playlistToDelete = nil
            }
        } message: {
            Text(L("playlists.delete.message"))
        }
        .alert(L("common.error"), isPresented: $showRefreshError) {
            Button(L("common.ok"), role: .cancel) { }
        } message: {
            Text(refreshError ?? L("common.unknown_error"))
        }
        .cinematicBackground()
    }

    // MARK: - Recovery card (C13)

    /// Retry / Switch playlist / Change server address / Add new —
    /// all existing paths, surfaced in one place after a refused
    /// check so a dead playlist is recoverable without hunting.
    private func recoveryCard(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(L("playlists.recovery.title"))
                    .font(.subheadline.weight(.bold))
            }
            Text(L("playlists.recovery.message"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                recoveryButton(title: L("common.try_again"), systemImage: "arrow.clockwise") {
                    Task { await refreshActivePlaylist() }
                }
                if let other = displayedPlaylists.first(where: { $0.id != playlist.id }) {
                    recoveryButton(title: L("playlists.recovery.switch"), systemImage: "arrow.left.arrow.right") {
                        activate(other)
                    }
                }
            }
            HStack(spacing: 8) {
                recoveryButton(title: L("playlists.change_server"), systemImage: "server.rack") {
                    playlistToEdit = playlist
                }
                recoveryButton(title: L("playlists.recovery.add_new"), systemImage: "plus") {
                    showAddSheet = true
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface)
        .cornerRadius(AppTheme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
        )
    }

    private func recoveryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Card

    private func playlistCard(_ playlist: Playlist) -> some View {
        let isActive = playlist.id == activePlaylistId
        let isDefault = PlaylistLibraryStore.defaultId == playlist.id
        let health = PlaylistHealthStore.health(for: playlist.id)
        _ = healthRefreshToken
        return HStack(spacing: 12) {
            SettingsIconTile(
                systemImage: playlist.kind == .m3u ? "list.bullet" : "tv",
                tint: AppTheme.accent, size: 44
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(playlist.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(playlist.kind == .m3u ? "M3U" : "Xtream")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.accent.opacity(0.15))
                        .foregroundColor(AppTheme.accent)
                        .cornerRadius(AppTheme.smallCornerRadius)
                    if isActive {
                        Text(L("playlists.active_badge"))
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.accent, in: Capsule())
                    }
                    if isDefault {
                        Text(L("playlists.default_badge"))
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.22), in: Capsule())
                    }
                    // C13: health dot from the last verify/sync.
                    Circle()
                        .fill(healthColor(health))
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(healthLabel(health))
                }
                Text(playlist.serverURL.isEmpty ? L("playlists.local_file") : playlist.serverURL)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if playlist.kind == .xtream, !playlist.username.isEmpty {
                    Text(playlist.username)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if !isActive {
                    Button {
                        activate(playlist)
                    } label: {
                        Label(L("playlists.activate"), systemImage: "checkmark.circle")
                    }
                }
                if !isDefault {
                    Button {
                        PlaylistLibraryStore.defaultId = playlist.id
                        healthRefreshToken += 1
                    } label: {
                        Label(L("playlists.make_default"), systemImage: "star")
                    }
                }
                // C13: NAMED quick action — opens the existing
                // edit flow for THIS record (favorites, history
                // and progress are keyed by its id and preserved).
                Button {
                    playlistToEdit = playlist
                } label: {
                    Label(L("playlists.change_server"), systemImage: "server.rack")
                }
                Button {
                    playlistToEdit = playlist
                } label: {
                    Label(L("common.edit"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    playlistToDelete = playlist
                } label: {
                    Label(L("common.delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(AppTheme.elevated))
            }
        }
        .padding(14)
        .background(AppTheme.surface)
        .cornerRadius(AppTheme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(isActive ? AppTheme.accent.opacity(0.45) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if editMode == .inactive, !isActive {
                activate(playlist)
            }
        }
    }

    private func healthColor(_ health: PlaylistHealth) -> Color {
        switch health {
        case .responds: return .green
        case .refused: return .red
        case .expired: return .orange
        case .unknown: return .gray.opacity(0.5)
        }
    }

    private func healthLabel(_ health: PlaylistHealth) -> String {
        switch health {
        case .responds: return L("playlists.health.responds")
        case .refused: return L("playlists.health.refused")
        case .expired: return L("playlists.health.expired")
        case .unknown: return L("playlists.health.unknown")
        }
    }

    // MARK: - Actions

    /// C13: drag reorder — persists the new library order.
    private func movePlaylists(from source: IndexSet, to destination: Int) {
        var ordered = displayedPlaylists
        ordered.move(fromOffsets: source, toOffset: destination)
        PlaylistLibraryStore.saveOrder(ordered)
    }

    /// Pop back to Settings first, then hand the switch to
    /// ContentView — the dashboard rebuilds under a settled stack.
    private func activate(_ playlist: Playlist) {
        dismiss()
        DispatchQueue.main.async {
            onActivate(playlist)
        }
    }

    /// Round 17 (R17-5): deletion runs through the ONE shared
    /// implementation (`AccountDataDeletion`) — the same path as
    /// Settings' Delete Account and the gate's saved-account
    /// removal, so the three can never drift apart. Deleting the
    /// active playlist exits to the gate afterwards.
    private func performDelete(_ target: Playlist) {
        let wasActive = target.id == activePlaylistId
        Task {
            await AccountDataDeletion.deletePlaylistData(target)
            if wasActive {
                await MainActor.run { onExitToGate() }
            }
        }
    }

    /// The refresh button re-syncs the ACTIVE playlist's content —
    /// the same pipelines the two Settings screens' refresh actions
    /// run (Xtream: full catalog re-sync; M3U URL: re-download and
    /// re-import; M3U local file: reload what is stored). Round 15
    /// (C13): the outcome also feeds the health dot, and a success
    /// plays the refresh UI sound (never in the player).
    private func refreshActivePlaylist() async {
        guard let active = activePlaylist, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            if active.kind == .m3u {
                if active.serverURL.isEmpty {
                    await M3UContentStore.shared.reloadIfActive(playlist: active)
                } else {
                    let content = try await M3UService().fetchRemote(urlString: active.serverURL, playlist: active)
                    let parsed = try await M3UParser.parseAsync(content)
                    try await M3UImporter.replace(
                        playlist: active,
                        channels: parsed.channels,
                        epgURL: parsed.epgURL
                    )
                    await M3UContentStore.shared.reloadIfActive(playlist: active)
                }
                PlaylistHealthStore.record(.responds, for: active.id)
            } else {
                try await PlaylistContentStore.shared.syncFromNetworkReplacingLocal(playlist: active) { _ in }
                await PlaylistContentStore.shared.reloadFromDatabaseIfActive(playlistId: active.id)
                PlaylistHealthStore.record(
                    ProviderExpiryStore.blockedExpiry(playlistId: active.id) != nil ? .expired : .responds,
                    for: active.id
                )
            }
            healthRefreshToken += 1
            AppSound.play(.refreshSuccess)
        } catch {
            PlaylistHealthStore.record(.refused, for: active.id)
            healthRefreshToken += 1
            refreshError = error.localizedDescription
            showRefreshError = true
        }
    }
}
