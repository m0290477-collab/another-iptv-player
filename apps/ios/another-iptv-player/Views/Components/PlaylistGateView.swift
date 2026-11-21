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

struct PlaylistGateView: View {
    /// The saved playlists — used ONLY to recognize a re-sign-in to
    /// an already-saved account (no list is rendered from it).
    let playlists: [Playlist]
    let onSelect: (Playlist) -> Void

    private enum FormKind: Hashable {
        case xtream, m3u
    }

    @State private var formKind: FormKind = .xtream
    /// Build 87 (per-surface motion): the segmented control's
    /// sliding selection pill + the paste highlight sweep.
    @Namespace private var segmentNamespace
    @State private var pasteFlash: Set<String> = []
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

    /// Build 87 (owner flow, corrected 2026-11-20): the add
    /// flow's phase ON THIS SCREEN — after Connect the form
    /// transitions IN PLACE to the loading state (live
    /// counters), then a brief completion state, then the app
    /// enters Home automatically. No modal progress sheet and
    /// no success sheet (both superseded by this flow).
    private enum ImportPhase: Equatable { case form, loading, completed, failed }
    @State private var importPhase: ImportPhase = .form
    @State private var importFailure: String?
    /// Live counters for the loading state — refreshed from
    /// the database at a throttled ~0.8 s cadence while the
    /// import runs (never per inserted row).
    @State private var liveCounts: (live: Int, movies: Int, series: Int) = (0, 0, 0)
    @State private var importTargetId: UUID?
    @State private var importTargetKind: PlaylistKind = .xtream
    /// The provider expiry for the loading header's chip —
    /// read from the same store the summary reads (recorded
    /// at verify); nil for sources that carry none.
    @State private var importExpiry: Date?
    /// The active timeline card's subtle pulse driver.
    @State private var importPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if importPhase == .form {
                    // Round 15 (C13): "All subscriptions expired" —
                    // an explicit line instead of blind-entering a
                    // dead playlist; the add form below stays ready.
                    if allSubscriptionsExpired {
                        allExpiredCard
                    }

                    // Build 87 (design 1): the compact header over
                    // the grouped form card, on the flat charcoal
                    // ground — no frosted card, no blurred backdrop.
                    header
                    addSection

                    // Round 15 (C13): after an explicit sign-out,
                    // one discreet row back into the last playlist
                    // (name only — tapping re-enters that record).
                    if let last = continueWithPlaylist {
                        continueWithRow(last)
                    }

                    helpLine
                } else {
                    // Build 87: the import states replace the
                    // form IN PLACE on this same screen.
                    importStateView
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
            // While a verify runs on the FORM the gate is inert
            // (the analog of the Add sheets'
            // `interactiveDismissDisabled(isLoading)`); the
            // import states stay interactive (Cancel / Retry).
            .disabled(isLoading && importPhase == .form)
        }
        .background(AppTheme.background)
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
        VStack(spacing: 6) {
            // Build 87 (owner-picked design 1, 'Apple-clean
            // form'): the compact brand lockup — small flame-X
            // and the wordmark on ONE line, the subtitle under
            // it in the accent. ("Super X Pro Max" stays a
            // DISPLAY string only, as everywhere.)
            HStack(spacing: 7) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(AppTheme.brandGradient)
                HStack(spacing: 3) {
                    Text("Super")
                        .foregroundStyle(.white)
                    Text("X")
                        .foregroundStyle(AppTheme.brandGradient)
                    Text("Pro Max")
                        .foregroundStyle(.white)
                }
                .font(.system(size: 21, weight: .black))
                .tracking(-0.5)
            }

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

    // MARK: - Build 87 import states (in place — no sheets)

    /// The loading mockup's lockup: flame + wordmark +
    /// subtitle, left-aligned over the state card.
    private var importLockup: some View {
        HStack(spacing: 10) {
            Image(systemName: "flame.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(AppTheme.brandGradient)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text("Super")
                        .foregroundStyle(.white)
                    Text("X")
                        .foregroundStyle(AppTheme.brandGradient)
                    Text("Pro Max")
                        .foregroundStyle(.white)
                }
                .font(.system(size: 20, weight: .black))
                .tracking(-0.5)
                Text(L("gate.subtitle"))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.accent)
            }
            Spacer()
        }
    }

    private var importStateView: some View {
        Group {
            switch importPhase {
            case .loading:
                importLoadingView
            case .completed:
                VStack(spacing: 22) {
                    importLockup
                    importCompletedView
                }
            case .failed:
                VStack(spacing: 22) {
                    importLockup
                    importFailedView
                }
            case .form:
                EmptyView()
            }
        }
        .animation(Motion.animate(.easeInOut(duration: 0.3)), value: importPhase)
    }

    private var importingName: String {
        (formKind == .xtream ? xtreamName : m3uName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stageState(_ stage: PlaylistValidationService.Stage) -> PlaylistValidationService.StageState {
        addStages[stage] ?? .pending
    }

    private var currentImportStage: PlaylistValidationService.Stage {
        let all = PlaylistValidationService.Stage.allCases.sorted { $0.rawValue < $1.rawValue }
        return all.first { stageState($0) == .active }
            ?? all.first { stageState($0) == .failed }
            ?? all.first { stageState($0) == .pending }
            ?? all.last!
    }

    /// Movies finish inside the shared movies/series stage:
    /// once series rows start landing, Movies reads Done.
    private var moviesStepState: PlaylistValidationService.StageState {
        let s = stageState(.loadingMoviesSeries)
        if s == .active && liveCounts.series > 0 { return .done }
        return s
    }

    private var seriesStepState: PlaylistValidationService.StageState {
        let s = stageState(.loadingMoviesSeries)
        if s == .active && liveCounts.series == 0 { return .pending }
        return s
    }

    private func counterChip(icon: String, label: String, value: Int) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.title3.weight(.black))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Timeline loading state (owner-approved design)

    private enum TimelineState: Equatable { case done, active, waiting, failed }

    private struct TimelineStep {
        let title: String
        let state: TimelineState
        let count: Int
        let countText: String
        let isChecking: Bool
    }

    private func timelineState(of stage: PlaylistValidationService.StageState) -> TimelineState {
        switch stage {
        case .done: return .done
        case .active: return .active
        case .failed: return .failed
        case .pending: return .waiting
        }
    }

    /// The stream check is the import's final phase: it runs
    /// after both content stages complete (the probe the old
    /// summary reported), so it reads active exactly while
    /// every content stage is done and the import still runs.
    private var checkingStepState: TimelineState {
        if stageState(.loadingChannels) == .failed || stageState(.loadingMoviesSeries) == .failed {
            return .failed
        }
        if stageState(.loadingChannels) == .done && stageState(.loadingMoviesSeries) == .done {
            return .active
        }
        return .waiting
    }

    private var timelineSteps: [TimelineStep] {
        [
            TimelineStep(title: L("dashboard.live"), state: timelineState(of: stageState(.loadingChannels)),
                         count: liveCounts.live, countText: L("addplaylist.summary.live", liveCounts.live), isChecking: false),
            TimelineStep(title: L("dashboard.movies"), state: timelineState(of: moviesStepState),
                         count: liveCounts.movies, countText: L("addplaylist.summary.movies", liveCounts.movies), isChecking: false),
            TimelineStep(title: L("dashboard.series"), state: timelineState(of: seriesStepState),
                         count: liveCounts.series, countText: L("addplaylist.summary.series", liveCounts.series), isChecking: false),
            TimelineStep(title: L("gate.import.checking_streams"), state: checkingStepState,
                         count: 0, countText: "", isChecking: true),
        ]
    }

    /// HONEST overall percentage (the owner's rule): six
    /// units — connecting, verifying, Live TV, Movies, Series
    /// and the stream check. A unit counts ONLY when it has
    /// actually completed; the importer publishes no
    /// intra-stage fraction, so the % advances by stage
    /// completion alone — never a fabricated smooth value.
    private var overallPercent: Int {
        var done = 0
        if stageState(.connecting) == .done { done += 1 }
        if stageState(.verifying) == .done { done += 1 }
        for step in timelineSteps where step.state == .done { done += 1 }
        return Int((Double(done) / 6.0 * 100).rounded())
    }

    private var importTimelineHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.surface)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(AppTheme.brandGradient)
                }
                .frame(width: 52, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AppTheme.cardBorderColor, lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(L("addplaylist.progress.title"))
                        .font(.title3.weight(.black))
                        .lineLimit(1)

                    // Playlist chip: the name, plus the
                    // provider expiry when the payload
                    // provided one (recorded at verify).
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .font(.caption2.weight(.semibold))
                        if let expiry = importExpiry {
                            Text("\(importingName) · \(L("gate.import.expires", expiry.formatted(date: .abbreviated, time: .omitted)))")
                        } else {
                            Text(importingName)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.accent.opacity(0.12), in: Capsule())
                    .lineLimit(1)
                }

                Spacer()

                Text("\(overallPercent)%")
                    .font(.system(size: 30, weight: .black))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            // The thin overall line — the same honest fraction.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 3)
                    Capsule()
                        .fill(AppTheme.accent)
                        .frame(width: proxy.size.width * Double(overallPercent) / 100, height: 3)
                }
            }
            .frame(height: 3)
            .animation(Motion.animate(.easeInOut(duration: 0.4)), value: overallPercent)
        }
    }

    private func timelineNode(_ step: TimelineStep) -> some View {
        Group {
            switch step.state {
            case .done:
                ZStack {
                    Circle().fill(Color.green)
                    CheckDrawView()
                        .frame(width: 22, height: 22)
                }
            case .active:
                BrandedLoader(size: 30)
            case .failed:
                ZStack {
                    Circle().fill(Color.orange.opacity(0.2))
                    Image(systemName: "exclamationmark")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.orange)
                }
            case .waiting:
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1.5)
                    if step.isChecking {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: 44, height: 44)
        .id(step.state)
        .transition(.scale.combined(with: .opacity))
    }

    private func timelineRow(index: Int, step: TimelineStep) -> some View {
        let isActive = step.state == .active
        let nodeCenter: CGFloat = isActive ? 36 : 22
        return HStack(alignment: .top, spacing: 14) {
            // Node column: the line runs the row's full
            // height; its colour boundary sits exactly at
            // the node's centre. The line is accent up to
            // and through the current step, gray after.
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(index == 0 ? Color.clear
                              : (timelineSteps[index - 1].state == .done || timelineSteps[index - 1].state == .active
                                 ? AppTheme.accent : Color.white.opacity(0.12)))
                        .frame(width: 2.5, height: nodeCenter)
                    Rectangle()
                        .fill(index == timelineSteps.count - 1 ? Color.clear
                              : (step.state == .done || step.state == .active
                                 ? AppTheme.accent : Color.white.opacity(0.12)))
                        .frame(width: 2.5)
                }
                .frame(minWidth: 2.5, maxWidth: 2.5, maxHeight: .infinity)

                timelineNode(step)
                    .padding(.top, isActive ? 14 : 0)
            }
            .frame(minWidth: 44, maxWidth: 44, maxHeight: .infinity)
            .animation(Motion.animate(.easeInOut(duration: 0.4)), value: step.state)

            if isActive {
                activeStepContent(step)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(step.title)
                            .font(.body.weight(.bold))
                            .foregroundStyle(step.state == .waiting ? .secondary : .primary)
                        Spacer()
                        if step.state == .done {
                            Text(L("addplaylist.stage.state.done"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                        } else if step.state == .failed {
                            Text(L("addplaylist.stage.state.failed"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(step.state == .done ? step.countText
                         : step.state == .failed ? L("addplaylist.stage.state.failed")
                         : L("addplaylist.stage.state.pending"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, isActive ? 14 : 2)
        .padding(.vertical, isActive ? 8 : 10)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(AppTheme.accent.opacity(0.45), lineWidth: 1)
                    )
                    .shadow(color: AppTheme.accent.opacity(importPulse ? 0.28 : 0.14), radius: 14)
            }
        }
        .animation(Motion.animate(.easeInOut(duration: 2.4)), value: importPulse)
    }

    private func activeStepContent(_ step: TimelineStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(step.title)
                    .font(.body.weight(.black))
                Text(L("gate.import.current"))
                    .font(.caption2.weight(.black))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppTheme.accent.opacity(0.22), in: Capsule())
            }

            if step.isChecking {
                Text(L("gate.import.checking_note"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(progressMessage ?? L(currentImportStage.titleKey))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.accent)
                    Text("\(step.count.formatted()) \(L("gate.import.so_far"))")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                // Activity bar — indeterminate BY DESIGN:
                // the importer publishes no intra-stage
                // fraction, so this bar signals activity
                // only, never a percentage.
                IndeterminateBar()
            }
        }
        .padding(.vertical, 10)
    }

    private var importLoadingView: some View {
        VStack(spacing: 20) {
            importTimelineHeader

            VStack(spacing: 0) {
                ForEach(Array(timelineSteps.enumerated()), id: \.offset) { index, step in
                    timelineRow(index: index, step: step)
                }
            }

            Text(L("gate.import.auto_enter"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            // Cancel stays available throughout the loading
            // (the old sheet's cancel semantics exactly).
            Button {
                cancelImport()
            } label: {
                Text(L("common.cancel"))
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AppTheme.cardBorderColor, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .task(id: importTargetId) {
            // Throttled live counters: ONE count read per
            // ~0.8 s while this state is on screen — never a
            // per-row update, so the import can't jank the UI.
            // The expiry chip refreshes on the same cadence.
            while !Task.isCancelled {
                if let id = importTargetId {
                    liveCounts = await PlaylistValidationService.importedCounts(
                        playlistId: id, kind: importTargetKind
                    )
                    importExpiry = ProviderExpiryStore.expiryDate(playlistId: id)
                }
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
        .onAppear {
            // The current card's very subtle pulse — gated
            // like every heavy effect (stilled by Reduce
            // Motion / the Q21 reduce-effects flag).
            if EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion) {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    importPulse = true
                }
            }
        }
    }

    private var importCompletedView: some View {
        VStack(spacing: 18) {
            if let summary = addSummary {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        AnimatedCheckView(size: 26)
                            .onAppear { Haptics.success() }
                        Text(L("addplaylist.summary.title"))
                            .font(.headline)
                    }

                    Text(summary.playlist.name)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)

                    HStack(spacing: 10) {
                        counterChip(icon: "tv", label: L("dashboard.live"), value: summary.liveCount)
                        counterChip(icon: "film", label: L("dashboard.movies"), value: summary.movieCount)
                        counterChip(icon: "rectangle.stack", label: L("dashboard.series"), value: summary.seriesCount)
                    }

                    // The old summary's real lines, kept: the
                    // provider expiry (only when the payload
                    // carries one) and the sampled-streams
                    // result, with the free note as small print.
                    if let expiry = summary.expiryDate {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar.badge.clock")
                                .foregroundStyle(.secondary)
                            Text(L("addplaylist.summary.expiry", expiry.formatted(date: .abbreviated, time: .omitted)))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let compat = summary.compatibility {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundStyle(.secondary)
                                Text(L("addplaylist.summary.compatibility", compat.reachable, compat.sampled))
                                    .font(.subheadline)
                            }
                            Text(L("addplaylist.summary.compatibility.method"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(L("addplaylist.summary.provider_note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(AppTheme.cardBorderColor, lineWidth: 1)
                )
            }
        }
        .task(id: addSummary?.playlist.id) {
            // A brief completion moment (~2 s), then Home —
            // automatically, no tap (the owner's flow).
            try? await Task.sleep(for: .seconds(2))
            guard importPhase == .completed, let summary = addSummary else { return }
            addSummary = nil
            addStages = [:]
            importPhase = .form
            onSelect(summary.playlist)
        }
    }

    private var importFailedView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.orange)
                Text(importFailure ?? L("common.unknown_error"))
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(AppTheme.cardBorderColor, lineWidth: 1)
            )

            Button {
                importFailure = nil
                importPhase = .loading
                if formKind == .xtream {
                    importTask = Task { await saveXtream() }
                } else {
                    importTask = Task { await saveM3U() }
                }
            } label: {
                Text(L("common.retry"))
                    .font(.headline.weight(.bold))
                    .foregroundColor(AppTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                importFailure = nil
                importPhase = .form
            } label: {
                Text(L("gate.import.back"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// The old progress sheet's cancel, unchanged: cancel the
    /// task and reset the add state — plus return to the form.
    private func cancelImport() {
        importTask?.cancel()
        importTask = nil
        isLoading = false
        progressMessage = nil
        addStages = [:]
        liveCounts = (0, 0, 0)
        importTargetId = nil
        importExpiry = nil
        importPhase = .form
    }

    // MARK: - Add form (radio-card Xtream / M3U choice)

    private var addSection: some View {
        VStack(spacing: 16) {
            // Build 87 (design 1): ONE grouped rounded card in
            // iOS Settings style — the segmented type switch at
            // its top, then the active form's hairline rows.
            // Every field, binding and action below is the
            // existing one; only the presentation changed.
            VStack(spacing: 0) {
                segmentedTypeSwitch
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                gateHairline
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
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(AppTheme.cardBorderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            // Design 1: the Connect/Add button is a full-width
            // accent pill BELOW the card — the forms' existing
            // submit actions and enablement, unchanged.
            if formKind == .xtream {
                submitButton(title: L("gate.sign_in"), enabled: canSaveXtream) {
                    importTask = Task { await saveXtream() }
                }
            } else {
                submitButton(title: L("gate.load_playlist"), enabled: canSaveM3U) {
                    importTask = Task { await saveM3U() }
                }
            }
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

    /// Build 61 (B10): the optional connection-fields group shared
    /// by both gate forms (Q18 backup URL, G4 custom EPG URL,
    /// G2 User-Agent + custom headers).
    /// Build 87 (design 1): the connection-extras fields as
    /// grouped rows in the same card — labels carry their
    /// "(optional)" suffixes, values right-aligned. Same
    /// bindings and placeholders as the boxed fields they
    /// replace.
    private func connectionFields(
        backup: Binding<String>,
        epg: Binding<String>,
        userAgent: Binding<String>,
        headers: Binding<String>
    ) -> some View {
        VStack(spacing: 0) {
            gateRow(label: L("addplaylist.field.backup_url"), labelWidth: 150) {
                TextField(L("addplaylist.field.backup_url.placeholder"), text: backup)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
            }
            Text(L("headers.backup.note"))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            gateHairline

            gateRow(label: L("addplaylist.field.epg_url"), labelWidth: 150) {
                TextField(L("addplaylist.field.epg_url.placeholder"), text: epg)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
            }

            gateHairline

            gateRow(label: L("headers.user_agent"), labelWidth: 150) {
                TextField(L("headers.user_agent.placeholder"), text: userAgent)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
            }

            gateHairline

            // The multi-line headers field keeps a stacked
            // row (label above the field) — the one row a
            // right-aligned single line cannot hold.
            VStack(alignment: .leading, spacing: 6) {
                Text(L("headers.custom"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField(L("headers.custom.placeholder"), text: headers, axis: .vertical)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(2...4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }

    /// Trims an optional field to nil-when-empty for the model.
    private func optionalField(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Build 87 (design 1): the iOS-style segmented control —
    /// a quiet gray track, the selected segment a lighter
    /// gray pill with white text (the picture's treatment;
    /// the accent stays for actions, not chrome).
    private var segmentedTypeSwitch: some View {
        HStack(spacing: 0) {
            segmentButton(kind: .m3u, title: L("playlist_type.m3u.title"))
            segmentButton(kind: .xtream, title: L("playlist_type.xtream.title"))
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .animation(Motion.animate(.spring(response: 0.35, dampingFraction: 0.85)), value: formKind)
    }

    private func segmentButton(kind: FormKind, title: String) -> some View {
        let selected = formKind == kind
        return Button {
            formKind = kind
        } label: {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundColor(selected ? .white : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                            .matchedGeometryEffect(id: "gateSegmentPill", in: segmentNamespace)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Build 87 (design 1): the grouped card's hairline.
    private var gateHairline: some View {
        Rectangle()
            .fill(AppTheme.cardBorderColor)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    /// Build 87 (design 1): one form row — the label on the
    /// left in secondary, the field right-aligned (iOS
    /// Settings style, as in the picked picture).
    private func gateRow<Content: View>(
        label: String,
        labelWidth: CGFloat = 104,
        focused: Bool = false,
        flashKey: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(focused ? .primary : .secondary)
                .lineLimit(2)
                .frame(width: labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        // Build 87 (per-surface motion): a focused field's
        // row lifts — a soft tint plus the accent hairline —
        // and a just-pasted row flashes once so the user
        // SEES what the paste filled. Both on Motion tokens.
        .background(
            flashKey.map { pasteFlash.contains($0) } == true
                ? AppTheme.accent.opacity(0.12)
                : (focused ? AppTheme.accent.opacity(0.05) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            if focused {
                Rectangle()
                    .fill(AppTheme.accent)
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
        .animation(Motion.animate(.easeInOut(duration: 0.25)), value: focused)
        .animation(Motion.animate(.easeOut(duration: 0.45)), value: pasteFlash)
    }

    /// The paste highlight sweep: each filled row flashes in
    /// sequence (70 ms stagger) and fades — driven by the
    /// fields the paste ACTUALLY changed (see
    /// pasteAllWithFlash), never a scripted decoration.
    private func flashPasted(_ keys: [String]) {
        guard !keys.isEmpty, Motion.animate(.easeOut(duration: 0.3)) != nil else { return }
        Task { @MainActor in
            for (index, key) in keys.enumerated() {
                if index > 0 { try? await Task.sleep(for: .milliseconds(70)) }
                pasteFlash.insert(key)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    pasteFlash.remove(key)
                }
            }
        }
    }

    /// Paste-all with the highlight sweep: pasteAll itself is
    /// untouched — the flash keys are the fields whose values
    /// the paste actually changed.
    private func pasteAllWithFlash() {
        let before = (xtreamURL, xtreamUsername, xtreamPassword)
        pasteAll()
        var keys: [String] = []
        if xtreamURL != before.0 && !xtreamURL.isEmpty { keys.append("url") }
        if xtreamUsername != before.1 && !xtreamUsername.isEmpty { keys.append("username") }
        if xtreamPassword != before.2 && !xtreamPassword.isEmpty { keys.append("password") }
        flashPasted(keys)
    }

    /// The Filter Adult Content row (design 1): title +
    /// explanatory caption on the left, the switch on the
    /// right, accent-tinted like every switch in the app.
    private func filterRow(isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("add_playlist.filter_adult"))
                    .font(.subheadline.weight(.semibold))
                Text(L("add_playlist.filter_adult.desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(AppTheme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Inline validation line under a bad row (round 14, B13).
    private func fieldError(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
    }

    private var xtreamForm: some View {
        VStack(spacing: 0) {
            // Round 14 (B13): "Paste all" — parses a pasted
            // provider message into the fields below. Design 1:
            // it is the card's action row under the switch.
            Button {
                pasteAllWithFlash()
            } label: {
                HStack {
                    Label(L("gate.paste_all"), systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.accent)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            gateHairline

            gateRow(label: L("gate.field.name"), focused: focusedField == .xtreamName) {
                TextField(L("add_playlist.name_placeholder"), text: $xtreamName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .xtreamName)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .xtreamURL }
            }

            gateHairline

            VStack(spacing: 0) {
                gateRow(label: L("add_playlist.server_url"), focused: focusedField == .xtreamURL, flashKey: "url") {
                    HStack(spacing: 8) {
                        TextField(L("add_playlist.server_url"), text: $xtreamURL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .xtreamURL)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .xtreamUsername }
                        // Paste button INSIDE the URL row (round 14, B13).
                        Button {
                            if let clip = UIPasteboard.general.string, !clip.isEmpty {
                                xtreamURL = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                                flashPasted(["url"])
                            }
                        } label: {
                            Text(L("gate.paste"))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(AppTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if xtreamURLInvalid {
                    fieldError(L("gate.validation.invalid_url"))
                }
            }

            gateHairline

            gateRow(label: L("add_playlist.username"), focused: focusedField == .xtreamUsername, flashKey: "username") {
                TextField(L("add_playlist.username"), text: $xtreamUsername)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .xtreamUsername)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .xtreamPassword }
            }

            gateHairline

            gateRow(label: L("add_playlist.password"), focused: focusedField == .xtreamPassword, flashKey: "password") {
                // Secure field with a show/hide eye — the value
                // path is unchanged.
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
                    .multilineTextAlignment(.trailing)
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
            }

            gateHairline

            filterRow(isOn: $filterAdultContent)

            gateHairline

            connectionFields(backup: $xtreamBackupURL, epg: $xtreamEPGURL, userAgent: $xtreamUserAgent, headers: $xtreamHeadersText)
        }
    }

    private var m3uForm: some View {
        VStack(spacing: 0) {
            gateRow(label: L("gate.field.name"), focused: focusedField == .m3uName) {
                TextField(L("add_m3u.name_placeholder"), text: $m3uName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .m3uName)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .m3uURL }
            }

            gateHairline

            VStack(spacing: 0) {
                gateRow(label: L("gate.field.playlist_url"), focused: focusedField == .m3uURL, flashKey: "playlistUrl") {
                    HStack(spacing: 8) {
                        TextField(L("add_m3u.url_placeholder"), text: $m3uURL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .m3uURL)
                            .submitLabel(.done)
                            .onSubmit { focusedField = nil }
                            .disabled(hasLocalFile)
                            .foregroundColor(hasLocalFile ? .secondary : .primary)
                        Button {
                            if let clip = UIPasteboard.general.string, !clip.isEmpty {
                                m3uURL = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                                flashPasted(["playlistUrl"])
                            }
                        } label: {
                            Text(L("gate.paste"))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(AppTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if m3uURLInvalid {
                    fieldError(L("gate.validation.invalid_url"))
                }
            }

            gateHairline

            HStack {
                Button {
                    focusedField = nil
                    showFileImporter = true
                } label: {
                    Label(hasLocalFile ? L("add_m3u.pick_another_file") : L("add_m3u.pick_file"),
                          systemImage: "doc.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                if let local = localFileName {
                    Text(local)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            if hasLocalFile {
                gateHairline

                Button(role: .destructive) {
                    localFileName = nil
                    localContent = nil
                } label: {
                    Label(L("add_m3u.remove_file"), systemImage: "xmark.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }

            gateHairline

            // Round 14 (B13): adult-filter toggle — parity with
            // the Xtream form.
            filterRow(isOn: $m3uFilterAdultContent)

            gateHairline

            connectionFields(backup: $m3uBackupURL, epg: $m3uEPGURL, userAgent: $m3uUserAgent, headers: $m3uHeadersText)

            gateHairline

            // Design-4: the helper line under the M3U fields is
            // small accent text (the mockup's "Load your .m3u or
            // .m3u8 playlist").
            Text(L("add_m3u.section.source_footer"))
                .font(.caption.weight(.medium))
                .foregroundColor(AppTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
        }
        // Build 87 (per-surface motion): the file rows
        // appear/disappear on the standard token when a local
        // file is picked or removed.
        .animation(Motion.animate(.easeInOut(duration: 0.25)), value: hasLocalFile)
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
        importPhase = .form
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
        importFailure = nil
        importPhase = .loading
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
                    importFailure = L("add_playlist.auth_failed")
                    importPhase = .failed
                    isLoading = false
                    progressMessage = nil
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                importFailure = explainedError(for: error)
                importPhase = .failed
                isLoading = false
                progressMessage = nil
                addStages = [:]
            }
        }
    }

    private func syncAndSaveXtream(newPlaylist: Playlist, client: XtreamAPIClient) async {
        // Build 87: this finisher drives the on-screen import
        // state (also reached from the expired warning's
        // Enter-anyway and the get.php detection path).
        importTargetId = newPlaylist.id
        importTargetKind = .xtream
        importFailure = nil
        importPhase = .loading
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
                    self.importPhase = .form
                }
                return
            }
            setStage(.loadingChannels, .done)
            setStage(.loadingMoviesSeries, .done)

            let compatibility = await PlaylistValidationService.probeCompatibility(playlist: newPlaylist)
            // Build 80 (item 9): no guide stage — the TV Guide/EPG
            // system was removed entirely; the summary follows the
            // content stages directly.
            let counts = await PlaylistValidationService.importedCounts(playlistId: newPlaylist.id, kind: .xtream)
            let expiry = ProviderExpiryStore.expiryDate(playlistId: newPlaylist.id)

            await MainActor.run {
                self.isLoading = false
                self.progressMessage = nil
                self.addStages = [:]
                self.importPhase = .completed
                self.addSummary = PlaylistValidationService.AddSummary(
                    playlist: newPlaylist,
                    expiryDate: expiry,
                    liveCount: counts.live, movieCount: counts.movies, seriesCount: counts.series,
                    compatibility: compatibility
                )
            }
        } catch {
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.isLoading = false
                    self.progressMessage = nil
                    self.addStages = [:]
                    self.importPhase = .form
                }
                return
            }
            await MainActor.run {
                self.importFailure = explainedError(for: error)
                self.importPhase = .failed
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
        importFailure = nil
        importPhase = .loading

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
            importPhase = .form
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

        importTargetId = newPlaylist.id
        importTargetKind = .m3u

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
                self.importPhase = .completed
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
                self.importFailure = (error as? PlaylistValidationService.ValidationFailure)?.errorDescription
                    ?? explainedError(for: error)
                self.importPhase = .failed
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

// MARK: - Build 87 timeline helpers

/// The completed node's check, drawn in with a trim sweep
/// when the node first appears (Motion-gated: under Reduce
/// Motion it renders complete instantly).
private struct CheckDrawView: View {
    @State private var trim: CGFloat = 0

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 5.5, y: 11.5))
            path.addLine(to: CGPoint(x: 9.5, y: 15.5))
            path.addLine(to: CGPoint(x: 16.5, y: 6.5))
        }
        .trim(from: 0, to: trim)
        .stroke(Color.white, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
        .onAppear {
            if Motion.animate(.easeOut(duration: 0.35)) != nil {
                withAnimation(.easeOut(duration: 0.35)) { trim = 1 }
            } else {
                trim = 1
            }
        }
    }
}

/// An indeterminate activity bar for the timeline's current
/// step: a short accent segment sliding across a quiet
/// track. It signals activity ONLY — the importer publishes
/// no intra-stage fraction, so no percentage is implied.
/// Stilled to a static segment by the effects gate.
private struct IndeterminateBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slide = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 5)
                Capsule()
                    .fill(AppTheme.accent)
                    .frame(width: proxy.size.width * 0.35, height: 5)
                    .offset(x: slide ? proxy.size.width * 0.65 : 0)
            }
        }
        .frame(height: 5)
        .clipped()
        .onAppear {
            if EffectsGate.allowsHeavyEffects(reduceMotion: reduceMotion) {
                withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                    slide = true
                }
            }
        }
    }
}
