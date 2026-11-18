import Foundation
import GRDB

/// Build 61 (B9) — G1 safe-migration layer + Q20 runtime repair.
///
/// G1 — upgrade safety, in `Persistence.makeShared` order:
///  1. BEFORE any migration of this build runs against the on-disk
///     database, `pendingMigrations(at:)` diffs the migrator's
///     registered identifiers against the identifiers already
///     applied to the file (GRDB's `grdb_migrations` record, read
///     through a read-only connection that runs NO migrations).
///  2. When migrations are pending, `writePreMigrationBackup(for:)`
///     checkpoints the WAL and writes a timestamped copy of the
///     database file next to it (`db-backup-<timestamp>.sqlite`,
///     newest two kept). Playlists, favorites, history and
///     downloads metadata therefore survive ANY migration outcome.
///  3. Migrations are idempotent at the granularity that matters:
///     GRDB executes each registered migration inside its own
///     transaction and records it in `grdb_migrations` only after
///     it commits, so re-running the migrator after a failure
///     re-runs exactly the migrations that never committed — never
///     a half-applied one.
///  4. On migration failure with a still-readable file, Persistence
///     restores the newest backup and opens it with migrations
///     disabled (retrying the migrator once first, in case the
///     failure was environmental): the app keeps running on the
///     old schema. No wipe, no crash loop.
///
/// Q20 — runtime corruption recovery: when SQLite itself cannot
/// read the file, `attemptRepair(of:)` works on a COPY of the main
/// file (WAL sidecars deliberately left behind — opening the copy
/// replays only checkpointed state): `PRAGMA integrity_check`,
/// then `REINDEX` + a second check. Only a copy that passes is
/// swapped in. If repair fails, Persistence falls back to its
/// pre-existing path (file renamed aside as `.corrupt.sqlite`,
/// fresh database, one-time in-app notice) — data is preserved
/// wherever SQLite can still read it, and no path here can
/// crash-loop: every step is throwing-optional and the final
/// fallback is the in-memory database.
nonisolated enum DatabaseSafety {
    static let backupPrefix = "db-backup-"
    private static let repairFileName = "db-repair.sqlite"
    private static let failedFilePrefix = "db-failed-"

    // MARK: - G1: pending-migration detection

    /// Registered-but-not-yet-applied migration identifiers for
    /// the database at `url`. `[]` when the file does not exist
    /// (fresh install — nothing to protect); `nil` when the file
    /// cannot be read at the SQLite level (the caller's normal
    /// open + probe flow decides what that means).
    static func pendingMigrations(at url: URL) -> [String]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            let applied = try queue.read { db in
                try AppDatabase.appliedMigrationIdentifiers(db)
            }
            return AppDatabase.registeredMigrationIdentifiers.filter { !applied.contains($0) }
        } catch {
            Log.error("DatabaseSafety", "pending-migration probe failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - G1: pre-migration backup

    /// Writes a timestamped copy of the database (WAL checkpointed
    /// first, so the copy carries every committed transaction) in
    /// the same directory, then prunes older backups to the newest
    /// `keep`. Returns the backup URL, or nil when the copy could
    /// not be written — the caller proceeds with the normal open
    /// either way (a failed backup must never block the app).
    @discardableResult
    static func writePreMigrationBackup(for databaseURL: URL, keep: Int = 2) -> URL? {
        let fm = FileManager.default
        // Flush the WAL into the main file so a plain file copy is
        // a complete, consistent snapshot. Opening a bare GRDB
        // queue runs NO migrations — AppDatabase owns those.
        if let queue = try? DatabaseQueue(path: databaseURL.path) {
            try? queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }
        let stamp = backupTimestamp()
        let backupURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("\(backupPrefix)\(stamp).sqlite")
        do {
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: databaseURL, to: backupURL)
            // A non-empty -wal surviving the checkpoint rides along
            // under the matching sidecar name.
            let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
            if let size = (try? fm.attributesOfItem(atPath: wal.path))?[.size] as? Int, size > 0 {
                let backupWal = URL(fileURLWithPath: backupURL.path + "-wal")
                try? fm.removeItem(at: backupWal)
                try? fm.copyItem(at: wal, to: backupWal)
            }
        } catch {
            Log.error("DatabaseSafety", "pre-migration backup failed: \(error.localizedDescription)")
            return nil
        }
        pruneBackups(for: databaseURL, keep: keep)
        Log.info("DatabaseSafety", "pre-migration backup written: \(backupURL.lastPathComponent)")
        return backupURL
    }

    /// The newest pre-migration backup sitting next to the
    /// database, if any (this launch's, or one left by a previous
    /// launch whose migration never completed).
    static func newestBackup(for databaseURL: URL) -> URL? {
        backupFiles(for: databaseURL).first
    }

    /// Restores `backup` over the database file: the current
    /// (failing) file is first moved aside under a `db-failed-`
    /// name for diagnosis — never deleted — and stale WAL/SHM
    /// sidecars are removed so the restored file opens clean.
    static func restoreBackup(_ backup: URL, to databaseURL: URL) -> Bool {
        let fm = FileManager.default
        let failedURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("\(failedFilePrefix)\(backupTimestamp()).sqlite")
        try? fm.removeItem(at: failedURL)
        try? fm.moveItem(at: databaseURL, to: failedURL)
        try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
        do {
            try fm.copyItem(at: backup, to: databaseURL)
            let backupWal = URL(fileURLWithPath: backup.path + "-wal")
            if fm.fileExists(atPath: backupWal.path) {
                try? fm.copyItem(at: backupWal, to: URL(fileURLWithPath: databaseURL.path + "-wal"))
            }
            return true
        } catch {
            Log.error("DatabaseSafety", "backup restore failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Q20: repair attempt

    /// Attempts to repair a database SQLite could not open, on a
    /// COPY of the main file only. Returns the repaired copy's URL
    /// when `PRAGMA integrity_check` passes (possibly after a
    /// `REINDEX`); the caller swaps it in. Returns nil when the
    /// copy is still corrupt — the caller's rename-aside + fresh
    /// start path then applies, exactly as before this layer
    /// existed.
    static func attemptRepair(of databaseURL: URL) -> URL? {
        let fm = FileManager.default
        let repairURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(repairFileName)
        try? fm.removeItem(at: repairURL)
        try? fm.removeItem(at: URL(fileURLWithPath: repairURL.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: repairURL.path + "-shm"))
        guard (try? fm.copyItem(at: databaseURL, to: repairURL)) != nil else { return nil }

        func integrityOK(_ queue: DatabaseQueue) -> Bool {
            (try? queue.read { db in
                try String.fetchOne(db, sql: "PRAGMA integrity_check")
            }) == "ok"
        }

        guard let queue = try? DatabaseQueue(path: repairURL.path) else {
            try? fm.removeItem(at: repairURL)
            return nil
        }
        if integrityOK(queue) {
            Log.info("DatabaseSafety", "Q20 repair: copy passes integrity check (WAL sidecar was the fault)")
            return repairURL
        }
        // Index corruption is the common repairable case: rebuild
        // every index, checkpoint, and check again.
        try? queue.writeWithoutTransaction { db in
            try db.execute(sql: "REINDEX")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        if integrityOK(queue) {
            Log.info("DatabaseSafety", "Q20 repair: REINDEX restored integrity")
            return repairURL
        }
        try? fm.removeItem(at: repairURL)
        Log.error("DatabaseSafety", "Q20 repair: integrity check still failing — repair abandoned")
        return nil
    }

    /// Swaps a repaired copy in over the database file (the
    /// corrupt original is preserved by the caller's rename-aside
    /// step, which runs first).
    static func installRepairedFile(_ repairURL: URL, at databaseURL: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
        do {
            try fm.moveItem(at: repairURL, to: databaseURL)
            return true
        } catch {
            Log.error("DatabaseSafety", "installing repaired DB failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Helpers

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Backup files next to the database, newest first (the
    /// timestamped names sort chronologically).
    private static func backupFiles(for databaseURL: URL) -> [URL] {
        let directory = databaseURL.deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix(backupPrefix) && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func pruneBackups(for databaseURL: URL, keep: Int) {
        for stale in backupFiles(for: databaseURL).dropFirst(keep) {
            try? FileManager.default.removeItem(at: stale)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: stale.path + "-wal"))
        }
    }
}
