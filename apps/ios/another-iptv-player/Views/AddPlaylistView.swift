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

    // Build 61 (B10, K2/G2/G4/Q18): connection-extras fields,
    // pre-filled from the SAME record being edited.
    @State private var backupURL: String
    @State private var epgURL: String
    @State private var userAgent: String
    @State private var headersText: String

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
        _backupURL = State(initialValue: editingPlaylist.backupURL ?? "")
        _epgURL = State(initialValue: editingPlaylist.epgURLOverride ?? "")
        _userAgent = State(initialValue: editingPlaylist.customUserAgent ?? "")
        _headersText = State(initialValue: editingPlaylist.customHeadersText)
    }

    /// Optional-field trim (nil when empty), as on the gate.
    private func optionalField(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Build 61 (B10, K1): pasting a full Xtream ready link into
    /// any field fills Server / Username / Password; a failed
    /// parse leaves the text untouched, no error.
    private func applyReadyLink(_ text: String) {
        guard let credentials = XtreamReadyLink.parse(text) else { return }
        url = credentials.serverURL
        username = credentials.username
        password = credentials.password
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

                    // Build 61 (B10, K2): connection extras —
                    // Q18 backup URL, G4 custom EPG URL, G2
                    // User-Agent + custom headers.
                    SettingsGroupHeader(title: L("addplaylist.section.connection"))
                    SettingsFormCard {
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(title: L("addplaylist.field.backup_url"))
                            TextField(L("addplaylist.field.backup_url.placeholder"), text: $backupURL)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .settingsFieldChrome()
                            Text(L("headers.backup.note"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(title: L("addplaylist.field.epg_url"))
                            TextField(L("addplaylist.field.epg_url.placeholder"), text: $epgURL)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .settingsFieldChrome()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(title: L("headers.user_agent"))
                            TextField(L("headers.user_agent.placeholder"), text: $userAgent)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .settingsFieldChrome()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(title: L("headers.custom"))
                            TextField(L("headers.custom.placeholder"), text: $headersText, axis: .vertical)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .lineLimit(2...4)
                                .settingsFieldChrome()
                        }
                    }
                }
                .padding(16)
                // Build 61 (B10, K1): in-form paste parsing.
                .onChange(of: url) { _, newValue in applyReadyLink(newValue) }
                .onChange(of: username) { _, newValue in applyReadyLink(newValue) }
                .onChange(of: password) { _, newValue in applyReadyLink(newValue) }
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
        // K2: the id is the EDITED record's id — favorites, pins,
        // groups and history keyed by it survive untouched.
        var newPlaylist = Playlist(
            id: editingPlaylist.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            serverURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password.trimmingCharacters(in: .whitespacesAndNewlines),
            filterAdultContent: filterAdultContent,
            epgEnabled: editingPlaylist.epgEnabled,
            serverTimezone: editingPlaylist.serverTimezone,
            timeshiftStyle: editingPlaylist.timeshiftStyle,
            backupURL: optionalField(backupURL),
            customUserAgent: optionalField(userAgent),
            customHeadersJSON: Playlist.encodeCustomHeaders(Playlist.parseHeaderLines(headersText))
        )
        newPlaylist.epgURLOverride = optionalField(epgURL)
        newPlaylist.m3uEpgURL = editingPlaylist.m3uEpgURL
        newPlaylist.createdAt = editingPlaylist.createdAt

        // Connection details changed → Q17 re-validation + resync.
        let detailsChanged =
            newPlaylist.serverURL != editingPlaylist.serverURL ||
            newPlaylist.username != editingPlaylist.username ||
            newPlaylist.password != editingPlaylist.password ||
            newPlaylist.filterAdultContent != editingPlaylist.filterAdultContent

        if !detailsChanged {
            // Only name / connection extras changed: save the SAME
            // record directly (no resync needed for those fields).
            do {
                try await AppDatabase.shared.write { db in
                    try newPlaylist.save(db)
                }
                // N1 (B13): keep the keychain restore mirror in
                // step on this direct save path too.
                CredentialStore.mirror(newPlaylist)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isLoading = false
            return
        }

        do {
            // Build 61 (B10, Q17+K2): probe BEFORE saving —
            // distinct plain failures (bad URL / bad credentials /
            // expired / unreachable); on any failure the OLD
            // record stays exactly as it was.
            let probed = try await PlaylistValidationService.probeXtream(playlist: newPlaylist)
            await syncAndSave(newPlaylist: probed.playlist, client: probed.client)
        } catch let failure as PlaylistValidationService.ValidationFailure {
            await MainActor.run {
                errorMessage = failure.errorDescription
                showError = true
                isLoading = false
                progressMessage = nil
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
