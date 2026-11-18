import SwiftUI
import UIKit

/// The iPad 11" (portrait short edge ~834 pt) design measure; on narrower screens the posters shrink proportionally.
struct PosterMetrics: Equatable, Sendable {
    /// 1.0 = referans cihaz; telefonlarda ~0.5–0.65.
    let layoutScale: CGFloat

    init(windowSize: CGSize) {
        let referenceShortSide: CGFloat = 834
        let short = min(windowSize.width, windowSize.height)
        let raw = short / referenceShortSide
        layoutScale = min(1, max(0.5, raw))
    }

    var shelfPosterWidth: CGFloat { scaled(200) }
    var shelfPosterHeight: CGFloat { scaled(300) }

    var categoryGridPosterWidth: CGFloat { scaled(200) }
    var categoryGridPosterHeight: CGFloat { scaled(300) }

    var searchGridMinWidth: CGFloat { scaled(110) }
    var searchCardWidth: CGFloat { scaled(160) }
    var searchCardHeight: CGFloat { scaled(240) }

    var liveShelfIcon: CGFloat { scaled(112) }
    var liveShelfLabelWidth: CGFloat { scaled(116) }
    var liveGridIconSize: CGFloat { scaled(180) }


    var searchLiveRowIcon: CGFloat { scaled(50) }
    var searchLiveRowLeadingInset: CGFloat { scaled(50) + 20 }

    var seriesDetailHeroWidth: CGFloat { scaled(118) }
    var seriesDetailHeroHeight: CGFloat { scaled(176) }

    var seasonStripWidth: CGFloat { scaled(120) }
    var seasonStripHeight: CGFloat { scaled(180) }

    var episodeThumbWidth: CGFloat { scaled(100) }
    var episodeThumbHeight: CGFloat { scaled(150) }
    var episodeRowDividerLeading: CGFloat { scaled(100) + 28 }

    var gridSpacing: CGFloat { scaled(16) }
    var gridRowSpacing: CGFloat { scaled(20) }
    var searchGridSpacing: CGFloat { scaled(12) }
    var searchSectionRowSpacing: CGFloat { scaled(16) }

    /// Shelf row: poster + title area (about 2 lines of caption).
    var shelfRowTotalHeight: CGFloat { shelfPosterHeight + scaled(64) }

    /// The prefetch size for the category detail grid (matches the .grid profile)
    /// Round 5: CachedImage now uses the full device scale (the 2x cover was
    /// removed — the blurry-logo fix); these helpers match too.
    func prefetchCategoryDecodePixelSize() -> CGSize {
        let s = UIScreen.main.scale
        return CGSize(
            width: ceil(categoryGridPosterWidth * s),
            height: ceil(categoryGridPosterHeight * s)
        )
    }

    /// The prefetch size for the horizontal shelf preview (matches the .shelf profile)
    func prefetchShelfDecodePixelSize() -> CGSize {
        let s = UIScreen.main.scale
        return CGSize(
            width: ceil(shelfPosterWidth * s),
            height: ceil(shelfPosterHeight * s)
        )
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        (base * layoutScale).rounded(.toNearestOrAwayFromZero)
    }
}

private struct PosterMetricsKey: EnvironmentKey {
    static var defaultValue: PosterMetrics {
        PosterMetrics(windowSize: UIScreen.main.bounds.size)
    }
}

extension EnvironmentValues {
    var posterMetrics: PosterMetrics {
        get { self[PosterMetricsKey.self] }
        set { self[PosterMetricsKey.self] = newValue }
    }
}
