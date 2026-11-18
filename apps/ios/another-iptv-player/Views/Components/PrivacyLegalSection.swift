import GRDB
import SwiftUI

/// Round 12 (point 4): the "Privacy & Legal" group the owner asked
/// for, modeled on STRONG's arrangement — Contact Support, Privacy
/// Policy, Terms of Use, Report objectionable content — placed
/// after About & Legal in BOTH settings screens (one shared
/// component, no duplication).
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
///
/// Build 61 (B3, owner rules O5/O6): the round-12 "Delete
/// Account" row that used to live here is REMOVED — erasing all
/// app data now has exactly ONE entry point, the Danger Zone's
/// "Erase all app data" (DangerZoneSection in
/// SettingsComponents.swift), which keeps this row's PIN guard
/// and adds the second confirmation. Both run the ONE shared
/// deletion implementation (`AccountDataDeletion`).
struct PrivacyLegalSection: View {
    let onExitToGate: () -> Void

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

/// Build 61 (B3, O6): the round-12 `DeleteAccountAction` wrapper
/// that lived here is removed with its row — the Danger Zone's
/// erase calls `AccountDataDeletion.deleteAllLocalData()`
/// directly (the ONE deletion path, round 17 R17-2, shared with
/// the gate's saved-account removal and My Playlists' delete).
