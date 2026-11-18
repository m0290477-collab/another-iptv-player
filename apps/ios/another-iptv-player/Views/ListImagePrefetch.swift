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
    static let maxBatch = 24

    /// How many items ahead of a visible cell the shelf/grid call
    /// sites warm. Small on purpose: the window moves with the user,
    /// so speculative work stays near the viewport.
    static let scrollWindow = 8

    private static let prefetcher: ImagePrefetcher = {
        let prefetcher = ImagePrefetcher(
            pipeline: .shared,
            destination: .memoryCache,
            maxConcurrentRequestCount: 6
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
