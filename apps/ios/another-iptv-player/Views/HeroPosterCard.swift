import SwiftUI

// MARK: - Hero poster card (build 87, item 16 — owner-picked design 4)
//
// The immersive carousel card from the owner's picked mockup
// (hero option 4, "carousel peek"): ONE large portrait poster
// card with big rounded corners; the previous/next cards peek
// at the edges scaled down and darker (the carousel applies
// that treatment — this card renders itself at full strength);
// the title sits CENTERED over a bottom gradient with the
// star row and meta line under it, and the Play (solid accent)
// + Details (glass) actions as rounded rectangles beneath.
// Portrait posters are this design's native art; a wide
// backdrop fills the same card. The art chain is the
// build-81/82 one: backdrop first, a load failure swaps to
// the poster, and an item with no working art renders
// CachedImage's designed title card — never a blank slab.

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

    /// Filled stars out of five, derived from the DISPLAYED
    /// rating value (10-scale → 5-scale, rounded) — the
    /// mockup's 4.8/5 title shows five; nothing is invented:
    /// no rating text, no star row.
    private var filledStars: Int? {
        guard let ratingText,
              let value = Double(ratingText.filter { $0.isNumber || $0 == "." })
        else { return nil }
        return min(5, max(0, Int((value / 2).rounded())))
    }

    private var metaText: String? {
        var parts: [String] = []
        if let ratingText { parts.append(ratingText) }
        if let metaLine { parts.append(metaLine) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
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
                    title: title,
                    onLoadFailed: {
                        if artURL == backdropURL { backdropLoadFailed = true }
                    }
                )
                // Parallax: the art is scaled a touch so the
                // shift never bares an edge against the frame.
                .scaleEffect(1.06)
                .offset(x: parallax)
                .onChange(of: backdropURL) { _, _ in backdropLoadFailed = false }

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.45),
                        .init(color: Color.black.opacity(0.88), location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onTapGesture { if showsControls { onDetails() } }

            VStack(spacing: 7) {
                Text(title)
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                if let filledStars {
                    HStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { index in
                            Image(systemName: index < filledStars ? "star.fill" : "star")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppTheme.ratingGold)
                        }
                    }
                }
                if let metaText {
                    Text(metaText)
                        .font(AppTheme.fontMetadata.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
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
            .padding(.bottom, 18)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
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
