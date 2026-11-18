import Foundation

/// Build 61 (B9) — Q10 dead-channel marking + the data behind
/// Q12's "Working first" sort.
///
/// The store is keyed by the app's content identity — the same
/// `<playlistId>_<type>_<streamId>` triple `ImportedSubtitleStore`
/// uses — so the controller-level failure counter (in
/// `VideoPlayerController`, the only place playback success and
/// failure are both observable) and the channel lists (which
/// compute the same key per channel) always agree.
///
/// A channel is marked DEAD after `deadThreshold` CONSECUTIVE
/// playback failures; any successful start resets the streak, so
/// a channel that recovers is never stuck marked. Markings are
/// user-clearable from Settings (Playback group) and via
/// `clearAll()`; nothing here deletes or hides data on its own —
/// the "Hide dead channels" toggle (`hideDeadKey`, same
/// UserDefaults key the settings row binds) is what filters
/// lists, and it defaults to off.
final class ChannelHealthStore: ObservableObject {
    static let shared = ChannelHealthStore()

    static let deadThreshold = 3
    /// The settings toggle's UserDefaults key ("Hide dead channels").
    static let hideDeadKey = "deadchannels.hide_dead"
    private static let storageKey = "deadchannels.health.v1"

    struct Record: Codable, Equatable {
        var consecutiveFailures: Int = 0
        var totalFailures: Int = 0
        var lastFailureAt: TimeInterval = 0
        var lastSuccessAt: TimeInterval = 0
    }

    private struct Storage: Codable {
        var records: [String: Record] = [:]
    }

    /// Bumped on every mutation so list views can recompute.
    @Published private(set) var revision = 0

    private var records: [String: Record]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            records = decoded.records
        } else {
            records = [:]
        }
    }

    // MARK: - Recording (controller level)

    /// A playback start succeeded for this content: the failure
    /// streak ends here (totals are kept for diagnostics).
    func recordSuccess(for contentKey: String) {
        guard var record = records[contentKey], record.consecutiveFailures > 0 else { return }
        record.consecutiveFailures = 0
        record.lastSuccessAt = Date().timeIntervalSince1970
        records[contentKey] = record
        persist()
        revision += 1
    }

    /// A playback attempt for this content failed for good (the
    /// controller's auto-reconnect budget was exhausted, or the
    /// failure was never recoverable).
    func recordFailure(for contentKey: String) {
        var record = records[contentKey] ?? Record()
        record.consecutiveFailures += 1
        record.totalFailures += 1
        record.lastFailureAt = Date().timeIntervalSince1970
        records[contentKey] = record
        persist()
        revision += 1
    }

    // MARK: - Reading

    static var hideDeadEnabled: Bool {
        UserDefaults.standard.bool(forKey: hideDeadKey)
    }

    func isDead(_ contentKey: String) -> Bool {
        (records[contentKey]?.consecutiveFailures ?? 0) >= Self.deadThreshold
    }

    func consecutiveFailures(_ contentKey: String) -> Int {
        records[contentKey]?.consecutiveFailures ?? 0
    }

    func deadKeys() -> Set<String> {
        Set(records.filter { $0.value.consecutiveFailures >= Self.deadThreshold }.keys)
    }

    func deadCount() -> Int { deadKeys().count }

    /// Health rank for Q12's "Working first" sort: never-failed
    /// channels first, then channels whose last outcome was a
    /// success, then failing-but-not-dead, dead last. Lower is
    /// healthier. Unknown channels rank as never-failed.
    func healthRank(_ contentKey: String) -> Int {
        guard let record = records[contentKey] else { return 0 }
        if record.consecutiveFailures >= Self.deadThreshold { return 3 }
        if record.consecutiveFailures > 0 { return 2 }
        if record.totalFailures > 0 { return 1 }
        return 0
    }

    // MARK: - Clearing (user action)

    /// Removes ONE channel's marking (it becomes unknown/healthy).
    func clearMarking(for contentKey: String) {
        guard records.removeValue(forKey: contentKey) != nil else { return }
        persist()
        revision += 1
    }

    /// Settings action: forget every marking.
    func clearAll() {
        guard !records.isEmpty else { return }
        records = [:]
        persist()
        revision += 1
    }

    // MARK: - Storage

    private func persist() {
        let storage = Storage(records: records)
        if let data = try? JSONEncoder().encode(storage) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
