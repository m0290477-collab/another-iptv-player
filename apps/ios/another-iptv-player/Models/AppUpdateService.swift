import Foundation
import Combine

/// Build 61 (B13, F7): the new-version notice.
///
/// On launch, ONE iTunes lookup for this app's bundle id
/// (`com.irqus.superx`). If the store version is newer than the
/// installed one, Home shows a dismissible banner linking to the
/// App Store page; dismissal is remembered per store version, so
/// the banner returns only for a genuinely newer release.
///
/// Failure honesty: a failed lookup, an empty result, an
/// unparseable version — every absence is TOTAL silence. No
/// error UI, no banner, no retry loop.
///
/// Note: this is meaningful only after App Store release. While
/// the app is TestFlight-only the lookup returns no result for
/// the bundle id and the feature stays silent, by design.
@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()

    /// The newer store version on offer, with its App Store page
    /// URL. Nil = nothing to show (up to date, lookup failed, or
    /// this version was already dismissed).
    @Published private(set) var availableUpdate: (version: String, storeURL: URL)?

    private static let dismissedVersionKey = "update.dismissedStoreVersion"
    private var didCheck = false

    private init() {}

    /// One lookup per launch, from the app root's deferred task.
    func checkIfNeeded() async {
        guard !didCheck else { return }
        didCheck = true

        guard let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let url = URL(string: "https://itunes.apple.com/lookup?bundleId=com.irqus.superx") else {
            return
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let lookup = try? JSONDecoder().decode(LookupResponse.self, from: data),
              let result = lookup.results.first,
              let storeVersion = result.version,
              let page = result.trackViewUrl.flatMap(URL.init(string:)) else {
            return // silence on any absence
        }
        guard Self.isNewer(storeVersion, than: installed) else { return }
        guard UserDefaults.standard.string(forKey: Self.dismissedVersionKey) != storeVersion else { return }
        availableUpdate = (version: storeVersion, storeURL: page)
    }

    /// Remembers the dismissal for THIS store version only; the
    /// next release re-offers the banner.
    func dismiss() {
        guard let update = availableUpdate else { return }
        UserDefaults.standard.set(update.version, forKey: Self.dismissedVersionKey)
        availableUpdate = nil
    }

    /// Dotted numeric compare ("2.4.1" > "2.4.0"); missing
    /// components count as 0, non-numeric components end the
    /// comparison as equal-so-far.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct LookupResponse: Decodable {
        struct Result: Decodable {
            let version: String?
            let trackViewUrl: String?
        }
        let results: [Result]
    }
}
