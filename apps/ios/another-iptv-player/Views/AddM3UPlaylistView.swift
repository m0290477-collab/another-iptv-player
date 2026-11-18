import SwiftUI
import GRDB
import UniformTypeIdentifiers

private enum M3UFormField: Hashable {
    case name, url
}

/// A separate edit screen for an M3U/M3U8-type playlist. The Xtream flow is unaffected.
///
/// Round 8 (F-5): edit-only, like AddPlaylistView — creation lives on
/// the playlist gate (round 4), so the new-playlist branches here were
/// unreachable and are removed (`editingPlaylist` is non-optional now;
/// the Xtream auto-detection branch and its `addAsXtream` helper went
/// with them). Round 16 (F2): the save pipelines themselves are no
/// longer copies at all — the gate and both sheets run the one shared
/// PlaylistSaveService. The only call site is ContentView's gate
/// edit sheet.
struct AddM3UPlaylistView: View {
    @Environment(\.dismiss) private var dismiss

    let editingPlaylist: Playlist

    @FocusState private var focusedField: M3UFormField?

    @State private var name: String
    @State private var url: String

    /// Has a local file been uploaded? (Mutually exclusive with URL mode.)
    @State private var localFileName: String? = nil
    @State private var localContent: String? = nil

    @State private var showFileImporter = false

    @State private var isLoading = false
    @State private var progressMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false

    init(editingPlaylist: Playlist) {
        self.editingPlaylist = editingPlaylist
        _name = State(initialValue: editingPlaylist.name)
        _url = State(initialValue: editingPlaylist.serverURL)
    }

    private var hasLocalFile: Bool { localContent != nil }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !isLoading else { return false }
        if hasLocalFile { return true }
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        // In editing, if the source hasn't changed only the name is updated; on playlists added from a local file
        // serverURL is empty — an empty URL must not block the record.
        if trimmedURL == editingPlaylist.serverURL { return true }
        return !trimmedURL.isEmpty
    }

    var body: some View {
        NavigationStack {
            // Round 14 (B11): rebuilt on the ELITE SettingsComponents
            // / AppTheme system instead of the classic Form look.
            // Save/validation logic below is unchanged.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsGroupHeader(title: L("add_playlist.section.info"))
                    SettingsFormCard {
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(title: L("gate.field.name"))
                            TextField(L("add_m3u.name_placeholder"), text: $name)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.words)
                                .focused($focusedField, equals: .name)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .url }
                                .settingsFieldChrome()
                        }
                    }

                    SettingsGroupHeader(title: L("add_m3u.section.source"))
                    SettingsFormCard {
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(title: L("gate.field.playlist_url"))
                            TextField(L("add_m3u.url_placeholder"), text: $url)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: .url)
                                .submitLabel(.done)
                                .disabled(hasLocalFile)
                                .foregroundColor(hasLocalFile ? .secondary : .primary)
                                .settingsFieldChrome()
                        }

                        HStack {
                            Button {
                                focusedField = nil
                                showFileImporter = true
                            } label: {
                                Label(hasLocalFile ? L("add_m3u.pick_another_file") : L("add_m3u.pick_file"),
                                      systemImage: "doc.badge.plus")
                            }

                            Spacer()

                            if let local = localFileName {
                                Text(local)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        if hasLocalFile {
                            Button(role: .destructive) {
                                localFileName = nil
                                localContent = nil
                            } label: {
                                Label(L("add_m3u.remove_file"), systemImage: "xmark.circle")
                            }
                        }

                        Text(L("add_m3u.section.source_footer"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(16)
            }
            .cinematicBackground()
            .navigationTitle(L("add_m3u.title_edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        Task { await savePlaylist() }
                    }
                    .disabled(!canSave)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: Self.allowedFileTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .overlay {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView().scaleEffect(1.5)
                        Text(progressMessage ?? L("common.loading"))
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
        // During a long import, accidentally scrolling down closed the sheet and left the Task
        // running invisibly in the background.
        .interactiveDismissDisabled(isLoading)
    }

    // MARK: - File Picker

    private static var allowedFileTypes: [UTType] {
        var types: [UTType] = [.plainText, .data]
        if let m3u = UTType(filenameExtension: "m3u") { types.insert(m3u, at: 0) }
        if let m3u8 = UTType(filenameExtension: "m3u8") { types.insert(m3u8, at: 0) }
        return types
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            errorMessage = err.localizedDescription
            showError = true
        case .success(let urls):
            guard let url = urls.first else { return }
            isLoading = true
            progressMessage = L("common.loading")
            Task {
                do {
                    let content = try await M3UService().readLocalAsync(url: url)
                    localContent = content
                    localFileName = url.lastPathComponent
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
                isLoading = false
                progressMessage = nil
            }
        }
    }

    // MARK: - Save

    private func savePlaylist() async {
        isLoading = true
        errorMessage = nil
        progressMessage = L("add_m3u.preparing")

        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Source unchanged while editing (no new file picked, URL untouched — including
        // the always-empty URL of local-file playlists): only update the name. Without
        // this, local-file playlists could never be renamed at all, and URL playlists
        // re-downloaded the entire list just to change the name.
        if !hasLocalFile, trimmedURL == editingPlaylist.serverURL {
            var updated = editingPlaylist
            updated.name = trimmedName
            do {
                try await AppDatabase.shared.write { db in
                    try updated.save(db)
                }
                // N1 (B13): keep the keychain restore mirror in
                // step on this direct save path too.
                CredentialStore.mirror(updated)
                await MainActor.run {
                    self.isLoading = false
                    self.progressMessage = nil
                    self.dismiss()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                    self.isLoading = false
                    self.progressMessage = nil
                }
            }
            return
        }

        // Round 8 (F-5): the Xtream auto-detection branch that used to
        // sit here ran only for NEW playlists (`editingPlaylist == nil`)
        // — unreachable since the gate took over creation, and removed.
        // Editing an M3U playlist never converts it (that would orphan
        // its favorites and watch history); a changed source simply
        // re-imports under the same playlist id below.
        let newPlaylist = Playlist(
            id: editingPlaylist.id,
            name: trimmedName,
            serverURL: hasLocalFile ? "" : trimmedURL,
            username: "",
            password: "",
            filterAdultContent: editingPlaylist.filterAdultContent,
            type: .m3u,
            m3uEpgURL: nil
        )

        do {
            // Round 16 (F2): fetch → parse → replace is the shared
            // PlaylistSaveService pipeline (identical to the gate's);
            // this sheet's copy never checked cancellation between
            // steps, so checkCancellation stays false here.
            try await PlaylistSaveService.importM3U(
                playlist: newPlaylist,
                localContent: localContent,
                remoteURLString: trimmedURL,
                clearServerURL: hasLocalFile,
                checkCancellation: false
            ) { message in
                self.progressMessage = message
            }

            await MainActor.run {
                self.isLoading = false
                self.progressMessage = nil
                self.dismiss()
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.showError = true
                self.isLoading = false
                self.progressMessage = nil
            }
        }
    }
}
