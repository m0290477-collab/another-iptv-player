import SwiftUI
import UIKit
import Nuke
import GRDB
import UniformTypeIdentifiers

/// Small rounded icon tile at the leading edge of a settings row — the
/// iOS-settings / elite treatment: a tinted rounded square with a white
/// glyph. Shared by both playlist settings screens (round 6) so their
/// rows read as one designed system instead of plain text rows.
struct SettingsIconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// Round 11: a settings row with a trailing menu picker — STRONG's
/// value rows ("Skip-intro length  85 s", "Default sleep timer
/// 30 min"). The label carries the
/// shared icon tile + title; the menu shows the current value at the
/// trailing edge. Used by both playlist settings screens for the
/// round-11 Player/App value settings.
struct SettingsPickerRow<Value: Hashable, Options: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    @Binding var selection: Value
    @ViewBuilder let options: () -> Options

    var body: some View {
        Picker(selection: $selection) {
            options()
        } label: {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: systemImage, tint: tint)
                Text(title)
            }
        }
        .pickerStyle(.menu)
    }
}

/// Round 12 (point 6, owner's explicit order): the Activation
/// section — STRONG's arrangement (header + card rows), placed after
/// Playlists and before Player in BOTH settings screens. Every value
/// is real: "Activated ✓" and "Lifetime Subscription" describe the
/// app itself (free forever — never the word "currently"), and the
/// Device ID / PIN come from `DeviceActivationStore` (generated once
/// by the app, persisted, stable per install), each with a working
/// copy button. No network call, no backend, nothing read from the
/// owner's screenshots.
struct ActivationSettingsSection: View {
    private enum CopiedField { case deviceID, pin }

    @State private var copiedField: CopiedField?
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        // Round 14 (B4): ONE short purpose line under the group
        // title — the card itself (name, "Activated ✓", Device ID /
        // PIN, "Lifetime Subscription") is exactly as the owner
        // ordered in round 12 and does not change.
        Section(header: VStack(alignment: .leading, spacing: 3) {
            Text(L("settings.group.activation"))
            Text(L("settings.scope.whole_app"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(nil)
            Text(L("settings.activation.purpose"))
                .font(.caption)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }) {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: "checkmark.seal.fill", tint: .green)
                Text(L("settings.activation.activated"))
                    .font(.body.weight(.semibold))
                Spacer()
                Image(systemName: "checkmark")
                    .font(.body.weight(.bold))
                    .foregroundColor(.green)
            }

            activationValueRow(
                systemImage: "doc.on.doc.fill",
                tint: .orange,
                label: L("settings.activation.device_id"),
                value: DeviceActivationStore.deviceID,
                field: .deviceID
            )

            activationValueRow(
                systemImage: "lock.fill",
                tint: .gray,
                label: L("settings.activation.pin"),
                value: DeviceActivationStore.pin,
                field: .pin
            )

            HStack(spacing: 12) {
                SettingsIconTile(systemImage: "infinity", tint: AppTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("settings.activation.lifetime"))
                    Text(L("settings.activation.lifetime_desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear { copyResetTask?.cancel() }
    }

    private func activationValueRow(
        systemImage: String, tint: Color, label: String, value: String, field: CopiedField
    ) -> some View {
        HStack(spacing: 12) {
            SettingsIconTile(systemImage: systemImage, tint: tint)
            Text(label)
            Spacer()
            Text(value)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                copy(value, field: field)
            } label: {
                Image(systemName: copiedField == field ? "checkmark" : "doc.on.doc")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(copiedField == field ? Color.green : AppTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("settings.activation.copy"))
        }
    }

    private func copy(_ value: String, field: CopiedField) {
        UIPasteboard.general.string = value
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copiedField = field
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { copiedField = nil }
        }
    }
}

/// Round 14 (B4): Default video fit — bound to the SAME AppStorage
/// key the player reads (`player.videoAspectMode`, values are the
/// `VideoAspectMode` raw values), so the Settings choice and the
/// in-player cycle can never disagree. Fit / Fill are the two
/// user-facing presentations (the enum's third case, Center/1:1,
/// stays reachable from the player's own cycle).
struct VideoFitSettingsRow: View {
    @AppStorage("player.videoAspectMode") private var videoAspectModeRaw = VideoAspectMode.fit.rawValue

    var body: some View {
        SettingsPickerRow(
            systemImage: "rectangle.arrowtriangle.2.inward",
            tint: .gray,
            title: L("settings.player.video_fit.title"),
            selection: $videoAspectModeRaw
        ) {
            Text(L("player.aspect_fit")).tag(VideoAspectMode.fit.rawValue)
            Text(L("player.aspect_fill")).tag(VideoAspectMode.fill.rawValue)
        }
    }
}

/// Round 14 (B4): Subtitle Appearance row — presents the EXISTING
/// `SubtitleAppearanceSheet` (previously orphaned: presented from no
/// screen). Presented with no live player, so the sheet persists via
/// `SubtitleAppearancePersistence` and the next playback picks the
/// appearance up.
struct SubtitleAppearanceSettingsRow: View {
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: "captions.bubble.fill", tint: .gray)
                Text(L("settings.player.subtitle_appearance"))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            SubtitleAppearanceSheet(player: nil)
        }
    }
}

/// Round 14 (B4): Audio Delay row — the SAME storage the tracks
/// panel uses (`AudioDelayPersistence`: load on appear, save on
/// change, same range/step and the same millisecond display the
/// PlaybackTrackSettingsSheet shows).
struct AudioDelaySettingsRow: View {
    @State private var audioDelaySeconds = AudioDelayPersistence.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: "waveform.path.ecg", tint: .gray)
                Text(L("player.audio_delay.label"))
                Spacer()
                Text(audioDelayDisplay)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $audioDelaySeconds,
                in: AudioDelayPersistence.range,
                step: AudioDelayPersistence.step
            )
            .padding(.leading, 40)
        }
        .padding(.vertical, 2)
        .onChange(of: audioDelaySeconds) { _, new in
            AudioDelayPersistence.save(new)
        }
    }

    private var audioDelayDisplay: String {
        let ms = Int((audioDelaySeconds * 1000).rounded())
        if ms == 0 { return L("subtitle.no_delay") }
        return ms > 0 ? "+\(ms) ms" : "\(ms) ms"
    }
}

/// Round 14 (B11): ELITE form building blocks for the Add Playlist
/// screens — a cinematic surface card, a group header and the
/// field label / field chrome the playlist gate uses, so the Add /
/// Edit screens share the gate's designed look instead of the
/// classic Form rows.
struct SettingsFormCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

/// Round 14 (B11): group header for the ELITE Add/Edit forms.
struct SettingsGroupHeader: View {
    let title: String

    var body: some View {
        Text(title)
            // ST5 (fixer): chrome font via AppFont — IBM Plex Sans
            // Arabic (SemiBold) when Arabic, identical system
            // headline otherwise.
            .font(AppFont.font(.headline, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Round 14 (B11): small label above a form field.
struct SettingsFieldLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Round 14 (B11): the gate's field chrome — padded, elevated
/// surface, design corner radius.
struct SettingsFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(AppTheme.elevated)
            .cornerRadius(AppTheme.cornerRadius)
    }
}

extension View {
    func settingsFieldChrome() -> some View {
        modifier(SettingsFieldChrome())
    }
}

/// Accent color picker (round 7) — lives in the App group of both
/// playlist settings screens, per the owner's order ("there must be an
/// option to change the app's color"). A row of preset swatches; the
/// selected one carries a checkmark and a bright ring. Tapping a swatch
/// sets `AccentThemeStore.shared.preset`, which persists the choice and
/// recolors the app accent everywhere (tab bar, Play buttons, "See
/// all", Featured badge, toggles, gate sign-in — see the store). The
/// LIVE badge red and the rating gold are semantic and do not follow.
struct AccentColorPickerRow: View {
    @ObservedObject private var theme = AccentThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: "paintpalette.fill", tint: theme.color)
                Text(L("settings.accent_color"))
            }
            HStack(spacing: 12) {
                ForEach(AccentPreset.allCases, id: \.self) { preset in
                    Button {
                        theme.preset = preset
                    } label: {
                        Circle()
                            .fill(preset.color)
                            .frame(width: 30, height: 30)
                            .overlay {
                                if theme.preset == preset {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        .white.opacity(theme.preset == preset ? 0.9 : 0.15),
                                        lineWidth: theme.preset == preset ? 2 : 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L(preset.nameKey))
                }
            }
            .padding(.leading, 40)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Round 15 (Part C) shared settings infrastructure

/// C5: a section header carrying the explicit scope division —
/// the group title plus a small "This playlist" / "Whole app"
/// caption, so every group on both settings dashboards states
/// which scope its rows belong to.
struct ScopedSectionHeader: View {
    let title: String
    /// True → "This playlist"; false → "Whole app".
    let thisPlaylist: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(L(thisPlaylist ? "settings.scope.this_playlist" : "settings.scope.whole_app"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }
}

/// C5: settings search matching — a section stays visible while
/// searching when the (already lowercased) query appears in its
/// keyword string (localized titles + feature names). An empty
/// query shows everything.
func settingsSearchMatches(_ query: String, _ keywords: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return true }
    return keywords.lowercased().contains(q)
}

/// C13: the last known reachability of a playlist, persisted per
/// playlist from REAL verify/sync outcomes only (Settings account
/// fetch, Test Connection, My Playlists refresh, gate verify).
/// `unknown` = never checked — shown honestly as "Not checked yet".
enum PlaylistHealth: String {
    case responds, refused, expired, unknown
}

enum PlaylistHealthStore {
    private static let key = "playlist.health.v1"

    static func health(for playlistId: UUID) -> PlaylistHealth {
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return PlaylistHealth(rawValue: dict[playlistId.uuidString] ?? "") ?? .unknown
    }

    static func record(_ health: PlaylistHealth, for playlistId: UUID) {
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        dict[playlistId.uuidString] = health.rawValue
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// Round 17 (R17-2/R17-5): removal for the shared account-data
    /// deletion path — one playlist's verdict, or every verdict.
    static func remove(for playlistId: UUID) {
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        guard dict.removeValue(forKey: playlistId.uuidString) != nil else { return }
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// The health verdict after a successful verify: expired when
    /// the shared expiry store says so, otherwise responding.
    static func recordVerified(playlistId: UUID, expDate: String?) {
        ProviderExpiryStore.record(playlistId: playlistId, expDate: expDate)
        record(ProviderExpiryStore.isExpired(expDateString: expDate) ? .expired : .responds,
               for: playlistId)
    }
}

/// C13: the user's playlist library arrangement — the marked
/// default and the drag-reorder order — persisted in UserDefaults
/// (names/ids only; no credentials, so both backup flows may carry
/// the default's id harmlessly, though neither does today).
enum PlaylistLibraryStore {
    private static let defaultKey = "playlist.defaultId"
    private static let orderKey = "playlist.order"

    static var defaultId: UUID? {
        get { UserDefaults.standard.string(forKey: defaultKey).flatMap(UUID.init(uuidString:)) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: defaultKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultKey)
            }
        }
    }

    static var order: [UUID] {
        (UserDefaults.standard.stringArray(forKey: orderKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    static func saveOrder(_ playlists: [Playlist]) {
        UserDefaults.standard.set(playlists.map { $0.id.uuidString }, forKey: orderKey)
    }

    /// Round 17 (R17-2/R17-5): drop one playlist from the default /
    /// order records (shared account-data deletion path).
    static func remove(playlistId: UUID) {
        if defaultId == playlistId { defaultId = nil }
        let current = order
        let filtered = current.filter { $0 != playlistId }
        if filtered != current {
            UserDefaults.standard.set(filtered.map(\.uuidString), forKey: orderKey)
        }
    }

    /// Playlists in the user's saved order; ones missing from the
    /// saved order (newly added) follow in creation order.
    static func sorted(_ playlists: [Playlist]) -> [Playlist] {
        let order = Self.order
        return playlists.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max
            let ib = order.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            return a.createdAt < b.createdAt
        }
    }
}

// MARK: - Preference keys, Reset, Backup (C5 + C3)

/// The app's REAL preference keys, enumerated from the tree's
/// @AppStorage / UserDefaults usage. Reset to Defaults and the
/// settings export/import operate on exactly this list — playlists,
/// history, progress, downloads, the expiry records, the PIN and
/// the gate's last-playlist name are NEVER in it.
enum AppPreferenceKeys {
    static let all: [String] = [
        // Player
        "player.pipEnabled", "player.continuePlayingInBackground",
        "player.speedUpOnLongPress", "player.autoPlayNextEpisode",
        "player.showSkipIntro", "player.skipIntroLengthSeconds",
        "player.defaultSleepTimerMinutes",
        "player.videoAspectMode",
        // Round 16 (R6): "player.debugOverlayEnabled" and
        // "player.nextEpisodeTimerSeconds" leave the list — both
        // features are deleted (the overlay in this round, the
        // post-end timer in round 14), so reset/export no longer
        // carries their fossil keys.
        // Round 20 (R20-2 cleanup): "player.enginePreference"
        // leaves the list by the same rule — its picker is deleted
        // and the R20-4 playback restoration removed its only
        // reader, so reset/export no longer carries the fossil
        // key. A stale value already stored on a device is inert
        // (nothing reads it) and is simply never carried again.
        // Round 15 player features
        "player.zappingEnabled", "player.zappingDirection",
        "player.nextEpisodeCardMode",
        // Downloads
        "download.wifi_only", "downloads.autoDownloadNextEpisode",
        // Notifications & reminders
        "notifications.expiryAlertsEnabled",
        "reminders.enabled", "reminders.leadTimeMinutes",
        // Appearance / motion / sound
        "app.accent_preset", "app.selected_language",
        "motion.intensity", "settings.uiSounds",
        "dashboard_selected_tab",
        // Build 61 (B3): appearance choice, buffer size and the
        // play-last-channel-on-launch toggle.
        "app.appearance", "player.bufferSize",
        "app.playLastChannelOnLaunch",
        // Build 61 (B9): loudness toggle, data-saver toggle,
        // hide-dead toggle + channel-health records, per-content
        // track/delay memory, TTFF samples.
        "player.loudnessNormalization", "perf.datasaver_on_cellular",
        "deadchannels.hide_dead", "deadchannels.health.v1",
        "playback.perContentTrackPreferences.v1", "perf.ttff.samples.v1",
        // Playback detail stores (audio delay, subtitle look,
        // per-kind track choices — all plain preferences)
        "playback.audioDelaySeconds", "playback.subtitleAppearance.v2",
        "playback.trackPreferences.v1",
        // PIN behaviour (the PIN itself lives in the Keychain and
        // is never reset from here)
        "pin.lockSettings",
        // Gate form drafts (non-sensitive fields only)
        "gate.draft.xtream.name", "gate.draft.xtream.url", "gate.draft.xtream.username",
        "gate.draft.m3u.name", "gate.draft.m3u.url"
    ]

    /// C5 Reset to Defaults: removes every preference above. The
    /// accent store is also pushed back to its default so the UI
    /// repaints immediately instead of at next launch.
    static func resetToDefaults() {
        for key in all { UserDefaults.standard.removeObject(forKey: key) }
        AccentThemeStore.shared.preset = .blue
    }
}

/// A JSON-friendly UserDefaults value for the backup file.
enum BackupValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        self = .string(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }

    static func read(_ key: String) -> BackupValue? {
        let defaults = UserDefaults.standard
        guard let raw = defaults.object(forKey: key) else { return nil }
        switch raw {
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Double: return .double(v)
        case let v as String: return .string(v)
        default: return nil
        }
    }

    func write(to key: String) {
        switch self {
        case .bool(let v): UserDefaults.standard.set(v, forKey: key)
        case .int(let v): UserDefaults.standard.set(v, forKey: key)
        case .double(let v): UserDefaults.standard.set(v, forKey: key)
        case .string(let v): UserDefaults.standard.set(v, forKey: key)
        }
    }
}

/// One playlist inside a backup file. `password` is present ONLY in
/// the C3 full backup (includesCredentials == true); the C5
/// settings export always writes nil and import re-prompts.
struct BackupPlaylistDTO: Codable, Equatable {
    /// Build 61 (B3, S5): the source playlist's id — never a
    /// credential; it exists so the backup's library entries
    /// (favorites / watch-later, keyed by playlist id) can be
    /// mapped onto the target playlist on import. Optional so
    /// backup files written before build 61 still decode.
    var id: String?
    var name: String
    var serverURL: String
    var username: String
    var password: String?
    var kind: String
    var filterAdultContent: Bool
    var m3uEpgURL: String?
    var epgURLOverride: String?
    var epgEnabled: Bool

    init(playlist: Playlist, includePassword: Bool) {
        id = playlist.id.uuidString
        name = playlist.name
        serverURL = playlist.serverURL
        username = playlist.username
        password = includePassword ? playlist.password : nil
        kind = playlist.type
        filterAdultContent = playlist.filterAdultContent
        m3uEpgURL = playlist.m3uEpgURL
        epgURLOverride = playlist.epgURLOverride
        epgEnabled = playlist.epgEnabled
    }

    func makePlaylist(password: String) -> Playlist {
        Playlist(
            name: name, serverURL: serverURL, username: username,
            password: password,
            filterAdultContent: filterAdultContent,
            type: PlaylistKind(rawValue: kind) ?? .xtream,
            m3uEpgURL: m3uEpgURL, epgURLOverride: epgURLOverride,
            epgEnabled: epgEnabled
        )
    }
}

/// The ONE backup file format behind both flows (C5 + C3): the C5
/// settings JSON (includesCredentials == false, passwords absent,
/// re-entered on import) and the C3 full backup (== true, warned in
/// plain text in the export UI). Import accepts either.
struct SuperXBackupFile: Codable {
    var format = "superx-backup"
    var version = 1
    var includesCredentials: Bool
    var settings: [String: BackupValue]
    var playlists: [BackupPlaylistDTO]
    /// Build 61 (B3, S5): favorites + watch-later library
    /// (`BackupService`). Optional: files written before build 61
    /// have no library and import exactly as before.
    var library: BackupService.LibraryDTO?

    static func make(playlists: [Playlist], includeCredentials: Bool) -> SuperXBackupFile {
        var settings: [String: BackupValue] = [:]
        for key in AppPreferenceKeys.all {
            if let value = BackupValue.read(key) { settings[key] = value }
        }
        return SuperXBackupFile(
            includesCredentials: includeCredentials,
            settings: settings,
            playlists: playlists.map { BackupPlaylistDTO(playlist: $0, includePassword: includeCredentials) }
        )
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Applies the file's preference values (whitelisted keys only —
    /// a file can never write an arbitrary UserDefaults key).
    func applySettings() {
        for (key, value) in settings where AppPreferenceKeys.all.contains(key) {
            value.write(to: key)
        }
        if let raw = settings["app.accent_preset"], case .string(let name) = raw,
           let preset = AccentPreset(rawValue: name) {
            AccentThemeStore.shared.preset = preset
        }
    }
}

// MARK: - Parental PIN UI (C3 + C5 guards)

/// PIN entry form: a numeric secure field + submit. Used inline by
/// the settings lock screen and inside `PINEntrySheet` for the
/// one-off guards (adult filter OFF, Delete Account).
struct PINEntryForm: View {
    var message: String?
    let onSuccess: () -> Void

    @State private var code = ""
    @State private var showError = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30))
                .foregroundColor(AppTheme.accent)
            Text(L("pin.enter"))
                .font(.headline)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            SecureField(L("pin.enter"), text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.title3.monospacedDigit())
                .padding(12)
                .background(AppTheme.elevated)
                .cornerRadius(AppTheme.cornerRadius)
                .frame(maxWidth: 220)
            if showError {
                Text(L("pin.wrong"))
                    .font(.caption)
                    .foregroundColor(.red)
            }
            Button {
                if PINStore.verify(code) {
                    onSuccess()
                } else {
                    showError = true
                    code = ""
                }
            } label: {
                Text(L("pin.unlock_settings"))
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
                    .background(AppTheme.accent)
                    .cornerRadius(AppTheme.cornerRadius)
            }
            .buttonStyle(.plain)
            .disabled(code.count < 4)
            .opacity(code.count < 4 ? 0.45 : 1)
        }
        .padding(24)
    }
}

/// Sheet wrapper for the one-off PIN guards.
struct PINEntrySheet: View {
    var message: String?
    let onSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            HStack {
                Button(L("common.cancel")) { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            PINEntryForm(message: message) {
                dismiss()
                onSuccess()
            }
            Spacer()
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
    }
}

/// The full-screen lock shown instead of a Settings form when
/// "Lock settings with PIN" is on and a PIN exists (C3). No cancel:
/// opening Settings requires the PIN, exactly as ordered.
struct PINLockScreen: View {
    let onUnlock: () -> Void

    var body: some View {
        PINEntryForm(message: L("pin.lock_settings.desc"), onSuccess: onUnlock)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.background.ignoresSafeArea())
    }
}

/// Set / change PIN sheet: current PIN first (when one exists),
/// then the new PIN twice. PINs are 4–6 digits.
private struct PINSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void

    @State private var current = ""
    @State private var newPIN = ""
    @State private var confirmPIN = ""
    @State private var errorText: String?

    private var hasExistingPIN: Bool { PINStore.hasPIN }

    var body: some View {
        NavigationStack {
            Form {
                if hasExistingPIN {
                    Section {
                        SecureField(L("pin.enter_current"), text: $current)
                            .keyboardType(.numberPad)
                    }
                }
                Section {
                    SecureField(L("pin.enter_new"), text: $newPIN)
                        .keyboardType(.numberPad)
                    SecureField(L("pin.confirm_new"), text: $confirmPIN)
                        .keyboardType(.numberPad)
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .cinematicScrollBackground()
            .navigationTitle(L("pin.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) { save() }
                }
            }
        }
    }

    private func save() {
        if hasExistingPIN, !PINStore.verify(current) {
            errorText = L("pin.wrong")
            return
        }
        let digits = newPIN.trimmingCharacters(in: .whitespaces)
        guard (4...6).contains(digits.count), digits.allSatisfy(\.isNumber) else {
            errorText = L("pin.wrong")
            return
        }
        guard digits == confirmPIN.trimmingCharacters(in: .whitespaces) else {
            errorText = L("pin.mismatch")
            return
        }
        if PINStore.setPIN(digits) {
            onDone()
            dismiss()
        } else {
            errorText = L("common.unknown_error")
        }
    }
}

/// C3/C5: the Parental PIN group shared by both settings screens —
/// set/change/remove the Keychain PIN and the "Lock settings with
/// PIN" toggle. The guards themselves live where the guarded
/// actions live (the screens' filter toggle, PrivacyLegalSection).
struct ParentalPINSection: View {
    @AppStorage("pin.lockSettings") private var lockSettings = false
    @State private var hasPIN = PINStore.hasPIN
    @State private var showSetup = false
    @State private var showRemoveEntry = false

    var body: some View {
        Section(header: ScopedSectionHeader(title: L("pin.title"), thisPlaylist: false)) {
            if hasPIN {
                Button {
                    showSetup = true
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "lock.rotation", tint: .gray)
                        Text(L("pin.change"))
                            .foregroundColor(.primary)
                    }
                }
                .buttonStyle(.plain)

                Toggle(isOn: $lockSettings) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "lock.fill", tint: AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("pin.lock_settings"))
                            Text(L("pin.lock_settings.desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button(role: .destructive) {
                    showRemoveEntry = true
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "lock.open.fill", tint: .red)
                        Text(L("pin.remove"))
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    showSetup = true
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "lock.fill", tint: AppTheme.accent)
                        Text(L("pin.set"))
                            .foregroundColor(.primary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showSetup) {
            PINSetupSheet { hasPIN = PINStore.hasPIN }
        }
        .sheet(isPresented: $showRemoveEntry) {
            PINEntrySheet(message: L("pin.remove")) {
                PINStore.clearPIN()
                lockSettings = false
                hasPIN = false
            }
        }
        .onAppear { hasPIN = PINStore.hasPIN }
    }
}

// MARK: - App-open lock (build 61, B15, W1)

/// W1: the APP-open lock group, shown directly under the parental
/// PIN group in both settings screens. This lock guards opening
/// the app itself (cold start + return from background) and is a
/// DIFFERENT lock from the parental PIN above: separate Keychain
/// item (salted hash), separate purpose, and the copy says so.
/// Unlock is by Face ID / Touch ID with the device passcode always
/// available as fallback, or by the app PIN when one is set — the
/// passcode path is what guarantees the user can never be locked
/// out permanently, so turning the lock on requires at least one
/// working unlock method (device auth evaluable, or set a PIN
/// first — the toggle routes there).
struct AppLockSection: View {
    @AppStorage(AppLockService.enabledKey) private var appLockEnabled = false
    @ObservedObject private var lockService = AppLockService.shared
    @State private var hasPIN = AppLockService.hasPIN
    @State private var showSetup = false
    @State private var showRemoveEntry = false
    @State private var pendingEnable = false

    var body: some View {
        Section(header: ScopedSectionHeader(title: L("applock.title"), thisPlaylist: false)) {
            Toggle(isOn: Binding(get: { appLockEnabled }, set: { setEnabled($0) })) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "lock.shield.fill", tint: AppTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("applock.enable"))
                        Text(L("applock.enable.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if hasPIN {
                Button {
                    showSetup = true
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "lock.rotation", tint: .gray)
                        Text(L("applock.pin_change"))
                            .foregroundColor(.primary)
                    }
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    showRemoveEntry = true
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "lock.open.fill", tint: .red)
                        Text(L("applock.pin_remove"))
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    showSetup = true
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "lock.fill", tint: AppTheme.accent)
                        Text(L("applock.pin_set"))
                            .foregroundColor(.primary)
                    }
                }
                .buttonStyle(.plain)
            }

            Text(L("applock.note"))
                .font(.caption)
                .foregroundColor(.secondary)
            Text(L("applock.passcode_note"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .sheet(isPresented: $showSetup) {
            AppPINSetupSheet {
                hasPIN = AppLockService.hasPIN
                if pendingEnable, AppLockService.hasPIN {
                    appLockEnabled = true
                }
                pendingEnable = false
            }
        }
        .sheet(isPresented: $showRemoveEntry) {
            AppPINEntrySheet {
                AppLockService.clearPIN()
                hasPIN = false
            }
        }
        .onAppear { hasPIN = AppLockService.hasPIN }
    }

    /// Turning the lock on requires a working unlock method: when
    /// the device offers neither biometrics nor a passcode AND no
    /// app PIN exists yet, route to PIN setup first and enable
    /// only once a PIN is stored.
    private func setEnabled(_ newValue: Bool) {
        guard newValue else {
            appLockEnabled = false
            return
        }
        if AppLockService.hasPIN || lockService.canUseDeviceOwnerAuthentication() {
            appLockEnabled = true
        } else {
            pendingEnable = true
            showSetup = true
        }
    }
}

// MARK: - Image cache row (C5) — REMOVED in build 61 (B3, O6)
//
// The round-15 image-cache size/clear row that lived here (and
// was shown inside NewFeatureSettingsSection) is gone: build
// 61's Storage group (StorageSettingsSection, below) is the ONE
// cache size/clear control in Settings, per the owner's
// single-instance rule. Its pipeline facts still hold — the
// shared ImagePipeline ("com.superx.images" DataCache) is what
// B2's StorageService measures and clears.

// MARK: - New feature settings (C5)

/// C5: the settings born with build 50's features, shared by both
/// dashboards so each control exists exactly once per screen with
/// the exact AppStorage keys the features read:
/// - Reminders: "reminders.enabled" (separate from the expiry
///   alerts toggle) + "reminders.leadTimeMinutes" (5/10/15/30).
/// - Zapping: "player.zappingEnabled" (default ON) +
///   "player.zappingDirection" ("upNext" / "downNext").
/// - Motion intensity: "motion.intensity" ("full"/"reduced"/"off").
/// - T-50 card mode: "player.nextEpisodeCardMode" ("auto"/"ask").
/// - UI sounds: "settings.uiSounds" (default ON, C12's gate).
/// (The auto-download-next toggle with
/// key "downloads.autoDownloadNextEpisode", default OFF, already
/// lives in both screens' Downloads groups — not duplicated here.)
struct NewFeatureSettingsSection: View {
    @AppStorage("reminders.enabled") private var remindersEnabled = true
    @AppStorage("reminders.leadTimeMinutes") private var reminderLeadTimeMinutes = 10
    @AppStorage("player.zappingEnabled") private var zappingEnabled = true
    @AppStorage("player.zappingDirection") private var zappingDirection = "upNext"
    @AppStorage("motion.intensity") private var motionIntensity = "full"
    @AppStorage("player.nextEpisodeCardMode") private var nextEpisodeCardMode = "auto"
    @AppStorage("settings.uiSounds") private var uiSounds = true

    var body: some View {
        Section(header: ScopedSectionHeader(title: L("settings.group.advanced"), thisPlaylist: false)) {
            Toggle(isOn: $remindersEnabled) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "bell.badge.fill", tint: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("reminders.enabled.title"))
                        Text(L("reminders.enabled.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsPickerRow(
                systemImage: "timer",
                tint: .orange,
                title: L("reminders.lead_time"),
                selection: $reminderLeadTimeMinutes
            ) {
                ForEach([5, 10, 15, 30], id: \.self) { minutes in
                    Text(L("player.sleep_timer.minutes", minutes)).tag(minutes)
                }
            }
            .disabled(!remindersEnabled)
            .opacity(remindersEnabled ? 1 : 0.45)

            Toggle(isOn: $zappingEnabled) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "arrow.up.arrow.down", tint: AppTheme.accent)
                    Text(L("player.zapping.enabled"))
                }
            }

            SettingsPickerRow(
                systemImage: "hand.draw.fill",
                tint: AppTheme.accent,
                title: L("player.zapping.direction"),
                selection: $zappingDirection
            ) {
                Text(L("player.zapping.direction.up_next")).tag("upNext")
                Text(L("player.zapping.direction.down_next")).tag("downNext")
            }
            .disabled(!zappingEnabled)
            .opacity(zappingEnabled ? 1 : 0.45)

            SettingsPickerRow(
                systemImage: "wand.and.stars",
                tint: SectionTheme.series,
                title: L("motion.intensity.title"),
                selection: $motionIntensity
            ) {
                Text(L("motion.intensity.full")).tag("full")
                Text(L("motion.intensity.reduced")).tag("reduced")
                Text(L("common.off")).tag("off")
            }

            SettingsPickerRow(
                systemImage: "forward.frame.fill",
                tint: .teal,
                title: L("player.next_episode_card.title"),
                selection: $nextEpisodeCardMode
            ) {
                Text(L("player.next_episode_card.auto")).tag("auto")
                Text(L("player.next_episode_card.ask")).tag("ask")
            }

            Toggle(isOn: $uiSounds) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "speaker.wave.2.fill", tint: .pink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("settings.ui_sounds.title"))
                        Text(L("settings.ui_sounds.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        }
    }
}

// MARK: - Backup & Reset (C5 + C3)

/// C5 + C3 as ONE coherent pair of flows over the single
/// `SuperXBackupFile` format:
/// - "Export settings (no passwords)": preferences + playlists as
///   JSON, passwords EXCLUDED; import re-prompts for each Xtream
///   password before the playlist becomes usable.
/// - "Export full backup (with passwords)": the C3 local-file
///   export — credentials included, behind a plain-text warning
///   alert before the share sheet is even offered.
/// Import accepts either file. Reset to Defaults sits here too.
struct BackupSettingsSection: View {
    let playlists: [Playlist]

    @State private var settingsExportURL: URL?
    @State private var fullExportURL: URL?
    @State private var showFullWarning = false
    @State private var fullExportReady = false
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var showImportResult = false
    @State private var pendingPasswordDTOs: [BackupPlaylistDTO] = []
    @State private var enteredPasswords: [Int: String] = [:]
    @State private var showPasswordPrompt = false
    @State private var showResetConfirm = false
    @State private var showResetDone = false
    // Build 61 (B3, S5): import is two-step — a decoded, validated
    // file waits here behind a summary + explicit confirm before
    // anything is applied.
    @State private var pendingImportFile: SuperXBackupFile?
    @State private var showImportSummary = false
    @State private var importSummaryText = ""
    /// Source playlist id → target playlist id, built as imported
    /// playlists land; the library apply maps through it.
    @State private var libraryIdMap: [String: UUID] = [:]
    /// The confirmed file, kept while its Xtream passwords are
    /// being re-entered — its library applies once those playlists
    /// exist (the password sheet's Save finishes the import).
    @State private var pendingLibraryFile: SuperXBackupFile?

    var body: some View {
        Section(header: ScopedSectionHeader(title: L("settings.backup.title"), thisPlaylist: false)) {
            if let settingsExportURL {
                ShareLink(item: settingsExportURL) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "square.and.arrow.up", tint: AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings.backup.export_settings"))
                                .foregroundColor(.primary)
                            Text(L("settings.backup.export_settings.desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Button {
                showFullWarning = true
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "exclamationmark.lock.fill", tint: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("settings.backup.export_full"))
                            .foregroundColor(.primary)
                        Text(L("settings.backup.export_full.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if fullExportReady, let fullExportURL {
                ShareLink(item: fullExportURL) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "square.and.arrow.up.fill", tint: .orange)
                        Text(L("settings.backup.export_full.confirm"))
                            .foregroundColor(AppTheme.accent)
                    }
                }
            }

            Button {
                showImporter = true
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "square.and.arrow.down", tint: .green)
                    Text(L("settings.backup.import"))
                        .foregroundColor(.primary)
                }
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "arrow.counterclockwise", tint: .red)
                    Text(L("settings.reset.title"))
                }
            }
            .buttonStyle(.plain)
        }
        .task(id: playlists.count) { await prepareSettingsExport() }
        .alert(L("settings.backup.full_warning.title"), isPresented: $showFullWarning) {
            Button(L("common.cancel"), role: .cancel) { }
            Button(L("settings.backup.export_full.confirm")) {
                Task {
                    await prepareFullExport()
                    fullExportReady = true
                }
            }
        } message: {
            Text(L("settings.backup.full_warning.message"))
        }
        // Build 61 (B3, S5): the summary + confirm step — nothing
        // from the file is applied until the user confirms here.
        .alert(L("backup.import.summary_title"), isPresented: $showImportSummary) {
            Button(L("common.cancel"), role: .cancel) { pendingImportFile = nil }
            Button(L("settings.backup.import")) {
                if let file = pendingImportFile {
                    pendingImportFile = nil
                    Task { await performImport(file) }
                }
            }
        } message: {
            Text(importSummaryText)
        }
        .alert(L("settings.reset.title"), isPresented: $showResetConfirm) {
            Button(L("common.cancel"), role: .cancel) { }
            Button(L("settings.reset.title"), role: .destructive) {
                AppPreferenceKeys.resetToDefaults()
                showResetDone = true
            }
        } message: {
            Text(L("settings.reset.message"))
        }
        .alert(L("settings.reset.title"), isPresented: $showResetDone) {
            Button(L("common.ok"), role: .cancel) { }
        } message: {
            Text(L("settings.reset.done"))
        }
        .alert(L("settings.backup.import"), isPresented: $showImportResult) {
            Button(L("common.ok"), role: .cancel) { }
        } message: {
            Text(importMessage ?? "")
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showPasswordPrompt) {
            passwordPromptSheet
        }
    }

    // MARK: Export preparation

    private func writeTempFile(_ file: SuperXBackupFile, name: String) -> URL? {
        guard let data = try? file.encodedData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    private func prepareSettingsExport() async {
        var file = SuperXBackupFile.make(playlists: playlists, includeCredentials: false)
        // Build 61 (B3, S5): the export also carries the library —
        // favorites (both stores) + watch-later lists.
        file.library = await BackupService.collectLibrary(playlistIds: playlists.map(\.id))
        settingsExportURL = writeTempFile(file, name: "superx-settings.json")
    }

    private func prepareFullExport() async {
        var file = SuperXBackupFile.make(playlists: playlists, includeCredentials: true)
        file.library = await BackupService.collectLibrary(playlistIds: playlists.map(\.id))
        fullExportURL = writeTempFile(file, name: "superx-full-backup.json")
    }

    // MARK: Import

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            importMessage = L("settings.backup.import.failed")
            showImportResult = true
            return
        }
        Task { await importFile(at: url) }
    }

    private func importFile(at url: URL) async {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        // Build 61 (B3, S5): validate FIRST — an unreadable or
        // non-Super X file fails here with the graceful error and
        // nothing is applied. A valid file goes to the summary +
        // confirm step; `performImport` runs only on confirm.
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SuperXBackupFile.self, from: data),
              file.format == "superx-backup" else {
            importMessage = L("settings.backup.import.failed")
            showImportResult = true
            return
        }
        let favoriteCount = (file.library?.favorites.count ?? 0) + (file.library?.m3uFavorites.count ?? 0)
        let watchlistCount = file.library?.watchlist.reduce(0) { $0 + $1.movieIds.count } ?? 0
        importSummaryText = L(
            "backup.import.summary_format",
            file.playlists.count, favoriteCount, watchlistCount, file.settings.count
        )
        pendingImportFile = file
        showImportSummary = true
    }

    /// Applies a confirmed backup file: settings, then playlists
    /// (with the existing password re-prompt for credential-free
    /// files), then the library through the source→target id map.
    private func performImport(_ file: SuperXBackupFile) async {
        file.applySettings()
        libraryIdMap = [:]

        var importedCount = 0
        var needsPassword: [BackupPlaylistDTO] = []
        for dto in file.playlists {
            if file.includesCredentials {
                if await saveImported(dto.makePlaylist(password: dto.password ?? "")) {
                    importedCount += 1
                }
                await recordLibraryMapping(for: dto)
            } else if dto.kind == PlaylistKind.m3u.rawValue {
                if await saveImported(dto.makePlaylist(password: "")) {
                    importedCount += 1
                }
                await recordLibraryMapping(for: dto)
            } else {
                needsPassword.append(dto)
            }
        }
        if needsPassword.isEmpty {
            let libraryResult = await applyPendingLibrary(file)
            importMessage = libraryResult != nil
                ? L("backup.import.done_library_format", importedCount,
                    libraryResult!.favoritesImported, libraryResult!.watchlistImported)
                : L("settings.backup.import.done_format", importedCount)
            showImportResult = true
        } else {
            pendingPasswordDTOs = needsPassword
            pendingLibraryFile = file
            enteredPasswords = [:]
            showPasswordPrompt = true
            if importedCount > 0 {
                importMessage = L("settings.backup.import.done_format", importedCount)
                showImportResult = true
            }
        }
    }

    /// Maps one imported DTO's source id onto the playlist that
    /// now exists locally (same identity rule `saveImported`
    /// dedupes by: kind + server + username).
    private func recordLibraryMapping(for dto: BackupPlaylistDTO) async {
        guard let sourceId = dto.id else { return }
        let target = try? await AppDatabase.shared.read { db in
            try Playlist.fetchAll(db).first {
                $0.kind.rawValue == dto.kind
                    && $0.serverURL == dto.serverURL
                    && $0.username == dto.username
            }
        }
        if let target = target ?? nil {
            libraryIdMap[sourceId] = target.id
        }
    }

    /// Applies the file's library (favorites + watch-later) when
    /// it has one; nil when the file carries no library.
    private func applyPendingLibrary(_ file: SuperXBackupFile) async -> BackupService.ApplyResult? {
        guard let library = file.library else { return nil }
        return await BackupService.applyLibrary(library, playlistIdMap: libraryIdMap)
    }

    /// Saves one imported playlist unless an identical record
    /// (same kind + server + username) already exists. Returns
    /// whether a row was written.
    private func saveImported(_ playlist: Playlist) async -> Bool {
        do {
            let exists = try await AppDatabase.shared.read { db in
                try Playlist.fetchAll(db).contains {
                    $0.kind == playlist.kind
                        && $0.serverURL == playlist.serverURL
                        && $0.username == playlist.username
                }
            }
            guard !exists else { return false }
            try await AppDatabase.shared.write { db in try playlist.save(db) }
            // N1 (B13): an imported playlist joins the keychain
            // restore mirror like any other save path.
            CredentialStore.mirror(playlist)
            return true
        } catch {
            return false
        }
    }

    private var passwordPromptSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("settings.backup.import.passwords.message"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                ForEach(Array(pendingPasswordDTOs.enumerated()), id: \.offset) { index, dto in
                    Section(header: Text(dto.name)) {
                        Text(dto.username)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField(L("settings.playlist.password"), text: Binding(
                            get: { enteredPasswords[index] ?? "" },
                            set: { enteredPasswords[index] = $0 }
                        ))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    }
                }
            }
            .cinematicScrollBackground()
            .navigationTitle(L("settings.backup.import.passwords_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { showPasswordPrompt = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        Task {
                            var count = 0
                            for (index, dto) in pendingPasswordDTOs.enumerated() {
                                let password = enteredPasswords[index] ?? ""
                                if await saveImported(dto.makePlaylist(password: password)) {
                                    count += 1
                                }
                                // Build 61 (B3, S5): now that this
                                // playlist exists, its library
                                // entries can be mapped + applied.
                                await recordLibraryMapping(for: dto)
                            }
                            var libraryResult: BackupService.ApplyResult?
                            if let file = pendingLibraryFile {
                                libraryResult = await applyPendingLibrary(file)
                                pendingLibraryFile = nil
                            }
                            showPasswordPrompt = false
                            importMessage = libraryResult != nil
                                ? L("backup.import.done_library_format", count,
                                    libraryResult!.favoritesImported, libraryResult!.watchlistImported)
                                : L("settings.backup.import.done_format", count)
                            showImportResult = true
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Build 61 (B3): Playback & Appearance, locks, storage,
// subscriptions, support, danger zone

/// Build 61 (B3) — owner rule O5 fixes the settings group order:
/// Playback / Appearance / Downloads / Parental / Storage /
/// Support & About. Each B3 section below belongs to exactly one
/// group, and the two settings screens place them in that order.
///
/// PLAYBACK group (item 7b + T2): the buffer-size preference
/// (Low / Default / High — read by KSPlayerEngine where its
/// options are built) and the "Play last channel on launch"
/// toggle (consumed at launch by LaunchResumeService through
/// the existing pending-playback path). Bound to the exact
/// UserDefaults keys the readers use.
struct PlaybackSettingsSection: View {
    @AppStorage("player.bufferSize") private var bufferSize = "default"
    @AppStorage("app.playLastChannelOnLaunch") private var playLastChannel = false
    // Build 61 (B9): Q1 loudness, P6 data saver, Q10 dead channels.
    @AppStorage("player.loudnessNormalization") private var loudnessNormalization = false
    @AppStorage(DataSaverService.toggleKey) private var dataSaverOnCellular = false
    @AppStorage(ChannelHealthStore.hideDeadKey) private var hideDeadChannels = false
    @ObservedObject private var channelHealth = ChannelHealthStore.shared
    /// F1 (B13): the ONE EPG time offset store — guide display,
    /// programme details and reminder fire dates all read it.
    @ObservedObject private var epgOffset = EPGOffsetStore.shared

    var body: some View {
        Section(header: ScopedSectionHeader(title: L("settings.playback.title"), thisPlaylist: false)) {
            SettingsPickerRow(
                systemImage: "waveform.path",
                tint: .teal,
                title: L("settings.buffer.title"),
                selection: $bufferSize
            ) {
                Text(L("settings.buffer.low")).tag("low")
                Text(L("settings.buffer.default")).tag("default")
                Text(L("settings.buffer.high")).tag("high")
            }

            // F1: EPG time offset, −12…+12 h in 0.5 h steps,
            // per-APP (the store is a singleton over one key).
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: "clock.arrow.2.circlepath", tint: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("epgoffset.title"))
                    Text(L("epgoffset.desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(epgOffsetValueText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper("", value: $epgOffset.offsetHours, in: -12...12, step: 0.5)
                    .labelsHidden()
            }

            Toggle(isOn: $playLastChannel) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "play.circle.fill", tint: AppTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("settings.play_last.title"))
                        Text(L("settings.play_last.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Build 61 (B9, Q1): loudness normalization — applied
            // by KSPlayerEngine as an FFmpeg audio filter on the
            // next load (see the engine hunk for the mechanism).
            Toggle(isOn: $loudnessNormalization) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "waveform.badge.magnifyingglass", tint: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("loudness.title"))
                        Text(L("loudness.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Build 61 (B9, P6): data saver — on cellular, defers
            // background refresh and channel pre-warming.
            Toggle(isOn: $dataSaverOnCellular) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "antenna.radiowaves.left.and.right", tint: .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("datasaver.title"))
                        Text(L("datasaver.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Build 61 (B9, Q10): dead-channel marking — channels
            // that fail to play repeatedly can be hidden from the
            // channel lists; markings are cleared here.
            Toggle(isOn: $hideDeadChannels) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "tv.slash", tint: .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("deadchannels.hide.title"))
                        Text(L("deadchannels.hide.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if channelHealth.deadCount() > 0 {
                Button(role: .destructive) {
                    channelHealth.clearAll()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemImage: "arrow.counterclockwise", tint: .red)
                        Text(L("deadchannels.clear.title", channelHealth.deadCount()))
                    }
                }
            }
        }
    }

    /// "+1.5 h" / "-0.5 h" / "0 h" — the stepper's current value.
    private var epgOffsetValueText: String {
        let value = epgOffset.offsetHours
        let number = value == 0 ? "0" : String(format: "%+.1f", value)
        return L("epgoffset.value_format", number)
    }
}

/// APPEARANCE group (item 7a): the appearance choice
/// (System / Light / Dark, default Dark), read by the app root.
/// The accent-colour picker stays where it already lives (the
/// legacy App & Appearance group) — O6: one instance only, it is
/// not duplicated here.
struct AppearanceSettingsSection: View {
    @AppStorage("app.appearance") private var appearance = "dark"
    /// Build 61 (B10, Q21): the single reduce-effects flag. B7's
    /// D-pack effects and B13's onboarding/splash read this exact
    /// key (`appearance.reduceEffects`); the image pipeline reads
    /// it at install to trim its memory cache.
    @AppStorage("appearance.reduceEffects") private var reduceEffects = false
    /// F6 (B13): the ONE section-visibility store, consumed by
    /// the tab bar and Home. Home and Live have NO toggles here —
    /// they can never be hidden.
    @ObservedObject private var sectionVisibility = SectionVisibilityStore.shared
    // Build 61 (B8, Z6): empty provider categories are hidden by
    // default; this toggle (default OFF) shows them again.
    @AppStorage(EmptyCategoryVisibility.defaultsKey) private var showEmptyCategories = false

    var body: some View {
        Section(header: ScopedSectionHeader(title: L("settings.appearance.title"), thisPlaylist: false)) {
            SettingsPickerRow(
                systemImage: "circle.lefthalf.filled",
                tint: .gray,
                title: L("settings.appearance.title"),
                selection: $appearance
            ) {
                Text(L("settings.appearance.system")).tag("system")
                Text(L("settings.appearance.light")).tag("light")
                Text(L("settings.appearance.dark")).tag("dark")
            }

            Toggle(isOn: $reduceEffects) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "sparkles.slash", tint: .gray)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("reducefx.title"))
                        Text(L("reducefx.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onChange(of: reduceEffects) { _, isOn in
                // Q21: turning it on trims the image memory cache
                // immediately, not just at the next launch.
                if isOn { IPTVRemoteImagePipeline.trimMemoryCache() }
            }

            Toggle(isOn: $showEmptyCategories) {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "folder", tint: .gray)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("settings.show_empty_categories.title"))
                        Text(L("settings.show_empty_categories.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // F6: show/hide sections. Each toggle writes the
            // shared `sections.hidden.<section>` key through the
            // store; hidden sections leave the tab bar AND Home.
            sectionToggle(.movies, titleKey: "sections.movies", systemImage: "film.fill", tint: AppTheme.accent)
            sectionToggle(.series, titleKey: "sections.series", systemImage: "play.tv.fill", tint: SectionTheme.series)
            sectionToggle(.matches, titleKey: "sections.matches", systemImage: "sportscourt.fill", tint: .green)
            sectionToggle(.library, titleKey: "sections.library", systemImage: "star.fill", tint: .yellow)
        }
    }

    /// One "Show <section>" toggle — ON means visible (the store
    /// persists the inverse, the shared hidden key).
    private func sectionToggle(_ section: SectionVisibilityStore.Section, titleKey: String, systemImage: String, tint: Color) -> some View {
        Toggle(isOn: Binding(
            get: { sectionVisibility.isVisible(section) },
            set: { sectionVisibility.setHidden(!$0, section) }
        )) {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: systemImage, tint: tint)
                Text(L(titleKey))
            }
        }
    }
}

/// Item 5: lock / unlock this playlist's categories behind the
/// parental PIN. The locked set lives in `ParentalControlStore`;
/// opening a locked category (category picker, live playback) is
/// blocked until the PIN is entered. Without a PIN there is
/// nothing to unlock with, so the section points at the PIN
/// section instead of offering locks that could not be enforced.
struct LockedCategoriesSection: View {
    let playlist: Playlist

    /// One lockable category row; `key` is unique across types
    /// (the same category id can exist under live and vod).
    private struct CategoryLockRow: Identifiable {
        let type: String
        let id: String
        let name: String
        var key: String { "\(type)|\(id)" }
    }

    @ObservedObject private var parentalStore = ParentalControlStore.shared
    @State private var categories: [CategoryLockRow] = []
    @State private var hasPIN = PINStore.hasPIN
    @State private var showPINForUnlockAll = false
    /// A lock toggle switched OFF, waiting for PIN verification.
    @State private var pendingUnlock: (type: String, id: String)?
    @State private var showPINForPendingUnlock = false

    var body: some View {
        Section(header: ScopedSectionHeader(title: L("parental.locked.title"), thisPlaylist: true)) {
            if !hasPIN {
                Text(L("parental.locked.need_pin"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if categories.isEmpty {
                Text(L("parental.locked.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(categories, id: \.key) { category in
                    Toggle(isOn: lockBinding(for: category)) {
                        HStack(spacing: 12) {
                            SettingsIconTile(
                                systemImage: parentalStore.isLocked(playlistId: playlist.id, type: category.type, categoryId: category.id)
                                    ? "lock.fill" : "lock.open.fill",
                                tint: .gray
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.name)
                                    .lineLimit(1)
                                Text(L(typeTitleKey(category.type)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if parentalStore.hasAnyLock(playlistId: playlist.id) {
                    Button {
                        showPINForUnlockAll = true
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIconTile(systemImage: "lock.open.fill", tint: AppTheme.accent)
                            Text(L("parental.locked.unlock_session"))
                                .foregroundColor(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { await loadCategories() }
        .onAppear { hasPIN = PINStore.hasPIN }
        .sheet(isPresented: $showPINForUnlockAll) {
            PINEntrySheet(message: L("parental.locked.enter_pin")) {
                parentalStore.unlockAllForSession(playlistId: playlist.id)
            }
        }
        .sheet(isPresented: $showPINForPendingUnlock) {
            PINEntrySheet(message: L("parental.locked.enter_pin")) {
                if let pending = pendingUnlock {
                    parentalStore.setLocked(false, playlistId: playlist.id, type: pending.type, categoryId: pending.id)
                    pendingUnlock = nil
                }
            }
        }
    }

    private func typeTitleKey(_ type: String) -> String {
        switch type {
        case "live": return "dashboard.live"
        case "vod": return "dashboard.movies"
        case "series": return "dashboard.series"
        default: return "dashboard.channels"
        }
    }

    /// Locking applies immediately; UNlocking a category here
    /// requires the PIN first (the toggle snaps back until the
    /// PIN sheet verifies).
    private func lockBinding(for category: CategoryLockRow) -> Binding<Bool> {
        Binding(
            get: { parentalStore.isLocked(playlistId: playlist.id, type: category.type, categoryId: category.id) },
            set: { newValue in
                if newValue {
                    parentalStore.setLocked(true, playlistId: playlist.id, type: category.type, categoryId: category.id)
                } else {
                    pendingUnlock = (type: category.type, id: category.id)
                    showPINForPendingUnlock = true
                }
            }
        )
    }

    private func loadCategories() async {
        let pid = playlist.id
        if playlist.kind == .m3u {
            // M3U categories are the channels' group titles — the
            // same ids the M3U category picker uses (type "m3u").
            let groups = (try? await AppDatabase.shared.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT groupTitle FROM m3uChannel WHERE playlistId = ? AND groupTitle IS NOT NULL AND groupTitle != '' ORDER BY groupTitle",
                    arguments: [pid]
                )
            }) ?? []
            categories = groups.map { CategoryLockRow(type: "m3u", id: $0, name: $0) }
        } else {
            let rows = (try? await AppDatabase.shared.read { db in
                try DBCategory
                    .filter(Column("playlistId") == pid)
                    .order(Column("sortIndex"))
                    .fetchAll(db)
            }) ?? []
            categories = rows.map { CategoryLockRow(type: $0.type, id: $0.id, name: $0.name) }
        }
    }
}

/// STORAGE group (T1): the cache size with a cache-only Clear,
/// on B2's `StorageService` contract (§5). (B2 builds
/// StorageService in wave 2; this UI calls exactly the
/// contracted statics.)
///
/// O5/O6 placement notes: the downloads size + Downloads link
/// half of T1 already lives in the screens' Downloads group
/// (the DownloadsView link and the storage-used row) — it is
/// NOT duplicated here. And this section's cache row is now the
/// ONE cache size/clear control in Settings: the round-15
/// image-cache row that sat in the Advanced group was removed
/// when this section landed (see the report).
struct StorageSettingsSection: View {
    @State private var cacheBytes: Int64 = 0
    /// Build 61 (B10, F2): the two clear-history confirmations.
    @State private var showClearWatchHistory = false
    @State private var showClearSearchHistory = false
    @State private var searchHistoryCount = SearchHistoryStore.queries.count

    var body: some View {
        Section(header: ScopedSectionHeader(title: L("storage.title"), thisPlaylist: false)) {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: "photo.stack", tint: .gray)
                Text(L("storage.cache"))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                    .foregroundColor(.secondary)
                Button(L("storage.clear_cache")) {
                    StorageService.clearCache()
                    refresh()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundColor(AppTheme.accent)
                .disabled(cacheBytes == 0)
            }

            // F2: Clear watch history — empties the watchHistory
            // table, which is the single store behind Continue
            // Watching / Continue Series / Recent Channels.
            Button {
                showClearWatchHistory = true
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "clock.arrow.circlepath", tint: .gray)
                    Text(L("storage.clear_watch_history"))
                        .foregroundColor(.primary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            // F2: Clear search history — the SAME SearchHistoryStore
            // the in-search clear calls (O6 single instance).
            Button {
                showClearSearchHistory = true
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "magnifyingglass", tint: .gray)
                    Text(L("storage.clear_search_history"))
                        .foregroundColor(.primary)
                    Spacer()
                    if searchHistoryCount > 0 {
                        Text("\(searchHistoryCount)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(searchHistoryCount == 0)
        }
        .task {
            refresh()
            searchHistoryCount = SearchHistoryStore.queries.count
        }
        .alert(L("storage.clear_watch_history.confirm_title"), isPresented: $showClearWatchHistory) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("storage.clear_watch_history"), role: .destructive) {
                Task { await WatchHistoryClearing.clearAll() }
            }
        } message: {
            Text(L("storage.clear_watch_history.confirm_message"))
        }
        .alert(L("storage.clear_search_history.confirm_title"), isPresented: $showClearSearchHistory) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("storage.clear_search_history"), role: .destructive) {
                SearchHistoryStore.clear()
                searchHistoryCount = 0
            }
        } message: {
            Text(L("storage.clear_search_history.confirm_message"))
        }
    }

    private func refresh() {
        cacheBytes = StorageService.cacheSizeBytes()
    }
}

/// T5: the subscription overview — EVERY saved playlist with its
/// provider label, recorded expiry, days remaining and a plainly
/// shown expired state. All values come from
/// `ProviderExpiryStore` (recorded from real provider verifies);
/// a playlist with no recorded expiry says so, and M3U playlists
/// carry no provider account at all.
struct SubscriptionSettingsSection: View {
    let playlists: [Playlist]

    var body: some View {
        Section(header: ScopedSectionHeader(title: L("subscription.title"), thisPlaylist: false)) {
            NavigationLink {
                SubscriptionOverviewView(playlists: playlists)
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "calendar.badge.clock", tint: .orange)
                    Text(L("subscription.title"))
                    Spacer()
                    if !playlists.isEmpty {
                        Text("\(playlists.count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

struct SubscriptionOverviewView: View {
    let playlists: [Playlist]

    /// Build 61 (B10, Z2): the Xtream account's real connection
    /// fields, fetched live per playlist (`user_info`:
    /// `status` / `active_cons` / `max_connections`). A playlist
    /// whose verify fails, or whose panel omits a field, simply
    /// renders no row for it — nothing is invented.
    @State private var userInfos: [UUID: XtreamUserInfo] = [:]

    var body: some View {
        List {
            ForEach(playlists) { playlist in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(playlist.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(playlist.kind == .m3u ? "M3U" : "Xtream")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.16), in: Capsule())
                    }
                    Text(providerLabel(for: playlist))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    expiryLine(for: playlist)
                    connectionLines(for: playlist)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.insetGrouped)
        .cinematicScrollBackground()
        .navigationTitle(L("subscription.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadUserInfos() }
    }

    /// Z2 fetch: one lightweight verify per Xtream playlist (the
    /// same call the account card uses); the result also refreshes
    /// the recorded expiry, exactly like the other verify sites.
    private func loadUserInfos() async {
        for playlist in playlists where playlist.kind == .xtream {
            let client = XtreamAPIClient(playlist: playlist)
            guard let response = try? await client.verify(),
                  let info = response.userInfo else { continue }
            ProviderExpiryStore.record(playlistId: playlist.id, expDate: info.expDate)
            userInfos[playlist.id] = info
        }
    }

    /// Z2 rows: status / active connections / max connections —
    /// each rendered ONLY when the API actually returned it.
    @ViewBuilder
    private func connectionLines(for playlist: Playlist) -> some View {
        if let info = userInfos[playlist.id] {
            if let status = info.status, !status.isEmpty {
                connectionRow(label: L("subscription.status"), value: status)
            }
            if let active = info.activeCons, !active.isEmpty {
                connectionRow(label: L("subscription.connections_active"), value: active)
            }
            if let max = info.maxConnections, !max.isEmpty {
                connectionRow(label: L("subscription.connections_max"), value: max)
            }
        }
    }

    private func connectionRow(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    /// The provider/server label: the server's host only — never
    /// the full URL, and never a credential.
    private func providerLabel(for playlist: Playlist) -> String {
        if playlist.kind == .m3u { return L("subscription.m3u_source") }
        if let host = URL(string: playlist.serverURL)?.host, !host.isEmpty {
            return L("subscription.provider_format", host)
        }
        return L("subscription.provider_unknown")
    }

    @ViewBuilder
    private func expiryLine(for playlist: Playlist) -> some View {
        if playlist.kind == .m3u {
            Text(L("settings.account.no_expiry"))
                .font(.caption)
                .foregroundColor(.secondary)
        } else if let expiry = ProviderExpiryStore.expiryDate(playlistId: playlist.id) {
            if ProviderExpiryStore.isExpired(expiryDate: expiry) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                    Text(L("subscription.expired_format", formatted(expiry)))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.red)
                }
            } else {
                Text(L("subscription.active_format", formatted(expiry), remainingText(expiry: expiry)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else {
            Text(L("settings.account.no_expiry"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// Same honest calendar-day math as the account card.
    private func remainingText(expiry: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(expiry) { return L("settings.account.expires_today") }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: expiry)
        ).day ?? 0
        if days <= 1 { return L("settings.account.day_left") }
        return L("settings.account.days_left", days)
    }
}

/// Item 13 (the missing half): the in-app FAQ and the diagnostics
/// copy action. Privacy Policy / Terms already live in
/// PrivacyLegalSection (verified) and are not duplicated here.
/// There is deliberately NO contact row — the owner has not named
/// a support destination. Diagnostics carry app version, OS,
/// device model and playlist count/kinds ONLY — no server URLs,
/// no usernames, no credentials.
struct SupportSettingsSection: View {
    let playlists: [Playlist]

    @State private var diagnosticsCopied = false
    @State private var copyResetTask: Task<Void, Never>?
    /// F3 (B13): connection & speed test state.
    @State private var speedTestRunning = false
    @State private var speedOutcome: ConnectionSpeedTestService.Outcome?
    @State private var speedTestServerName: String?

    /// The playlist the speed test measures: the ACTIVE one (the
    /// content stores' active id), falling back to the first
    /// saved playlist. Nil when there is nothing to test.
    private var speedTestPlaylist: Playlist? {
        let activeId = PlaylistContentStore.shared.activePlaylistId ?? M3UContentStore.shared.activePlaylistId
        if let activeId, let active = playlists.first(where: { $0.id == activeId }) {
            return active
        }
        return playlists.first
    }

    var body: some View {
        Section(header: ScopedSectionHeader(title: L("support.title"), thisPlaylist: false)) {
            NavigationLink {
                FAQView()
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "questionmark.circle.fill", tint: AppTheme.accent)
                    Text(L("support.faq.title"))
                }
            }

            // F3: connection & speed test against the ACTIVE
            // provider's server only (see ConnectionSpeedTestService).
            Button {
                runSpeedTest()
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "speedometer", tint: .teal)
                    Text(L("speedtest.run"))
                        .foregroundColor(.primary)
                    Spacer()
                    if speedTestRunning { ProgressView() }
                }
            }
            .buttonStyle(.plain)
            .disabled(speedTestRunning || speedTestPlaylist == nil)

            if let outcome = speedOutcome {
                speedTestResultRows(outcome)
            }

            Button {
                copyDiagnostics()
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "doc.on.doc.fill", tint: .gray)
                    Text(L("support.diagnostics.copy"))
                        .foregroundColor(.primary)
                    Spacer()
                    if diagnosticsCopied {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.bold))
                            .foregroundColor(.green)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .onDisappear { copyResetTask?.cancel() }
    }

    // MARK: - F3: connection & speed test

    private func runSpeedTest() {
        guard let playlist = speedTestPlaylist else { return }
        // G5: with no network path the verdict is known without
        // a 20-second timeout — report it immediately.
        if OfflineState.shared.isOffline {
            speedTestServerName = playlist.name
            speedOutcome = ConnectionSpeedTestService.Outcome(
                verdict: .unreachable, responseTimeMs: nil, throughputMbps: nil, sampledBytes: 0)
            return
        }
        speedTestRunning = true
        speedOutcome = nil
        speedTestServerName = playlist.name
        Task {
            let outcome = await ConnectionSpeedTestService.run(playlist: playlist)
            speedOutcome = outcome
            speedTestRunning = false
        }
    }

    @ViewBuilder
    private func speedTestResultRows(_ outcome: ConnectionSpeedTestService.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: outcome.verdict == .unreachable ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(outcome.verdict == .good ? Color.green : (outcome.verdict == .weak ? Color.orange : Color.red))
                Text(L(verdictKey(outcome.verdict)))
                    .font(.subheadline.weight(.semibold))
                if let name = speedTestServerName {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let ms = outcome.responseTimeMs {
                Text(L("speedtest.response_format", ms))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let mbps = outcome.throughputMbps {
                Text(L("speedtest.throughput_format", String(format: "%.1f", mbps)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The method, labeled in small text: the sample came
            // from the provider's own server, capped — approximate
            // by construction, never a general internet speed.
            Text(L("speedtest.method_format", String(format: "%.1f", Double(outcome.sampledBytes) / 1_000_000)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 52)
    }

    private func verdictKey(_ verdict: ConnectionSpeedTestService.Verdict) -> String {
        switch verdict {
        case .good: return "speedtest.verdict.good"
        case .weak: return "speedtest.verdict.weak"
        case .unreachable: return "speedtest.verdict.unreachable"
        }
    }

    private func copyDiagnostics() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        let xtreamCount = playlists.filter { $0.kind == .xtream }.count
        let m3uCount = playlists.count - xtreamCount
        var text = """
        Super X \(version) (\(build))
        iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)
        \(L("support.diagnostics.playlists_format", playlists.count, xtreamCount, m3uCount))
        \(L("support.diagnostics.language_format", LocalizationManager.shared.effectiveLanguageCode))
        """
        // G6 (B13): MetricKit's plain-language summary joins the
        // diagnostics ONLY when iOS has actually delivered
        // diagnostic payloads — nil keeps the text unchanged.
        if let metricKitSummary = MetricKitService.summaryForDiagnostics() {
            text += "\n" + metricKitSummary
        }
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        diagnosticsCopied = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { diagnosticsCopied = false }
        }
    }
}

/// The FAQ screen: real questions and answers about how this app
/// actually works (bring-your-own-provider, local-only data,
/// expiry, downloads, the PIN, backups).
struct FAQView: View {
    private let questionCount = 6

    var body: some View {
        List {
            ForEach(1...questionCount, id: \.self) { index in
                Section {
                    Text(L("support.faq.a\(index)"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } header: {
                    Text(L("support.faq.q\(index)"))
                        .font(.headline)
                        .foregroundColor(.primary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .cinematicScrollBackground()
        .navigationTitle(L("support.faq.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// T6: the danger zone — "Sign out of all playlists" and "Erase
/// all app data", EACH behind a double confirmation (an
/// explanatory alert, then a second final confirm).
///
/// Erase is complete: it runs the ONE shared wipe
/// (`AccountDataDeletion.deleteAllLocalData` — playlists +
/// content, both favorite stores, watch history, downloads
/// metadata AND files, EPG, PIN, hidden categories, watchlist,
/// per-playlist stores) and then removes the ENTIRE UserDefaults
/// persistent domain (every app setting), resetting the
/// in-memory language/accent stores so the gate that follows is
/// a genuine first-run state.
///
/// Stores cleared by Erase (audited by grep over
/// @AppStorage / UserDefaults / GRDB tables):
/// GRDB tables (via AccountDataDeletion): playlist, category,
/// liveStream, vodStream, series, season, episode, favorite,
/// m3uFavorite, m3uChannel, watchHistory, downloadedItem,
/// epgProgramme, epgChannel, epgSource + staging tables.
/// UserDefaults: the whole persistent domain — every
/// @AppStorage preference, HiddenCategoryStore,
/// CategoryOrderStore, WatchlistStore, ProviderExpiryStore,
/// PlaylistHealthStore, PlaylistLibraryStore,
/// ParentalControlStore locks, gate drafts/session keys,
/// subtitle/audio-delay/track-preference stores, widget and
/// intent keys. Keychain: the parental PIN. Files: download
/// files + resume data, the Nuke image caches, URLCache.
/// In-memory: both content stores unloaded, EPG store reset,
/// widget snapshot emptied.
struct DangerZoneSection: View {
    let onExitToGate: () -> Void

    @State private var showSignOutFirst = false
    @State private var showSignOutFinal = false
    @State private var showEraseFirst = false
    @State private var showEraseFinal = false
    /// The PIN guard the old Privacy & Legal "Delete Account" row
    /// carried (round 15, C5) moves here with the erase: with a
    /// parental PIN set, the PIN comes before both confirmations.
    @State private var showPINForErase = false
    @State private var isWorking = false
    @State private var showError = false

    var body: some View {
        Section(header: ScopedSectionHeader(title: L("danger.title"), thisPlaylist: false)) {
            Button(role: .destructive) {
                showSignOutFirst = true
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "rectangle.portrait.and.arrow.right", tint: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("danger.sign_out_all"))
                        Text(L("danger.sign_out_all.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isWorking { Spacer(); ProgressView() }
                }
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            Button(role: .destructive) {
                if PINStore.hasPIN {
                    showPINForErase = true
                } else {
                    showEraseFirst = true
                }
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "trash.fill", tint: .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("danger.erase"))
                        Text(L("danger.erase.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isWorking { Spacer(); ProgressView() }
                }
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
        }
        .sheet(isPresented: $showPINForErase) {
            PINEntrySheet(message: L("pin.guard.delete_account")) {
                DispatchQueue.main.async { showEraseFirst = true }
            }
        }
        // Sign out of all playlists: confirmation 1 of 2.
        .alert(L("danger.sign_out_all"), isPresented: $showSignOutFirst) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("danger.continue"), role: .destructive) {
                DispatchQueue.main.async { showSignOutFinal = true }
            }
        } message: {
            Text(L("danger.sign_out_all.message"))
        }
        // Sign out of all playlists: confirmation 2 of 2 (final).
        .alert(L("danger.sign_out_all.final_title"), isPresented: $showSignOutFinal) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("danger.sign_out_all.final_confirm"), role: .destructive) {
                Task { await signOutAll() }
            }
        } message: {
            Text(L("danger.sign_out_all.final_message"))
        }
        // Erase all app data: confirmation 1 of 2.
        .alert(L("danger.erase"), isPresented: $showEraseFirst) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("danger.continue"), role: .destructive) {
                DispatchQueue.main.async { showEraseFinal = true }
            }
        } message: {
            Text(L("danger.erase.message"))
        }
        // Erase all app data: confirmation 2 of 2 (final).
        .alert(L("danger.erase.final_title"), isPresented: $showEraseFinal) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("danger.erase.final_confirm"), role: .destructive) {
                Task { await eraseAll() }
            }
        } message: {
            Text(L("danger.erase.final_message"))
        }
        .alert(L("common.error"), isPresented: $showError) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(L("danger.error_message"))
        }
    }

    /// Removes every saved playlist and all of its per-playlist
    /// data through the shared per-playlist deletion path; app
    /// settings themselves are kept. Ends at the gate with no
    /// active playlist.
    private func signOutAll() async {
        isWorking = true
        let playlists = (try? await AppDatabase.shared.read { db in
            try Playlist.fetchAll(db)
        }) ?? []
        var succeeded = true
        for playlist in playlists {
            if !(await AccountDataDeletion.deletePlaylistData(playlist)) {
                succeeded = false
            }
            await ParentalControlStore.shared.removeAll(playlistId: playlist.id)
        }
        await PlaylistContentStore.shared.unload()
        await M3UContentStore.shared.unload()
        await EPGStore.shared.setActivePlaylist(nil)
        isWorking = false
        if succeeded {
            onExitToGate()
        } else {
            showError = true
        }
    }

    /// The full erase described in the type header.
    private func eraseAll() async {
        isWorking = true
        let wiped = await AccountDataDeletion.deleteAllLocalData()
        await ParentalControlStore.shared.removeAllEverywhere()
        // Every remaining UserDefaults key — the entire app
        // domain, no key list to fall behind the tree.
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        // The in-memory stores that mirror defaults must not
        // repaint the erased values back.
        AccentThemeStore.shared.preset = .blue
        LocalizationManager.shared.selectedLanguage = "system"
        isWorking = false
        if wiped {
            onExitToGate()
        } else {
            showError = true
        }
    }
}
