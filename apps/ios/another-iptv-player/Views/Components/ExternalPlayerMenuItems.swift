import SwiftUI
import UIKit

/// B2 (build 61, item 10): "Open in external player" for a playable
/// stream URL. VLC and Infuse are offered ONLY when the app is
/// actually installed (`canOpenURL` against the schemes declared in
/// `LSApplicationQueriesSchemes` in App-Info.plist); the share sheet
/// is always available as the fallback for every other player
/// (Outplayer etc.) — the user picks the app there. No dead entries:
/// an app that is not installed never appears.
enum ExternalPlayer {
    static func vlcURL(for streamURL: URL) -> URL? {
        URL(string: "vlc://" + streamURL.absoluteString)
    }

    static func infuseURL(for streamURL: URL) -> URL? {
        guard let encoded = streamURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "infuse://x-callback-url/play?url=\(encoded)")
    }

    static var canOpenVLC: Bool {
        guard let probe = URL(string: "vlc://") else { return false }
        return UIApplication.shared.canOpenURL(probe)
    }

    static var canOpenInfuse: Bool {
        guard let probe = URL(string: "infuse://") else { return false }
        return UIApplication.shared.canOpenURL(probe)
    }
}

/// A context-menu `Menu` ("Open in external player") with the
/// installed players + share-sheet fallback for `streamURL`.
struct ExternalPlayerMenuItems: View {
    let streamURL: URL

    var body: some View {
        Menu {
            if ExternalPlayer.canOpenVLC, let url = ExternalPlayer.vlcURL(for: streamURL) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label(L("external.vlc"), systemImage: "play.rectangle.on.rectangle")
                }
            }
            if ExternalPlayer.canOpenInfuse, let url = ExternalPlayer.infuseURL(for: streamURL) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label(L("external.infuse"), systemImage: "play.rectangle.on.rectangle")
                }
            }
            ShareLink(item: streamURL) {
                Label(L("external.share"), systemImage: "square.and.arrow.up")
            }
        } label: {
            Label(L("external.title"), systemImage: "arrow.up.forward.app")
        }
    }
}
