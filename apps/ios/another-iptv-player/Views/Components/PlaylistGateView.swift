import AVFoundation
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
// password) persisted across restarts via @AppStorage.
//
// Deliberately absent (the reference app's reseller layer, excluded by
// the owner): no device ID, no subscription check, no activation/support
// buttons, no demo mode. Every control on this screen does something real.

private enum GateFormField: Hashable {
    case xtreamName, xtreamURL, xtreamUsername, xtreamPassword
    case m3uName, m3uURL
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

    // M3U form state (name / URL also restart-persisted drafts).
    @AppStorage("gate.draft.m3u.name") private var m3uName = ""
    @AppStorage("gate.draft.m3u.url") private var m3uURL = ""
    @State private var m3uFilterAdultContent = false
    @State private var localFileName: String? = nil
    @State private var localContent: String? = nil
    @State private var showFileImporter = false

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

    // Round 15 (C13): QR sign-in + the sign-out "Continue with"
    // row. The name is NAME ONLY (written by ContentView at
    // sign-out) — no URL, no credentials ever touch this key.
    @AppStorage("gate.lastPlaylistName") private var lastPlaylistName = ""
    @State private var showScanner = false
    @State private var showScannerUnavailable = false

    // Round 17 (R17-5): removal of the saved account behind the
    // "Continue with" row — confirmation state + failure surface.
    @State private var playlistPendingRemoval: Playlist?
    @State private var showRemoveConfirmation = false
    @State private var showRemoveError = false

    private var hasLocalFile: Bool { localContent != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                // Round 15 (C13): "All subscriptions expired" —
                // an explicit line instead of blind-entering a
                // dead playlist; the add form below stays ready.
                if allSubscriptionsExpired {
                    allExpiredCard
                }

                // Round 15 (C13): after an explicit sign-out, one
                // discreet row back into the last playlist (name
                // only — tapping re-enters that saved record).
                if let last = continueWithPlaylist {
                    continueWithRow(last)
                }

                addSection

                helpLine
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
            // While a verify/import runs, the gate is inert — the analog
            // of the Add sheets' `interactiveDismissDisabled(isLoading)`.
            .disabled(isLoading)
        }
        .overlay {
            if isLoading {
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
        .sheet(isPresented: $showScanner) {
            QRScannerView(
                onScan: { scanned in
                    showScanner = false
                    handleScanned(scanned)
                },
                onClose: { showScanner = false }
            )
            .ignoresSafeArea()
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
        .alert(L("gate.qr.unavailable.title"), isPresented: $showScannerUnavailable) {
            Button(L("common.ok"), role: .cancel) { }
        } message: {
            Text(L("gate.qr.unavailable.message"))
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

    /// The REAL app icon from the bundle's primary-icon files
    /// (the asset catalog's AppIcon set, compiled into the app
    /// bundle) — nil only if the bundle metadata is missing, in
    /// which case the header falls back to an accent SX monogram.
    private var appIconImage: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }

    private var header: some View {
        VStack(spacing: 10) {
            // Round 14 (B13): the real app icon, ≈84 pt, rounded,
            // with a subtle accent glow — ALWAYS in the header,
            // including the signed-out path.
            Group {
                if let appIconImage {
                    Image(uiImage: appIconImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(AppTheme.accent)
                        Text("SX")
                            .font(.system(size: 34, weight: .black))
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: AppTheme.accent.opacity(0.45), radius: 14, x: 0, y: 6)
            .padding(.bottom, 2)

            // Typographic wordmark — no invented logo artwork. Round 5
            // elite alignment: bigger, black weight, tight tracking — the
            // bold confident type of the approved Home/Movies pictures.
            HStack(spacing: 4) {
                Text("Super")
                Text("X")
                    .foregroundColor(AppTheme.accent)
            }
            .font(.system(size: 44, weight: .black))
            .tracking(-0.5)
            .foregroundStyle(.white)

            Text(L("gate.welcome"))
                .font(.subheadline)
                .foregroundColor(.secondary)

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
            Text(L("playlist_type.title"))
                .font(.title2.weight(.bold))

            // Round 14 (B13): two radio cards showing the EXISTING
            // subtitle strings, so a newcomer sees the difference.
            HStack(spacing: 12) {
                typeCard(
                    kind: .xtream,
                    title: L("playlist_type.xtream.title"),
                    subtitle: L("playlist_type.xtream.subtitle"),
                    systemImage: "tv"
                )
                typeCard(
                    kind: .m3u,
                    title: L("playlist_type.m3u.title"),
                    subtitle: L("playlist_type.m3u.subtitle"),
                    systemImage: "list.bullet"
                )
            }

            // Round 15 (C13): QR sign-in — the scan feeds the
            // existing XtreamLinkDetector / smart-paste parser
            // (see `handleScanned`). Devices without a usable
            // camera get the graceful unavailable path instead.
            Button {
                // Round 17 (R17-1): the scanner is now the app's
                // own AVCaptureSession scanner — the only gate is
                // a physical camera; authorization is handled
                // inside the scanner (denied shows a message,
                // never a black screen).
                if AVCaptureDevice.default(for: .video) != nil {
                    showScanner = true
                } else {
                    showScannerUnavailable = true
                }
            } label: {
                Label(L("gate.qr.scan"), systemImage: "qrcode.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.accent)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

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
    }

    private func typeCard(kind: FormKind, title: String, subtitle: String, systemImage: String) -> some View {
        let selected = formKind == kind
        return Button {
            formKind = kind
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundColor(selected ? AppTheme.accent : .secondary)
                    Spacer()
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.body)
                        .foregroundColor(selected ? AppTheme.accent : .secondary)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .strokeBorder(selected ? AppTheme.accent : Color.white.opacity(0.06), lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Small label above a field (round 14, B13).
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
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
                    .padding(12)
                    .background(AppTheme.elevated)
                    .cornerRadius(AppTheme.cornerRadius)
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
                .padding(12)
                .background(AppTheme.elevated)
                .cornerRadius(AppTheme.cornerRadius)
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
                    .padding(12)
                    .background(AppTheme.elevated)
                    .cornerRadius(AppTheme.cornerRadius)
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
                .padding(12)
                .background(AppTheme.elevated)
                .cornerRadius(AppTheme.cornerRadius)
            }

            Toggle(isOn: $filterAdultContent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("add_playlist.filter_adult"))
                    Text(L("add_playlist.filter_adult.desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            submitButton(title: L("gate.sign_in"), enabled: canSaveXtream) {
                importTask = Task { await saveXtream() }
            }
        }
        .padding(16)
        .background(AppTheme.surface)
        .cornerRadius(AppTheme.cornerRadius)
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
                    .padding(12)
                    .background(AppTheme.elevated)
                    .cornerRadius(AppTheme.cornerRadius)
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
                .padding(12)
                .background(AppTheme.elevated)
                .cornerRadius(AppTheme.cornerRadius)
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

            Text(L("add_m3u.section.source_footer"))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            submitButton(title: L("gate.load_playlist"), enabled: canSaveM3U) {
                importTask = Task { await saveM3U() }
            }
        }
        .padding(16)
        .background(AppTheme.surface)
        .cornerRadius(AppTheme.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func submitButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
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

    /// Routes a scanned string through the EXISTING parsers: a
    /// get.php link goes to XtreamLinkDetector and fills the Xtream
    /// form; a plain playlist URL fills the M3U form; anything else
    /// is handed to the smart-paste parser via the pasteboard it
    /// already reads.
    private func handleScanned(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let credentials = XtreamLinkDetector.detect(urlString: text) {
            formKind = .xtream
            xtreamURL = credentials.serverURL
            xtreamUsername = credentials.username
            xtreamPassword = credentials.password
            return
        }
        if Self.isValidServerURL(text), !text.contains(" ") {
            formKind = .m3u
            m3uURL = text
            return
        }
        formKind = .xtream
        UIPasteboard.general.string = text
        pasteAll()
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
                        .font(.headline)
                        .foregroundColor(.white)
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

        // A new playlist carries no EPG/timeshift state over — the same
        // values AddPlaylistView builds when `editingPlaylist == nil`.
        var newPlaylist = Playlist(
            name: xtreamName.trimmingCharacters(in: .whitespacesAndNewlines),
            serverURL: xtreamURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username: xtreamUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            password: xtreamPassword.trimmingCharacters(in: .whitespacesAndNewlines),
            filterAdultContent: filterAdultContent
        )

        do {
            // Round 16 (F2): verify + timezone capture is the shared
            // PlaylistSaveService pipeline (identical to the edit
            // sheet's); the gate keeps its own dedupe + expiry
            // parking + direct-entry behavior below.
            let (response, client) = try await PlaylistSaveService.verifyXtream(playlist: &newPlaylist)
            guard !Task.isCancelled else { return }

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
            }
        }
    }

    private func syncAndSaveXtream(newPlaylist: Playlist, client: XtreamAPIClient) async {
        do {
            try await PlaylistSaveService.syncXtream(playlist: newPlaylist, client: client) { message in
                self.progressMessage = message
            }
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.isLoading = false
                    self.progressMessage = nil
                }
                return
            }

            await MainActor.run {
                self.isLoading = false
                self.progressMessage = nil
                // Round 11: sign-in completes by ENTERING the app
                // with the saved playlist — the gate no longer has a
                // saved list to fall back to. The importer upserted
                // this very struct, so its id is the saved record's.
                self.onSelect(newPlaylist)
            }
        } catch {
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.isLoading = false
                    self.progressMessage = nil
                }
                return
            }
            await MainActor.run {
                self.errorMessage = explainedError(for: error)
                self.showError = true
                self.isLoading = false
                self.progressMessage = nil
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
            m3uEpgURL: nil
        )

        // Round 11: re-adding a URL that is already saved reuses the
        // existing record (same id, original creation date) instead
        // of inserting a duplicate playlist.
        if !hasLocalFile,
           let existing = playlists.first(where: { $0.kind == .m3u && $0.serverURL == trimmedURL }) {
            newPlaylist.id = existing.id
            newPlaylist.createdAt = existing.createdAt
        }

        do {
            // Round 16 (F2): fetch → parse → replace is the shared
            // PlaylistSaveService pipeline (identical to the edit
            // sheet's), with the gate's between-steps cancellation
            // checks preserved inside it.
            try await PlaylistSaveService.importM3U(
                playlist: newPlaylist,
                localContent: localContent,
                remoteURLString: trimmedURL,
                clearServerURL: hasLocalFile,
                checkCancellation: true
            ) { message in
                self.progressMessage = message
            }
            guard !Task.isCancelled else {
                isLoading = false
                progressMessage = nil
                return
            }

            await MainActor.run {
                self.isLoading = false
                self.progressMessage = nil
                // Round 15 (C13): a successful load is a health
                // data point for My Playlists.
                PlaylistHealthStore.record(.responds, for: newPlaylist.id)
                // Round 11: enter the app with the saved playlist
                // (same direct-entry rule as the Xtream flow).
                self.onSelect(newPlaylist)
            }
        } catch is CancellationError {
            // The pipeline's between-steps cancellation check —
            // the old inline copy reset silently here too.
            isLoading = false
            progressMessage = nil
            return
        } catch {
            guard !Task.isCancelled else {
                isLoading = false
                progressMessage = nil
                return
            }
            await MainActor.run {
                self.errorMessage = explainedError(for: error)
                self.showError = true
                self.isLoading = false
                self.progressMessage = nil
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
            type: .xtream
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

        do {
            try await PlaylistSaveService.syncXtream(playlist: playlist, client: client) { message in
                self.progressMessage = message
            }
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.isLoading = false
                    self.progressMessage = nil
                }
                return true
            }
            await MainActor.run {
                self.isLoading = false
                self.progressMessage = nil
                self.onSelect(playlist)
            }
        } catch {
            // Account verified but sync failed: surface the error instead of falling
            // back, since get.php is likely blocked on such panels anyway.
            await MainActor.run {
                self.errorMessage = explainedError(for: error)
                self.showError = true
                self.isLoading = false
                self.progressMessage = nil
            }
        }
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

// MARK: - QR scanner (round 15, C13; rebuilt round 17, R17-1)

/// QR sign-in scanner. Round 17 (R17-1): the VisionKit
/// `DataScannerViewController` version rendered a BLACK screen on
/// the owner's phone — its only start call sat in
/// `updateUIViewController` (`try? startScanning()`), which fires
/// before the controller is in a window / before camera
/// authorization settles; the throw was swallowed by `try?` and
/// nothing ever retried, leaving the system's "Find nearby text
/// or barcodes." guidance line over a dead preview. It also only
/// delivered a value on a user TAP (`didTapOn`).
///
/// The scanner is now the app's own `AVCaptureSession` pipeline,
/// where every step is explicit and observable:
/// - authorization is checked/requested FIRST; denied or
///   restricted shows a real message screen (icon + text + close),
///   never a black preview;
/// - the session is configured on a background queue and the
///   preview layer is bound in `viewDidLoad` and re-framed on
///   every layout pass, so the camera feed is actually visible;
/// - scanning starts in `viewDidAppear` (a live window) and stops
///   in `viewDidDisappear`;
/// - the first QR the metadata output recognizes is delivered
///   automatically — no tap on the code required.
private struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        controller.onClose = onClose
        return controller
    }

    func updateUIViewController(_ controller: QRScannerViewController, context: Context) {}
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "superx.qr-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var didDeliver = false

    private let hintLabel = UILabel()
    private let messageStack = UIStackView()
    private let messageIcon = UIImageView()
    private let messageLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.05, alpha: 1)

        // Hint pill at the bottom — visible over the live preview.
        hintLabel.text = L("gate.qr.hint")
        hintLabel.font = .preferredFont(forTextStyle: .subheadline)
        hintLabel.textColor = .white
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        hintLabel.layer.cornerRadius = 12
        hintLabel.layer.masksToBounds = true
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        // Close — always reachable, scanning or not.
        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        // Denied / unavailable message (hidden unless needed):
        // an icon + wrapped text on the dark background — the
        // explicit alternative to the old black screen.
        messageIcon.image = UIImage(systemName: "video.slash.fill")
        messageIcon.tintColor = .white
        messageIcon.contentMode = .scaleAspectFit
        messageIcon.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .white
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageStack.axis = .vertical
        messageStack.alignment = .center
        messageStack.spacing = 14
        messageStack.addArrangedSubview(messageIcon)
        messageStack.addArrangedSubview(messageLabel)
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        messageStack.isHidden = true
        view.addSubview(messageStack)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 34),
            closeButton.heightAnchor.constraint(equalToConstant: 34),
            hintLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            messageIcon.widthAnchor.constraint(equalToConstant: 44),
            messageIcon.heightAnchor.constraint(equalToConstant: 44),
            messageStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            messageStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
            messageStack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        requestAuthorizationAndConfigure()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSessionIfReady()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    @objc private func closeTapped() {
        onClose?()
    }

    // MARK: Authorization + configuration

    private func requestAuthorizationAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureSession()
                } else {
                    DispatchQueue.main.async { self.showMessage(
                        title: L("gate.qr.denied.title"),
                        body: L("gate.qr.denied.message")
                    ) }
                }
            }
        case .denied, .restricted:
            showMessage(title: L("gate.qr.denied.title"), body: L("gate.qr.denied.message"))
        @unknown default:
            showMessage(title: L("gate.qr.unavailable.title"), body: L("gate.qr.unavailable.message"))
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            var configured = false
            if let device = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                let output = AVCaptureMetadataOutput()
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    if output.availableMetadataObjectTypes.contains(.qr) {
                        output.metadataObjectTypes = [.qr]
                        configured = true
                    }
                }
            }
            self.session.commitConfiguration()
            guard configured else {
                DispatchQueue.main.async {
                    self.showMessage(title: L("gate.qr.unavailable.title"), body: L("gate.qr.unavailable.message"))
                }
                return
            }
            self.isConfigured = true
            DispatchQueue.main.async {
                let preview = AVCaptureVideoPreviewLayer(session: self.session)
                preview.videoGravity = .resizeAspectFill
                preview.frame = self.view.bounds
                self.view.layer.insertSublayer(preview, at: 0)
                self.previewLayer = preview
                if self.view.window != nil { self.startSessionIfReady() }
            }
        }
    }

    private func startSessionIfReady() {
        guard isConfigured, !didDeliver else { return }
        let session = self.session
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
        }
    }

    private func showMessage(title: String, body: String) {
        hintLabel.isHidden = true
        messageLabel.text = "\(title)\n\n\(body)"
        messageStack.isHidden = false
    }

    // MARK: AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didDeliver,
              let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              object.type == .qr,
              let value = object.stringValue,
              !value.isEmpty
        else { return }
        didDeliver = true
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
        onScan?(value)
    }
}

#Preview {
    PlaylistGateView(
        playlists: [],
        onSelect: { _ in }
    )
    .preferredColorScheme(.dark)
}
