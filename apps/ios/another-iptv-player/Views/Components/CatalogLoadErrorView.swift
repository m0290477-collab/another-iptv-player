import SwiftUI

/// When the catalog load fails, the shared error state the three tabs (Live/Movies/Series) show instead of a blank screen:
/// message + inline "Try Again". Previously the error only appeared
/// in a one-time alert on the Dashboard, and a user who tapped OK was left with blank tabs
/// and no way out (the only escape was Settings → Refresh All).
struct CatalogLoadErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(L("catalog.load_failed.title"))
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, 32)
            Button {
                onRetry()
            } label: {
                Label(L("common.try_again"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
