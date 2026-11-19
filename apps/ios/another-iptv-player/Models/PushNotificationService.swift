import Combine
import Foundation
import UIKit
import UserNotifications

/// A match deep link carried by a push tap (item 9): tapping the
/// notification opens exactly this match's detail screen.
struct MatchDeepLink: Identifiable, Equatable {
    let id = UUID()
    let sport: MatchSport
    let leaguePath: String
    let eventId: String
}

final class MatchDeepLinkRouter: ObservableObject {
    static let shared = MatchDeepLinkRouter()
    @Published var pending: MatchDeepLink?
    private init() {}
}

/// Build 63 (owner, item 9): the app side of goal notifications.
///
/// The watching/pushing itself is a separate server service (the
/// parent's track). This side only:
///  1. requests notification authorization at the moment the user
///     first follows a team — NEVER at cold launch;
///  2. registers for remote notifications and POSTs the device
///     token + followed-team set to the watcher endpoint;
///  3. routes push taps to the match detail (foreground arrivals
///     show as normal system banners).
///
/// HARD LAUNCH RULE (build-61 lesson): nothing in this file runs
/// at cold launch. The only launch-time touch is the AppDelegate
/// assigning `UNUserNotificationCenter.delegate` (a plain object
/// assignment — no I/O, no registration, no observers that can
/// block). Registration/upload failures are silent and
/// non-blocking by design: following teams works fully offline;
/// the upload simply retries on the next follow/pref change.
final class PushNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationService()

    /// PLACEHOLDER — the parent supplies the real watcher endpoint
    /// constant before this feature can deliver pushes. Until
    /// then uploads go nowhere (`.invalid` never resolves) and
    /// fail silently, exactly as designed; the app side is
    /// complete but inert.
    static let watcherEndpointURL = URL(string: "https://example.invalid/superx-watcher/register")!

    private static let tokenDefaultsKey = "push.deviceToken.v1"

    private override init() { super.init() }

    // MARK: Registration (user-action driven only)

    /// Called when the user follows their FIRST team.
    func ensureAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// AppDelegate callback (token delivery is system-driven,
    /// after the user granted authorization above).
    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: Self.tokenDefaultsKey)
        uploadRegistration()
    }

    func didFailToRegister() {
        // Silent by design — a later follow/pref change retries
        // the whole flow.
    }

    // MARK: Upload

    /// POSTs {token, teams:[…]} to the watcher endpoint. No token
    /// or an empty follow set still posts (an empty set is how the
    /// server learns the user unfollowed everything). Every
    /// failure is swallowed: this must never block or error the UI.
    func uploadRegistration() {
        guard let token = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey),
              !token.isEmpty else { return }
        let teams = FollowedTeamsStore.shared.teams.map { team in
            [
                "sport": team.sportRaw,
                "leaguePath": team.leaguePath,
                "teamId": team.teamId,
                "teamName": team.teamName,
                "goals": team.notifyGoals,
                "kickoff": team.notifyKickoff,
                "fullTime": team.notifyFullTime
            ] as [String: Any]
        }
        let payload: [String: Any] = ["token": token, "teams": teams]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: Self.watcherEndpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { _, _, _ in
            // Response intentionally ignored (see type note).
        }.resume()
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Foreground arrival: present as a normal system banner —
    /// EXCEPT while the player is fullscreen (item 12d, owner's
    /// hard rule: while watching anything, NO notification,
    /// banner or alert of any kind may appear). In that state
    /// the push is fully suppressed: no banner, no list entry,
    /// no sound. The score itself still lands in the Matches
    /// data through the normal refresh paths.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if PlayerOverlayController.fullscreenPresented {
            completionHandler([])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }

    /// Tap: open the match detail for the pushed event. The
    /// payload contract with the watcher is
    /// {eventId, leaguePath, sport} in `userInfo`.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let eventId = info["eventId"] as? String,
           let leaguePath = info["leaguePath"] as? String,
           let sportRaw = info["sport"] as? String,
           let sport = MatchSport(rawValue: sportRaw) {
            DispatchQueue.main.async {
                MatchDeepLinkRouter.shared.pending = MatchDeepLink(
                    sport: sport, leaguePath: leaguePath, eventId: eventId
                )
            }
        }
        completionHandler()
    }
}
