import Foundation
import Network

/// Build 61 (B9) — P6 data saver.
///
/// The Settings toggle "Data saver on cellular"
/// (`perf.datasaver_on_cellular`, default off) becomes ACTIVE
/// only while the device's current path is cellular. While
/// active:
///  - the background-refresh task skips its network work
///    (catalog + EPG refresh) and only re-schedules local expiry
///    alerts (see `BackgroundRefreshService`);
///  - channel connection pre-warming (P1) and host pre-warm (E1)
///    stand down — no speculative connections on a metered link.
///
/// The quality-cap half of P6 is NOT implemented: T3 landed
/// partial in wave 1 because the track plumbing exposes no
/// writable resolution path, and no controller-level cap
/// mechanism exists that touches no protected file (see the B9
/// report for the full evidence). This service therefore carries
/// no cap state — nothing here pretends to limit stream quality.
final class DataSaverService: ObservableObject {
    static let shared = DataSaverService()

    static let toggleKey = "perf.datasaver_on_cellular"

    @Published private(set) var isCellular = false

    private let monitor = NWPathMonitor()
    private var didStart = false

    /// The user's toggle (Settings ▸ Playback).
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: toggleKey)
    }

    /// Toggle on AND currently on a cellular path.
    static var isActive: Bool {
        isEnabled && shared.isCellular
    }

    /// Starts path monitoring (idempotent). Called once from the
    /// app root's deferred launch task — deliberately NOT on the
    /// cold-start critical path.
    func start() {
        guard !didStart else { return }
        didStart = true
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular) && path.status == .satisfied
            DispatchQueue.main.async {
                self?.isCellular = cellular
            }
        }
        monitor.start(queue: DispatchQueue(label: "superx.datasaver.path"))
    }
}
