import GRDB
import SwiftUI

/// Round 12 (point 4): the "Privacy & Legal" group the owner asked
/// for, modeled on STRONG's arrangement — Contact Support, Privacy
/// Policy, Terms of Use, Report objectionable content, Delete
/// Account — placed after About & Legal in BOTH settings screens
/// (one shared component, no duplication).
///
/// Every row is genuinely wired, per the no-fake-UI rule:
/// - Contact Support / Report objectionable content open in-app
///   text screens in Super X's own voice (round 17, R17-6: the
///   GitHub issue tracker is GONE as a support/report channel —
///   no email address or other external channel is shown or
///   invented either; Super X has no published support address,
///   and the texts say honestly where help actually lives: the
///   user's own provider).
/// - Privacy Policy / Terms of Use open in-app text screens. The
///   privacy text states only true things about this app (nothing
///   collected, everything local); the terms state only true
///   things (free, brings no content, the user's own provider
///   supplies the streams).
/// - Delete Account does the honest local equivalent for an app
///   with no server accounts: after a destructive confirmation it
///   deletes ALL playlists and ALL app data on this device
///   (catalog, favorites, history, EPG, downloads incl. files)
///   through the ONE shared deletion implementation
///   (`AccountDataDeletion`) and returns to the playlist gate.
struct PrivacyLegalSection: View {
    let onExitToGate: () -> Void

    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    /// Round 15 (C5): when a parental PIN is set, Delete Account
    /// asks for it BEFORE the destructive confirmation.
    @State private var showPINForDelete = false
    /// Round 14 (B1): a failed wipe step must SURFACE, never fail
    /// silently behind a bare `try?` — this drives the error alert.
    @State private var showDeleteError = false

    var body: some View {
        Section(header: Text(L("settings.group.privacy_legal"))) {
            NavigationLink {
                LegalSupportView(mode: .support)
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "bubble.left.and.bubble.right.fill", tint: .green)
                    Text(L("settings.legal.contact_support"))
                }
            }

            NavigationLink {
                LegalDocumentView(kind: .privacy)
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "hand.raised.fill", tint: .gray)
                    Text(L("settings.legal.privacy_policy"))
                }
            }

            NavigationLink {
                LegalDocumentView(kind: .terms)
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "doc.text.fill", tint: .gray)
                    Text(L("settings.legal.terms"))
                }
            }

            NavigationLink {
                LegalSupportView(mode: .report)
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "exclamationmark.bubble.fill", tint: .orange)
                    Text(L("settings.legal.report_content"))
                }
            }

            Button(role: .destructive) {
                // Round 15 (C5): PIN guard — with a PIN set, the
                // PIN comes first; the confirmation follows it.
                if PINStore.hasPIN {
                    showPINForDelete = true
                } else {
                    showDeleteConfirmation = true
                }
            } label: {
                HStack(spacing: 12) {
                    SettingsIconTile(systemImage: "person.crop.circle.badge.xmark", tint: .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("settings.legal.delete_account"))
                        Text(L("settings.legal.delete_account_desc"))
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    if isDeleting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isDeleting)
        }
        .sheet(isPresented: $showPINForDelete) {
            PINEntrySheet(message: L("pin.guard.delete_account")) {
                showDeleteConfirmation = true
            }
        }
        .alert(L("settings.legal.delete_account.title"), isPresented: $showDeleteConfirmation) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("common.confirm_delete_yes"), role: .destructive) {
                Task { @MainActor in
                    isDeleting = true
                    let succeeded = await DeleteAccountAction.wipeAllLocalData()
                    isDeleting = false
                    if succeeded {
                        onExitToGate()
                    } else {
                        showDeleteError = true
                    }
                }
            }
        } message: {
            Text(L("settings.legal.delete_account.message"))
        }
        .alert(L("common.error"), isPresented: $showDeleteError) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(L("settings.legal.delete_account.error_message"))
        }
    }
}

/// In-app legal text screen (Privacy Policy / Terms of Use /
/// license). Round 14 (B13): internal (not private) so the
/// playlist gate's help sheet links to these SAME legal
/// destinations instead of duplicating the texts. Round 17
/// (R17-6): the `.license` kind is the ONE place the upstream
/// project still appears — the MIT attribution the license
/// itself requires, shown as a credits notice, not a channel.
struct LegalDocumentView: View {
    enum Kind { case privacy, terms, license }
    let kind: Kind

    private var titleKey: String {
        switch kind {
        case .privacy: return "settings.legal.privacy_policy"
        case .terms: return "settings.legal.terms"
        case .license: return "settings.about.licenses.title"
        }
    }
    private var bodyKey: String {
        switch kind {
        case .privacy: return "settings.legal.privacy.body"
        case .terms: return "settings.legal.terms.body"
        case .license: return "settings.legal.license.body"
        }
    }

    var body: some View {
        ScrollView {
            Text(L(bodyKey))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(AppTheme.background)
        .navigationTitle(L(titleKey))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// In-app support / report screen. Round 17 (R17-6): text only,
/// in Super X's own voice — the "Open GitHub Issues" button and
/// the GitHub-as-support-channel framing are removed, and NO
/// replacement external channel is invented (Super X has no
/// published support address; the texts say so and point at the
/// one party that can actually help with a subscription: the
/// user's own provider).
private struct LegalSupportView: View {
    enum Mode { case support, report }
    let mode: Mode

    private var titleKey: String {
        mode == .support ? "settings.legal.contact_support" : "settings.legal.report_content"
    }
    private var bodyKey: String {
        mode == .support ? "settings.legal.support.body" : "settings.legal.report.body"
    }

    var body: some View {
        ScrollView {
            Text(L(bodyKey))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(AppTheme.background)
        .navigationTitle(L(titleKey))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The Delete Account action (round 12, point 4): the honest local
/// equivalent for an app whose accounts live only on the user's own
/// provider panels. Removes every playlist and every piece of app
/// data stored on this device.
///
/// Round 17 (R17-2): the implementation moved to
/// `AccountDataDeletion` — the ONE deletion path shared with the
/// gate's saved-account removal and My Playlists' delete. The old
/// inline version deleted from `epgShortCache` / `xmltvGuideCache`
/// in a single all-or-nothing transaction; both tables were
/// dropped by the `dropLegacyEPGTables` migration, so the wipe
/// threw on a nonexistent table, rolled EVERYTHING back and
/// reported "Some data could not be deleted" with nothing deleted.
enum DeleteAccountAction {
    /// Returns true only when every store succeeded; each store is
    /// cleared independently inside `AccountDataDeletion`, so one
    /// failure can no longer block the rest.
    static func wipeAllLocalData() async -> Bool {
        await AccountDataDeletion.deleteAllLocalData()
    }
}
