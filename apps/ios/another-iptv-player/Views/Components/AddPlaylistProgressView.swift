import SwiftUI

/// Build 61 (B10, L1/L2/L3): the add-playlist staged progress
/// checklist and the end-of-add summary, shared by the gate and
/// the My Playlists add sheet.
///
/// L1: every row's state is bound to a REAL importer stage via
/// `PlaylistValidationService`'s stage callbacks — there is no
/// timer and no scripted animation anywhere in this file.
/// L2: the summary shows the playlist name, the REAL expiry
/// (Xtream auth date; for M3U a date row exists ONLY when the
/// summary carries one, which M3U sources never produce here),
/// the REAL imported counts read back from the database, and a
/// "Start Watching" button that lands on Home with the new
/// playlist active (the caller performs the activation).
/// L3: when a non-critical stage failed, the summary says which
/// part failed and offers Retry for that stage only.
/// Free-forever wording (§3.5): the subscription named here is
/// the user's own PROVIDER subscription — the copy says so.
///
/// Build 67 (W8, S7 — owner pick, style 1 'Glass Ring'): the
/// progress card is now a frosted-glass card with a big circular
/// progress RING (percentage in the centre, current step under
/// it) and the step rows below. HONESTY RULES, unchanged in
/// spirit from build 63 and tightened here:
/// - the ring % derives ONLY from completed content steps
///   (Live TV / Movies / Series / TV Guide): 3 of 4 resolved =
///   75%. A step counts when it is done OR failed (the flow has
///   finished with it); an active step contributes NOTHING —
///   the % never animates on a timer and never interpolates
///   inside a stage.
/// - step counters land at COMPLETION with real imported
///   counts: a row shows a count only when its stage is done
///   AND the caller supplied the real count (the importer
///   publishes counts only at completion; the full real counts
///   live on the summary card the moment the add lands).
/// - the failed-guide end state (F5) shows the ring at its
///   truthful value with the guide row in warning state, and
///   the card hands over to the L3 partial-success summary —
///   it never sits on "Loading the guide" indefinitely.
struct AddPlaylistProgressView: View {
    let stages: [PlaylistValidationService.Stage: PlaylistValidationService.StageState]
    /// The playlist's name heads the card, as the mockup shows.
    /// Optional — the card renders without it when a caller has
    /// no name yet.
    var playlistName: String? = nil
    /// Build 67 (W8, S7): REAL imported counts for the step
    /// rows, supplied by a caller only once the matching import
    /// has completed and the counts were read back. Nil (the
    /// default) renders no number — never an estimate.
    var liveCount: Int? = nil
    var movieCount: Int? = nil
    var seriesCount: Int? = nil
    let onCancel: () -> Void

    private func state(of stage: PlaylistValidationService.Stage) -> PlaylistValidationService.StageState {
        stages[stage] ?? .pending
    }

    /// The four content steps the ring measures, in card order.
    /// Movies and Series are separate ROWS bound to the one real
    /// importer stage that loads them together, so the ring
    /// counts that stage twice — once per row it completes.
    private var ringSteps: [PlaylistValidationService.Stage] {
        [.loadingChannels, .loadingMoviesSeries, .loadingMoviesSeries, .loadingGuide]
    }

    /// Ring fraction: resolved steps (done or failed) over the
    /// four content steps. Nothing else moves the ring.
    private var progressFraction: Double {
        let resolved = ringSteps.filter {
            state(of: $0) == .done || state(of: $0) == .failed
        }.count
        return Double(resolved) / Double(ringSteps.count)
    }

    private var percent: Int {
        Int((progressFraction * 100).rounded())
    }

    private var allStepsResolved: Bool {
        ringSteps.allSatisfy { state(of: $0) == .done || state(of: $0) == .failed }
    }

    private var anyStepFailed: Bool {
        ringSteps.contains { state(of: $0) == .failed }
    }

    /// The stage the ring's centre label names: the active one,
    /// else the failed one, else the next pending, else the last.
    private var currentStage: PlaylistValidationService.Stage {
        let ordered = PlaylistValidationService.Stage.allCases.sorted { $0.rawValue < $1.rawValue }
        return ordered.first { state(of: $0) == .active }
            ?? ordered.first { state(of: $0) == .failed }
            ?? ordered.first { state(of: $0) == .pending }
            ?? ordered.last!
    }

    /// Centre-of-ring caption: the running step's name while the
    /// flow is live; once every step is resolved it states the
    /// outcome plainly (done / failed) instead of naming a step
    /// that is no longer running.
    private var ringSubtitle: String {
        if anyStepFailed { return L("addplaylist.stage.state.failed") }
        if allStepsResolved { return L("addplaylist.stage.state.done") }
        return L(currentStage.titleKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Card head (mockup's top line): accent dot, the
            // playlist name, then the progress title.
            HStack(spacing: 8) {
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 9, height: 9)
                if let playlistName, !playlistName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(playlistName)
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                    Text("—")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(L("addplaylist.progress.title"))
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
            }

            // The Glass Ring: track + gradient arc, the real
            // percentage and the current step in the centre.
            ZStack {
                Circle()
                    .stroke(AppTheme.surface, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progressFraction)
                    .stroke(
                        AppTheme.brandGradient,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: AppTheme.accentStart.opacity(0.45), radius: 10)
                VStack(spacing: 2) {
                    Text(L("b67w8.progress.percent", percent))
                        .font(.system(size: 40, weight: .heavy))
                        .monospacedDigit()
                    Text(ringSubtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
            }
            .frame(width: 168, height: 168)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.35), value: progressFraction)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ringSubtitle)
            .accessibilityValue(L("b67w8.progress.percent", percent))

            // One row per content type, bound to its real stage.
            VStack(spacing: 8) {
                stageRow(label: L("dashboard.live"), stage: .loadingChannels,
                         countText: liveCount.map { L("addplaylist.summary.live", $0) })
                stageRow(label: L("dashboard.movies"), stage: .loadingMoviesSeries,
                         countText: movieCount.map { L("addplaylist.summary.movies", $0) })
                stageRow(label: L("dashboard.series"), stage: .loadingMoviesSeries,
                         countText: seriesCount.map { L("addplaylist.summary.series", $0) })
                stageRow(label: L("epg.guide.title"), stage: .loadingGuide, countText: nil)
            }

            Button {
                onCancel()
            } label: {
                Text(L("common.cancel"))
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(AppTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.surface.opacity(0.65), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .background { glassCard }
        .shadow(radius: 20)
    }

    /// Frosted-glass card fill: the system thin material over
    /// the app's elevated tint (the Cinematic Glass language).
    private var glassCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                .fill(AppTheme.elevated.opacity(0.55))
            RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }

    /// One content-type row of the Glass Ring card: the stage's
    /// state glyph (spinner while loading, check when stored,
    /// warning on failure, hollow circle while queued), the
    /// label, and — only on a done row with a real supplied
    /// count — the count. See the type note.
    private func stageRow(
        label: String,
        stage: PlaylistValidationService.Stage,
        countText: String?
    ) -> some View {
        HStack(spacing: 11) {
            stateGlyph(for: state(of: stage))
            Text(label)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            if state(of: stage) == .done, let countText {
                Text(countText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            AppTheme.surface.opacity(0.65),
            in: RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue(for: state(of: stage)))
    }

    @ViewBuilder
    private func stateGlyph(for state: PlaylistValidationService.StageState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.accent)
        case .active:
            BrandedLoader(size: 20)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }

    private func accessibilityValue(for state: PlaylistValidationService.StageState) -> String {
        switch state {
        case .pending: return L("addplaylist.stage.state.pending")
        case .active: return L("addplaylist.stage.state.active")
        case .done: return L("addplaylist.stage.state.done")
        case .failed: return L("addplaylist.stage.state.failed")
        }
    }
}

/// L2/L3 summary card (see the type note above).
struct AddPlaylistSummaryView: View {
    let summary: PlaylistValidationService.AddSummary
    /// L3: re-runs ONLY the failed stage; the card stays up and
    /// the caller refreshes the summary when the retry lands.
    let onRetryFailedStage: (() -> Void)?
    let onStartWatching: () -> Void

    /// Build 67 (W8, S7 continuity): the summary is the Glass
    /// Ring card at its end state. Only the guide can land in
    /// `failedStage` (see `AddSummary`), so a partial summary's
    /// ring stands at 3 of 4 content steps — its truthful value.
    private var summaryRingFraction: Double {
        summary.failedStage == nil ? 1 : 0.75
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                // Build 67 (W8, S7): the progress card's ring at
                // its end state, carrying the outcome glyph —
                // X7 (B7): the drawn animated check (+ light
                // success haptic) on full success; the partial-
                // success warning glyph is unchanged.
                ZStack {
                    Circle()
                        .stroke(AppTheme.surface, lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: summaryRingFraction)
                        .stroke(
                            AppTheme.brandGradient,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    if summary.failedStage == nil {
                        AnimatedCheckView(size: 22)
                            .onAppear { Haptics.success() }
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 46, height: 46)
                Text(summary.failedStage == nil ? L("addplaylist.summary.title") : L("addplaylist.summary.partial_title"))
                    .font(.headline)
            }

            Text(summary.playlist.name)
                .font(.title3.weight(.bold))
                .lineLimit(2)

            // L2 expiry row: real provider date only; M3U
            // summaries carry no date, so no row renders at all.
            if let expiry = summary.expiryDate {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(.secondary)
                    Text(L("addplaylist.summary.expiry", expiry.formatted(date: .abbreviated, time: .omitted)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Build 63 (Style 2): the big-number treatment from
            // the picked mockup lives HERE, where the counts are
            // real (read back from the database at summary time).
            VStack(alignment: .leading, spacing: 6) {
                bigCountRow(icon: "tv", text: L("addplaylist.summary.live", summary.liveCount))
                if summary.playlist.kind == .xtream {
                    bigCountRow(icon: "film", text: L("addplaylist.summary.movies", summary.movieCount))
                    bigCountRow(icon: "rectangle.stack", text: L("addplaylist.summary.series", summary.seriesCount))
                }
            }

            // Z1: the REAL compatibility ratio from the
            // first-bytes probe, with the method labeled honestly.
            if let compat = summary.compatibility {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(L("addplaylist.summary.compatibility", compat.reachable, compat.sampled))
                            .font(.subheadline)
                    }
                    Text(L("addplaylist.summary.compatibility.method"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if summary.failedStage != nil {
                Text(L("addplaylist.summary.guide_failed"))
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                // Build 67 (W8, F5): when the failed guide is
                // still loading in the background, the summary
                // says so; after a failed RETRY nothing is
                // loading, and this line stays out.
                if summary.guideLoadingInBackground {
                    Text(L("b67w8.progress.guide_background"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onRetryFailedStage {
                    Button {
                        onRetryFailedStage()
                    } label: {
                        Text(L("addplaylist.summary.retry_guide"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Free-forever discipline (§3.5): the subscription is
            // with the user's provider, never with Super X.
            Text(L("addplaylist.summary.provider_note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onStartWatching()
            } label: {
                Text(L("addplaylist.summary.start_watching"))
                    .font(.headline.weight(.bold))
                    .foregroundColor(AppTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(AppTheme.accent)
                    .cornerRadius(AppTheme.cornerRadius)
            }
            .buttonStyle(.plain)
            .accessibilityHint(L("addplaylist.summary.start_watching.hint"))
        }
        .padding(24)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                    .fill(AppTheme.elevated.opacity(0.55))
                RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .shadow(radius: 20)
    }

    private func bigCountRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 22)
            Text(text)
                .font(.title3.weight(.black))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
