import SwiftUI

// Round 16 (R1): the orphaned LanguagePickerSection wrapper is
// removed (zero call sites — both settings screens embed
// LanguagePickerRow directly inside their own groups).

/// The language row itself (without a section header) — a separate struct so the settings screens can
/// embed the row inside their own groups (round 6).
struct LanguagePickerRow: View {
    @ObservedObject private var manager = LocalizationManager.shared

    var body: some View {
        NavigationLink {
            LanguagePickerListView()
        } label: {
            HStack {
                Text(L("settings.language.title"))
                Spacer()
                Text(currentLanguageDisplayName)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var currentLanguageDisplayName: String {
        let code = manager.selectedLanguage
        if code == "system" { return L("settings.language.system") }
        return LocalizationManager.supportedLanguages.first { $0.code == code }?.nativeName ?? code
    }
}

/// Language list on the detail screen + a tick on the selected language.
struct LanguagePickerListView: View {
    @ObservedObject private var manager = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(LocalizationManager.supportedLanguages) { lang in
                Button {
                    manager.selectedLanguage = lang.code
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lang.code == "system" ? L("settings.language.system") : lang.nativeName)
                                .foregroundColor(.primary)
                            if lang.code != "system" {
                                Text(lang.englishName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if manager.selectedLanguage == lang.code {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle(L("settings.language.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
