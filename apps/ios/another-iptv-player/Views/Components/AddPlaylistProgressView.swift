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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("addplaylist.progress.title"))
                .font(.headline)
            ForEach(PlaylistValidationService.Stage.allCases, id: \.rawValue) { stage in
                HStack(spacing: 10) {
                    stageIcon(stages[stage] ?? .pending)
                    Text(L(stage.titleKey))
                        .font(.subheadline)
                        .foregroundStyle(stages[stage] == .pending ? .secondary : .primary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L(stage.titleKey))
                .accessibilityValue(accessibilityValue(for: stages[stage] ?? .pending))
            }
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
    private func stageIcon(_ state: PlaylistValidationService.StageState) -> some View {
        // Decorative: the row's combined accessibility element
        // already announces the stage + state (Q24).
        Group { stageIconBody(state) }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func stageIconBody(_ state: PlaylistValidationService.StageState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .active:
            ProgressView()
                .frame(width: 20, height: 20)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.accent)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
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
                Image(systemName: summary.failedStage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(summary.failedStage == nil ? AppTheme.accent : .orange)
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

            VStack(alignment: .leading, spacing: 4) {
                countRow(icon: "tv", text: L("addplaylist.summary.live", summary.liveCount))
                if summary.playlist.kind == .xtream {
                    countRow(icon: "film", text: L("addplaylist.summary.movies", summary.movieCount))
                    countRow(icon: "rectangle.stack", text: L("addplaylist.summary.series", summary.seriesCount))
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

    private func countRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }
}
