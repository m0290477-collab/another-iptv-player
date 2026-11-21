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
    /// Build 87 (per-surface motion): the art's parallax
    /// shift, measured by the background reader below from
    /// the card's own global position (zero when centered).
    @State private var parallax: CGFloat = 0

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
                // The near-black ground (visible only while art
                // loads or when the title card renders).
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black)
                CachedImage(
                    url: artURL,
                    width: width,
                    height: height,
                    cornerRadius: 24,
                    contentMode: .fill,
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
                // Parallax: the art is scaled a touch so the
                // shift never bares an edge against the frame.
                .scaleEffect(1.06)
                .offset(x: parallax)
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
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    showsControls ? AppTheme.accent.opacity(0.55) : Color.white.opacity(0.14),
                    lineWidth: showsControls ? 1.2 : 1
                )
        )
        // Build 88 (owner-approved Home mockup): the CENTERED
        // card glows in the accent — the tab-glow token, the
        // same restrained glow family as the selected tab's
        // icon. Peek neighbours stay quiet (plain hairline,
        // no glow), so exactly one card on screen glows.
        .shadow(color: showsControls ? AppTheme.tabGlow : .clear,
                radius: showsControls ? 18 : 0, y: showsControls ? 8 : 0)
        // The parallax reader: an invisible background that
        // reports the card's global position as it travels.
        // Updates are a few points of offset on visible cards
        // only — no timers, no polling.
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { updateParallax(midX: geo.frame(in: .global).midX) }
                    .onChange(of: geo.frame(in: .global).midX) { _, midX in
                        updateParallax(midX: midX)
                    }
            }
        }
    }

    private func updateParallax(midX: CGFloat) {
        let delta = midX - UIScreen.main.bounds.width / 2
        let value = max(-10, min(10, delta * -0.055))
        if abs(value - parallax) > 0.5 { parallax = value }
    }
}
