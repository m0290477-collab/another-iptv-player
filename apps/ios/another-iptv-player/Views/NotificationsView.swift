import SwiftUI

// MARK: - Notifications (round 10)
//
// The Home top bar's bell opens this page. Its content is computed
// ONLY from real account data: for an Xtream playlist the page runs
// the same `verify()` the Settings account card uses and derives a
// warning from the account's actual expiry timestamp — an
// "expiring soon" item inside the last 30 days, an "expired" item
// once the date has passed. An account with no expiry (unlimited)
// or more than 30 days left produces NO item, and M3U playlists
// have no account data at all — both land on the honest empty
// state. Nothing here is sample or placeholder content.
//
// Round 11 (owner, build 47): the alert is the PROVIDER (panel)
// subscription's expiry — titled exactly "Your provider
// subscription", never presented as the app's own subscription
// ending (the app has no subscription; the owner called the old
// "Subscription Expiring — 0 days" item wrong). Round 14 (A1):
// the expired verdict is the shared exp_date TIMESTAMP verdict
// (`ProviderExpiryStore.isExpired`) — the same one the playback
// gate and the account card use. The Settings ▸ App ▸
// Notifications toggle (`notifications.expiryAlertsEnabled`)
// gates these alerts for real.
//
// Round 12 (owner, point 5): the item renders its TITLE ONLY — the
// description line under it is deleted. Round 12 (point 9): the
// page's verify also records the expiry into ProviderExpiryStore
// for the playback gate.
struct NotificationsView: View {
    let playlist: Playlist

    @AppStorage("notifications.expiryAlertsEnabled") private var expiryAlertsEnabled = true

    private struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        // Round 12 (point 5): title ONLY — the owner ordered the
        // description line under "Your provider subscription"
        // deleted. The item still appears only inside the same real
        // windows as before (expired, or expiring within 30 days).
    }

    @State private var items: [Item] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(L("notifications.empty"))
                        .font(.headline)
                    Text(L("notifications.empty.detail"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 32)
            } else {
                List {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            SettingsIconTile(systemImage: item.icon, tint: item.tint)
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(AppTheme.surface)
                    }
                }
                .listStyle(.insetGrouped)
                .cinematicScrollBackground()
            }
        }
        .navigationTitle(L("notifications.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .cinematicBackground()
        .task { await load() }
    }

    private func load() async {
        // The Settings Notifications toggle gates these alerts.
        guard expiryAlertsEnabled else {
            isLoading = false
            return
        }
        // M3U playlists carry no account/expiry data — nothing real
        // can be computed, so the page is honestly empty.
        guard playlist.kind == .xtream else {
            isLoading = false
            return
        }
        let client = XtreamAPIClient(playlist: playlist)
        if let response = try? await client.verify() {
            // Round 12 (point 9): this verify also feeds the
            // playback gate's expiry record.
            ProviderExpiryStore.record(playlistId: playlist.id, expDate: response.userInfo?.expDate)
            // Round 14 (A1): the expired verdict is the SHARED
            // timestamp verdict — `ProviderExpiryStore.isExpired`,
            // the same one the playback gate uses. No day-math
            // anywhere: the provider cuts at the exact exp_date
            // timestamp, so this page, the gate and the account
            // card can never disagree again (round 13, fault 1).
            if ProviderExpiryStore.isExpired(expDateString: response.userInfo?.expDate) {
                items = [Item(
                    icon: "exclamationmark.triangle.fill",
                    tint: .red,
                    title: L("notifications.expired.title")
                )]
            } else if let expiry = ProviderExpiryStore.parseExpiryDate(response.userInfo?.expDate) {
                // Not expired: the "expiring soon" item appears
                // inside the last 30 days before the timestamp.
                // The interval only decides WHETHER the item
                // appears — no description line is rendered
                // (round 12, point 5).
                let remainingDays = expiry.timeIntervalSinceNow / 86_400
                if remainingDays <= 30 {
                    items = [Item(
                        icon: "clock.badge.exclamationmark",
                        tint: .orange,
                        title: L("notifications.expiry.title")
                    )]
                }
            }
        }
        isLoading = false
    }
}
