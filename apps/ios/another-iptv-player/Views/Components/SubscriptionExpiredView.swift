import SwiftUI

/// Round 12 (point 9): the ONE expired state shown when the playback
/// gate (`PlayerOverlayController.present`) blocks a presentation
/// because the playlist's provider subscription has expired. It
/// names the expiry date and routes the user to Settings, where
/// they can switch playlists or update the provider subscription.
struct SubscriptionExpiredView: View {
    let expiryDate: Date
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    private var expiryDateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: expiryDate)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text(L("expiry.blocked.title"))
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text(L("expiry.blocked.message", expiryDateText))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                onOpenSettings()
            } label: {
                Text(L("expiry.blocked.open_settings"))
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Button {
                onClose()
            } label: {
                Text(L("common.close"))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(AppTheme.background)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
