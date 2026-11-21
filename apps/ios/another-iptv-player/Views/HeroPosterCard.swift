import SwiftUI

// MARK: - Hero poster card (build 87, item 16 — owner-picked design 4)
//
// The immersive carousel card from the owner's picked mockup
// (hero option 4, "carousel peek"): ONE large portrait poster
// card with big rounded corners; the previous/next cards peek
// at the edges scaled down and darker (the carousel applies
// that treatment — this card renders itself at full strength);
// the title sits CENTERED in a glass info panel over the
// poster's lower third, with the rating (one star + number,
// build 88 F7) and meta line under it, and the Play (solid
// accent) + Details (glass) actions as rounded rectangles
// beneath. The centered card carries the accent border +
// glow (build 88, owner-approved "max" mockup); peeks stay
// quiet. Portrait posters are this design's native art; a
// wide backdrop fills the same card. The art chain is the
// build-81/82 one: backdrop first, a load failure swaps to
// the poster, and an item with no working art renders
// CachedImage's designed placeholder (gradient + icon — the
// overlay title is the ONE title in that state, build 88
// F8) — never a blank slab.
//
// Build 89 (item 2, owner — "مش صورة كامله، يقص الصور"):
// the art is now aspect-FITTED and shown WHOLE. Builds
// 87/88 aspect-FILLED it into this 3:4 card, which crops
// roughly a tenth of a 2:3 poster's height (the cut heads
// and titles in the owner's recording) and over half of a
// wide backdrop's width. The fitted picture rests on the
// card's near-black ground — no blurred pillars (the owner
// rejected those in build 81) — and the scrim, glass panel,
// failure-swap chain and title-card fallback are unchanged.
// The same round fixes the recording's mid-swipe ghosting:
// the glass info panel now fades with the card's distance
// from the centre (see panelVisibility), so two panels can
// never overlap mid-transition — only the art travels.

struct HeroPosterCard: View {
    let title: String
    let backdropURL: URL?
    let posterURL: URL?
    /// The item's REAL rating, exactly as displayed elsewhere
    /// (normalized 10-scale text); nil when the record has none.
    let ratingText: String?
    /// "Sci-Fi • 2024 • 2h 14m" — only parts the record carries.
    let metaLine: String?
    let iconName: String
    let width: CGFloat
    /// Peek neighbours render art + title only; the actions
    /// belong to the centered card (one control set on screen,
    /// the no-duplication rule the old hero also kept).
    var showsControls: Bool = true
    let onPlay: () -> Void
    let onDetails: () -> Void

    /// Build 82 (item 1): a backdrop that exists but fails to
    /// load swaps to the poster instead of stranding the card.
    @State private var backdropLoadFailed = false
    /// Build 89 (item 2): the card's signed distance from
    /// the screen centre in points, measured by the
    /// background reader below (zero when centered). It
    /// drives the info panel's travel fade (see
    /// panelVisibility). It replaces the build-87 parallax
    /// state: the fitted art no longer shifts inside the
    /// card, because any shift or scale would push part of
    /// the whole picture past the card's clip and cut it.
    @State private var centerDelta: CGFloat = 0

    /// How visible this card's glass info panel is, from
    /// its distance to the centre: fully visible while the
    /// card sits (nearly) centered, fading as it travels,
    /// gone once it rests as a peek neighbour. During a
    /// swipe BOTH passing cards are off-centre, so both
    /// panels are faded at the crossing — two readable
    /// panels can never double-render mid-transition again
    /// (the owner's recording showed the outgoing and
    /// incoming titles/buttons overlapping while the cards
    /// crossed). Only the art travels; the panel belongs
    /// to the centered card alone, which is design 4's own
    /// rule (the overlay lives on the center card; peeks
    /// are scaled, darkened art). Positional, not animated,
    /// so Reduce Motion needs no exception.
    private var panelVisibility: CGFloat {
        let travel = abs(centerDelta)
        let fadeStart = width * 0.15
        let fadeEnd = width * 0.65
        if travel <= fadeStart { return 1 }
        if travel >= fadeEnd { return 0 }
        return 1 - (travel - fadeStart) / (fadeEnd - fadeStart)
    }

    private var height: CGFloat { width * 4 / 3 }

    private var artURL: URL? {
        if let backdropURL, !backdropLoadFailed { return backdropURL }
        return posterURL
    }

    /// Build 88 (F7): the rating renders ONCE — one gold star
    /// + the number — leading the meta line (the approved
    /// mockup's "4.8 • 2025 • Action/Sci-Fi • 2h 14m"). Build
    /// 87 printed BOTH a five-star row derived from the value
    /// AND the raw number inside the meta line; the owner's
    /// recording showed the duplication on every slide. The
    /// value is the item's real displayed rating text —
    /// nothing is derived or invented: no rating text, no
    /// star, no number.
    @ViewBuilder
    private var ratingMetaRow: some View {
        if ratingText != nil || metaLine != nil {
            HStack(spacing: 5) {
                if let ratingText {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.ratingGold)
                        Text(ratingText)
                            .font(AppTheme.fontMetadata.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                if ratingText != nil && metaLine != nil {
                    Text("•")
                        .font(AppTheme.fontMetadata)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let metaLine {
                    Text(metaLine)
                        .font(AppTheme.fontMetadata.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .shadow(color: .black.opacity(0.7), radius: 5, y: 1)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Art + gradient carry the details tap (the
            // FeaturedSlide pattern — the buttons above keep
            // their own actions, never both).
            ZStack {
                // The near-black ground: visible while art
                // loads, when the title card renders, and —
                // build 89 (item 2) — as the bands around the
                // aspect-fitted whole picture (thin side bands
                // for a portrait poster; top/bottom bands for
                // a wide backdrop, under the scrim below).
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black)
                CachedImage(
                    url: artURL,
                    width: width,
                    height: height,
                    cornerRadius: 24,
                    // Build 89 (item 2): FIT, not fill — the
                    // whole picture shows, nothing is cut.
                    contentMode: .fit,
                    iconName: iconName,
                    loadProfile: .high,
                    // Build 88 (F8): NO title is passed. The
                    // placeholder's own title text under this
                    // card's overlay title printed the title
                    // TWICE in the no-art state (small gray +
                    // big white — the owner's recording, frame
                    // f030). The overlay below is now the ONE
                    // title in every state (loading, failed, no
                    // art); the placeholder keeps its gradient
                    // + section icon.
                    title: nil,
                    onLoadFailed: {
                        if artURL == backdropURL { backdropLoadFailed = true }
                    }
                )
                // Build 89 (item 2): NO scale and NO offset on
                // the fitted art (builds 87/88 scaled it 1.06
                // for parallax) — either would push part of
                // the whole picture past the card's clip and
                // cut it again.
                .onChange(of: backdropURL) { _, _ in backdropLoadFailed = false }

                // Build 88 (F9): a stronger scrim — the fade
                // starts higher and lands near-opaque, so the
                // overlay text survives posters whose own
                // baked-in title art sits at the bottom (the
                // owner's "Tiny Fugitives" frame: the poster's
                // printed FUGITIVES collided with the overlay).
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.30),
                        .init(color: Color.black.opacity(0.55), location: 0.62),
                        .init(color: Color.black.opacity(0.97), location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onTapGesture { if showsControls { onDetails() } }

            // Build 88 (owner-approved Home mockup): the title,
            // rating/meta and actions sit in a GLASS info panel
            // floating over the poster's lower third — a dark
            // material slab with a hairline glass stroke. The
            // panel doubles as the F9 scrim: overlay text over
            // it stays readable even when the poster's own
            // baked-in title sits behind it. The panel carries
            // the same details tap the art carries (it covers
            // the art's tap area now); the buttons above it
            // keep their own actions.
            VStack(spacing: 7) {
                Text(title)
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.85), radius: 8, y: 2)
                ratingMetaRow
                if showsControls {
                    HStack(spacing: 12) {
                        Button(action: onPlay) {
                            Label(L("home.play"), systemImage: "play.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AppTheme.onAccent)
                                .padding(.horizontal, 26)
                                .padding(.vertical, 11)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(AppTheme.accent)
                                )
                                .signatureGlow()
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        Button(action: onDetails) {
                            Label(L("home.details"), systemImage: "info.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 11)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.white.opacity(0.14))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                                )
                        }
                        .buttonStyle(PressScaleButtonStyle())
                    }
                    .padding(.top, 5)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .onTapGesture { if showsControls { onDetails() } }
            // Build 89 (item 2): the travel fade — see
            // panelVisibility. A faded-out panel also stops
            // taking touches, so a travelling card's buttons
            // can never be hit mid-swipe.
            .opacity(panelVisibility)
            .allowsHitTesting(panelVisibility > 0.5)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    // Build 89 (item 2): the centered card's
                    // accent border fades with the same travel
                    // fade as its panel, instead of snapping
                    // between cards when the selection settles.
                    showsControls ? AppTheme.accent.opacity(0.55 * panelVisibility) : Color.white.opacity(0.14),
                    lineWidth: showsControls ? 1.2 : 1
                )
        )
        // Build 88 (owner-approved Home mockup): the CENTERED
        // card glows in the accent — the tab-glow token, the
        // same restrained glow family as the selected tab's
        // icon. Peek neighbours stay quiet (plain hairline,
        // no glow), so exactly one card on screen glows.
        // Build 89: the glow fades with the travel fade too.
        .shadow(color: showsControls ? AppTheme.tabGlow.opacity(panelVisibility) : .clear,
                radius: showsControls ? 18 : 0, y: showsControls ? 8 : 0)
        // The centre-distance reader: an invisible background
        // that reports the card's global position as it
        // travels, feeding the panel's travel fade. Updates
        // land only while the value actually moves, on
        // visible cards only — no timers, no polling.
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { updateCenterDelta(midX: geo.frame(in: .global).midX) }
                    .onChange(of: geo.frame(in: .global).midX) { _, midX in
                        updateCenterDelta(midX: midX)
                    }
            }
        }
    }

    private func updateCenterDelta(midX: CGFloat) {
        let delta = midX - UIScreen.main.bounds.width / 2
        if abs(delta - centerDelta) > 0.5 { centerDelta = delta }
    }
}
