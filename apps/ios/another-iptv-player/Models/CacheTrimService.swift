import Foundation

/// Build 61 (B9) — Q22 automatic cache trimming.
///
/// The bound: the app's Caches directory (Library/Caches — the
/// same tree B2's `StorageService.cacheSizeBytes()` measures for
/// the T1 storage page, SPEC §5 contract) is capped at
/// `capBytes`. The dominant tenant is the Nuke image disk cache
/// ("com.superx.images", itself size-limited to 300 MB in
/// `IPTVRemoteImagePipeline`), so the app-level cap uses the same
/// 300 MB figure: the numbers the user sees on the T1 page and
/// the bound enforced here describe the same directory with the
/// same limit.
///
/// Enforcement points: once from the app root's deferred launch
/// task, then periodically (every 6 hours) for long-running
/// sessions. Eviction is oldest-first by file content-modification
/// date and stops at 90% of the cap, so a trim never fights the
/// caches that are actively warm. URLCache's own database files
/// (`Cache.db*`) are never unlinked directly — when the tree is
/// still over the cap after file eviction, `URLCache.shared` is
/// emptied through its own API instead. Downloads live outside
/// Caches (Application Support / Documents) and are never
/// touched; favorites, settings and the database are not in this
/// tree either.
enum CacheTrimService {
    /// 300 MB — deliberately identical to the Nuke disk cache's
    /// own size limit (CachedImage.swift, round 15).
    static let capBytes: Int64 = 300 * 1024 * 1024
    private static let targetFraction = 0.9
    private static var didStartPeriodicTrim = false

    static func cachesDirectoryURL() -> URL? {
        try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
    }

    /// Total size of the Caches tree in bytes — the same
    /// measurement the T1 page shows via `StorageService`.
    static func cacheSizeBytes() -> Int64 {
        guard let root = cachesDirectoryURL() else { return 0 }
        return directorySize(at: root)
    }

    /// Trims the Caches tree back under the cap, oldest files
    /// first. Safe to call from any queue; does nothing when the
    /// tree is already within bounds.
    static func trimIfNeeded() {
        guard let root = cachesDirectoryURL() else { return }
        let target = Int64(Double(capBytes) * targetFraction)
        var size = directorySize(at: root)
        guard size > capBytes else { return }

        let fm = FileManager.default
        var files: [(url: URL, size: Int64, modified: Date)] = []
        if let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true
                else { continue }
                // URLCache's SQLite store is managed through its
                // own API below, never by unlinking its files.
                if url.lastPathComponent.hasPrefix("Cache.db") { continue }
                files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
            }
        }
        files.sort { $0.modified < $1.modified }
        for file in files {
            if size <= target { break }
            if (try? fm.removeItem(at: file.url)) != nil {
                size -= file.size
            }
        }
        if size > target {
            URLCache.shared.removeAllCachedResponses()
            size = directorySize(at: root)
        }
        Log.info("CacheTrim", "Q22 trim finished: Caches now \(size) bytes (cap \(capBytes))")
    }

    /// Starts the periodic trimmer once per process: a utility
    /// task that trims every ~6 hours while the app lives. Called
    /// from the app root's deferred launch task (never on the
    /// cold-start critical path).
    static func startPeriodicTrimming() {
        guard !didStartPeriodicTrim else { return }
        didStartPeriodicTrim = true
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 3_600 * 1_000_000_000)
                if Task.isCancelled { return }
                trimIfNeeded()
            }
        }
    }

    private static func directorySize(at root: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
