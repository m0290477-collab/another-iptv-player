import Foundation
import MetricKit

/// Build 61 (B13, G6): MetricKit intake — the app's own
/// system-provided diagnostics, no third-party crash SDK.
///
/// An `MXMetricManager` subscriber is registered once at launch
/// (AppDelegate, next to the BG refresh registration, following
/// B1's pattern). When iOS delivers diagnostic payloads (crashes,
/// hangs, CPU exceptions, disk writes), the service reduces them
/// to plain counts stored in UserDefaults; Support's
/// copy-diagnostics action appends a one-line plain-language
/// summary via `summaryForDiagnostics()` when — and only when —
/// payloads actually exist. No payloads → nil → the diagnostics
/// text is exactly what it was before this feature.
final class MetricKitService: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitService()

    private static let countsKey = "metrickit.diagnosticCounts.v1"
    private static let lastReceivedKey = "metrickit.lastReceivedAt.v1"

    private struct Counts: Codable {
        var crashes = 0
        var hangs = 0
        var cpuExceptions = 0
        var diskWriteExceptions = 0
    }

    /// One-time registration at app launch.
    static func register() {
        MXMetricManager.shared.add(shared)
    }

    // MARK: - MXMetricManagerSubscriber

    /// Metric payloads (performance histograms) carry nothing the
    /// Support summary can state plainly; only diagnostics are
    /// counted.
    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        var counts = Self.loadCounts()
        for payload in payloads {
            counts.crashes += payload.crashDiagnostics?.count ?? 0
            counts.hangs += payload.hangDiagnostics?.count ?? 0
            counts.cpuExceptions += payload.cpuExceptionDiagnostics?.count ?? 0
            counts.diskWriteExceptions += payload.diskWriteExceptionDiagnostics?.count ?? 0
        }
        Self.saveCounts(counts)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastReceivedKey)
    }

    // MARK: - Diagnostics summary (consumed by B3's Support surface)

    /// One plain-language line for the copy-diagnostics text, or
    /// nil when iOS has never delivered a diagnostic payload —
    /// absence stays total silence, exactly like F7's rule.
    static func summaryForDiagnostics() -> String? {
        let counts = loadCounts()
        let total = counts.crashes + counts.hangs + counts.cpuExceptions + counts.diskWriteExceptions
        guard total > 0 else { return nil }
        var parts: [String] = []
        if counts.crashes > 0 { parts.append(L("metrickit.crashes_format", counts.crashes)) }
        if counts.hangs > 0 { parts.append(L("metrickit.hangs_format", counts.hangs)) }
        if counts.cpuExceptions > 0 { parts.append(L("metrickit.cpu_format", counts.cpuExceptions)) }
        if counts.diskWriteExceptions > 0 { parts.append(L("metrickit.disk_format", counts.diskWriteExceptions)) }
        return L("metrickit.summary_format", parts.joined(separator: ", "))
    }

    // MARK: - Storage

    private static func loadCounts() -> Counts {
        guard let data = UserDefaults.standard.data(forKey: countsKey),
              let counts = try? JSONDecoder().decode(Counts.self, from: data) else {
            return Counts()
        }
        return counts
    }

    private static func saveCounts(_ counts: Counts) {
        if let data = try? JSONEncoder().encode(counts) {
            UserDefaults.standard.set(data, forKey: countsKey)
        }
    }
}
