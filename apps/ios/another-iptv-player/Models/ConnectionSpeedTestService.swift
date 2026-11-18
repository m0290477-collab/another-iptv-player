import Foundation

/// Build 61 (B13, F3): the Support connection & speed test.
///
/// Both halves run against the ACTIVE PROVIDER's server only —
/// no third-party speed-test service is contacted, ever:
///
///  (a) Reachability + response time: a timed request to the
///      provider endpoint (Xtream: the panel API; M3U: the
///      playlist URL itself), timed to first byte.
///  (b) Throughput: the SAME fetch continues as a capped timed
///      download — for Xtream the provider's own XMLTV guide
///      endpoint (`PlaybackURLBuilder.xmltvURL()`), for M3U the
///      playlist file — stopped after a few seconds or a few MB,
///      and reported as APPROXIMATE Mbps with the method labeled
///      in the UI. The sample measures this one provider path,
///      not the device's internet speed, and the UI says so.
enum ConnectionSpeedTestService {

    enum Verdict {
        case good
        case weak
        case unreachable
    }

    struct Outcome {
        var verdict: Verdict
        /// Time to first byte, milliseconds. Nil when unreachable.
        var responseTimeMs: Int?
        /// Approximate throughput of the capped sample. Nil when
        /// nothing usable was downloaded.
        var throughputMbps: Double?
        /// Bytes actually received during the sample (shown in
        /// the method note so the number stays honest).
        var sampledBytes: Int
    }

    /// The provider endpoint used for both halves of the test.
    static func testURL(for playlist: Playlist) -> URL? {
        switch playlist.kind {
        case .xtream:
            return PlaybackURLBuilder(playlist: playlist).xmltvURL()
        case .m3u:
            let trimmed = playlist.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(string: trimmed)
        }
    }

    static func run(playlist: Playlist) async -> Outcome {
        guard let url = testURL(for: playlist) else {
            return Outcome(verdict: .unreachable, responseTimeMs: nil, throughputMbps: nil, sampledBytes: 0)
        }
        let sample = await CappedFetch.run(url: url, maxDuration: 5, maxBytes: 8 * 1024 * 1024)
        guard sample.receivedBytes > 0, sample.firstByteSeconds != nil else {
            return Outcome(verdict: .unreachable, responseTimeMs: nil, throughputMbps: nil, sampledBytes: 0)
        }
        let responseMs = Int(((sample.firstByteSeconds ?? sample.elapsedSeconds) * 1_000).rounded())
        // Throughput counts from first byte to the end of the
        // sample window (the capped body transfer), the honest
        // measure of the provider path's delivery rate.
        let transferSeconds = max(0.1, sample.elapsedSeconds - (sample.firstByteSeconds ?? 0))
        let mbps = Double(sample.receivedBytes) * 8 / transferSeconds / 1_000_000
        let verdict: Verdict
        if responseMs <= 800 && mbps >= 5 {
            verdict = .good
        } else {
            verdict = .weak
        }
        return Outcome(
            verdict: verdict,
            responseTimeMs: responseMs,
            throughputMbps: mbps,
            sampledBytes: sample.receivedBytes
        )
    }
}

/// A one-shot download that stops at a byte or time cap and
/// reports what actually arrived. Implemented with a delegate
/// (not `URLSession.data`) so the fetch can be cut mid-body —
/// a provider guide file can be tens of MB and the test must
/// never download all of it.
private final class CappedFetch: NSObject, URLSessionDataDelegate {
    struct Sample {
        var receivedBytes = 0
        var firstByteSeconds: TimeInterval?
        var elapsedSeconds: TimeInterval = 0
    }

    private var continuation: CheckedContinuation<Sample, Never>?
    private var session: URLSession?
    private var startedAt = Date()
    private var sample = Sample()
    private var maxBytes = 0
    private var finished = false

    static func run(url: URL, maxDuration: TimeInterval, maxBytes: Int) async -> Sample {
        let fetch = CappedFetch()
        return await withCheckedContinuation { continuation in
            fetch.continuation = continuation
            fetch.maxBytes = maxBytes
            fetch.startedAt = Date()
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = maxDuration + 5
            config.timeoutIntervalForResource = maxDuration + 5
            let session = URLSession(configuration: config, delegate: fetch, delegateQueue: nil)
            fetch.session = session
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            session.dataTask(with: request).resume()
            // Hard cap on the whole sample window.
            DispatchQueue.global().asyncAfter(deadline: .now() + maxDuration) {
                fetch.finish()
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if sample.firstByteSeconds == nil {
            sample.firstByteSeconds = Date().timeIntervalSince(startedAt)
        }
        sample.receivedBytes += data.count
        if sample.receivedBytes >= maxBytes {
            finish()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        sample.elapsedSeconds = Date().timeIntervalSince(startedAt)
        session?.invalidateAndCancel()
        continuation?.resume(returning: sample)
        continuation = nil
    }
}
