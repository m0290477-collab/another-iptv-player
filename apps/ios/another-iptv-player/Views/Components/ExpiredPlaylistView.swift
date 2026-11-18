import SwiftUI

/// Build 61 (B10, L4): the expired-account full-screen state and
/// the playback-attempt notice.
///
/// Data source is REAL provider data only: `ProviderExpiryStore`
/// (the exp_date recorded from the provider's own auth responses)
/// or the panel's expired status recorded the same way. M3U
/// playlists NEVER enter this state on a guessed date — they have
/// no expiry record, so `blockedExpiry` is nil for them; an M3U
/// playlist lands here only if a future path records an actual
/// server rejection through `M3UExpiryRejectionStore` below.
///
/// Free-forever wording (§3.5): the subscription that ended is
/// with the user's PROVIDER — the copy says exactly that.
struct ExpiredPlaylistView: View {
    let playlist: Playlist
    let expiryDate: Date
    /// Other saved playlists exist → the Switch action is offered.
    let canSwitch: Bool
    let onRenew: () -> Void
    let onSwitch: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "flame.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(AppTheme.brandGradient)
                .accessibilityHidden(true)

            Text(L("expired.title"))
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            // "Your subscription ended on <date>" — provider copy.
            Text(L("expired.message", expiryDate.formatted(date: .abbreviated, time: .omitted)))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(L("expired.provider_note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button {
                    onRenew()
                } label: {
                    Text(L("expired.renew"))
                        .font(.headline.weight(.bold))
                        .foregroundColor(AppTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(AppTheme.accent)
                        .cornerRadius(AppTheme.cornerRadius)
                }
                .buttonStyle(.plain)
                .accessibilityHint(L("expired.renew.hint"))

                if canSwitch {
                    Button {
                        onSwitch()
                    } label: {
                        Text(L("expired.switch"))
                            .font(.headline.weight(.semibold))
                            .foregroundColor(AppTheme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(AppTheme.surface)
                            .cornerRadius(AppTheme.cornerRadius)
                    }
                    .buttonStyle(.plain)
                }

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Text(L("expired.remove"))
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
    }
}

/// The plain message shown INSTEAD of the player when a playback
/// attempt targets an expired playlist (L4): presented through
/// the same overlay slot the player would have used, so the user
/// sees the message — never a spinner over a dead stream.
struct ExpiredPlaybackNoticeView: View {
    let expiryDate: Date
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text(L("expired.message", expiryDate.formatted(date: .abbreviated, time: .omitted)))
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("expired.provider_note"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                onClose()
            } label: {
                Text(L("common.ok"))
                    .font(.headline.weight(.bold))
                    .foregroundColor(AppTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.accent)
                    .cornerRadius(AppTheme.cornerRadius)
            }
            .buttonStyle(.plain)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
    }
}

/// Build 61 (B10, L4): records an ACTUAL server rejection for an
/// M3U playlist (e.g. the provider answering 401/403 to the
/// playlist fetch). This is the ONLY way an M3U playlist can
/// enter the expired state — never a guessed date. No current
/// fetch path records rejections yet (the refresh paths treat a
/// refusal as a generic failure), so in build 61 M3U playlists
/// simply never enter the state; the store exists so a future
/// rejection signal has a truthful place to land, and the guard
/// below already reads it.
enum M3UExpiryRejectionStore {
    private static let key = "provider_expiry.m3u_rejected.v1"

    static func recordRejection(playlistId: UUID) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.insert(playlistId.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    static func hasRejection(playlistId: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(playlistId.uuidString)
    }

    static func remove(playlistId: UUID) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.remove(playlistId.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}

/// The L4 verdict used at playlist activation and at the
/// present-player call site: non-nil (with the real end date)
/// when the playlist is in the expired state.
enum ExpiredPlaylistGuard {
    static func blockedState(playlist: Playlist) -> Date? {
        if playlist.kind == .m3u {
            // M3U: ONLY an actual recorded server rejection AND
            // a real recorded date — without both, there is no
            // truthful "ended on <date>" to show, so no state.
            guard M3UExpiryRejectionStore.hasRejection(playlistId: playlist.id),
                  let date = ProviderExpiryStore.expiryDate(playlistId: playlist.id)
            else { return nil }
            return date
        }
        return ProviderExpiryStore.blockedExpiry(playlistId: playlist.id)
    }

    /// Id-only form for the present-player call site, which knows
    /// the playlist id but not its kind: the Xtream verdict is the
    /// recorded exp_date; the M3U verdict additionally requires a
    /// recorded server rejection (same rule as the Playlist form).
    static func blockedState(playlistId: UUID) -> Date? {
        if let blocked = ProviderExpiryStore.blockedExpiry(playlistId: playlistId) {
            return blocked
        }
        guard M3UExpiryRejectionStore.hasRejection(playlistId: playlistId) else { return nil }
        return ProviderExpiryStore.expiryDate(playlistId: playlistId)
    }
}
