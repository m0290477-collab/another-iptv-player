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
    /// Build 65 (style 3 'Card Summary'): the playlist's name
    /// heads the card, as the mockup shows. Optional — the card
    /// renders without it when a caller has no name yet.
    var playlistName: String? = nil
    let onCancel: () -> Void

    // Build 63 (owner pick, Style 2 "Bar") → Build 65 (style 3
    // 'Card Summary'): ONE card — playlist name on top, one row
    // per content type (Channels / Movies / Series / Guide)
    // whose state glyph is bound to the REAL importer stage for
    // that type, the current-step label, and the slim
    // red-orange progress bar UNDER the rows, with Cancel.
    // Numbers: the importer publishes real counts ONLY at
    // completion, so mid-load rows carry state, never invented
    // numbers — the real big counts land on the SUMMARY card
    // (below) the moment they exist, exactly as build 63
    // established.

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
        VStack(alignment: .leading, spacing: 14) {
            // Card head: the playlist name (the mockup's top
            // line) + the progress title under it.
            VStack(alignment: .leading, spacing: 3) {
                if let playlistName, !playlistName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(playlistName)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                }
                Text(L("addplaylist.progress.title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // One row per content type, bound to its real stage.
            VStack(spacing: 10) {
                summaryRow(icon: "tv", label: L("dashboard.live"), stage: .loadingChannels)
                summaryRow(icon: "film", label: L("dashboard.movies"), stage: .loadingMoviesSeries)
                summaryRow(icon: "rectangle.stack", label: L("dashboard.series"), stage: .loadingMoviesSeries)
                summaryRow(icon: "calendar", label: L("epg.guide.title"), stage: .loadingGuide)
            }

            // Current step label (connecting / verifying have no
            // content row — they speak here).
            HStack(spacing: 8) {
                if state(of: currentStage) == .active {
                    BrandedLoader(size: 20)
                }
                Text(L(currentStage.titleKey))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state(of: currentStage) == .failed ? .orange : .primary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L(currentStage.titleKey))
            .accessibilityValue(accessibilityValue(for: state(of: currentStage)))

            // Slim progress bar UNDER the rows (Style 2's bar,
            // kept — the Card Summary places it at the card's
            // foot).
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

    /// One content-type row of the summary card: icon + label +
    /// the stage's state glyph (spinner while loading, check
    /// when stored, warning on failure, hollow circle while
    /// queued). No numbers — see the type note.
    private func summaryRow(icon: String, label: String, stage: PlaylistValidationService.Stage) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 22)
            Text(label)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            switch state(of: stage) {
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue(for: state(of: stage)))
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
            // Build 65 (Card Summary continuity): the progress
            // card's slim bar, complete — the summary is the same
            // card at 100%, now carrying the real counts.
            Capsule()
                .fill(AppTheme.accent)
                .frame(height: 5)

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
