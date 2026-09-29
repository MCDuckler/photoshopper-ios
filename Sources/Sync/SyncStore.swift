import Foundation
import SQLite3

/// What this phone has put into Photos: one row per synced photo.
/// Rebuildable from the album itself (XMP tag in every file) after a reinstall.
struct SyncedRow: Equatable {
    var photoID: String
    var recipeHash: String
    var variant: String
    var assetID: String
    var bytes: Int
    var syncedAt: Date
}

final class SyncStore {
    static let shared = SyncStore()
    private var db: OpaquePointer?
    private let lock = NSLock()

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("sync.sqlite").path
        sqlite3_open(path, &db)
        exec("""
        CREATE TABLE IF NOT EXISTS synced (
            photo_id TEXT PRIMARY KEY, recipe_hash TEXT NOT NULL, variant TEXT NOT NULL,
            asset_id TEXT NOT NULL, bytes INTEGER NOT NULL DEFAULT 0, synced_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS failures (photo_id TEXT PRIMARY KEY, count INTEGER NOT NULL, last_error TEXT, at REAL NOT NULL);
        """)
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func col(_ st: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }

    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func all() -> [String: SyncedRow] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: SyncedRow] = [:]
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT photo_id, recipe_hash, variant, asset_id, bytes, synced_at FROM synced", -1, &st, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW {
            let r = SyncedRow(photoID: col(st, 0),
                              recipeHash: col(st, 1),
                              variant: col(st, 2),
                              assetID: col(st, 3),
                              bytes: Int(sqlite3_column_int64(st, 4)),
                              syncedAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 5)))
            out[r.photoID] = r
        }
        return out
    }

    func upsert(_ r: SyncedRow) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "INSERT INTO synced(photo_id, recipe_hash, variant, asset_id, bytes, synced_at) VALUES(?,?,?,?,?,?) ON CONFLICT(photo_id) DO UPDATE SET recipe_hash=excluded.recipe_hash, variant=excluded.variant, asset_id=excluded.asset_id, bytes=excluded.bytes, synced_at=excluded.synced_at"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, r.photoID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(st, 2, r.recipeHash, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(st, 3, r.variant, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(st, 4, r.assetID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(st, 5, Int64(r.bytes))
        sqlite3_bind_double(st, 6, r.syncedAt.timeIntervalSince1970)
        sqlite3_step(st)
        clearFailure(r.photoID, locked: true)
    }

    func remove(_ photoID: String) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM synced WHERE photo_id = ?", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, photoID, -1, SQLITE_TRANSIENT)
        sqlite3_step(st)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM synced; DELETE FROM failures;")
    }

    func noteFailure(_ photoID: String, _ error: String) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "INSERT INTO failures(photo_id, count, last_error, at) VALUES(?,1,?,?) ON CONFLICT(photo_id) DO UPDATE SET count=count+1, last_error=excluded.last_error, at=excluded.at"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, photoID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(st, 2, error, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(st, 3, Date().timeIntervalSince1970)
        sqlite3_step(st)
    }

    func failureCount(_ photoID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count FROM failures WHERE photo_id = ?", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, photoID, -1, SQLITE_TRANSIENT)
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : 0
    }

    private func clearFailure(_ photoID: String, locked: Bool) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM failures WHERE photo_id = ?", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, photoID, -1, SQLITE_TRANSIENT)
        sqlite3_step(st)
    }
}
