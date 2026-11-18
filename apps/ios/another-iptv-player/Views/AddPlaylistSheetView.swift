import SwiftUI
import UniformTypeIdentifiers

// MARK: - Add Playlist sheet (round 10)
//
// Creation form for Settings ▸ My Playlists: a segmented Xtream /
// M3U toggle over the two creation flows, with "Add & Activate" as
// the commit action — on success the caller activates the new
// playlist immediately (a second or third account, added without
// leaving the dashboard).
//
// The save pipelines are the gate's own (round 4): Xtream runs
// `XtreamAPIClient.verify()` + `XtreamImporter.syncAndSave`; M3U
// runs the `XtreamLinkDetector` auto-detection, then
// `M3UService` / `M3UParser` / `M3UImporter.replace`. Only the form
// orchestration is mirrored (the same relationship the gate has to
// the standalone Add screens); no parallel networking path exists.
// The name field is OPTIONAL here (the owner's spec): left blank it
// falls back to the server's host, or the picked file's name — a
// value derived from the user's own input, never invented.
struct AddPlaylistSheetView: View {
    let onCreated: (Playlist) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum FormKind: Hashable {
        case xtream, m3u
    }

    @State private var formKind: FormKind = .xtream

    // Xtream form state.
    @State private var xtreamName = ""
    @State private var xtreamURL = "http://"
    @State private var xtreamUsername = ""
    @State private var xtreamPassword = ""
    @State private var showPassword = false
    @State private var filterAdultContent = false

    // M3U form state.
    @State private var m3uName = ""
    @State private var m3uURL = ""
    @State private var localFileName: String? = nil
    @State private var localContent: String? = nil
    @State private var showFileImporter = false

    // Shared save state.
    @State private var isLoading = false
    @State private var progressMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    /// G5 (B13): the offline alert for the network save paths.
    @State private var showOfflineAlert = false

    private var hasLocalFile: Bool { localContent != nil }

    var body: some View {
        NavigationStack {
            // Round 14 (B11): rebuilt on the ELITE SettingsComponents
            // / AppTheme system instead of the classic Form look.
            // Save/validation logic below is unchanged.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker(L("playlist_type.section"), selection: $formKind) {
                        Text(L("playlist_type.xtream.title")).tag(FormKind.xtream)
                        Text(L("playlist_type.m3u.title")).tag(FormKind.m3u)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if formKind == .xtream {
                        xtreamSections
                    } else {
                        m3uSections
                    }
                }
                .padding(16)
            }
            .cinematicBackground()
            .navigationTitle(L("playlists.empty.add_button"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("playlists.add_and_activate")) {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
            .overlay {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
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
            .alert(L("offline.title"), isPresented: $showOfflineAlert) {
                Button(L("common.try_again")) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        Task { await save() }
                    }
                }
                Button(L("common.cancel"), role: .cancel) { }
            } message: {
                Text(L("offline.message"))
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: Self.allowedFileTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
        }
        .interactiveDismissDisabled(isLoading)
    }

    // MARK: - Form sections

    private var xtreamSections: some View {
        Group {
            SettingsGroupHeader(title: L("add_playlist.section.info"))
            SettingsFormCard {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(title: L("gate.field.name"))
                    TextField(L("playlists.name_optional"), text: $xtreamName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .settingsFieldChrome()
                }

                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(title: L("add_playlist.server_url"))
                    TextField(L("add_playlist.server_url"), text: $xtreamURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .settingsFieldChrome()
                }
            }

            SettingsGroupHeader(title: L("add_playlist.section.credentials"))
            SettingsFormCard {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(title: L("add_playlist.username"))
                    TextField(L("add_playlist.username"), text: $xtreamUsername)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .settingsFieldChrome()
                }

                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(title: L("add_playlist.password"))
                    HStack(spacing: 8) {
                        Group {
                            if showPassword {
                                TextField(L("add_playlist.password"), text: $xtreamPassword)
                            } else {
                                SecureField(L("add_playlist.password"), text: $xtreamPassword)
                            }
                        }
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("gate.toggle_password_visibility"))
                    }
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
    }

    private var m3uSections: some View {
        Group {
            SettingsGroupHeader(title: L("add_playlist.section.info"))
            SettingsFormCard {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(title: L("gate.field.name"))
                    TextField(L("playlists.name_optional"), text: $m3uName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .settingsFieldChrome()
                }
            }

            SettingsGroupHeader(title: L("add_m3u.section.source"))
            SettingsFormCard {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(title: L("gate.field.playlist_url"))
                    TextField(L("add_m3u.url_placeholder"), text: $m3uURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(hasLocalFile)
                        .foregroundColor(hasLocalFile ? .secondary : .primary)
                        .settingsFieldChrome()
                }

                HStack {
                    Button {
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
    }

    // MARK: - Validation

    private var canSave: Bool {
        guard !isLoading else { return false }
        switch formKind {
        case .xtream:
            return !xtreamURL.trimmingCharacters(in: .whitespaces).isEmpty
                && !xtreamUsername.isEmpty && !xtreamPassword.isEmpty
        case .m3u:
            if hasLocalFile { return true }
            return !m3uURL.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func save() async {
        // G5 (B13): adding a playlist is network-only — EXCEPT an
        // M3U picked from a local file, which imports fine
        // offline. Offline, show the plain message with Retry
        // instead of a spinner against a dead path.
        let needsNetwork = formKind == .xtream || !hasLocalFile
        if needsNetwork, OfflineState.shared.isOffline {
            showOfflineAlert = true
            return
        }
        switch formKind {
        case .xtream: await saveXtream()
        case .m3u: await saveM3U()
        }
    }

    /// Display name when the optional field is left blank: the
    /// server's host for URL-based playlists, the file's name for a
    /// picked file — always from the user's own input.
    private func fallbackName(for urlString: String) -> String {
        if let host = URL(string: urlString)?.host, !host.isEmpty {
            return host
        }
        return urlString
    }

    // MARK: - Xtream save (the gate's pipeline)

    private func saveXtream() async {
        isLoading = true
        errorMessage = nil
        progressMessage = L("add_playlist.verifying")

        let trimmedURL = xtreamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = xtreamName.trimmingCharacters(in: .whitespacesAndNewlines)
        var newPlaylist = Playlist(
            name: trimmedName.isEmpty ? fallbackName(for: trimmedURL) : trimmedName,
            serverURL: trimmedURL,
            username: xtreamUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            password: xtreamPassword.trimmingCharacters(in: .whitespacesAndNewlines),
            filterAdultContent: filterAdultContent
        )

        let client = XtreamAPIClient(playlist: newPlaylist)

        do {
            let response = try await client.verify()

            if let tz = response.serverInfo?.timezone?.trimmingCharacters(in: .whitespacesAndNewlines), !tz.isEmpty {
                newPlaylist.serverTimezone = tz
            }

            if response.userInfo?.auth == 1 {
                do {
                    try await XtreamImporter.syncAndSave(playlist: newPlaylist, client: client) { message in
                        self.progressMessage = message
                    }
                    await MainActor.run {
                        self.isLoading = false
                        self.progressMessage = nil
                        self.onCreated(newPlaylist)
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = L("add_playlist.download_save_error", error.localizedDescription)
                        self.showError = true
                        self.isLoading = false
                        self.progressMessage = nil
                    }
                }
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

    // MARK: - M3U save (the gate's pipeline)

    private func saveM3U() async {
        isLoading = true
        errorMessage = nil
        progressMessage = L("add_m3u.preparing")

        let trimmedURL = m3uURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = m3uName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String = {
            if !trimmedName.isEmpty { return trimmedName }
            if let localFileName {
                return (localFileName as NSString).deletingPathExtension
            }
            return fallbackName(for: trimmedURL)
        }()

        // Xtream-style get.php links connect through the Xtream API
        // when possible — identical auto-detection to the gate.
        if !hasLocalFile,
           let credentials = XtreamLinkDetector.detect(urlString: trimmedURL),
           await addAsXtream(credentials: credentials, name: resolvedName) {
            return
        }

        let newPlaylist = Playlist(
            name: resolvedName,
            serverURL: hasLocalFile ? "" : trimmedURL,
            username: "",
            password: "",
            filterAdultContent: false,
            type: .m3u,
            m3uEpgURL: nil
        )

        do {
            let rawContent: String
            if let local = localContent {
                rawContent = local
            } else {
                progressMessage = L("add_m3u.downloading")
                rawContent = try await M3UService().fetchRemote(urlString: trimmedURL)
            }

            progressMessage = L("add_m3u.parsing")
            let parsed = try await M3UParser.parseAsync(rawContent)

            progressMessage = L("add_m3u.saving_db")
            try await M3UImporter.replace(
                playlist: newPlaylist,
                channels: parsed.channels,
                epgURL: parsed.epgURL,
                clearServerURL: hasLocalFile
            )

            await MainActor.run {
                self.isLoading = false
                self.progressMessage = nil
                self.onCreated(newPlaylist)
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

    /// The gate's addAsXtream, verbatim except success reports the
    /// created playlist to the caller instead of resetting a form.
    private func addAsXtream(credentials: XtreamLinkDetector.Credentials, name: String) async -> Bool {
        await MainActor.run { progressMessage = L("add_m3u.xtream_detected") }

        let playlist = Playlist(
            name: name,
            serverURL: credentials.serverURL,
            username: credentials.username,
            password: credentials.password,
            type: .xtream
        )
        let client = XtreamAPIClient(playlist: playlist)

        do {
            _ = try await client.verify()
        } catch {
            // get.php link without a working player_api — treat as a regular M3U link.
            return false
        }

        do {
            try await XtreamImporter.syncAndSave(playlist: playlist, client: client) { message in
                self.progressMessage = message
            }
            await MainActor.run {
                self.isLoading = false
                self.progressMessage = nil
                self.onCreated(playlist)
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.showError = true
                self.isLoading = false
                self.progressMessage = nil
            }
        }
        return true
    }

    // MARK: - File picker (mirrors the gate / AddM3UPlaylistView)

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
}
