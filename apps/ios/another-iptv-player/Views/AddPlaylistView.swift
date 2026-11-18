import SwiftUI
import GRDB

private enum PlaylistFormField: Hashable {
    case name, url, username, password
}

/// Edit-only Xtream playlist form (round 8, F-5). Creation lives on
/// the playlist gate (round 4) — its forms run the same pipelines — so
/// this screen's old new-playlist branch was unreachable and has been
/// removed: `editingPlaylist` is now a required, non-optional value and
/// every nil-branch went with it. The only call site is ContentView's
/// gate edit sheet, which always passes the playlist being edited.
struct AddPlaylistView: View {
    @Environment(\.dismiss) private var dismiss

    let editingPlaylist: Playlist

    @FocusState private var focusedField: PlaylistFormField?

    @State private var name: String
    @State private var url: String
    @State private var username: String
    @State private var password: String

    @State private var filterAdultContent: Bool

    @State private var isLoading = false
    @State private var progressMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false

    init(editingPlaylist: Playlist) {
        self.editingPlaylist = editingPlaylist
        _name = State(initialValue: editingPlaylist.name)
        _url = State(initialValue: editingPlaylist.serverURL)
        _username = State(initialValue: editingPlaylist.username)
        _password = State(initialValue: editingPlaylist.password)
        _filterAdultContent = State(initialValue: editingPlaylist.filterAdultContent)
    }
    
    var body: some View {
        NavigationStack {
            // Round 14 (B11): rebuilt on the ELITE SettingsComponents
            // / AppTheme system (cinematic background, styled cards,
            // labels above fields) instead of the classic Form look.
            // Save/validation logic below is unchanged.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsGroupHeader(title: L("add_playlist.section.info"))
                    SettingsFormCard {
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(title: L("gate.field.name"))
                            TextField(L("add_playlist.name_placeholder"), text: $name)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.words)
                                .focused($focusedField, equals: .name)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .url }
                                .settingsFieldChrome()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(title: L("add_playlist.server_url"))
                            TextField(L("add_playlist.server_url"), text: $url)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: .url)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .username }
                                .settingsFieldChrome()
                        }
                    }

                    SettingsGroupHeader(title: L("add_playlist.section.credentials"))
                    SettingsFormCard {
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(title: L("add_playlist.username"))
                            TextField(L("add_playlist.username"), text: $username)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: .username)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                                .settingsFieldChrome()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(title: L("add_playlist.password"))
                            SecureField(L("add_playlist.password"), text: $password)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .password)
                                .submitLabel(.done)
                                .onSubmit { focusedField = nil }
                                .settingsFieldChrome()
                        }
                    }

                    SettingsGroupHeader(title: L("add_playlist.section.content_settings"))
                    SettingsFormCard {
                        Toggle(isOn: $filterAdultContent) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("add_playlist.filter_adult"))
                                Text(L("add_playlist.filter_adult.desc"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .cinematicBackground()
            .navigationTitle(L("add_playlist.xtream.title_edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        Task { await savePlaylist() }
                    }
                    .disabled(name.isEmpty || url.isEmpty || username.isEmpty || password.isEmpty || isLoading)
                }
            }
            .overlay {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(progressMessage ?? L("add_playlist.verifying"))
                            .font(.headline)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .background(AppTheme.elevated.opacity(0.95))
                    .cornerRadius(AppTheme.cornerRadius)
                    .shadow(radius: 20)
                }
            }
            .alert(L("common.error"), isPresented: $showError, actions: {
                Button(L("common.ok"), role: .cancel) { }
            }, message: {
                Text(errorMessage ?? L("common.unknown_error"))
            })
        }
        // The sheet must not be dismissible by scrolling while verification/sync is running (see AddM3UPlaylistView).
        .interactiveDismissDisabled(isLoading)
    }

    private func savePlaylist() async {
        isLoading = true
        errorMessage = nil
        progressMessage = L("add_playlist.verifying")
        
        // Carry EPG/catch-up columns over on edit so a name-only save doesn't
        // reset them (the panel timezone is otherwise re-resolved lazily later).
        var newPlaylist = Playlist(
            id: editingPlaylist.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            serverURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password.trimmingCharacters(in: .whitespacesAndNewlines),
            filterAdultContent: filterAdultContent,
            epgEnabled: editingPlaylist.epgEnabled,
            serverTimezone: editingPlaylist.serverTimezone,
            timeshiftStyle: editingPlaylist.timeshiftStyle
        )

        // Credentials or filter changed check
        let detailsChanged =
            newPlaylist.serverURL != editingPlaylist.serverURL ||
            newPlaylist.username != editingPlaylist.username ||
            newPlaylist.password != editingPlaylist.password ||
            newPlaylist.filterAdultContent != editingPlaylist.filterAdultContent

        if !detailsChanged {
            // Only name changed
            do {
                try await AppDatabase.shared.write { db in
                    try newPlaylist.save(db)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isLoading = false
            return
        }
        
        do {
            // Round 16 (F2): verify + timezone capture is the shared
            // PlaylistSaveService pipeline (identical to the gate's).
            let (response, client) = try await PlaylistSaveService.verifyXtream(playlist: &newPlaylist)

            if response.userInfo?.auth == 1 {
                await syncAndSave(newPlaylist: newPlaylist, client: client)
            } else {
                await MainActor.run {
                    errorMessage = L("add_playlist.auth_failed")
                    showError = true
                    isLoading = false
                    progressMessage = nil
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
                isLoading = false
                progressMessage = nil
            }
        }
    }
    
    private func syncAndSave(newPlaylist: Playlist, client: XtreamAPIClient) async {
        do {
            try await PlaylistSaveService.syncXtream(playlist: newPlaylist, client: client) { message in
                self.progressMessage = message
            }

            await MainActor.run {
                self.isLoading = false
                self.progressMessage = nil
                self.dismiss()
            }
        } catch {
            await MainActor.run {
                self.errorMessage = L("add_playlist.download_save_error", error.localizedDescription)
                self.showError = true
                self.isLoading = false
                self.progressMessage = nil
            }
        }
    }
}
