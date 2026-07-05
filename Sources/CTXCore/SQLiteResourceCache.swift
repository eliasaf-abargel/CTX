import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistent, disk-backed cache of *safe metadata only* — the same
/// `KubernetesResourceList` rows already held in memory. By construction, that
/// type never carries Secret values, ConfigMap values, raw YAML, kubeconfig
/// contents, or tokens (see `SECURITY.md`); Secrets/ConfigMaps are already
/// metadata-only at the point they become a `KubernetesResourceList`, so
/// persisting one is exactly as safe as caching it in memory already was. YAML
/// (`KubernetesYAMLResult`) and Logs (`KubernetesLogsResult`) are never passed
/// to this type's API and are never persisted.
///
/// Its only purpose is making the next app launch feel instant: on open, the
/// coordinator hydrates from here before any kubectl call runs — that data is
/// necessarily older than the in-memory stale threshold, so it renders
/// immediately as a *stale* entry, which is exactly what triggers a normal
/// background refresh to quietly replace it, the same stale-while-revalidate
/// path already used for same-session staleness.
///
/// Uses the system `libsqlite3` directly (`import SQLite3`, no package
/// dependency) — a thin, single-purpose wrapper, not a general SQL layer.
public actor SQLiteResourceCache {
    /// Cached entries older than this are dropped on open. This is a
    /// startup-hydration seed only, never load-bearing on its own — an entry
    /// this old has long since been superseded by live refreshes, so keeping it
    /// forever would only cost disk space, especially for dynamic clusters where
    /// namespaces come and go often.
    private static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    private let db: OpaquePointer?

    public init(path: URL? = nil) {
        let dbPath = path ?? Self.defaultPath()
        try? FileManager.default.createDirectory(at: dbPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.db = Self.openHealthyDatabase(at: dbPath)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public func store(contextID: String, namespace: String, kind: String, list: KubernetesResourceList) {
        guard let db, let payload = try? JSONEncoder().encode(list), let json = String(data: payload, encoding: .utf8) else { return }
        let sql = """
        INSERT INTO resource_cache (context_id, namespace, kind, loaded_at, payload) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(context_id, namespace, kind) DO UPDATE SET loaded_at = excluded.loaded_at, payload = excluded.payload
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, contextID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, namespace, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, kind, -1, sqliteTransient)
        sqlite3_bind_double(statement, 4, list.loadedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 5, json, -1, sqliteTransient)
        sqlite3_step(statement)
    }

    public func load(contextID: String, namespace: String, kind: String) -> KubernetesResourceList? {
        guard let db else { return nil }
        let sql = "SELECT payload FROM resource_cache WHERE context_id = ? AND namespace = ? AND kind = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, contextID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, namespace, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, kind, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) else { return nil }
        return try? JSONDecoder().decode(KubernetesResourceList.self, from: Data(String(cString: cString).utf8))
    }

    /// Removes every entry for a context — used when the user removes that
    /// Kubernetes context from CTX, so a stale disk entry can never resurface
    /// under a context CTX no longer knows about.
    public func clearContext(_ contextID: String) {
        exec("DELETE FROM resource_cache WHERE context_id = ?", bindings: [contextID])
    }

    private func exec(_ sql: String, bindings: [String] = []) {
        Self.exec(db, sql, bindings: bindings)
    }

    /// Opens `path`, verifying the database is actually readable rather than
    /// trusting `sqlite3_open` alone — SQLite defers most corruption detection
    /// to the first real read, so a prior crash mid-write (or a manually
    /// damaged file) can otherwise leave the cache silently, permanently
    /// non-functional. On a failed integrity check, the file is deleted and
    /// recreated fresh exactly once — this is a disposable cache, not a source
    /// of truth, so discarding a corrupted copy is always safe.
    private static func openHealthyDatabase(at path: URL, hasRetried: Bool = false) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open(path.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        guard isHealthy(handle) else {
            sqlite3_close(handle)
            guard !hasRetried else { return nil }
            try? FileManager.default.removeItem(at: path)
            return openHealthyDatabase(at: path, hasRetried: true)
        }

        exec(handle, "PRAGMA journal_mode=WAL")
        exec(handle, "PRAGMA busy_timeout=2000")
        exec(handle, """
        CREATE TABLE IF NOT EXISTS resource_cache (
            context_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            kind TEXT NOT NULL,
            loaded_at REAL NOT NULL,
            payload TEXT NOT NULL,
            PRIMARY KEY (context_id, namespace, kind)
        )
        """)
        pruneExpiredEntries(handle)
        return handle
    }

    private static func isHealthy(_ db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: cString) == "ok"
    }

    private static func pruneExpiredEntries(_ db: OpaquePointer) {
        let cutoff = Date().addingTimeInterval(-retentionInterval).timeIntervalSince1970
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM resource_cache WHERE loaded_at < ?", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        sqlite3_step(statement)
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String, bindings: [String] = []) {
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient)
        }
        sqlite3_step(statement)
    }

    private static func defaultPath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CTX", isDirectory: true).appendingPathComponent("resource-cache.sqlite3")
    }
}
