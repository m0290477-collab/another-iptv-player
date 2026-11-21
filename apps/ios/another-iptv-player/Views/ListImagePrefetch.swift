import Foundation
import Nuke
import SwiftUI
import UIKit

enum ListImagePrefetch {
    // Round 7 (performance): batch cut 48 → 24 and the prefetcher now
    // runs at .low priority. All artwork comes from ONE panel host and
    // the pipeline's DataLoader allows 10 connections per host, so
    // normal-priority prefetch batches queued ahead of the posters the
    // user was actually looking at — on-screen images arrived late and
    // scrolling stuttered while the decoder worked through speculative
    // batches (each 2.25x the pixels of the old 2x decodes). Low
    // priority lets render requests preempt; the smaller batch bounds
    // how much speculative work one shelf can enqueue.
    //
    // Round 20 (R20-5): the round-7 settings were only half the story.
    // At 3 concurrent requests the prefetcher could never get ahead of
    // a fast scroll: every shelf enqueued its head batch into ONE
    // shared queue hundreds of requests deep, and nothing ever
    // cancelled the stale entries, so by the time a prefetch ran the
    // user was long past it (owner recording, build 54: whole Series
    // shelves sat as placeholder tiles for seconds). Three changes:
    // concurrency 3 → 6 (still below the 10/host loader cap, and
    // render requests keep priority), a `stop` counterpart so a shelf
    // that scrolls off can retract its not-yet-started head batch,
    // and scroll-window prefetching at the call sites (each visible
    // cell warms the items just ahead of it) instead of head-only.
    //
    // Build 90 (F5a, D1 RC2): two of round 20's three changes did
    // not reach the scroll-window batches. The per-cell window
    // batches were started but NEVER retracted — the only `stop`
    // call sites were the head batches — so a fast fling enqueued
    // ~350–600 stale low-priority requests (15 shelves × head +
    // windows) that drained 6-wide for tens of seconds, mostly for
    // shelves already scrolled past, while the shelf on screen
    // waited. And at 6 concurrent the drain could not keep up even
    // with retraction in place. Now: (a) the keyed-batch API below
    // lets a call site retract a whole window batch as a unit when
    // its cell/shelf disappears, and (b) concurrency rises 6 → 10
    // — still below the loader's 12 connections/host (build 89),
    // and the prefetcher's .low priority keeps render requests
    // ahead of it in the pipeline's priority-aware queues.
    static let maxBatch = 24

    /// How many items ahead of a visible cell the shelf/grid call
    /// sites warm. Small on purpose: the window moves with the user,
    /// so speculative work stays near the viewport.
    static let scrollWindow = 8

    private static let prefetcher: ImagePrefetcher = {
        let prefetcher = ImagePrefetcher(
            pipeline: .shared,
            destination: .memoryCache,
            maxConcurrentRequestCount: 10
        )
        prefetcher.priority = .low
        return prefetcher
    }()

    /// Pre-caches a limited number of URLs before a grid or shelf.
    ///
    /// The Nuke memory-cache key includes the Resize processor's size + contentMode;
    /// if the prefetch request is not built EXACTLY the same as the render request, the cache never hits
    /// and every image is decoded twice. Therefore the caller [passes] the card's real render
    /// parameters (the width/height/contentMode/loadProfile it gives CachedImage)
    /// and the request is built with CachedImage.request.
    static func start(
        urls: [URL],
        width: CGFloat,
        height: CGFloat,
        contentMode: SwiftUI.ContentMode = .fit,
        loadProfile: ImageLoadProfile = .grid
    ) {
        let slice = Array(urls.prefix(maxBatch))
        guard !slice.isEmpty else { return }
        prefetcher.startPrefetching(with: requests(for: slice, width: width, height: height, contentMode: contentMode, loadProfile: loadProfile))
    }

    /// Round 20 (R20-5): retracts a batch previously handed to
    /// `start` (same parameters, so the same requests). Call sites
    /// invoke it when a shelf scrolls off screen: its queued — not
    /// yet started — prefetches are dropped, keeping the shared
    /// queue short for the shelves actually on screen. Requests
    /// already in flight finish into the memory cache, which is
    /// harmless (and helps if the user scrolls back).
    static func stop(
        urls: [URL],
        width: CGFloat,
        height: CGFloat,
        contentMode: SwiftUI.ContentMode = .fit,
        loadProfile: ImageLoadProfile = .grid
    ) {
        let slice = Array(urls.prefix(maxBatch))
        guard !slice.isEmpty else { return }
        prefetcher.stopPrefetching(with: requests(for: slice, width: width, height: height, contentMode: contentMode, loadProfile: loadProfile))
    }

    // MARK: - Keyed batches (Build 90, F5a)

    /// The requests started under each caller-chosen key. The
    /// plain `start`/`stop` pair above forces a call site to
    /// rebuild the exact URL list to retract a batch; a scroll
    /// window's list is recomputed from live catalog state, so by
    /// disappear time the call site can no longer reproduce it —
    /// which is exactly why the window batches were never
    /// retracted (D1 RC2). The keyed API remembers the batch
    /// itself: start under a stable per-cell/per-shelf key, stop
    /// by the same key, no list needed.
    private static let keyedLock = NSLock()
    private static var keyedBatches: [String: [ImageRequest]] = [:]

    /// Starts a prefetch batch registered under `key`. Starting
    /// again under the same key first retracts the previous batch
    /// (a cell whose window shifted replaces its stale batch
    /// instead of leaking it into the shared queue). Batch size
    /// is capped at `maxBatch`, same as `start`.
    ///
    /// Intended use (Live TV / Movies / Series shelves): on cell
    /// appear, `start(keyed: "window-<shelfID>-<cellID>", urls:
    /// <the next `scrollWindow` items>, width: …, height: …,
    /// contentMode: …, loadProfile: …)` with the cell's REAL
    /// render parameters; on cell or shelf disappear,
    /// `stop(keyed:)` with the same key.
    static func start(
        keyed key: String,
        urls: [URL],
        width: CGFloat,
        height: CGFloat,
        contentMode: SwiftUI.ContentMode = .fit,
        loadProfile: ImageLoadProfile = .grid
    ) {
        let slice = Array(urls.prefix(maxBatch))
        guard !slice.isEmpty else { return }
        let batch = requests(for: slice, width: width, height: height, contentMode: contentMode, loadProfile: loadProfile)
        keyedLock.lock()
        let replaced = keyedBatches[key]
        keyedBatches[key] = batch
        keyedLock.unlock()
        if let replaced {
            prefetcher.stopPrefetching(with: replaced)
        }
        prefetcher.startPrefetching(with: batch)
    }

    /// Retracts the batch registered under `key` (queued requests
    /// are dropped; in-flight ones finish into the memory cache,
    /// same contract as `stop`). Unknown keys are a no-op. Note
    /// the shared-prefetcher caveat, same as the head batches: if
    /// two live batches contain the identical request, retracting
    /// one also drops that request from the other — prefetch is
    /// speculative, so the render path simply loads it on demand.
    static func stop(keyed key: String) {
        keyedLock.lock()
        let batch = keyedBatches.removeValue(forKey: key)
        keyedLock.unlock()
        guard let batch else { return }
        prefetcher.stopPrefetching(with: batch)
    }

    private static func requests(
        for urls: [URL],
        width: CGFloat,
        height: CGFloat,
        contentMode: SwiftUI.ContentMode,
        loadProfile: ImageLoadProfile
    ) -> [ImageRequest] {
        urls.map {
            CachedImage.request(
                url: $0,
                width: width,
                height: height,
                contentMode: contentMode,
                loadProfile: loadProfile
            )
        }
    }
}
