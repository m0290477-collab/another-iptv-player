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

nonisolated extension AppDatabase {
    static let shared = makeShared()

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

    /// Disk full, a sandbox problem, or the S2 protection → instead of killing the app, an
    /// in-memory fallback. This session's data does not persist, but the app
    /// stays open; the root view warns the user once.
    private static func makeInMemoryFallback() -> AppDatabase {
        do {
            let queue = try DatabaseQueue(configuration: databaseConfiguration())
            Log.error("Persistence", "in-memory DB fallback aktif — kullanıcı verisi bu oturumda kaybolacak")
            isEphemeral = true
            return try AppDatabase(queue)
        } catch {
            // If the DB cannot be opened even in memory, the device is in a critical state; a last resort with a clear message.
            Log.error("Persistence", "in-memory DB fallback başarısız: \(error.localizedDescription)")
            fatalError("DB tamamen başarısız: \(error.localizedDescription)")
        }
    }
    
    static func empty() -> AppDatabase {
        let dbQueue = try! DatabaseQueue(configuration: databaseConfiguration())
        return try! AppDatabase(dbQueue)
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
            let normalize: @Sendable (String) -> String = { s in
                let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldLocale)
                return folded
                    .replacingOccurrences(of: "ı", with: "i")
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
