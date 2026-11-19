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
struct AddPlaylistProgressView: View {
    let stages: [PlaylistValidationService.Stage: PlaylistValidationService.StageState]
    let onCancel: () -> Void

    // Build 63 (owner pick, Style 2 "Bar"): the checklist is
    // replaced by a slim red-orange progress bar across the top,
    // a row of step dots (completed filled), the current step
    // label, and a Cancel text action — all derived PURELY from
    // the same stage states; semantics unchanged. The mockup's
    // big counting numbers live on the SUMMARY card (below):
    // real counts exist only once content is stored, and this
    // view never fabricates mid-load numbers.

    private var orderedStages: [PlaylistValidationService.Stage] {
        PlaylistValidationService.Stage.allCases.sorted { $0.rawValue < $1.rawValue }
    }

    private func state(of stage: PlaylistValidationService.Stage) -> PlaylistValidationService.StageState {
        stages[stage] ?? .pending
    }

    /// Bar fraction: each finished stage contributes its full
    /// share; the active stage contributes half of its share.
    private var progressFraction: Double {
        let total = Double(max(orderedStages.count, 1))
        var value = 0.0
        for stage in orderedStages {
            switch state(of: stage) {
            case .done, .failed: value += 1
            case .active: value += 0.5
            case .pending: break
            }
        }
        return min(value / total, 1)
    }

    /// The stage the label names: the active one, else the
    /// failed one, else the next pending, else the last.
    private var currentStage: PlaylistValidationService.Stage {
        orderedStages.first { state(of: $0) == .active }
            ?? orderedStages.first { state(of: $0) == .failed }
            ?? orderedStages.first { state(of: $0) == .pending }
            ?? orderedStages.last!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Slim progress bar across the top.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.surface)
                        .frame(height: 5)
                    Capsule()
                        .fill(AppTheme.accent)
                        .frame(width: proxy.size.width * progressFraction, height: 5)
                }
            }
            .frame(height: 5)
            .animation(.easeInOut(duration: 0.35), value: progressFraction)

            Text(L("addplaylist.progress.title"))
                .font(.headline)

            // Step dots: done filled, active ringed, failed
            // orange, pending hollow.
            HStack(spacing: 0) {
                ForEach(orderedStages, id: \.rawValue) { stage in
                    stepDot(state(of: stage))
                    if stage != orderedStages.last {
                        Spacer(minLength: 8)
                    }
                }
            }
            .accessibilityHidden(true)

            // Current step label.
            HStack(spacing: 8) {
                if state(of: currentStage) == .active {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.accent)
                }
                Text(L(currentStage.titleKey))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state(of: currentStage) == .failed ? .orange : .primary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L(currentStage.titleKey))
            .accessibilityValue(accessibilityValue(for: state(of: currentStage)))

            Button(L("common.cancel")) { onCancel() }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.accent)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .background(AppTheme.elevated.opacity(0.97))
        .cornerRadius(AppTheme.cornerRadius)
        .shadow(radius: 20)
    }

    @ViewBuilder
    private func stepDot(_ state: PlaylistValidationService.StageState) -> some View {
        switch state {
        case .done:
            Circle().fill(AppTheme.accent).frame(width: 12, height: 12)
        case .active:
            ZStack {
                Circle().stroke(AppTheme.accent, lineWidth: 2).frame(width: 14, height: 14)
                Circle().fill(AppTheme.accent).frame(width: 6, height: 6)
            }
        case .failed:
            Circle().fill(.orange).frame(width: 12, height: 12)
        case .pending:
            Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1.5).frame(width: 12, height: 12)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                // X7 (B7): the add-success summary leads with the
                // drawn animated check (+ light success haptic);
                // the partial-success warning glyph is unchanged.
                if summary.failedStage == nil {
                    AnimatedCheckView(size: 26)
                        .onAppear { Haptics.success() }
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
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
        .background(AppTheme.elevated.opacity(0.97))
        .cornerRadius(AppTheme.cornerRadius)
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
