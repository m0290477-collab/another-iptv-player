import Foundation
import GRDB

/// Last-query cache to normalize the query words once when the query changes, not per row:
/// `localized_contains` is called for every row (100k+ rows).
/// `nonisolated`: runs inside GRDB's DatabaseFunction callbacks on DB queues (a
/// DatabasePool serves concurrent readers), so all state is guarded by the lock.
private nonisolated final class NormalizedQueryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var lastQuery: String?
    private var lastWords: [String] = []

    func words(for query: String, normalize: (String) -> String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if lastQuery == query { return lastWords }
        let words = query
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map(normalize)
        lastQuery = query
        lastWords = words
        return words
    }
}

/// Build 66 (W4, item 15a): typed storage-open failure. Thrown by
/// the throwing open path (`openInMemoryFallback()`) when no usable
/// store could be opened at all — replacing the old `fatalError`
/// that crash-looped the app on a device whose storage was broken.
enum PersistenceError: Error {
    case storageUnavailable(underlying: String)
}

nonisolated extension AppDatabase {
    /// Build 66 (W4, item 15a): a `var`, not a `let` — when the
    /// storage-unavailable recovery's "Try again" re-attempts the
    /// open and succeeds, the recovered instance replaces this one
    /// (see `retryStorageOpen()`). All existing read sites compile
    /// and behave exactly as before.
    nonisolated(unsafe) static var shared = makeShared()

    /// True: the disk DB could not be opened, the session runs in-memory — nothing written in this session
    /// persists. The root view warns the user once.
    nonisolated(unsafe) private(set) static var isEphemeral = false
    /// True: the corrupt DB file was set aside and created from scratch on disk — the data was
    /// reset, but everything after that persists. The root view warns the user once.
    nonisolated(unsafe) private(set) static var didResetCorruptStore = false
    /// S2 (Round 14): True when the on-disk DB is a perfectly readable
    /// SQLite file but opening it failed anyway — i.e. a MIGRATION in
    /// this build failed, not corruption. The file is left completely
    /// untouched (a fixed build will open it with all data intact) and
    /// the session runs on the in-memory fallback (`isEphemeral` is
    /// also set, so the root view's existing one-time warning fires).
    nonisolated(unsafe) private(set) static var didPreserveStoreAfterOpenFailure = false
    /// Build 61 (B9, G1): True when this build's migrations failed
    /// against the live file and the session is running on the
    /// RESTORED pre-migration backup with the OLD schema (migrations
    /// disabled). The user's data is intact; a fixed build migrates
    /// it normally. The root view warns the user once.
    nonisolated(unsafe) private(set) static var didRestorePreMigrationBackup = false
    /// Build 61 (B9, Q20): True when the on-disk DB failed to open
    /// but the repair pass (integrity check / REINDEX on a copy)
    /// recovered it with data preserved. No user data was lost, so
    /// no warning is shown; the flag exists for diagnostics.
    nonisolated(unsafe) private(set) static var didRecoverStoreViaRepair = false
    /// Build 66 (W4, item 15a): True when even the in-memory
    /// fallback failed to open (as a migrated store). The session
    /// then runs on a no-migration placeholder instance that must
    /// never be queried — the root view replaces the whole UI with
    /// StorageUnavailableView while this is set.
    nonisolated(unsafe) private(set) static var isStorageUnavailable = false

    private static func databaseFileURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

        // Use Bundle Identifier for a unique subfolder (crucial on macOS).
        // Round 16 (R9): the nil-fallback names this app's own bundle
        // id (it previously carried the upstream project's id; the
        // fallback never executes in the shipped app, where the
        // bundle identifier is always present).
        let bundleID = Bundle.main.bundleIdentifier ?? "com.irqus.superx"
        let appDirectoryURL = appSupportURL.appendingPathComponent(bundleID, isDirectory: true)
        let directoryURL = appDirectoryURL.appendingPathComponent("Database", isDirectory: true)

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent("db.sqlite")
    }

    private static func makeShared() -> AppDatabase {
        do {
            // A single schema file instead of the old db.sqlite + multiple migration history (local data is reset).
            let databaseURL = try databaseFileURL()
            // === Build 61 (B9, G1): BEFORE the first migration of
            // this build runs, write a timestamped backup of the
            // database file whenever migrations are still pending.
            // The diff is computed through a read-only connection
            // that runs no migrations (DatabaseSafety). A failed
            // backup never blocks the open — the catch path below
            // still has the S2 preservation behaviour. ===
            if let pending = DatabaseSafety.pendingMigrations(at: databaseURL), !pending.isEmpty {
                DatabaseSafety.writePreMigrationBackup(for: databaseURL)
            }
            let dbPool = try DatabasePool(path: databaseURL.path, configuration: databaseConfiguration())
            return try AppDatabase(dbPool)
        } catch {
            Log.error("Persistence", "DB pool init failed (disk/sandbox/corrupt?): \(error.localizedDescription)")

            // S2 (Round 14): the catch above used to treat EVERY failure
            // the same — including a MIGRATION error thrown by
            // `AppDatabase.init` in a new build — and moved the user's
            // live DB aside, wiping playlists/favorites/history over
            // what may be a one-line schema bug in the update itself.
            // Now: probe the file at the SQLite level FIRST (read-only,
            // no migrations run). Only a file SQLite itself cannot read
            // is corruption; a readable file means the failure came
            // from migration/init code, and the file must survive.
            if let databaseURL = try? databaseFileURL() {
                switch probeDatabaseFile(at: databaseURL) {
                case .readable:
                    // === Build 61 (B9, G1): a pre-migration backup
                    // exists → restore it and keep running on the
                    // old schema (see openRestoredDatabase). Only
                    // when no backup exists does the S2 preservation
                    // path below apply. ===
                    if let backup = DatabaseSafety.newestBackup(for: databaseURL),
                       let restored = openRestoredDatabase(databaseURL: databaseURL, backup: backup) {
                        return restored
                    }
                    // Migration/init failure — NEVER move, rename or
                    // wipe the file. A read-only open of the real file
                    // is not an option here: `AppDatabase.init` always
                    // runs the migrator, and the pending (failing)
                    // migration would throw again on a read-only pool.
                    // The in-memory fallback is the least invasive
                    // non-destructive option this structure supports:
                    // the session starts empty but the user's file
                    // stays byte-identical for a fixed build.
                    didPreserveStoreAfterOpenFailure = true
                    Log.error("Persistence", "DB dosyası sağlam ama açılış/migration başarısız — dosya KORUNDU, oturum bellek-içi fallback ile sürüyor")
                    return makeInMemoryFallback()
                case .unreadable:
                    // === Build 61 (B9, Q20): before the reset
                    // below, try to REPAIR: integrity check /
                    // REINDEX on a copy of the file. A copy that
                    // passes is swapped in (the corrupt original is
                    // still renamed aside first, exactly as the
                    // reset path does) and opened normally — user
                    // data preserved, no reset, no warning needed.
                    if let repaired = DatabaseSafety.attemptRepair(of: databaseURL) {
                        let fm = FileManager.default
                        let aside = databaseURL.deletingPathExtension().appendingPathExtension("corrupt.sqlite")
                        try? fm.removeItem(at: aside)
                        try? fm.moveItem(at: databaseURL, to: aside)
                        if DatabaseSafety.installRepairedFile(repaired, at: databaseURL),
                           let pool = try? DatabasePool(path: databaseURL.path, configuration: databaseConfiguration()),
                           let db = try? AppDatabase(pool) {
                            didRecoverStoreViaRepair = true
                            Log.error("Persistence", "Q20: bozuk DB onarıldı ve verisiyle açıldı (orijinal db.corrupt.sqlite olarak kenara alındı)")
                            return db
                        }
                        // Swap-in failed after the original was
                        // set aside: fall through — the reset path
                        // below recreates a fresh file at the same
                        // path (the corrupt original stays aside).
                    }
                    // Real corruption: set the file aside and create it FROM SCRATCH on disk;
                    // try: better than the in-memory fallback — the data
                    // it is reset, but everything after that persists; the old
                    // file is kept as .corrupt.
                    let fm = FileManager.default
                    let backup = databaseURL.deletingPathExtension().appendingPathExtension("corrupt.sqlite")
                    try? fm.removeItem(at: backup)
                    try? fm.moveItem(at: databaseURL, to: backup)
                    try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
                    try? fm.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
                    if let pool = try? DatabasePool(path: databaseURL.path, configuration: databaseConfiguration()),
                       let db = try? AppDatabase(pool) {
                        didResetCorruptStore = true
                        Log.error("Persistence", "bozuk DB kenara alındı (db.corrupt.sqlite), yeni disk DB oluşturuldu")
                        return db
                    }
                    return makeInMemoryFallback()
                case .noFile:
                    // No file to open (sandbox/directory problem): there is also nothing to move
                    // or preserve.
                    return makeInMemoryFallback()
                }
            }

            return makeInMemoryFallback()
        }
    }

    /// S2 (Round 14): SQLite-level health probe for the DB file.
    /// Opens the file READ-ONLY through GRDB and reads the schema —
    /// crucially WITHOUT running any migration. A non-SQLite or
    /// corrupt file fails here (SQLITE_NOTADB / SQLITE_CORRUPT); a
    /// healthy file whose only problem is a failing migration in the
    /// current build reads fine.
    private enum DatabaseFileProbe {
        case noFile
        case readable
        case unreadable
    }

    private static func probeDatabaseFile(at url: URL) -> DatabaseFileProbe {
        guard FileManager.default.fileExists(atPath: url.path) else { return .noFile }
        do {
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            // Force the lazy connection open and touch the schema.
            _ = try queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master") ?? 0
            }
            return .readable
        } catch {
            Log.error("Persistence", "DB probe failed (gerçek bozulma?): \(error.localizedDescription)")
            return .unreadable
        }
    }

    /// Build 61 (B9, G1): restore path for a failed migration.
    /// The newest pre-migration backup replaces the live file (the
    /// failing file is kept aside by `DatabaseSafety.restoreBackup`
    /// under a `db-failed-` name). The migrator is retried ONCE on
    /// the restored copy — a failure caused by the environment
    /// (interrupted write, transient I/O) heals silently. If it
    /// fails again, the restored database opens with migrations
    /// DISABLED: the app runs on the old schema with all user data
    /// intact, and `didRestorePreMigrationBackup` makes the root
    /// view warn once. Returns nil when even the no-migration open
    /// fails — the caller then falls back to the S2 behaviour.
    private static func openRestoredDatabase(databaseURL: URL, backup: URL) -> AppDatabase? {
        guard DatabaseSafety.restoreBackup(backup, to: databaseURL) else { return nil }
        if let pool = try? DatabasePool(path: databaseURL.path, configuration: databaseConfiguration()),
           let db = try? AppDatabase(pool) {
            Log.error("Persistence", "G1: yedek geri yüklendi, migration tekrar denemede başarılı — normal açılış")
            return db
        }
        guard let pool = try? DatabasePool(path: databaseURL.path, configuration: databaseConfiguration()),
              let db = try? AppDatabase(pool, runMigrations: false)
        else { return nil }
        didRestorePreMigrationBackup = true
        Log.error("Persistence", "G1: migration başarısız — yedek geri yüklendi, oturum ESKİ şemayla sürüyor (veri sağlam)")
        return db
    }

    /// Disk full, a sandbox problem, or the S2 protection → instead of killing the app, an
    /// in-memory fallback. This session's data does not persist, but the app
    /// stays open; the root view warns the user once.
    /// Build 66 (W4, item 15a): the throwing in-memory open. A
    /// failure here means NO usable store exists — surfaced as the
    /// typed `PersistenceError.storageUnavailable` instead of the
    /// old fatalError crash loop.
    private static func openInMemoryFallback() throws -> AppDatabase {
        do {
            let queue = try DatabaseQueue(configuration: databaseConfiguration())
            let db = try AppDatabase(queue)
            Log.error("Persistence", "in-memory DB fallback aktif — kullanıcı verisi bu oturumda kaybolacak")
            isEphemeral = true
            return db
        } catch {
            Log.error("Persistence", "in-memory DB fallback başarısız: \(error.localizedDescription)")
            throw PersistenceError.storageUnavailable(underlying: error.localizedDescription)
        }
    }

    private static func makeInMemoryFallback() -> AppDatabase {
        do {
            return try openInMemoryFallback()
        } catch {
            // Storage is genuinely unavailable: flag it so the root
            // view presents StorageUnavailableView (with a Try again
            // that re-runs the whole open chain via
            // `retryStorageOpen()`), and return a no-migration
            // placeholder instance. The placeholder has NO schema
            // and must never be queried — the root view's guard
            // replaces the UI before any query can reach it, and the
            // app root's deferred DB work is skipped while the flag
            // is set. `AppDatabase.init` with migrations disabled
            // cannot throw, so this construction only fails if
            // SQLite cannot create an in-memory store at all.
            isStorageUnavailable = true
            if let queue = try? DatabaseQueue(),
               let placeholder = try? AppDatabase(queue, runMigrations: false) {
                return placeholder
            }
            // Documented last resort (kept from the pre-66 code): if
            // even a bare in-memory SQLite store cannot be created,
            // there is no AppDatabase value the app could run on and
            // no recovery UI could be backed by one. This path is
            // unreachable in any state where SQLite itself works.
            fatalError("DB tamamen başarısız: in-memory store could not be created")
        }
    }

    /// Build 66 (W4, item 15a): the StorageUnavailableView "Try
    /// again" action — re-runs the FULL open chain once (disk open
    /// → G1 backup-restore → no-migration open → in-memory
    /// fallback, in the original order). On success the recovered
    /// instance replaces `shared`, the flag clears, and the caller
    /// dismisses the recovery screen. Returns whether storage is
    /// usable now.
    static func retryStorageOpen() -> Bool {
        isStorageUnavailable = false
        isEphemeral = false
        let reopened = makeShared()
        guard !isStorageUnavailable else { return false }
        shared = reopened
        return true
    }

    static func empty() -> AppDatabase {
        // Preview-only. Build 66 (W4, item 15a): the `try!` pair is
        // replaced with tiered attempts — a migrated in-memory
        // store, then a no-migration one (whose init cannot throw).
        if let dbQueue = try? DatabaseQueue(configuration: databaseConfiguration()),
           let db = try? AppDatabase(dbQueue) {
            return db
        }
        if let dbQueue = try? DatabaseQueue(),
           let db = try? AppDatabase(dbQueue, runMigrations: false) {
            return db
        }
        // Same documented last resort as makeInMemoryFallback():
        // unreachable while SQLite itself works.
        fatalError("DB tamamen başarısız: preview store could not be created")
    }
    
    private static func databaseConfiguration() -> Configuration {
        var config = Configuration()
        // C10 (Round 15): incremental auto-vacuum — large replacements
        // (EPG guide, catalog sync) free pages that an incremental
        // vacuum can hand back without a full-file rewrite. Must be set
        // on every connection; on an existing full-vacuum file it takes
        // effect after the next VACUUM, on new files immediately.
        config.prepareDatabase { db in
            try? db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }
        config.prepareDatabase { db in
            let foldLocale = Locale(identifier: "en_US_POSIX")
            let alphanumericSet = CharacterSet.alphanumerics

            // Must stay in sync with CatalogTextSearch.normalize (see rationale there):
            // locale-invariant case fold + "ı"→"i" so lowercase queries match ALL-CAPS
            // names in both English ("HISTORY") and Turkish ("IŞIK") catalogs.
            // Build 66 (W4, syncing W8's unified fold): the SAME
            // Arabic equivalence pass as CatalogTextSearch.baseFold —
            // ة→ه, ى→ي, ک→ك, ی→ي and tatweel (U+0640) stripped — so
            // the SQL-side fold and the in-memory fold never diverge.
            let normalize: @Sendable (String) -> String = { s in
                let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldLocale)
                return folded
                    .replacingOccurrences(of: "ı", with: "i")
                    .replacingOccurrences(of: "\u{0629}", with: "\u{0647}")
                    .replacingOccurrences(of: "\u{0649}", with: "\u{064A}")
                    .replacingOccurrences(of: "\u{06A9}", with: "\u{0643}")
                    .replacingOccurrences(of: "\u{06CC}", with: "\u{064A}")
                    .replacingOccurrences(of: "\u{0640}", with: "")
                    .components(separatedBy: alphanumericSet.inverted)
                    .joined()
            }

            let queryCache = NormalizedQueryCache()
            let containsFunc = DatabaseFunction("localized_contains", argumentCount: 2, pure: true) { (dbValues: [DatabaseValue]) -> DatabaseValueConvertible? in
                guard dbValues.count == 2,
                      let text = String.fromDatabaseValue(dbValues[0]),
                      let query = String.fromDatabaseValue(dbValues[1]) else { return nil }

                let normalizedText = normalize(text)
                let queryWords = queryCache.words(for: query, normalize: normalize)
                if queryWords.isEmpty { return false }

                // Every word in the query must be found in the normalized text
                return queryWords.allSatisfy { word in
                    normalizedText.contains(word)
                }
            }
            db.add(function: containsFunc)
            
            let startsWithFunc = DatabaseFunction("localized_starts_with", argumentCount: 2, pure: true) { (dbValues: [DatabaseValue]) -> DatabaseValueConvertible? in
                guard dbValues.count == 2,
                      let text = String.fromDatabaseValue(dbValues[0]),
                      let query = String.fromDatabaseValue(dbValues[1]) else { return nil }
                return normalize(text).hasPrefix(normalize(query))
            }
            db.add(function: startsWithFunc)
            
            let equalsFunc = DatabaseFunction("localized_equals", argumentCount: 2, pure: true) { (dbValues: [DatabaseValue]) -> DatabaseValueConvertible? in
                guard dbValues.count == 2,
                      let text = String.fromDatabaseValue(dbValues[0]),
                      let query = String.fromDatabaseValue(dbValues[1]) else { return nil }
                return normalize(text) == normalize(query)
            }
            db.add(function: equalsFunc)
        }
        return config
    }
}
