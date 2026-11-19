import Foundation
import SwiftUI

/// Build 65 (Display style 1 'Live Preview Cards'): the two NEW
/// display preferences the Display screen ships. Both are REAL —
/// each one is consumed by the layout it names:
///
/// - `PosterSizePreference` scales every poster metric in the app
///   (`PosterMetrics.scaled` multiplies by `factor`), so the choice
///   is visible on Home, the sections and search alike.
/// - `HomeDensityPreference` drives the vertical spacing between
///   Home's content rows (`HomeView`'s shelf stack).
///
/// Both persist in UserDefaults under their own keys and default
/// to today's shipped behaviour (medium / comfortable), so an
/// untouched install renders exactly as build 64 did.
enum PosterSizePreference: String, CaseIterable {
    case small, medium, large

    static let defaultsKey = "display.posterSize"

    static var current: PosterSizePreference {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)
        return PosterSizePreference(rawValue: raw ?? "") ?? .medium
    }

    /// Multiplier applied to the display-derived poster scale.
    var factor: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1.0
        case .large: return 1.18
        }
    }

    var nameKey: String { "display.poster_size.\(rawValue)" }
}

enum HomeDensityPreference: String, CaseIterable {
    case comfortable, compact

    static let defaultsKey = "display.homeDensity"

    static var current: HomeDensityPreference {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)
        return HomeDensityPreference(rawValue: raw ?? "") ?? .comfortable
    }

    /// Vertical spacing between Home's content rows.
    var shelfSpacing: CGFloat {
        switch self {
        case .comfortable: return 26
        case .compact: return 16
        }
    }

    var nameKey: String { "display.density.\(rawValue)" }
}
