import Foundation
import Combine
import Network

/// Build 61 (B13, G5): the ONE offline-state service, driven by
/// `NWPathMonitor`. The whole app reads `isOffline` from here:
///
///  - both dashboards show the shared `OfflineBannerView` while
///    offline (the app still opens to the cached catalog and the
///    downloads — nothing here blocks local content);
///  - network-only entry points (playlist refresh, add-playlist,
///    EPG refresh) check `isOffline` first and present the plain
///    offline message with a Retry action instead of starting a
///    request that can only spin and fail.
///
/// The monitor starts once, at service creation (first access from
/// a dashboard), and runs for the app's lifetime.
final class OfflineState: ObservableObject {
    static let shared = OfflineState()

    /// True only when the path is positively unsatisfied. Until
    /// the first path update arrives the app assumes online, so a
    /// cold start never flashes a false offline banner.
    @Published private(set) var isOffline = false

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.irqus.superx.offline-monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            DispatchQueue.main.async {
                guard let self, self.isOffline != offline else { return }
                self.isOffline = offline
            }
        }
        monitor.start(queue: monitorQueue)
    }
}
