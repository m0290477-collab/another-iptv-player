import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Branded entry gate (round 4)
//
// The gate is the app's entry screen when there is nothing to enter
// yet (or right after an explicit sign-out): a Super X wordmark
// header and ONE add form whose type choice switches between the
// Xtream and M3U flows. Both forms run the EXACT save pipelines
// the standalone add screens use — `XtreamAPIClient.verify()` +
// `XtreamImporter.syncAndSave` for Xtream; `XtreamLinkDetector`
// auto-detection, then `M3UService`/`M3UParser`/`M3UImporter.replace`
// for M3U — with the same validation, progress messages and error
// surfacing. Nothing here writes a parallel networking path; the
// standalone Add/Edit screens remain in the tree and are still what
// Settings ▸ My Playlists presents for edits.
//
// Round 11 (owner, build 47): the saved-playlist list that used to
// sit at the top of this screen is REMOVED — wrong place, ugly, the
// raw server URL on show, and no way to delete from here. The gate
// is a clean sign-in form only; playlist selection, switching and
// deletion live in Settings ▸ My Playlists. A successful sign-in
// now enters the app directly with the saved playlist (the import
// pipelines upsert the very struct built here), and re-signing into
// an already-saved account reuses that record instead of piling up
// a duplicate. A returning user with a saved playlist never sees
// this screen at all — ContentView's auto-load enters directly.
//
// Round 14 (B13): professional rebuild of the PRESENTATION only —
// the real app icon in the header (always), playlist-type radio
// cards with their existing subtitle strings, small labels above
// fields, paste inside the URL field + a "Paste all" smart paste,
// inline validation with a real URL-with-host check, an explained
// error card (plain-language cause + next step) instead of raw
// error text, an EXPIRED-ACCOUNT WARNING after a successful verify
// (browse allowed, never silent), a Cancel button during import,
// the adult-filter toggle on the M3U form too, a help line with an
// explainer sheet + the Privacy/Terms destinations, and
// non-sensitive draft fields (name / URL / username — never the
// password) persisted across restarts via @AppStorage. Build 66:
// the M3U URL draft is the exception — it commonly embeds
// credentials, so it lives in @State only (see the form state).
//
// Deliberately absent (the reference app's reseller layer, excluded by
// the owner): no device ID, no subscription check, no activation/support
// buttons, no demo mode. Every control on this screen does something real.

private enum GateFormField: Hashable {
    case xtreamName, xtreamURL, xtreamUsername, xtreamPassword
    case m3uName, m3uURL
}

private extension View {
    /// Build 61 (Design-4) gate field treatment: dark translucent
    /// fill with a thin red-orange (accent) outline, as in panel 4.
    /// Padding included — replaces the old elevated-fill chain.
    func gateFieldStyle() -> some View {
        padding(12)
            .background(AppTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.accent.opacity(0.45), lineWidth: 1)
            )
    }
}

struct PlaylistGateView: View {
    /// The saved playlists — used ONLY to recognize a re-sign-in to
    /// an already-saved account (no list is rendered from it).
    let playlists: [Playlist]
    let onSelect: (Playlist) -> Void

    private enum FormKind: Hashable {
        case xtream, m3u
    }

    @State private var formKind: FormKind = .xtream
    @FocusState private var focusedField: GateFormField?

    // Xtream form state. Round 14 (B13): name / URL / username are
    // @AppStorage drafts — they survive an app restart; the
    // PASSWORD is deliberately never persisted as a draft.
    @AppStorage("gate.draft.xtream.name") private var xtreamName = ""
    @AppStorage("gate.draft.xtream.url") private var xtreamURL = "http://"
    @AppStorage("gate.draft.xtream.username") private var xtreamUsername = ""
    @State private var xtreamPassword = ""
    @State private var showPassword = false
    @State private var filterAdultContent = false

    // M3U form state. The NAME is a restart-persisted draft; the
    // URL is NOT (build 66, W2): an M3U URL commonly embeds the
    // provider credentials, so it is kept in @State only and
    // never written to UserDefaults.
    @AppStorage("gate.draft.m3u.name") private var m3uName = ""
    @State private var m3uURL = ""
    @State private var m3uFilterAdultContent = false
    @State private var localFileName: String? = nil
    @State private var localContent: String? = nil
    @State private var showFileImporter = false

    // Build 61 (B10): connection-extras field state for both forms
    // (Q18 backup URL, G4 custom EPG URL, G2 User-Agent + headers).
    // @State only — an M3U backup URL can carry credentials, so
    // none of this is persisted as a draft.
    @State private var xtreamBackupURL = ""
    @State private var xtreamEPGURL = ""
    @State private var xtreamUserAgent = ""
    @State private var xtreamHeadersText = ""
    @State private var m3uBackupURL = ""
    @State private var m3uEPGURL = ""
    @State private var m3uUserAgent = ""
    @State private var m3uHeadersText = ""

    // Build 61 (B10, L1/L2/L3): staged add progress + summary.
    @State private var addStages: [PlaylistValidationService.Stage: PlaylistValidationService.StageState] = [:]
    @State private var addSummary: PlaylistValidationService.AddSummary?

    // Shared save state: one loading overlay + one error alert, exactly
    // the presentation the two Add screens use individually.
    @State private var isLoading = false
    @State private var progressMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false

    // Round 14 (B13): the running import is a stored, CANCELLABLE
    // task; the overlay's Cancel button cancels it.
    @State private var importTask: Task<Void, Never>?

    // Round 14 (B13): expired-account warning at entry. After a
    // successful verify that shows the account expired, entry waits
    // on this card: "Enter anyway" runs the pending import (browsing
    // is allowed; playback is gated elsewhere), Cancel aborts.
    private enum PendingEntry {
        case xtream(playlist: Playlist, client: XtreamAPIClient)
    }
    @State private var pendingEntry: PendingEntry?
    @State private var expiredDateText = ""
    @State private var showExpiredWarning = false

    // Round 14 (B13): "No sign-in details?" explainer sheet.
    @State private var showHelp = false

    // Round 15 (C13): the sign-out "Continue with" row. The name
    // is NAME ONLY (written by ContentView at sign-out) — no URL,
    // no credentials ever touch this key.
    // Build 66 (W2, item 2): QR sign-in is REMOVED — the scanner,
    // its sheet and its state are gone with the camera permission.
    @AppStorage("gate.lastPlaylistName") private var lastPlaylistName = ""

    // Round 17 (R17-5): removal of the saved account behind the
    // "Continue with" row — confirmation state + failure surface.
    @State private var playlistPendingRemoval: Playlist?
    @State private var showRemoveConfirmation = false
    @State private var showRemoveError = false

    private var hasLocalFile: Bool { localContent != nil }

    /// Build 65 (Login gate style 2 'Cinematic Card'): the blurred
    /// cinematic backdrop behind the gate — the brand flame blown
    /// up, blurred and dimmed over a warm charcoal gradient (brand
    /// art only; the gate has no catalog to borrow posters from,
    /// and none are invented).
    private var gateBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.06, blue: 0.045),
                    AppTheme.background,
                    AppTheme.background
                ],
                startPoint: .top, endPoint: .bottom
            )
            Image(systemName: "flame.fill")
                .font(.system(size: 430, weight: .bold))
                .foregroundStyle(AppTheme.brandGradient)
                .blur(radius: 95)
                .opacity(0.32)
                .offset(y: -190)
            // A second, cooler ember low in the frame for depth.
            Image(systemName: "flame.fill")
                .font(.system(size: 300, weight: .bold))
                .foregroundStyle(AppTheme.brandGradient)
                .blur(radius: 110)
                .opacity(0.14)
                .offset(x: 130, y: 330)
        }
        .ignoresSafeArea()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                // Round 15 (C13): "All subscriptions expired" —
                // an explicit line instead of blind-entering a
                // dead playlist; the add form below stays ready.
                if allSubscriptionsExpired {
                    allExpiredCard
                }

                // Build 65 (style 2 'Cinematic Card'): header +
                // form live inside ONE frosted-glass card over the
                // blurred backdrop — the mockup's composition.
                // Every field, the segmented switch and all logic
                // are the existing views, unchanged.
                VStack(spacing: 22) {
                    header
                    addSection
                }
                .padding(20)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(AppTheme.surface.opacity(0.55))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)

                // Round 15 (C13): after an explicit sign-out, one
                // discreet row back into the last playlist (name
                // only — tapping re-enters that saved record).
                // Build 65: it sits UNDER the card, where the
                // mockup puts its saved-playlist chips.
                if let last = continueWithPlaylist {
                    continueWithRow(last)
                }

                helpLine
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
            // While a verify/import runs, the gate is inert — the analog
            // of the Add sheets' `interactiveDismissDisabled(isLoading)`.
            .disabled(isLoading)
        }
        // Build 65 (Cinematic Card): the blurred backdrop behind
        // the scroll content (ContentView's flat cinematic
        // background sits behind this).
        .background(gateBackdrop)
        .overlay {
            if let summary = addSummary {
                // Build 61 (B10, L2/L3): the end-of-add summary.
                AddPlaylistSummaryView(
                    summary: summary,
                    onRetryFailedStage: summary.failedStage == nil ? nil : {
                        Task { await retryGuideStage() }
                    },
                    onStartWatching: {
                        addSummary = nil
                        addStages = [:]
                        onSelect(summary.playlist)
                    }
                )
                .padding(.horizontal, 24)
            } else if isLoading {
                if !addStages.isEmpty {
                    // Build 61 (B10, L1): the staged checklist,
                    // bound to the real importer stages; Cancel
                    // leaves nothing half-saved.
                    AddPlaylistProgressView(
                        stages: addStages,
                        playlistName: formKind == .xtream ? xtreamName : m3uName
                    ) {
                        importTask?.cancel()
                        importTask = nil
                        isLoading = false
                        progressMessage = nil
                        addStages = [:]
                    }
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(progressMessage ?? L("common.loading"))
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        // Round 14 (B13): cancel during import.
                        Button(L("common.cancel")) {
                            importTask?.cancel()
                            importTask = nil
                            isLoading = false
                            progressMessage = nil
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.accent)
                    }
                    .padding(24)
                    .background(AppTheme.elevated.opacity(0.95))
                    .cornerRadius(AppTheme.cornerRadius)
                    .shadow(radius: 20)
                }
            }
        }
        .overlay {
            if showExpiredWarning {
                expiredWarningCard
            }
        }
        .alert(L("common.error"), isPresented: $showError, actions: {
            Button(L("common.ok"), role: .cancel) { }
        }, message: {
            Text(errorMessage ?? L("common.unknown_error"))
        })
        .sheet(isPresented: $showHelp) {
            GateHelpView()
        }
        // Round 17 (R17-5): the saved-account removal confirmation
        // + its failure surface (the shared deletion path reports
        // honestly, exactly like Settings' Delete Account).
        .alert(L("gate.remove_account.title"), isPresented: $showRemoveConfirmation) {
            Button(L("common.cancel"), role: .cancel) { playlistPendingRemoval = nil }
            Button(L("gate.remove_account"), role: .destructive) {
                guard let target = playlistPendingRemoval else { return }
                playlistPendingRemoval = nil
                Task {
                    let succeeded = await AccountDataDeletion.deletePlaylistData(target)
                    if !succeeded { showRemoveError = true }
                }
            }
        } message: {
            Text(L("gate.remove_account.message", playlistPendingRemoval?.name ?? ""))
        }
        .alert(L("common.error"), isPresented: $showRemoveError) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(L("settings.legal.delete_account.error_message"))
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.allowedFileTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            // Build 61 (Design-4, panel 4): the centered flame mark
            // over the wordmark — the mockup's flame-X treatment,
            // rendered with the system flame glyph in the fixed
            // Design-4 brand gradient (the LaunchMark asset is an
            // opaque blue-on-black raster, so it cannot carry the
            // treatment; the app icon itself is unchanged and still
            // shows everywhere the system shows it).
            Image(systemName: "flame.fill")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(AppTheme.brandGradient)
                .shadow(color: AppTheme.accentStart.opacity(0.45), radius: 14, x: 0, y: 6)
                .padding(.bottom, 2)

            // Typographic wordmark — no invented logo artwork: "Super"
            // in white, the X in the brand gradient (the mockup's
            // flame-treated X), black weight, tight tracking.
            // Build 61 fixer (Z11): this release presents as "Super X
            // Pro Max" — DISPLAY string only (bundle ID /
            // CFBundleDisplayName / product name untouched); the size
            // steps down so the longer lockup fits the gate header.
            HStack(spacing: 4) {
                Text("Super")
                    .foregroundStyle(.white)
                Text("X")
                    .foregroundStyle(AppTheme.brandGradient)
                Text("Pro Max")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 32, weight: .black))
            .tracking(-0.5)

            // Design-4 subtitle ("IPTV • Playlist Login" in the
            // mockup), in the accent.
            Text(L("gate.subtitle"))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.accent)

            if playlists.isEmpty {
                Text(L("playlists.empty.message"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Add form (radio-card Xtream / M3U choice)

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Build 61 (Design-4, panel 4): the segmented pill switch
            // replaces the round-14 radio cards — one capsule track,
            // the selected segment a dark pill with accent text and a
            // thin accent outline, the other segment plain white text.
            // Same `formKind` state, same two forms below; the type
            // subtitles still live in the help sheet's explainer.
            segmentedTypeSwitch

            Group {
                if formKind == .xtream {
                    xtreamForm
                } else {
                    m3uForm
                }
            }
            .id(formKind)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.25), value: formKind)
        // Build 61 (B10, K1): in-form paste parsing — pasting a
        // full Xtream get.php-style ready link into ANY field
        // fills Server / Username / Password. Parse failure leaves
        // the text exactly as-is, no error. NO clipboard access.
        .onChange(of: xtreamURL) { _, newValue in applyReadyLink(newValue) }
        .onChange(of: xtreamUsername) { _, newValue in applyReadyLink(newValue) }
        .onChange(of: xtreamPassword) { _, newValue in applyReadyLink(newValue) }
        .onChange(of: m3uURL) { _, newValue in applyReadyLink(newValue) }
    }

    /// K1: fill the Xtream fields from a pasted ready link.
    private func applyReadyLink(_ text: String) {
        guard let credentials = XtreamReadyLink.parse(text) else { return }
        formKind = .xtream
        if xtreamURL != credentials.serverURL { xtreamURL = credentials.serverURL }
        xtreamUsername = credentials.username
        xtreamPassword = credentials.password
    }

    /// L1 stage bookkeeping (driven by the real save pipelines).
    private func setStage(_ stage: PlaylistValidationService.Stage, _ state: PlaylistValidationService.StageState) {
        addStages[stage] = state
    }

    private func resetStages() {
        addStages = Dictionary(uniqueKeysWithValues: PlaylistValidationService.Stage.allCases.map { ($0, .pending) })
    }

    /// L3 retry: re-runs ONLY the guide stage for the summarized
    /// playlist; success clears the summary's failed-stage mark.
    private func retryGuideStage() async {
        guard let summary = addSummary else { return }
        let failed = await PlaylistValidationService.runGuideStage(playlist: summary.playlist) { stage, state in
            if state == .done || state == .failed {
                self.addSummary = PlaylistValidationService.AddSummary(
                    playlist: summary.playlist,
                    expiryDate: summary.expiryDate,
                    liveCount: summary.liveCount,
                    movieCount: summary.movieCount,
                    seriesCount: summary.seriesCount,
                    failedStage: state == .done ? nil : .loadingGuide,
                    compatibility: summary.compatibility
                )
            }
            _ = stage
        }
        _ = failed
    }

    /// Build 61 (B10): the optional connection-fields group shared
    /// by both gate forms (Q18 backup URL, G4 custom EPG URL,
    /// G2 User-Agent + custom headers).
    private func connectionFields(
        backup: Binding<String>,
        epg: Binding<String>,
        userAgent: Binding<String>,
        headers: Binding<String>
    ) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                fieldLabel(L("addplaylist.field.backup_url"))
                TextField(L("addplaylist.field.backup_url.placeholder"), text: backup)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .gateFieldStyle()
                Text(L("headers.backup.note"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 6) {
                fieldLabel(L("addplaylist.field.epg_url"))
                TextField(L("addplaylist.field.epg_url.placeholder"), text: epg)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .gateFieldStyle()
            }
            VStack(spacing: 6) {
                fieldLabel(L("headers.user_agent"))
                TextField(L("headers.user_agent.placeholder"), text: userAgent)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .gateFieldStyle()
            }
            VStack(spacing: 6) {
                fieldLabel(L("headers.custom"))
                TextField(L("headers.custom.placeholder"), text: headers, axis: .vertical)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(2...4)
                    .gateFieldStyle()
            }
        }
    }

    /// Trims an optional field to nil-when-empty for the model.
    private func optionalField(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Build 61 (Design-4): the M3U | Xtream segmented pill switch.
    private var segmentedTypeSwitch: some View {
        HStack(spacing: 4) {
            segmentButton(kind: .m3u, title: L("playlist_type.m3u.title"))
            segmentButton(kind: .xtream, title: L("playlist_type.xtream.title"))
        }
        .padding(4)
        .background(Capsule().fill(AppTheme.surface))
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func segmentButton(kind: FormKind, title: String) -> some View {
        let selected = formKind == kind
        return Button {
            formKind = kind
        } label: {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundColor(selected ? AppTheme.accent : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(selected ? AppTheme.background : Color.clear)
                )
                .overlay(
                    Capsule().strokeBorder(selected ? AppTheme.accent.opacity(0.65) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Small label above a field (round 14, B13). Build 61
    /// (Design-4): bold white, as in the mockup.
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline validation line under a bad field (round 14, B13).
    private func fieldError(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var xtreamForm: some View {
        VStack(spacing: 14) {
            // Round 14 (B13): "Paste all" — parses a pasted provider
            // message into the fields below.
            Button {
                pasteAll()
            } label: {
                Label(L("gate.paste_all"), systemImage: "doc.on.clipboard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.accent)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                fieldLabel(L("gate.field.name"))
                TextField(L("add_playlist.name_placeholder"), text: $xtreamName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .xtreamName)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .xtreamURL }
                    .gateFieldStyle()
            }

            VStack(spacing: 6) {
                fieldLabel(L("add_playlist.server_url"))
                // Paste button INSIDE the URL field (round 14, B13).
                HStack(spacing: 8) {
                    TextField(L("add_playlist.server_url"), text: $xtreamURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .xtreamURL)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .xtreamUsername }
                    Button {
                        if let clip = UIPasteboard.general.string, !clip.isEmpty {
                            xtreamURL = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Text(L("gate.paste"))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .gateFieldStyle()
                if xtreamURLInvalid {
                    fieldError(L("gate.validation.invalid_url"))
                }
            }

            VStack(spacing: 6) {
                fieldLabel(L("add_playlist.username"))
                TextField(L("add_playlist.username"), text: $xtreamUsername)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .xtreamUsername)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .xtreamPassword }
                    .gateFieldStyle()
            }

            VStack(spacing: 6) {
                fieldLabel(L("add_playlist.password"))
                // Secure field with a show/hide eye — the one affordance the
                // old form lacked; the value path is unchanged.
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
                    .focused($focusedField, equals: .xtreamPassword)
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("gate.toggle_password_visibility"))
                }
                .gateFieldStyle()
            }

            Toggle(isOn: $filterAdultContent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("add_playlist.filter_adult"))
                    Text(L("add_playlist.filter_adult.desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            connectionFields(backup: $xtreamBackupURL, epg: $xtreamEPGURL, userAgent: $xtreamUserAgent, headers: $xtreamHeadersText)

            submitButton(title: L("gate.sign_in"), enabled: canSaveXtream) {
                importTask = Task { await saveXtream() }
            }
        }
        .padding(16)
        .background(AppTheme.cardGradient, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var m3uForm: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                fieldLabel(L("gate.field.name"))
                TextField(L("add_m3u.name_placeholder"), text: $m3uName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .m3uName)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .m3uURL }
                    .gateFieldStyle()
            }

            VStack(spacing: 6) {
                fieldLabel(L("gate.field.playlist_url"))
                HStack(spacing: 8) {
                    TextField(L("add_m3u.url_placeholder"), text: $m3uURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .m3uURL)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .disabled(hasLocalFile)
                        .foregroundColor(hasLocalFile ? .secondary : .primary)
                    Button {
                        if let clip = UIPasteboard.general.string, !clip.isEmpty {
                            m3uURL = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Text(L("gate.paste"))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .gateFieldStyle()
                if m3uURLInvalid {
                    fieldError(L("gate.validation.invalid_url"))
                }
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Round 14 (B13): adult-filter toggle — parity with
            // the Xtream form.
            Toggle(isOn: $m3uFilterAdultContent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("add_playlist.filter_adult"))
                    Text(L("add_playlist.filter_adult.desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            connectionFields(backup: $m3uBackupURL, epg: $m3uEPGURL, userAgent: $m3uUserAgent, headers: $m3uHeadersText)

            // Design-4: the helper line under the M3U fields is
            // small accent text (the mockup's "Load your .m3u or
            // .m3u8 playlist").
            Text(L("add_m3u.section.source_footer"))
                .font(.caption.weight(.medium))
                .foregroundColor(AppTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)

            submitButton(title: L("gate.load_playlist"), enabled: canSaveM3U) {
                importTask = Task { await saveM3U() }
            }
        }
        .padding(16)
        .background(AppTheme.cardGradient, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func submitButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Design-4 primary button: big solid accent fill, BLACK
            // bold text (the mockup's Load Playlist / Connect).
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundColor(AppTheme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.accent)
                .cornerRadius(AppTheme.cornerRadius)
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    // MARK: - Round 15 (C13): continue-with, all-expired, QR scan

    /// The saved playlist the "Continue with" row points at: the
    /// one whose NAME was recorded at sign-out (name only).
    private var continueWithPlaylist: Playlist? {
        guard !lastPlaylistName.isEmpty else { return nil }
        return playlists.first(where: { $0.name == lastPlaylistName })
    }

    /// Round 17 (R17-5): the row now carries its own removal
    /// control — a trailing menu button AND a long-press context
    /// menu, both leading to the same confirmation, which runs
    /// the ONE shared deletion path (`AccountDataDeletion`) and
    /// returns the gate to the clean add-playlist state. Tapping
    /// the row itself still continues, exactly as before.
    private func continueWithRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundColor(AppTheme.accent)
            Text(L("gate.continue_with_format", playlist.name))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer()
            Menu {
                Button(role: .destructive) {
                    playlistPendingRemoval = playlist
                    showRemoveConfirmation = true
                } label: {
                    Label(L("gate.remove_account"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("gate.remove_account"))
        }
        .padding(14)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect(playlist) }
        .contextMenu {
            Button {
                onSelect(playlist)
            } label: {
                Label(L("gate.continue_with_format", playlist.name), systemImage: "play.circle")
            }
            Button(role: .destructive) {
                playlistPendingRemoval = playlist
                showRemoveConfirmation = true
            } label: {
                Label(L("gate.remove_account"), systemImage: "trash")
            }
        }
    }

    /// True only when every saved playlist is an Xtream playlist
    /// with a RECORDED expiry that has passed (the shared store's
    /// verdict). M3U playlists carry no expiry and never count.
    private var allSubscriptionsExpired: Bool {
        guard !playlists.isEmpty else { return false }
        return playlists.allSatisfy { playlist in
            playlist.kind == .xtream
                && ProviderExpiryStore.isExpired(expiryDate: ProviderExpiryStore.expiryDate(playlistId: playlist.id))
        }
    }

    private var allExpiredCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundColor(.orange)
            Text(L("gate.all_expired.title"))
                .font(.subheadline.weight(.bold))
            Text(L("gate.all_expired.message"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: - Help line (round 14, B13)

    private var helpLine: some View {
        Button {
            showHelp = true
        } label: {
            Text(L("gate.help.link"))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.accent)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Expired-account warning (round 14, B13)

    private var expiredWarningCard: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.orange)
                Text(L("gate.expired.title"))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(L("gate.expired.message", expiredDateText))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showExpiredWarning = false
                    guard let pendingEntry else { return }
                    self.pendingEntry = nil
                    switch pendingEntry {
                    case .xtream(let playlist, let client):
                        isLoading = true
                        progressMessage = L("add_playlist.verifying")
                        importTask = Task { await syncAndSaveXtream(newPlaylist: playlist, client: client) }
                    }
                } label: {
                    Text(L("gate.expired.enter_anyway"))
                        .font(.headline.weight(.bold))
                        .foregroundColor(AppTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.accent)
                        .cornerRadius(AppTheme.cornerRadius)
                }
                .buttonStyle(.plain)
                Button(L("common.cancel")) {
                    showExpiredWarning = false
                    pendingEntry = nil
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
            }
            .padding(24)
            .background(AppTheme.elevated)
            .cornerRadius(AppTheme.cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
            )
            .shadow(radius: 20)
            .padding(.horizontal, 32)
        }
    }

    /// After a successful verify: if the account is expired (the
    /// shared store's timestamp verdict on exp_date, or the panel's
    /// own status), park the entry behind the warning card instead
    /// of silently accepting it. Returns true when the warning was
    /// shown (the caller must NOT proceed).
    private func parkIfExpired(playlist: Playlist, client: XtreamAPIClient, response: XtreamAuthResponse) -> Bool {
        ProviderExpiryStore.record(playlistId: playlist.id, expDate: response.userInfo?.expDate)
        let statusExpired = response.userInfo?.status?.caseInsensitiveCompare("Expired") == .orderedSame
        let expired = ProviderExpiryStore.isExpired(expDateString: response.userInfo?.expDate) || statusExpired
        // Round 15 (C13): the verify outcome also feeds the
        // per-playlist health dot in My Playlists.
        PlaylistHealthStore.record(expired ? .expired : .responds, for: playlist.id)
        guard expired else {
            return false
        }
        pendingEntry = .xtream(playlist: playlist, client: client)
        if let expiry = ProviderExpiryStore.parseExpiryDate(response.userInfo?.expDate) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            expiredDateText = formatter.string(from: expiry)
        } else {
            expiredDateText = response.userInfo?.expDate ?? ""
        }
        isLoading = false
        progressMessage = nil
        showExpiredWarning = true
        return true
    }

    // MARK: - Explained errors (round 14, B13)

    /// Maps common failures to a plain-language cause + next step
    /// instead of surfacing raw `error.localizedDescription`.
    private func explainedError(for error: Error) -> String {
        if let xtreamError = error as? XtreamError {
            switch xtreamError {
            case .unauthenticated:
                return L("gate.error.auth")
            case .networkError:
                return L("gate.error.network")
            case .serverError, .decodingError:
                return L("gate.error.server")
            case .invalidURL:
                return L("gate.validation.invalid_url")
            }
        }
        if error is URLError {
            return L("gate.error.network")
        }
        return L("gate.error.generic")
    }

    // MARK: - Smart paste (round 14, B13)

    /// "Paste all": parses a pasted provider message — a get.php
    /// link (via the existing XtreamLinkDetector), or labeled /
    /// bare URL + username + password lines — and fills the Xtream
    /// fields. Only fields actually found are touched.
    private func pasteAll() {
        guard let raw = UIPasteboard.general.string, !raw.isEmpty else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // A get.php link anywhere in the message carries everything.
        for token in text.components(separatedBy: .whitespacesAndNewlines) {
            if let credentials = XtreamLinkDetector.detect(urlString: token) {
                xtreamURL = credentials.serverURL
                xtreamUsername = credentials.username
                xtreamPassword = credentials.password
                return
            }
        }
        // The whole pasted text may itself be a single get.php link.
        if let credentials = XtreamLinkDetector.detect(urlString: text) {
            xtreamURL = credentials.serverURL
            xtreamUsername = credentials.username
            xtreamPassword = credentials.password
            return
        }

        // Labeled lines ("URL: …", "Username: …", "Password: …")
        // and a bare URL token fallback.
        var foundURL: String?
        var foundUser: String?
        var foundPass: String?
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            let value = Self.valueAfterLabel(in: line)
            if lower.contains("pass") {
                if let value { foundPass = value }
            } else if lower.contains("user") {
                if let value { foundUser = value }
            } else if lower.contains("url") || lower.contains("server") || lower.contains("host") || lower.contains("portal") {
                if let value, Self.isValidServerURL(value) { foundURL = value }
            }
        }
        if foundURL == nil {
            for token in text.components(separatedBy: .whitespacesAndNewlines) where Self.isValidServerURL(token) {
                foundURL = token
                break
            }
        }
        if let foundURL { xtreamURL = foundURL }
        if let foundUser { xtreamUsername = foundUser }
        if let foundPass { xtreamPassword = foundPass }
    }

    /// The value part of a "Label: value" / "Label = value" line —
    /// the last whitespace-separated token after the separator.
    private static func valueAfterLabel(in line: String) -> String? {
        guard let separatorIndex = line.lastIndex(where: { $0 == ":" || $0 == "=" }) else { return nil }
        let rest = line[line.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return rest.components(separatedBy: .whitespaces).last
    }

    // MARK: - Validation (round 14, B13: trimmed + real URL check)

    /// A real URL-with-host check: http(s) scheme and a non-empty
    /// host — the check that enables Sign In.
    private static func isValidServerURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Inline-error condition for the Xtream URL: something was
    /// typed (beyond the untouched "http://" prefix) and it is not
    /// a valid server URL.
    private var xtreamURLInvalid: Bool {
        let trimmed = xtreamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "http://", trimmed != "https://" else { return false }
        return !Self.isValidServerURL(xtreamURL)
    }

    private var m3uURLInvalid: Bool {
        guard !hasLocalFile else { return false }
        let trimmed = m3uURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !Self.isValidServerURL(m3uURL)
    }

    private var canSaveXtream: Bool {
        !xtreamName.trimmingCharacters(in: .whitespaces).isEmpty
            && Self.isValidServerURL(xtreamURL)
            && !xtreamUsername.trimmingCharacters(in: .whitespaces).isEmpty
            && !xtreamPassword.isEmpty
            && !isLoading
    }

    /// AddM3UPlaylistView's new-playlist rule: trimmed name required;
    /// a picked file or a valid trimmed URL is enough.
    private var canSaveM3U: Bool {
        guard !m3uName.trimmingCharacters(in: .whitespaces).isEmpty, !isLoading else { return false }
        if hasLocalFile { return true }
        return Self.isValidServerURL(m3uURL)
    }

    // MARK: - Xtream save (new playlists, via the shared PlaylistSaveService)

    private func saveXtream() async {
        isLoading = true
        errorMessage = nil
        progressMessage = L("add_playlist.verifying")
        // Build 61 (B10, L1): the staged checklist starts with the
        // real verify below (connecting → verifying).
        resetStages()
        setStage(.connecting, .active)

        // A new playlist carries no EPG/timeshift state over — the same
        // values AddPlaylistView builds when `editingPlaylist == nil`.
        var newPlaylist = Playlist(
            name: xtreamName.trimmingCharacters(in: .whitespacesAndNewlines),
            serverURL: xtreamURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username: xtreamUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            password: xtreamPassword.trimmingCharacters(in: .whitespacesAndNewlines),
            filterAdultContent: filterAdultContent,
            epgURLOverride: optionalField(xtreamEPGURL),
            backupURL: optionalField(xtreamBackupURL),
            customUserAgent: optionalField(xtreamUserAgent),
            customHeadersJSON: Playlist.encodeCustomHeaders(Playlist.parseHeaderLines(xtreamHeadersText))
        )

        do {
            // Round 16 (F2): verify + timezone capture is the shared
            // PlaylistSaveService pipeline (identical to the edit
            // sheet's); the gate keeps its own dedupe + expiry
            // parking + direct-entry behavior below.
            let (response, client) = try await PlaylistSaveService.verifyXtream(playlist: &newPlaylist)
            guard !Task.isCancelled else { return }

            setStage(.connecting, .done)
            setStage(.verifying, .done)
            if response.userInfo?.auth == 1 {
                // Round 11: re-signing into an already-saved account
                // (same server + username) refreshes THAT record —
                // entered name/password/filter and the captured
                // timezone merged in — instead of inserting a
                // duplicate playlist.
                if let existing = playlists.first(where: {
                    $0.kind == .xtream
                        && $0.serverURL == newPlaylist.serverURL
                        && $0.username == newPlaylist.username
                }) {
                    var target = existing
                    target.name = newPlaylist.name
                    target.password = newPlaylist.password
                    target.filterAdultContent = newPlaylist.filterAdultContent
                    target.epgURLOverride = newPlaylist.epgURLOverride
                    target.backupURL = newPlaylist.backupURL
                    target.customUserAgent = newPlaylist.customUserAgent
                    target.customHeadersJSON = newPlaylist.customHeadersJSON
                    target.serverTimezone = newPlaylist.serverTimezone ?? existing.serverTimezone
                    let targetClient = XtreamAPIClient(playlist: target)
                    if parkIfExpired(playlist: target, client: targetClient, response: response) { return }
                    await syncAndSaveXtream(newPlaylist: target, client: targetClient)
                } else {
                    if parkIfExpired(playlist: newPlaylist, client: client, response: response) { return }
                    await syncAndSaveXtream(newPlaylist: newPlaylist, client: client)
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
            guard !Task.isCancelled else { return }
            await MainActor.run {
                errorMessage = explainedError(for: error)
                showError = true
                isLoading = false
                progressMessage = nil
                addStages = [:]
            }
        }
    }

    private func syncAndSaveXtream(newPlaylist: Playlist, client: XtreamAPIClient) async {
        // Build 61 (B10, L1): the content stages run with the real
        // importer; the guide stage and the Z1 probe follow, then
        // the L2 summary (Start Watching enters the app — the
        // round-11 direct-entry rule now lands via the summary).
        if addStages.isEmpty { resetStages(); setStage(.connecting, .done); setStage(.verifying, .done) }
        setStage(.loadingChannels, .active)
        do {
            // Build 63: bounded content import, same budget as the
            // service path (600 s) — a timeout surfaces as the
            // plain unreachable error instead of an endless stage.
            do {
                try await PlaylistValidationService.withStageTimeout(600) {
                    try await PlaylistSaveService.syncXtream(playlist: newPlaylist, client: client) { message in
                        self.progressMessage = message
                    }
                }
            } catch is PlaylistValidationService.StageTimeoutError {
                throw PlaylistValidationService.ValidationFailure.unreachable
            }
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.isLoading = false
                    self.progressMessage = nil
                    self.addStages = [:]
                }
                return
            }
            setStage(.loadingChannels, .done)
            setStage(.loadingMoviesSeries, .done)

            let compatibility = await PlaylistValidationService.probeCompatibility(playlist: newPlaylist)
            // Build 67 (coordinator, F5): the same bounded guide
            // stage as the service path (runAddFlowGuideStage) —
            // build 63's instant handoff marked the stage done
            // before a byte was fetched and hard-wired
            // guideFailed = false, so a stalled/failed guide could
            // never reach this summary. Now a timeout/failure is
            // the truthful L3 partial success and the load
            // continues in the background inside the helper.
            let guideFailed = await PlaylistValidationService.runAddFlowGuideStage(playlist: newPlaylist) { stage, state in
                self.setStage(stage, state)
            }
            let counts = await PlaylistValidationService.importedCounts(playlistId: newPlaylist.id, kind: .xtream)
            let expiry = ProviderExpiryStore.expiryDate(playlistId: newPlaylist.id)

            await MainActor.run {
                self.isLoading = false
                self.progressMessage = nil
                self.addStages = [:]
                self.addSummary = PlaylistValidationService.AddSummary(
                    playlist: newPlaylist,
                    expiryDate: expiry,
                    liveCount: counts.live, movieCount: counts.movies, seriesCount: counts.series,
                    failedStage: guideFailed ? .loadingGuide : nil,
                    compatibility: compatibility,
                    guideLoadingInBackground: guideFailed
                )
            }
        } catch {
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.isLoading = false
                    self.progressMessage = nil
                    self.addStages = [:]
                }
                return
            }
            await MainActor.run {
                self.errorMessage = explainedError(for: error)
                self.showError = true
                self.isLoading = false
                self.progressMessage = nil
                self.addStages = [:]
            }
        }
    }

    // MARK: - M3U save (new playlists, via the shared PlaylistSaveService)

    private func saveM3U() async {
        isLoading = true
        errorMessage = nil
        progressMessage = L("add_m3u.preparing")

        let trimmedURL = m3uURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = m3uName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Xtream-style get.php links get connected through the Xtream API
        // when possible — identical auto-detection to AddM3UPlaylistView
        // (new playlists only there too).
        if !hasLocalFile,
           let credentials = XtreamLinkDetector.detect(urlString: trimmedURL),
           await addAsXtream(credentials: credentials, name: trimmedName) {
            return
        }
        guard !Task.isCancelled else {
            isLoading = false
            progressMessage = nil
            return
        }

        var newPlaylist = Playlist(
            name: trimmedName,
            serverURL: hasLocalFile ? "" : trimmedURL,
            username: "",
            password: "",
            filterAdultContent: m3uFilterAdultContent,
            type: .m3u,
            m3uEpgURL: nil,
            epgURLOverride: optionalField(m3uEPGURL),
            backupURL: optionalField(m3uBackupURL),
            customUserAgent: optionalField(m3uUserAgent),
            customHeadersJSON: Playlist.encodeCustomHeaders(Playlist.parseHeaderLines(m3uHeadersText))
        )

        // Round 11: re-adding a URL that is already saved reuses the
        // existing record (same id, original creation date) instead
        // of inserting a duplicate playlist.
        if !hasLocalFile,
           let existing = playlists.first(where: { $0.kind == .m3u && $0.serverURL == trimmedURL }) {
            newPlaylist.id = existing.id
            newPlaylist.createdAt = existing.createdAt
        }

        // Build 61 (B10, Q17 + L1/L2/L3): the staged validation
        // service — probe (fetch + parse) BEFORE anything is
        // saved, the shared importer, the guide stage, the Z1
        // probe, then the summary. A failed probe saves nothing.
        resetStages()
        do {
            let summary = try await PlaylistValidationService.importM3U(
                playlist: newPlaylist,
                localContent: localContent
            ) { stage, state in
                self.setStage(stage, state)
            }
            guard !Task.isCancelled else {
                isLoading = false
                progressMessage = nil
                addStages = [:]
                return
            }

            await MainActor.run {
                self.isLoading = false
                self.progressMessage = nil
                self.addStages = [:]
                // Round 15 (C13): a successful load is a health
                // data point for My Playlists.
                PlaylistHealthStore.record(.responds, for: summary.playlist.id)
                // L2: the summary's Start Watching enters the app
                // with the saved playlist.
                self.addSummary = summary
            }
        } catch is CancellationError {
            isLoading = false
            progressMessage = nil
            addStages = [:]
            return
        } catch {
            guard !Task.isCancelled else {
                isLoading = false
                progressMessage = nil
                addStages = [:]
                return
            }
            await MainActor.run {
                // Q17: distinct plain failures from the probe
                // (bad URL / unreachable / empty) surface as-is.
                self.errorMessage = (error as? PlaylistValidationService.ValidationFailure)?.errorDescription
                    ?? explainedError(for: error)
                self.showError = true
                self.isLoading = false
                self.progressMessage = nil
                self.addStages = [:]
            }
        }
    }

    /// A detected get.php link connecting through the Xtream API —
    /// the shared PlaylistSaveService pipeline; success enters the
    /// app with the saved playlist (the gate's direct-entry rule).
    private func addAsXtream(credentials: XtreamLinkDetector.Credentials, name: String) async -> Bool {
        await MainActor.run { progressMessage = L("add_m3u.xtream_detected") }

        var playlist = Playlist(
            name: name,
            serverURL: credentials.serverURL,
            username: credentials.username,
            password: credentials.password,
            filterAdultContent: m3uFilterAdultContent,
            type: .xtream,
            epgURLOverride: optionalField(m3uEPGURL),
            backupURL: optionalField(m3uBackupURL),
            customUserAgent: optionalField(m3uUserAgent),
            customHeadersJSON: Playlist.encodeCustomHeaders(Playlist.parseHeaderLines(m3uHeadersText))
        )
        // Round 11: same no-duplicate rule as the Xtream form.
        if let existing = playlists.first(where: {
            $0.kind == .xtream
                && $0.serverURL == playlist.serverURL
                && $0.username == playlist.username
        }) {
            playlist.id = existing.id
            playlist.createdAt = existing.createdAt
        }
        let response: XtreamAuthResponse
        let client: XtreamAPIClient
        do {
            // Round 16 (F2): shared verify pipeline. This path
            // never captured the panel timezone onto the record,
            // so restore the field afterwards — the saved record
            // stays identical to the old inline copy's.
            let savedTimezone = playlist.serverTimezone
            (response, client) = try await PlaylistSaveService.verifyXtream(playlist: &playlist)
            playlist.serverTimezone = savedTimezone
        } catch {
            // get.php link without a working player_api — treat as a regular M3U link.
            return false
        }

        // Round 14 (B13): the expired-account warning applies here
        // too — a get.php sign-in is still a sign-in.
        if parkIfExpired(playlist: playlist, client: client, response: response) {
            return true
        }

        // Build 61 (B10): the staged finisher (content stages →
        // guide → Z1 → L2 summary) — the same end-of-add as the
        // Xtream form. A sync failure surfaces the error instead
        // of falling back, since get.php is likely blocked on
        // such panels anyway (syncAndSaveXtream shows it).
        await syncAndSaveXtream(newPlaylist: playlist, client: client)
        return true
    }

    // MARK: - File picker (mirrors AddM3UPlaylistView)

    private static var allowedFileTypes: [UTType] {
        var types: [UTType] = [.plainText, .data]
        if let m3u = UTType(filenameExtension: "m3u") { types.insert(m3u, at: 0) }
        if let m3u8 = UTType(filenameExtension: "m3u8") { types.insert(m3u8, at: 0) }
        return types
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            errorMessage = explainedError(for: err)
            showError = true
        case .success(let urls):
            guard let url = urls.first else { return }
            isLoading = true
            progressMessage = L("common.loading")
            importTask = Task {
                do {
                    let content = try await M3UService().readLocalAsync(url: url)
                    localContent = content
                    localFileName = url.lastPathComponent
                } catch {
                    errorMessage = explainedError(for: error)
                    showError = true
                }
                isLoading = false
                progressMessage = nil
            }
        }
    }
}

// MARK: - Gate help sheet (round 14, B13)

/// The "No sign-in details?" explainer: what the details are, where
/// they come from, and the SAME Privacy / Terms destinations the
/// Settings ▸ Privacy & Legal group uses (LegalDocumentView).
private struct GateHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("gate.help.body"))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)

                    NavigationLink {
                        LegalDocumentView(kind: .privacy)
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIconTile(systemImage: "hand.raised.fill", tint: .gray)
                            Text(L("settings.legal.privacy_policy"))
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    NavigationLink {
                        LegalDocumentView(kind: .terms)
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIconTile(systemImage: "doc.text.fill", tint: .gray)
                            Text(L("settings.legal.terms"))
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(AppTheme.background)
            .navigationTitle(L("gate.help.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
            }
        }
    }
}

#Preview {
    PlaylistGateView(
        playlists: [],
        onSelect: { _ in }
    )
    .preferredColorScheme(.dark)
}
