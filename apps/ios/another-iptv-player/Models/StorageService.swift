import Foundation

/// B2 (build 61, T1-service): the storage contract of SPEC §5 that
/// B3's Storage settings UI calls. All values are measured from the
/// filesystem at call time — nothing is cached or estimated.
///
/// Cache = the app's Library/Caches directory (the Nuke image
/// DataCache "com.superx.images" lives there, alongside URLCache's
/// store). Downloads = Application Support/Downloads, managed by
/// `DownloadStorage`. The two roots are disjoint: `clearCache()` can
/// never touch downloads, favorites, the database or settings.
nonisolated enum StorageService {

    // MARK: - Contract (SPEC §5)

    /// Total size of everything under Library/Caches.
    static func cacheSizeBytes() -> Int64 {
        guard let caches = cachesDirectory() else { return 0 }
        return directorySize(at: caches)
    }

    /// Total size of the Downloads root (media files + resume blobs).
    static func downloadsSizeBytes() -> Int64 {
        DownloadStorage.totalUsedBytes()
    }

    /// Number of downloaded media files on disk. Resume blobs
    /// (`.resume` directory) are bookkeeping, not downloads, and are
    /// not counted.
    static func downloadsCount() -> Int {
        guard let root = try? DownloadStorage.rootDirectory() else { return 0 }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    /// Removes ONLY the contents of Library/Caches (every entry in
    /// it, including the image DataCache) plus the shared URLCache.
    /// Downloads (Application Support), the GRDB database, favorites
    /// and UserDefaults are in different roots and are never touched.
    static func clearCache() {
        if let caches = cachesDirectory() {
            let fm = FileManager.default
            if let entries = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
                for entry in entries {
                    try? fm.removeItem(at: entry)
                }
            }
        }
        URLCache.shared.removeAllCachedResponses()
    }

    // MARK: - Helpers

    private static func cachesDirectory() -> URL? {
        try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
    }

    private static func directorySize(at directory: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: []
              )
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true,
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
