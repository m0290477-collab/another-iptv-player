import StoreKit
import UIKit

/// Manages the in-app App Store rating request.
///
/// Strategy: after the user has had a certain number of *successful sessions* (reaching a playlist dashboard
/// without problems), the system rating dialog is requested. Apple actually shows this
/// dialog at most 3 times a year; therefore the request is also kept behind a
/// version + date based gate on our side.
@MainActor
final class RatingManager {
    static let shared = RatingManager()
    private init() {}

    private let defaults = UserDefaults.standard

    private enum Key {
        static let sessionCount = "rating.successfulSessionCount"
        static let lastPromptVersion = "rating.lastPromptVersion"
        static let lastPromptDate = "rating.lastPromptDate"
    }

    /// The successful-session threshold at which the first request is shown.
    private let promptThreshold = 4
    /// The minimum days between two requests.
    private let minDaysBetweenPrompts = 90

    /// Was a session already counted for this app launch? (one count per launch)
    private var didCountThisLaunch = false

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Called when the user reaches content (when the dashboard opens).
    /// Counts only once per app launch.
    func registerSuccessfulSession() {
        if MockFixture.isActive { return }
        guard !didCountThisLaunch else { return }
        didCountThisLaunch = true
        let count = defaults.integer(forKey: Key.sessionCount) + 1
        defaults.set(count, forKey: Key.sessionCount)
    }

    /// If all conditions are met, requests the system rating dialog.
    /// Best called a few seconds after a successful session is triggered.
    func requestReviewIfAppropriate() {
        if MockFixture.isActive { return }
        // Continue only if a real session was counted for this launch.
        guard didCountThisLaunch else { return }

        guard defaults.integer(forKey: Key.sessionCount) >= promptThreshold else { return }

        // If we already asked on this version, do not ask again.
        guard defaults.string(forKey: Key.lastPromptVersion) != currentVersion else { return }

        // Has enough time passed since the last request?
        if let last = defaults.object(forKey: Key.lastPromptDate) as? Date {
            let days = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
            guard days >= minDaysBetweenPrompts else { return }
        }

        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }

        AppStore.requestReview(in: scene)

        defaults.set(currentVersion, forKey: Key.lastPromptVersion)
        defaults.set(Date(), forKey: Key.lastPromptDate)
    }
}
