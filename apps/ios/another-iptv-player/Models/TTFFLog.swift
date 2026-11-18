import Foundation

/// Build 61 (B9) — E6 time-to-first-frame instrumentation.
///
/// `VideoPlayerController` stamps the moment a `play(...)` request
/// is issued and records the elapsed time when the engine reports
/// its first rendered frame (`KSPlayerEngine.hasRenderedFirstFrame`).
/// Samples stay ON DEVICE (UserDefaults, newest 20) — no analytics,
/// nothing leaves the phone.
///
/// Display contract for B13's F3 diagnostics screen: read
/// `recentSamples()`, `lastMs`, `medianMs`, `sampleCount`, or the
/// ready-made `diagnosticLine()`. Wire ONE line into the existing
/// copy-diagnostics output; no other UI is needed from B9.
enum TTFFLog {
    private static let storageKey = "perf.ttff.samples.v1"
    static let maxSamples = 20

    struct Sample: Codable, Equatable {
        /// When the first frame rendered (epoch seconds).
        var at: TimeInterval
        /// Tap → first rendered frame, milliseconds.
        var milliseconds: Int
        var isLive: Bool
    }

    static func record(milliseconds: Int, isLive: Bool) {
        guard milliseconds > 0 else { return }
        var samples = recentSamples()
        samples.append(Sample(at: Date().timeIntervalSince1970, milliseconds: milliseconds, isLive: isLive))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        if let data = try? JSONEncoder().encode(samples) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Oldest → newest.
    static func recentSamples() -> [Sample] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Sample].self, from: data)
        else { return [] }
        return decoded
    }

    static var sampleCount: Int { recentSamples().count }

    static var lastMs: Int? { recentSamples().last?.milliseconds }

    static var medianMs: Int? {
        let values = recentSamples().map(\.milliseconds).sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }

    /// One plain line for the diagnostics copy output; empty
    /// string until the first sample exists (B13 renders nothing
    /// in that case).
    static func diagnosticLine() -> String {
        guard let last = lastMs, let median = medianMs else { return "" }
        return L("perf.ttff.line", sampleCount, last, median)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
