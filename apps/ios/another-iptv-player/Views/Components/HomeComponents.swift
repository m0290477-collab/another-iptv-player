import Combine
import NukeUI
import SwiftUI
import UIKit

// MARK: - Cinematic home components (Style 1 mockup structure)
//
// Shared building blocks for the restructured home screens: the Live tab's
// hero card, search entry and section headers, and the Series tab's wide
// cards. Everything here renders REAL catalog data only — callers pass
// model values in; nothing is invented or hard-coded.

// MARK: - LIVE badge

/// Red pill shown on live content. Red is reserved for LIVE in the design.
struct LiveBadge: View {
    /// B12 (Round 14): slow pulse, opacity 0.6↔1 over 1.6 s — the
    /// spec's ONE repeating animation on a badge. Opacity only.
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
            Text(L("player.live_badge"))
                .font(AppTheme.fontBadge)
                // C9 (Round 15): NO .tracking here — this is a LOCALIZED
                // string; tracking breaks Arabic letter joins (the exact
                // defect C9 names). Tracking is for Latin brand text only.
        }
        .opacity(reduceMotion ? 1 : (pulsing ? 1 : 0.6))
        .onAppear {
            guard !reduceMotion, Motion.animate(.easeInOut(duration: 1.6)) != nil else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(AppTheme.live))
    }
}

// MARK: - Section header with See all

/// Mockup-style section header: large bold white title on the left and a
/// "See all ›" link on the right that navigates to a real full list.
///
/// Round 8: this is now the ONE shelf-header style in the app. The
/// category shelves and the Recently Added shelves used a second style
/// (headline title + chevron as one big link, from the upstream layout);
/// they render through this header now, passing their real per-category
/// count for the optional badge (the elite pattern's count badge, kept).
struct CinematicSectionHeader<Destination: View>: View {
    let title: String
    /// Optional real item count, shown as an accent badge before the
    /// "See all" link (category shelves pass their item count).
    var count: Int? = nil
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // Build 61 (B7, completing B6's cross-builder note):
            // Design-4 section headers are small-caps ACCENT titles
            // ("• LIVE CHANNELS •" style, SPEC §2) via the shared
            // tokens — no per-screen header styling anywhere.
            Text("• \(title.uppercased()) •")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.accent)
                .lineLimit(1)
            Spacer()
            if let count, count > 0 {
                Text(CatalogCountFormatter.string(count))
                    .font(AppTheme.fontBadge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AppTheme.accent))
            }
            NavigationLink(destination: destination) {
                HStack(spacing: 3) {
                    Text(L("category.see_all"))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            }
            .buttonStyle(PressScaleButtonStyle())
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Search entry bar

/// Dark rounded search bar. Tapping it opens the real SearchView (the
/// caller presents it); it is an entry point, not a text field.
struct HomeSearchBar: View {
    let placeholder: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(placeholder)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(AppTheme.elevated)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live hero card

/// Drives the hero's inline live preview on a DEDICATED `KSPlayerEngine`
/// (the same engine class the fullscreen player uses — reused, not
/// modified). The engine is used directly, never through
/// `VideoPlayerController`: the controller claims the app audio session
/// (`.playback` + setActive) and installs remote commands, which a muted
/// preview must not do. The engine alone never touches the audio session;
/// its volume is forced to 0 at the player level.
///
/// Lifecycle (driven by `LiveHeroCard` from the caller's `previewActive`
/// signal): start on active, `stopPlayback()` (non-terminal release) on
/// inactive/disappear, `dispose()` only when the owning view is destroyed.
/// Failure handling: an engine failure message before establishment, or no
/// establishment within 10 s, fails the preview back to the logo state —
/// the card is never left black.
final class HeroPreviewController: ObservableObject {
    let engine = KSPlayerEngine()

    /// First frame established — the surface may fade in over the logo.
    @Published private(set) var isLive = false
    /// Preview gave up (error or timeout); the logo state is the fallback.
    @Published private(set) var isFailed = false

    private var startedURL: URL?
    private var isLoading = false
    private var timeoutTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Volume lives on the player instance; an engine fallback swaps the
        // player (surface revision bump) and resets it — re-apply the mute
        // on every swap, and once playback is established.
        engine.$surfaceRevision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyMute() }
            .store(in: &cancellables)
        engine.$isPlaybackEstablished
            .receive(on: DispatchQueue.main)
            .sink { [weak self] established in
                guard let self, established, !self.isFailed else { return }
                self.isLoading = false
                self.timeoutTask?.cancel()
                self.timeoutTask = nil
                self.isLive = true
                self.applyMute()
            }
            .store(in: &cancellables)
        engine.$playbackFailureMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self, message != nil, !self.engine.isPlaybackEstablished else { return }
                self.fail()
            }
            .store(in: &cancellables)
    }

    func start(url: URL, userAgent: String? = nil) {
        if startedURL == url, !isFailed, isLive || isLoading { return }
        startedURL = url
        isFailed = false
        isLive = false
        isLoading = true
        // Build 61 (B7, G2 honesty): the preview load carries the
        // ACTIVE playlist's custom User-Agent like every other load
        // path — it used to pass nil, silently dropping the user's
        // per-playlist UA on this one surface.
        engine.load(url, play: true, startSeconds: nil, liveLowLatency: true, userAgent: userAgent)
        applyMute()
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.engine.isPlaybackEstablished { self.fail() }
        }
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        startedURL = nil
        isLoading = false
        isLive = false
        engine.stopPlayback()
    }

    private func fail() {
        timeoutTask?.cancel()
        timeoutTask = nil
        isLoading = false
        isLive = false
        isFailed = true
        engine.stopPlayback()
    }

    private func applyMute() {
        engine.setVolume(0)
    }

    deinit {
        timeoutTask?.cancel()
        engine.dispose()
    }
}

/// Hosts the preview engine's video view. Mirrors the app's own
/// `KSPlayerVideoSurfaceHost` attach pattern, minus subtitles/cast (a
/// muted preview has neither), and with touch handling DISABLED on the
/// hosted video view so the tap always reaches the hero card's Button —
/// the preview surface can never swallow the tap-to-play action.
private struct HeroVideoSurfaceHost: UIViewRepresentable {
    let engine: KSPlayerEngine
    /// Read so `updateUIView` runs when the engine swaps its video view.
    let surfaceRevision: Int

    func makeUIView(context: Context) -> HeroVideoContainerView {
        let view = HeroVideoContainerView()
        view.attach(engine.videoView)
        return view
    }

    func updateUIView(_ uiView: HeroVideoContainerView, context: Context) {
        uiView.attach(engine.videoView)
    }
}

private final class HeroVideoContainerView: UIView {
    private weak var hostedView: UIView?

    func attach(_ videoView: UIView?) {
        guard let videoView else { return }
        if hostedView === videoView, videoView.superview === self { return }
        hostedView?.removeFromSuperview()
        hostedView = videoView
        videoView.isUserInteractionEnabled = false
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

/// The preview surface layer: black backdrop + the engine's video view.
/// Observes the engine directly (like the app's `KSPlayerVideoSurface`)
/// so surface swaps re-host without re-rendering the whole hero card.
private struct HeroPreviewSurface: View {
    @ObservedObject var engine: KSPlayerEngine

    var body: some View {
        ZStack {
            Color.black
            HeroVideoSurfaceHost(engine: engine, surfaceRevision: engine.surfaceRevision)
        }
    }
}

/// Large 16:9 tap-to-play hero for the Live tab's featured channel.
/// Round 3: the card is a REAL live preview — the featured channel's own
/// stream playing muted inside the card (see `HeroPreviewController`),
/// fading in over the logo state once the first frame is established.
/// The channel's logo over a theme gradient remains the base/fallback
/// visual (channels carry no backdrop art, and a failed or not-yet-live
/// preview must never read as a black card). The red LIVE badge sits
/// top-left, a play affordance is centered (it fades out while the
/// preview is live — the moving picture is the affordance), and the
/// channel name plus the REAL current EPG programme title (when the
/// guide has one) sit bottom-left. Tapping anywhere runs the caller's
/// existing fullscreen player flow.
struct LiveHeroCard: View {
    let stream: DBLiveStream
    var nowProgramTitle: String? = nil
    var previewURL: URL? = nil
    var previewActive: Bool = false
    /// Build 61 (B7, G2): the active playlist's custom User-Agent,
    /// forwarded to the preview load (was hard-coded nil).
    var userAgent: String? = nil
    let onPlay: () -> Void

    @StateObject private var preview = HeroPreviewController()
    @State private var contentShown = false
    @Environment(\.posterMetrics) private var posterMetrics

    var body: some View {
        Button(action: onPlay) {
            ZStack {
                LinearGradient(
                    colors: [AppTheme.accent.opacity(0.30), AppTheme.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if let icon = stream.streamIcon, let url = URL(string: icon) {
                    // Round 9 (owner recording, build 45): the hero used
                    // to request its logo ONLY at 210×118 / .high — a
                    // cache key no other surface produces, so at tab
                    // open it always fetched cold (full panel-logo
                    // download + decode) and the hero sat as a bare dark
                    // box with a play glyph until it landed, while the
                    // rows below already showed the same logo. The logo
                    // is now PROGRESSIVE, two layers of the SAME art:
                    // (1) the exact shelf request the trending/category
                    // cards issue for this channel (same size + profile
                    // via `CachedImage.request`, so it resolves from
                    // the memory cache those surfaces and their prefetch
                    // already warmed — the art is on screen immediately),
                    // (2) the hero's own full-size .high request on top
                    // with a clear placeholder, crossfading in when it
                    // lands so the settled hero keeps today's crispness.
                    ZStack {
                        LazyImage(request: CachedImage.request(
                            url: url,
                            width: posterMetrics.liveShelfIcon,
                            height: posterMetrics.liveShelfIcon,
                            contentMode: .fit,
                            loadProfile: .shelf
                        )) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 210, height: 118)

                        LazyImage(request: CachedImage.request(
                            url: url,
                            width: 210,
                            height: 118,
                            contentMode: .fit,
                            loadProfile: .high
                        )) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 210, height: 118)
                    }
                }

                if previewURL != nil {
                    HeroPreviewSurface(engine: preview.engine)
                        .opacity(preview.isLive ? 1 : 0)
                        .animation(.easeOut(duration: 0.4), value: preview.isLive)
                        .allowsHitTesting(false)
                }

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.45),
                        .init(color: AppTheme.background.opacity(0.88), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 58, height: 58)
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: 2)
                }
                .opacity(preview.isLive ? 0 : 1)
                .animation(.easeOut(duration: 0.3), value: preview.isLive)

                VStack {
                    HStack {
                        LiveBadge()
                        Spacer()
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stream.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let nowProgramTitle, !nowProgramTitle.isEmpty {
                            Text(nowProgramTitle)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.heroCornerRadius, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .opacity(contentShown ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { contentShown = true }
            syncPreview()
        }
        .onDisappear { preview.stop() }
        .onChange(of: previewActive) { _, _ in syncPreview() }
        .onChange(of: stream.streamId) { _, _ in syncPreview() }
        .onChange(of: previewURL) { _, _ in syncPreview() }
    }

    private func syncPreview() {
        if previewActive, let url = previewURL {
            preview.start(url: url, userAgent: userAgent)
        } else {
            preview.stop()
        }
    }
}

// MARK: - Content filter chips (round 5)

/// Tab-level content filter for the unified content-screen pattern.
/// Round 8 (D-4/D-5): the round-5 chip set (All / Favorites / Newest /
/// History) duplicated two destinations that already exist once per
/// tab — Favorites is the nav-bar star's FavoritesView, and History is
/// the Continue Watching row — so those two chips were removed app-wide
/// (with their grids). What remains are the pure content orderings:
/// `.all` (the shelves) and `.newest` (the catalog's added/lastModified
/// ordering, Movies/Series only — Live has no per-channel date field,
/// so Live shows no chips row at all now).
enum ContentChip: Hashable {
    case all, newest

    var title: String {
        switch self {
        case .all: return L("home.chip_all")
        case .newest: return L("home.chip_newest")
        }
    }
}

/// The chips row: selected chip is the solid blue accent, the rest sit on
/// the elevated surface. One row, horizontally scrollable for narrow
/// screens / long translations.
struct ContentChipsRow: View {
    let chips: [ContentChip]
    @Binding var selection: ContentChip

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    Button {
                        selection = chip
                    } label: {
                        Text(chip.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selection == chip ? Color.white : Color.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(selection == chip ? AppTheme.accent : AppTheme.elevated)
                            )
                    }
                    .buttonStyle(PressScaleButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Catalog count formatting (round 5)

/// "16,652" — locale-grouped decimal for the header count lines and the
/// Home tab's category tiles. Counts always come from the loaded catalog
/// arrays; nothing is hard-coded.
enum CatalogCountFormatter {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func string(_ value: Int) -> String {
        // C9 (Round 15) one-locale law: bind to the APP's chosen
        // language, not the device locale.
        formatter.locale = AppTheme.appLocale
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Ranked poster card (round 5)

/// Top-Rated row card (elite Home design): a poster with a giant OUTLINED
/// rank numeral overlapping its left edge, the title under the poster and
/// the real rating (gold star) beside it. Round 8 (audit C3) cut the
/// numeral to two layers; round 9 replaces those with a TRUE outline
/// (see `rankNumeral`). Only items with a valid normalized rating ever
/// reach this card (callers filter), so the rating line always shows a
/// real score.
struct RankedPosterCard: View {
    let rank: Int
    let imageURL: URL?
    let title: String
    let ratingText: String?
    /// Round 10 (point 15): the item's OWN "year • genre" line —
    /// callers build it from the record's real fields, nil when the
    /// record carries neither.
    var metaText: String? = nil
    var posterWidth: CGFloat = 150
    var posterHeight: CGFloat = 225
    var iconName: String = "film"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CachedImage(
                    url: imageURL,
                    width: posterWidth,
                    height: posterHeight,
                    cornerRadius: AppTheme.cornerRadius,
                    contentMode: .fill,
                    iconName: iconName,
                    loadProfile: .shelf
                )
                .padding(.leading, 26)

                rankNumeral
                    .offset(y: 10)
            }

            Text(title)
                .font(AppTheme.fontCardTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: posterWidth, alignment: .leading)
                .padding(.leading, 26)

            if let metaText {
                Text(metaText)
                    .font(AppTheme.fontMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: posterWidth, alignment: .leading)
                    .padding(.leading, 26)
            }

            if let ratingText {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.ratingGold)
                    Text(ratingText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 26)
            }
        }
    }

    private var rankNumeral: some View {
        // Round 9 (owner screenshot, build 45): the round-8 two-layer
        // trick — a white copy scaled 1.05 behind a copy FILLED with
        // the near-black background color — rendered as a SOLID BLACK
        // digit with a hairline rim: a black hole on dark posters and
        // a black sticker on light ones ("the color is black, it's not
        // visible"). The approved ELITE pattern is an OUTLINED numeral,
        // so the digit is now drawn stroke-only (transparent interior)
        // with a strong light stroke and a soft dark shadow that keeps
        // the outline legible over light AND dark art. One layer, no
        // fill anywhere. Size and overlap position are unchanged; the
        // two-digit "10" sizes intrinsically wider, exactly as the old
        // Text did.
        OutlinedRankText(text: "\(rank)", fontSize: 84)
            .shadow(color: .black.opacity(0.45), radius: 7, x: 0, y: 2)
    }
}

/// Stroke-only text for the Top-Rated rank numerals. SwiftUI `Text` has
/// no text-stroke, so this wraps a `UILabel` whose attributed string
/// uses a POSITIVE `strokeWidth` — CoreText then paints ONLY the stroke
/// (the glyph interior stays transparent; the poster shows through).
/// The stroke is specified as a percentage of the font size
/// (4.5% of 84 pt ≈ 3.8 pt), thick enough to read as a design outline
/// at arm's length. The label's own shadow is drawn from the stroked
/// glyphs, grounding the numeral on light posters.
private struct OutlinedRankText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat

    private var attributed: NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .black),
                .strokeColor: UIColor.white.withAlphaComponent(0.95),
                .strokeWidth: 4.5,
                .foregroundColor: UIColor.clear
            ]
        )
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.backgroundColor = .clear
        label.clipsToBounds = false
        label.shadowColor = UIColor.black.withAlphaComponent(0.55)
        label.shadowOffset = CGSize(width: 0, height: 2)
        label.attributedText = attributed
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.attributedText = attributed
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UILabel,
        context: Context
    ) -> CGSize? {
        // Intrinsic text size: one digit is compact, "10" takes the
        // width it needs — the card's ZStack imposes no fixed frame.
        uiView.attributedText = attributed
        return uiView.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
    }
}

// MARK: - In-view search field (round 10)

/// The app's ONE text-entry search field: a real `TextField` in the
/// elevated rounded bar, used by the unified Search page and both
/// Favorites screens. It replaces `.searchable` on those surfaces —
/// the system modifier mounted its field twice on focus (the
/// owner's build-46 recordings show the doubled field in Search and
/// the same glitch breaking the Favorites header). The tab-level
/// `.searchable` fields inside category lists are a different,
/// working pattern and are untouched.
struct CatalogSearchField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .foregroundStyle(.primary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("filter.clear"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .fill(AppTheme.elevated)
        )
        // C12 (Round 15): search-field focus glow — accent ring +
        // soft accent shadow while the field is focused (opacity /
        // stroke only, no layout change).
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.accent.opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
        )
        .shadow(color: AppTheme.accent.opacity(isFocused ? 0.25 : 0), radius: 8)
        .animation(Motion.animate(.easeOut(duration: 0.2)), value: isFocused)
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .onTapGesture { isFocused = true }
    }
}

// MARK: - Filter pill chip (round 10)

/// The capsule filter pill shared by the Search page's section
/// pills and the Favorites type switch — one chip style app-wide:
/// solid accent when selected, elevated surface otherwise.
struct PillChipButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(isSelected ? AppTheme.accent : AppTheme.elevated))
                .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sort & filter sheet (round 10)

/// The styled bottom-sheet panel that replaces the raw iOS popover
/// `Menu` on the category screens (point 13): grouped sections in
/// the app's design language — a Sort section (checkmark on the
/// current option; picking one applies and dismisses, like the old
/// menu) and, where the screen has one, a filter section (genre /
/// file type / live toggles; taps toggle in place, with a clear
/// row). One component drives all three screens; each screen keeps
/// its own state and option sets.
struct SortFilterSheet: View {
    struct Row: Identifiable {
        let id: String
        let title: String
        var systemImage: String? = nil
        let isSelected: Bool
        let action: () -> Void
    }

    let sortRows: [Row]
    var filterTitle: String? = nil
    var filterRows: [Row] = []
    var onClearFilters: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sortRows) { row in
                        sheetRow(row) {
                            row.action()
                            dismiss()
                        }
                    }
                } header: {
                    Text(L("sort.title"))
                }

                if !filterRows.isEmpty {
                    Section {
                        ForEach(filterRows) { row in
                            sheetRow(row, action: row.action)
                        }
                        if let onClearFilters {
                            Button(role: .destructive) {
                                onClearFilters()
                            } label: {
                                Label(L("filter.clear"), systemImage: "xmark.circle")
                            }
                        }
                    } header: {
                        if let filterTitle {
                            Text(filterTitle)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .cinematicScrollBackground()
            .navigationTitle(L("sort.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sheetRow(_ row: Row, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage = row.systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(row.isSelected ? AppTheme.accent : .secondary)
                        .frame(width: 22)
                }
                Text(row.title)
                    .foregroundStyle(.primary)
                Spacer()
                if row.isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(AppTheme.surface)
    }
}

// MARK: - Series wide card (16:9) — REMOVED in round 9

// `SeriesWideCard` was deleted: every shelf that used it (Series tab
// Popular / Recently Added / per-category, Home's New Series) now
// renders the portrait `SeriesCard` with the series cover — the same
// card, size and image profile as the Movies shelves. The wide card's
// 264 pt 16:9 frame upscaled backdrop art where it existed and low-res
// covers where it did not, which is exactly the blur the owner filmed
// in build 45 next to the Movies rows' crisp portrait posters.


// MARK: - C12 shelf edge fade

extension View {
    /// C12 (Round 15): soft fade at the horizontal shelf's edges so
    /// cards dissolve instead of hard-clipping. A mask only — no
    /// layout, no per-cell work. Leading/trailing follow the layout
    /// direction, so RTL shelves fade on their own edges.
    func shelfEdgeFade() -> some View {
        mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.03),
                    .init(color: .black, location: 0.97),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }
}

// MARK: - B6 skeleton shelf (Round 14)

/// Skeleton placeholder shelf shown while a content type is still
/// loading (B6: skeleton placeholders instead of the bare spinner).
/// Pure surface blocks with ONE shared opacity pulse (the B12 shimmer
/// treatment); static under Reduce Motion / motion-off. No text, no
/// fake data — the blocks carry no titles or counts.
struct SkeletonShelf: View {
    var cardWidth: CGFloat = 110
    var cardHeight: CGFloat = 165
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: AppTheme.spacingCardGap) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(AppTheme.elevated)
                    .frame(width: cardWidth, height: cardHeight)
            }
        }
        .padding(.horizontal, AppTheme.spacingScreenMargin)
        .opacity(dimmed ? 0.45 : 0.85)
        // D4 (B7): one shared shimmer sweep over the whole skeleton
        // shelf (single overlay, not per-card), gated by the shared
        // effects gate — Reduce Motion / Q21 render it static.
        .shimmerSweep(active: true)
        .onAppear {
            guard !reduceMotion, Motion.animate(.easeInOut(duration: 1.1)) != nil else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        }
    }
}


// MARK: - Live mini hero card (B6 On now / C6 Tonight)

/// LiveHeroCard-style art for the Home live shelves: the channel's
/// logo over the theme gradient, a LIVE badge, the channel name and
/// the REAL EPG programme title, plus the on-air progress bar (C12:
/// the bar animates its width on the EPG tick — the width is driven
/// by the `progress` value, which changes when the snapshot/tick
/// updates). Used by Home's On-now and Tonight shelves.
struct LiveHeroMiniCard: View {
    let stream: DBLiveStream
    let nowTitle: String
    var progress: Double? = nil
    var timeText: String? = nil
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    LinearGradient(
                        colors: [SectionTheme.live.opacity(0.25), AppTheme.surface],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    if let icon = stream.streamIcon, let url = URL(string: icon) {
                        CachedImage(url: url, width: 150, height: 84, cornerRadius: AppTheme.cornerRadius,
                                    contentMode: .fit, iconName: "tv", loadProfile: .shelf)
                            .frame(width: 150, height: 84)
                    }
                    LiveBadge()
                        .padding(6)
                    VStack {
                        Spacer()
                        if let progress {
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.black.opacity(0.5)).frame(height: 3)
                                Rectangle().fill(AppTheme.live)
                                    .frame(width: 150 * min(max(progress, 0), 1), height: 3)
                                    .animation(Motion.animate(.linear(duration: 0.6)), value: progress)
                            }
                        }
                    }
                }
                .frame(width: 150, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(AppTheme.cardBorderColor, lineWidth: 1))

                Text(stream.name)
                    .font(AppTheme.fontCardTitle)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                HStack(spacing: 5) {
                    if let timeText {
                        Text(timeText)
                            .font(AppTheme.fontBadge)
                            .foregroundStyle(AppTheme.accent)
                    }
                    Text(nowTitle)
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 150, alignment: .leading)
            }
        }
        .buttonStyle(PressScaleButtonStyle())
    }
}
