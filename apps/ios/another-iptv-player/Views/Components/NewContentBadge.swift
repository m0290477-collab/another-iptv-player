import SwiftUI

/// Build 61 (B8, R2): the NEW badge — Design-4 red-orange capsule,
/// shown on posters/rows for items first seen within the last 7 days
/// and not yet opened (state lives in `FirstSeenStore`). Pure view:
/// callers decide visibility from the store so grids stay cheap.
struct NewContentBadge: View {
    var body: some View {
        Text(L("newcontent.badge"))
            .font(.caption2.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(AppTheme.accent))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}
