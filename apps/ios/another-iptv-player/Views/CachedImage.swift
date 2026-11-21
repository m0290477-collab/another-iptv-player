import Foundation
import SwiftUI
import Nuke
import NukeUI
import UIKit

/// Remote channel-icon / poster URLs are often dead or TLS-broken; a
/// `URLSession.shared` storm floods the console via CFNetwork. It cannot
/// be silenced entirely, but per-host connection limits and timeouts cut
/// both the log volume and the latency.
enum IPTVRemoteImagePipeline {
    private static let installLock = NSLock()
    private static var didInstall = false

    /// Build 61 (B10, Q21): immediate memory trim when the user
    /// turns "Reduce effects" on mid-session (the install-time
    /// bounds in `installAsShared` cover the next launch).
    static func trimMemoryCache() {
        ImagePipeline.shared.cache.removeAll()
    }

    static func installAsShared() {
        installLock.lock()
        defer { installLock.unlock() }
        guard !didInstall else { return }
        didInstall = true

        let urlConf = DataLoader.defaultConfiguration
        // Round 15 (C10): per-host connections raised to 10 (spec range
        // 8-12) so poster grids fill in parallel instead of queueing.
        urlConf.httpMaximumConnectionsPerHost = 10
        // Round 20 (R20-5): per-request timeout 10s → 5s. This loader
        // serves ONLY tile/poster art (small files); a poster that has
        // not started arriving within 5s is, for scrolling purposes,
        // dead — but at 10s each dead URL held one of the 10 per-host
        // connections hostage while visible cells queued behind it
        // (owner recording, build 54: placeholder fields lasting
        // seconds during fast scrolls). A failed load is not
        // negatively cached, so a slow-but-alive host still gets its
        // poster on the next appearance/retry. The 20s resource
        // timeout (whole-transfer bound) is unchanged.
        urlConf.timeoutIntervalForRequest = 5
        urlConf.timeoutIntervalForResource = 20
        urlConf.waitsForConnectivity = false
        let loader = DataLoader(configuration: urlConf)

        // Cap the memory cache: left unbounded it can fill all of RAM.
        // Build 61 (B10, Q21): with "Reduce effects" on
        // (`appearance.reduceEffects`), the memory cache is
        // trimmed to a quarter of the normal bounds.
        let reduceEffects = UserDefaults.standard.bool(forKey: "appearance.reduceEffects")
        let memoryCache = ImageCache()
        memoryCache.costLimit = reduceEffects ? 40 * 1024 * 1024 : 150 * 1024 * 1024  // 150 MB
        memoryCache.countLimit = reduceEffects ? 400 : 1500

        // Round 15 (C10): explicit disk DataCache capped at ~300 MB
        // (previously Nuke's implicit default governed disk use).
        let dataCache = try? DataCache(name: "com.superx.images")
        dataCache?.sizeLimit = 300 * 1024 * 1024

        ImagePipeline.shared = ImagePipeline {
            $0.dataLoader = loader
            $0.imageCache = memoryCache
            $0.dataCache = dataCache
            // Round 15 (C11): the dead #available(iOS 15) guard is gone
            // — the deployment target is iOS 18.
            $0.isUsingPrepareForDisplay = true
        }
    }
}

/// Nuke `LazyImage` + pixel resize; use `grid` or `shelf` when scrolling lists/grids.
enum ImageLoadProfile: Equatable, Sendable {
    /// Single / header: light animation, request cancels on disappear.
    case standard
    /// Horizontal shelf: small decode, no cancel on disappear (see body).
    case shelf
    /// Long grid / list: retina decode, cancels on disappear (C10).
    case grid
    /// Large images / backdrops: no (or very high) downsampling.
    case high
}

struct CachedImage: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    /// Round 14 (B9): the default is the shared card radius token so
    /// every poster matches without call sites passing a value.
    var cornerRadius: CGFloat = AppTheme.cornerRadius
    var contentMode: SwiftUI.ContentMode = .fit
    var iconName: String = "photo"
    var loadProfile: ImageLoadProfile = .standard
    /// Round 15 (C9): optional identity for the placeholder — when a
    /// title is supplied, the fallback is a surface gradient + the
    /// item's own title in the card font + the section symbol, instead
    /// of an anonymous icon. Call sites that pass nothing keep the
    /// icon-only placeholder.
    var title: String? = nil
    /// Round 19 (R19-2): optional failure hook — call sites that own
    /// a fallback image (e.g. the detail hero's poster) use it to
    /// swap invisibly when this load fails.
    var onLoadFailed: (() -> Void)? = nil

    var body: some View {
        Group {
            if let url, ArtworkFailureMemo.shared.isFailed(url) {
                // Build 81 (item 5b): this URL already failed in
                // this session — render the designed placeholder
                // immediately instead of re-issuing a doomed
                // request on every scroll reappearance (the
                // pipeline keeps no negative cache; see
                // ArtworkFailureMemo). After the memo's TTL the
                // URL is retried normally.
                // Build 82 (items 1+4): the failure hook fires
                // here too — the load DID fail, and call sites
                // with a fallback image (the detail hero's
                // poster swap, the tab heroes) otherwise never
                // learn about a memo-hit failure and stay stuck
                // on the placeholder even though their fallback
                // art is sitting unused.
                placeholder
                    .onAppear { onLoadFailed?() }
            } else if let url {
                // A custom `transaction` can trigger multiple LazyImageContext updates in the same frame; animation is handled by the parent `Group` instead.
                LazyImage(request: makeRequest(url: url)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                            .onAppear { ArtworkFailureMemo.shared.recordSuccess(url) }
                    } else if state.error != nil {
                        // Round 19 (R19-2): a failed image NEVER
                        // renders as a warning glyph — it falls back
                        // to the same invisible placeholder as the
                        // loading state (gradient + section symbol),
                        // and the call site is notified so it can
                        // swap in its own fallback art.
                        // Build 81 (item 5b): the failure is also
                        // memoized so the URL is not retried on
                        // every reappearance.
                        placeholder
                            .onAppear {
                                ArtworkFailureMemo.shared.recordFailure(url)
                                onLoadFailed?()
                            }
                    } else {
                        placeholder
                    }
                }
                // Round 15 (C10): grid loads now cancel on disappear;
                // when the cell reappears LazyImage re-issues the same
                // request, which is the priority restore (Nuke resumes
                // from its caches, it does not restart cold). The SHELF
                // profile deliberately keeps the old no-cancel behavior:
                // the documented round-5-era bug was shelf cells whose
                // lowered-priority requests stuck and never loaded.
                .onDisappear((loadProfile == .standard || loadProfile == .grid) ? .cancel : nil)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                placeholder
            }
        }
        .transaction { t in
            // Build 83 (item 5): the load crossfade now also
            // covers the `.high` profile — heroes and detail
            // backdrops fade in on load instead of snapping.
            // The list profiles (shelf/grid) stay instant on
            // purpose: implicit animations on recycled grid
            // cells read as flicker while scrolling, and the
            // speed law outranks the flourish there.
            if loadProfile == .standard || loadProfile == .high {
                t.animation = .easeIn(duration: 0.12)
            } else {
                t.animation = nil
            }
        }
    }

    private func makeRequest(url: URL) -> ImageRequest {
        Self.request(url: url, width: width, height: height, contentMode: contentMode, loadProfile: loadProfile)
    }

    /// The exact ImageRequest the render path uses. ListImagePrefetch
    /// uses it too — prefetch/render keys only match this way (see the
    /// Resize size+contentMode).
    static func request(
        url: URL,
        width: CGFloat,
        height: CGFloat,
        contentMode: SwiftUI.ContentMode,
        loadProfile: ImageLoadProfile
    ) -> ImageRequest {
        let target = downsamplePixelSize(width: width, height: height, loadProfile: loadProfile)
        let nukeMode: ImageProcessingOptions.ContentMode = (contentMode == .fill) ? .aspectFill : .aspectFit
        return ImageRequest(
            url: url,
            processors: [
                ImageProcessors.Resize(
                    size: target,
                    unit: .pixels,
                    contentMode: nukeMode,
                    crop: false,
                    upscale: false
                )
            ]
        )
    }

    private static func downsamplePixelSize(width: CGFloat, height: CGFloat, loadProfile: ImageLoadProfile) -> CGSize {
        // Round 5 (blur fix): the old code capped the decode at 2x for the
        // shelf/standard/grid profiles on the theory that "2x is visually
        // indistinguishable from 3x". On the owner's 3x phone it is NOT:
        // every tile/poster/logo was decoded at 2x its point size and then
        // upscaled 1.5x by the display — the blurry channel logos he
        // reported. Requests use the FULL device scale for every profile,
        // so a tile decodes at exactly its displayed pixel size.
        //
        // Round 7 (performance): the round-5 blanket caps (1024 for
        // everything, 2048 for .high) sat far above every real surface and
        // let oversized layouts (full-width iPad heroes, search cards)
        // decode far beyond display need. Caps are now per profile, tied
        // to the largest real surface each profile serves on a 3x phone:
        //   standard — rows/collage slots/small icons:      ≤ 512 px
        //   shelf    — shelf posters 100×150 pt → 300×450:  ≤ 640 px
        //   grid     — grid posters (iPad 200×300 pt @2x):  ≤ 768 px
        //   high     — hero/featured card ≤ 760 pt wide:    ≤ 1600 px
        // On the owner's phone every visible tile already requests below
        // its cap, so crispness is unchanged; the caps bind only where
        // the old blanket values allowed pure waste. The pipeline's
        // 150 MB / 1500-item memory cache remains the second bound.
        let s = UIScreen.main.scale
        let cap: CGFloat
        switch loadProfile {
        case .standard: cap = 512
        case .shelf: cap = 640
        case .grid: cap = 768
        case .high: cap = 1600
        }
        return CGSize(
            width: min(ceil(width * s), cap),
            height: min(ceil(height * s), cap)
        )
    }

    /// Round 14 (B9) + Round 15 (C9): the dark elegant placeholder —
    /// a surface→elevated gradient on the video-surface token (never
    /// pure black, never the washed-out quaternary fill), the section
    /// symbol in a soft accent tint, and — when the call site supplied
    /// a title — the item's own title in the card font.
    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.surface, AppTheme.elevated],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            VStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: min(width, height) * 0.24, weight: .light))
                    .foregroundStyle(AppTheme.accent.opacity(0.45))
                if let title, !title.isEmpty, width >= 80, height >= 100 {
                    Text(title)
                        .font(AppTheme.fontCardTitle)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 8)
                }
            }
        }
        .frame(width: width, height: height)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(AppTheme.cardBorderColor, lineWidth: 1)
        )
    }

}

/// Build 83 (item 4, owner — "صور مقصوصة", the pictures are
/// cropped): measured pixel aspect (width ÷ height) of remote
/// artwork, probed through the SAME Nuke pipeline `CachedImage`
/// renders with. The heroes use it to show artwork WHOLE: art
/// whose measured aspect is wide fills the hero frame as before;
/// portrait/square art is aspect-FITTED over the hero's near-black
/// ground instead of being aspect-fill-cropped (a 2:3 poster
/// filled into a 16:9 frame loses over half its height — the
/// cut faces in the owner's screenshot).
///
/// The probe issues a SMALL aspect-fit request: the returned
/// image keeps the source's natural aspect at a fraction of the
/// bytes, and the pipeline's data cache shares the underlying
/// download with the hero's own full-size request, so probing
/// costs no second fetch of the original. Results are memoised
/// per URL for the session. A failed probe returns nil and the
/// caller keeps its field-based default (backdrop field → fill,
/// poster field → fit) — nothing is ever guessed into a value
/// the payload didn't provide.
final class ArtworkAspectProbe {
    static let shared = ArtworkAspectProbe()

    private var aspects: [String: CGFloat] = [:]
    private let lock = NSLock()

    func cachedAspect(for url: URL) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return aspects[url.absoluteString]
    }

    func probe(_ url: URL) async -> CGFloat? {
        if let cached = cachedAspect(for: url) { return cached }
        let request = ImageRequest(
            url: url,
            processors: [
                ImageProcessors.Resize(
                    size: CGSize(width: 96, height: 96),
                    unit: .pixels,
                    contentMode: .aspectFit,
                    crop: false,
                    upscale: false
                )
            ]
        )
        guard let image = try? await ImagePipeline.shared.image(for: request) else {
            return nil
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let aspect = size.width / size.height
        lock.lock()
        aspects[url.absoluteString] = aspect
        lock.unlock()
        return aspect
    }
}
