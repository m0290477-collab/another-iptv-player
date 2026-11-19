import SwiftUI

/// Build 66 (W4, item 15a): shown when the app's storage could not
/// be opened at all — disk open, backup restore and the in-memory
/// fallback all failed (see Persistence). Replaces the pre-66
/// behaviour, which was a fatalError crash loop on every launch.
///
/// Honest copy rules: the user's data has NOT been deleted (the
/// on-disk file is untouched by this path), and the one action
/// offered — Try again — re-attempts the open exactly once per tap.
struct StorageUnavailableView: View {
    /// Re-attempts the storage open once; returns whether storage
    /// is usable now (the caller then dismisses this screen).
    let onRetry: () -> Bool
    /// Called after a successful retry so the parent can swap the
    /// normal UI back in.
    let onRecovered: () -> Void

    @State private var retryFailed = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(L("storage.unavailable.title"))
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            Text(L("storage.unavailable.message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if retryFailed {
                Text(L("storage.unavailable.retry_failed"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(L("common.try_again")) {
                if onRetry() {
                    onRecovered()
                } else {
                    retryFailed = true
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
