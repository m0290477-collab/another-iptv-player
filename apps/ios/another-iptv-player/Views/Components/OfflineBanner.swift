import SwiftUI

/// Build 61 (B13, G5): the shared offline indicator — one slim
/// banner shown at the top of both dashboards while
/// `OfflineState` reports no network path. Local content (cached
/// catalog, downloads) stays fully usable underneath it; the
/// banner only explains why network actions are paused.
struct OfflineBannerView: View {
    @ObservedObject private var offlineState = OfflineState.shared

    var body: some View {
        if offlineState.isOffline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.caption.weight(.semibold))
                Text(L("offline.banner"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .padding(.top, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityElement(children: .combine)
        }
    }
}
