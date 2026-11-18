import AudioToolbox
import Foundation

/// Round 15 (C12): the ONLY three moments the app may make a UI
/// sound, per the effects specialist's strict fence. System sounds
/// only — no bundled audio, no haptics, and NEVER called from any
/// player code path.
enum AppSoundMoment {
    case downloadComplete
    case refreshSuccess
    case favorite
}

/// Round 15 (C12): gated by the "UI sounds" settings toggle —
/// `@AppStorage("settings.uiSounds")`, default ON. The gate is read
/// from UserDefaults here (not @AppStorage) so non-View callers use
/// the exact same value the toggle writes; an absent value means ON,
/// matching the toggle's default.
enum AppSound {
    static func play(_ moment: AppSoundMoment) {
        guard UserDefaults.standard.object(forKey: "settings.uiSounds") as? Bool ?? true else { return }
        let soundID: SystemSoundID
        switch moment {
        case .downloadComplete:
            // MailReceived-style completion chime.
            soundID = 1001
        case .refreshSuccess:
            // Short positive "sent" tick.
            soundID = 1057
        case .favorite:
            // Soft pop.
            soundID = 1054
        }
        AudioServicesPlaySystemSound(soundID)
    }
}
