import Foundation
import SQLite3

public struct ObjectIndexScope: Hashable, Sendable {
    public let connectionID: UUID
    public let bucket: String
    public let prefix: String

    public init(connectionID: UUID, bucket: String, prefix: String) {
        self.connectionID = connectionID
        self.bucket = bucket
        self.prefix = prefix
    }

    fileprivate var id: String {
        [
            connectionID.uuidString,
            Data(bucket.utf8).base64EncodedString(),
            Data(prefix.utf8).base64EncodedString(),
        ].joined(separator: ":")
    }
}

public struct ObjectIndexSnapshot: Equatable, Sendable {
    public let objectCount: Int
    public let indexedAt: Date
    public let isStale: Bool

    public init(objectCount: Int, indexedAt: Date, isStale: Bool = false) {
        self.objectCount = objectCount
        self.indexedAt = indexedAt
        self.isStale = isStale
    }
}

public struct ObjectIndexBuild: Hashable, Sendable {
    fileprivate let scope: ObjectIndexScope
    fileprivate let generation: String
}

public struct ObjectIndexPage: Sendable {
    public let objects: [S3Object]
    public let continuationCursor: Int64?
    public let snapshot: ObjectIndexSnapshot
}

public enum ObjectSearchIndexError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case incompatibleSchema

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The local search index is unavailable."
        case .incompatibleSchema:
            "The local search index was created by an incompatible app version."
        }
    }
}

public actor ObjectSearchIndex {
    private struct ActiveSnapshot {
        let generation: String
        let snapshot: ObjectIndexSnapshot
    }

    private struct IndexedScope {
        let id: String
        let generation: String
        let prefix: String
    }

    private struct Candidate {
        let rowID: Int64
        let object: S3Object
    }

    private static let schemaVersion: Int32 = 1
    private let database: SQLiteConnection

    public init(fileURL: URL) throws {
        database = try SQLiteConnection(fileURL: fileURL)
        try Self.migrate(database)
        try Self.discardInterruptedBuilds(database)
    }

    public static func applicationSupport(appName: String = "S3Workbench") throws
        -> ObjectSearchIndex
    {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(appName, isDirectory: true)
        return try ObjectSearchIndex(fileURL: directory.appendingPathComponent("search-index.sqlite3"))
    }

    public func snapshot(for scope: ObjectIndexScope) throws -> ObjectIndexSnapshot? {
        try activeSnapshot(for: scope)?.snapshot
    }

    public func beginRebuild(for scope: ObjectIndexScope) throws -> ObjectIndexBuild {
        let generation = UUID().uuidString
        try database.transaction {
            try ensureScope(scope)
            try discardBuilds(for: scope.id)
            try database.withStatement(
                "INSERT INTO search_builds(scope_id, generation, started_at, is_dirty) VALUES (?, ?, ?, 0)"
            ) { statement in
                try bind(scope.id, to: 1, in: statement)
                try bind(generation, to: 2, in: statement)
                sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                try stepDone(statement)
            }
        }
        return ObjectIndexBuild(scope: scope, generation: generation)
    }

    public func append(_ objects: [S3Object], to build: ObjectIndexBuild) throws {
        guard try buildExists(build) else { throw ObjectSearchIndexError.unavailable }
        let objects = objects.filter {
            bytesStart($0.key, with: build.scope.prefix)
                && !bytesEqual($0.key, build.scope.prefix)
        }
        guard !objects.isEmpty else { return }

        try database.transaction {
            try database.withStatement(
                """
                INSERT INTO search_entries(
                    scope_id, generation, search_key, object_key, size, modified_at, etag,
                    storage_class
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """
            ) { statement in
                for object in objects {
                    try Task.checkCancellation()
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(build.scope.id, to: 1, in: statement)
                    try bind(build.generation, to: 2, in: statement)
                    try bind(Self.folded(object.key), to: 3, in: statement)
                    try bind(object.key, to: 4, in: statement)
                    sqlite3_bind_int64(statement, 5, object.size)
                    try bind(object.lastModified, to: 6, in: statement)
                    try bind(object.eTag, to: 7, in: statement)
                    try bind(object.storageClass, to: 8, in: statement)
                    try stepDone(statement)
                }
            }
        }
    }

    public func finishRebuild(_ build: ObjectIndexBuild) throws -> ObjectIndexSnapshot {
        guard try buildExists(build) else { throw ObjectSearchIndexError.unavailable }
        let count = try entryCount(scopeID: build.scope.id, generation: build.generation)
        let indexedAt = Date()
        let isDirty = try buildIsDirty(build)
        try database.transaction {
            try database.withStatement(
                """
                UPDATE search_scopes
                SET active_generation = ?, indexed_at = ?, object_count = ?, is_stale = ?
                WHERE scope_id = ?
                """
            ) { statement in
                try bind(build.generation, to: 1, in: statement)
                sqlite3_bind_double(statement, 2, indexedAt.timeIntervalSince1970)
                sqlite3_bind_int64(statement, 3, Int64(count))
                sqlite3_bind_int(statement, 4, isDirty ? 1 : 0)
                try bind(build.scope.id, to: 5, in: statement)
                try stepDone(statement)
            }
            try database.withStatement(
                "DELETE FROM search_entries WHERE scope_id = ? AND generation <> ?"
            ) { statement in
                try bind(build.scope.id, to: 1, in: statement)
                try bind(build.generation, to: 2, in: statement)
                try stepDone(statement)
            }
            try deleteBuild(build)
        }
        return ObjectIndexSnapshot(objectCount: count, indexedAt: indexedAt, isStale: isDirty)
    }

    public func cancelRebuild(_ build: ObjectIndexBuild) throws {
        try database.transaction {
            try database.withStatement(
                "DELETE FROM search_entries WHERE scope_id = ? AND generation = ?"
            ) { statement in
                try bind(build.scope.id, to: 1, in: statement)
                try bind(build.generation, to: 2, in: statement)
                try stepDone(statement)
            }
            try deleteBuild(build)
        }
    }

    public func search(
        scope: ObjectIndexScope,
        matching query: String,
        below matchingPrefix: String,
        after continuationCursor: Int64? = nil,
        limit: Int = 1_000
    ) throws -> ObjectIndexPage? {
        guard (1...1_000).contains(limit) else {
            throw S3ServiceError.invalidConfiguration("Search page size must be between 1 and 1,000.")
        }
        guard let active = try activeSnapshot(for: scope) else { return nil }

        let foldedQuery = Self.folded(query)
        let ftsQuery = foldedQuery.unicodeScalars.count >= 3
            ? "\"\(foldedQuery.replacingOccurrences(of: "\"", with: "\"\""))\""
            : nil
        let batchSize = min(max(limit, 256), 1_000)
        var cursor = continuationCursor ?? 0
        var matches: [S3Object] = []

        while matches.count < limit {
            try Task.checkCancellation()
            let candidates = try candidates(
                scopeID: scope.id,
                generation: active.generation,
                ftsQuery: ftsQuery,
                after: cursor,
                limit: batchSize
            )
            guard !candidates.isEmpty else {
                return ObjectIndexPage(
                    objects: matches,
                    continuationCursor: nil,
                    snapshot: active.snapshot
                )
            }

            for candidate in candidates {
                cursor = candidate.rowID
                if Self.matches(
                    candidate.object.key,
                    below: matchingPrefix,
                    query: query
                ) {
                    matches.append(candidate.object)
                    if matches.count == limit {
                        return ObjectIndexPage(
                            objects: matches,
                            continuationCursor: cursor,
                            snapshot: active.snapshot
                        )
                    }
                }
            }
            if candidates.count < batchSize {
                return ObjectIndexPage(
                    objects: matches,
                    continuationCursor: nil,
                    snapshot: active.snapshot
                )
            }
        }

        return ObjectIndexPage(
            objects: matches,
            continuationCursor: cursor,
            snapshot: active.snapshot
        )
    }

    public func upsert(
        _ object: S3Object,
        connectionID: UUID,
        bucket: String
    ) throws {
        let scopes = try indexedScopes(connectionID: connectionID, bucket: bucket)
        try database.transaction {
            for scope in scopes where bytesStart(object.key, with: scope.prefix)
                && !bytesEqual(object.key, scope.prefix)
            {
                try deleteEntry(key: object.key, scopeID: scope.id, generation: scope.generation)
                try insert(object, scopeID: scope.id, generation: scope.generation)
                try updateCount(scopeID: scope.id, generation: scope.generation)
                try markBuildDirty(scopeID: scope.id)
            }
        }
    }

    public func removeObject(
        key: String,
        connectionID: UUID,
        bucket: String
    ) throws {
        let scopes = try indexedScopes(connectionID: connectionID, bucket: bucket)
        try database.transaction {
            for scope in scopes where bytesStart(key, with: scope.prefix) {
                try deleteEntry(key: key, scopeID: scope.id, generation: scope.generation)
                try updateCount(scopeID: scope.id, generation: scope.generation)
                try markBuildDirty(scopeID: scope.id)
            }
        }
    }

    public func remove(scope: ObjectIndexScope) throws {
        try database.transaction {
            try database.withStatement("DELETE FROM search_entries WHERE scope_id = ?") { statement in
                try bind(scope.id, to: 1, in: statement)
                try stepDone(statement)
            }
            try database.withStatement("DELETE FROM search_builds WHERE scope_id = ?") { statement in
                try bind(scope.id, to: 1, in: statement)
                try stepDone(statement)
            }
            try database.withStatement("DELETE FROM search_scopes WHERE scope_id = ?") { statement in
                try bind(scope.id, to: 1, in: statement)
                try stepDone(statement)
            }
        }
    }

    public func remove(connectionID: UUID) throws {
        let connectionID = connectionID.uuidString
        try database.transaction {
            try database.withStatement(
                """
                DELETE FROM search_entries
                WHERE scope_id IN (
                    SELECT scope_id FROM search_scopes WHERE connection_id = ?
                )
                """
            ) { statement in
                try bind(connectionID, to: 1, in: statement)
                try stepDone(statement)
            }
            try database.withStatement(
                """
                DELETE FROM search_builds
                WHERE scope_id IN (
                    SELECT scope_id FROM search_scopes WHERE connection_id = ?
                )
                """
            ) { statement in
                try bind(connectionID, to: 1, in: statement)
                try stepDone(statement)
            }
            try database.withStatement(
                "DELETE FROM search_scopes WHERE connection_id = ?"
            ) { statement in
                try bind(connectionID, to: 1, in: statement)
                try stepDone(statement)
            }
        }
    }

    private static func migrate(_ database: SQLiteConnection) throws {
        let version = try database.int32Value(sql: "PRAGMA user_version")
        guard version <= schemaVersion else { throw ObjectSearchIndexError.incompatibleSchema }
        guard version == 0 else { return }

        try database.transaction {
            try database.execute(
                """
                CREATE TABLE search_scopes (
                    scope_id TEXT PRIMARY KEY,
                    connection_id TEXT NOT NULL,
                    bucket BLOB NOT NULL,
                    root_prefix BLOB NOT NULL,
                    active_generation TEXT,
                    indexed_at REAL,
                    object_count INTEGER NOT NULL DEFAULT 0,
                    is_stale INTEGER NOT NULL DEFAULT 0
                )
                """
            )
            try database.execute(
                """
                CREATE TABLE search_builds (
                    scope_id TEXT PRIMARY KEY REFERENCES search_scopes(scope_id) ON DELETE CASCADE,
                    generation TEXT NOT NULL UNIQUE,
                    started_at REAL NOT NULL,
                    is_dirty INTEGER NOT NULL DEFAULT 0
                )
                """
            )
            try database.execute(
                """
                CREATE VIRTUAL TABLE search_entries USING fts5(
                    scope_id UNINDEXED,
                    generation UNINDEXED,
                    search_key,
                    object_key UNINDEXED,
                    size UNINDEXED,
                    modified_at UNINDEXED,
                    etag UNINDEXED,
                    storage_class UNINDEXED,
                    tokenize='trigram'
                )
                """
            )
            try database.execute("PRAGMA user_version = \(schemaVersion)")
        }
    }

    private static func discardInterruptedBuilds(_ database: SQLiteConnection) throws {
        try database.transaction {
            try database.execute(
                """
                DELETE FROM search_entries
                WHERE generation IN (SELECT generation FROM search_builds)
                """
            )
            try database.execute("DELETE FROM search_builds")
        }
    }

    private func ensureScope(_ scope: ObjectIndexScope) throws {
        try database.withStatement(
            """
            INSERT INTO search_scopes(scope_id, connection_id, bucket, root_prefix)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(scope_id) DO UPDATE SET
                connection_id = excluded.connection_id,
                bucket = excluded.bucket,
                root_prefix = excluded.root_prefix
            """
        ) { statement in
            try bind(scope.id, to: 1, in: statement)
            try bind(scope.connectionID.uuidString, to: 2, in: statement)
            try bind(Data(scope.bucket.utf8), to: 3, in: statement)
            try bind(Data(scope.prefix.utf8), to: 4, in: statement)
            try stepDone(statement)
        }
    }

    private func activeSnapshot(for scope: ObjectIndexScope) throws -> ActiveSnapshot? {
        try database.withStatement(
            """
            SELECT active_generation, indexed_at, object_count, is_stale
            FROM search_scopes
            WHERE scope_id = ? AND active_generation IS NOT NULL
            """
        ) { statement in
            try bind(scope.id, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW,
                let generation = text(statement, column: 0)
            else { return nil }
            return ActiveSnapshot(
                generation: generation,
                snapshot: ObjectIndexSnapshot(
                    objectCount: Int(sqlite3_column_int64(statement, 2)),
                    indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    isStale: sqlite3_column_int(statement, 3) != 0
                )
            )
        }
    }

    private func candidates(
        scopeID: String,
        generation: String,
        ftsQuery: String?,
        after cursor: Int64,
        limit: Int
    ) throws -> [Candidate] {
        let sql: String
        if ftsQuery == nil {
            sql =
                """
                SELECT rowid, object_key, size, modified_at, etag, storage_class
                FROM search_entries
                WHERE scope_id = ? AND generation = ? AND rowid > ?
                ORDER BY rowid
                LIMIT ?
                """
        } else {
            sql =
                """
                SELECT rowid, object_key, size, modified_at, etag, storage_class
                FROM search_entries
                WHERE search_entries MATCH ? AND scope_id = ? AND generation = ? AND rowid > ?
                ORDER BY rowid
                LIMIT ?
                """
        }

        return try database.withStatement(sql) { statement in
            var parameter: Int32 = 1
            if let ftsQuery {
                try bind(ftsQuery, to: parameter, in: statement)
                parameter += 1
            }
            try bind(scopeID, to: parameter, in: statement)
            try bind(generation, to: parameter + 1, in: statement)
            sqlite3_bind_int64(statement, parameter + 2, cursor)
            sqlite3_bind_int(statement, parameter + 3, Int32(limit))

            var rows: [Candidate] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let key = text(statement, column: 1) else {
                    throw ObjectSearchIndexError.unavailable
                }
                rows.append(
                    Candidate(
                        rowID: sqlite3_column_int64(statement, 0),
                        object: S3Object(
                            key: key,
                            size: sqlite3_column_int64(statement, 2),
                            lastModified: optionalDate(statement, column: 3),
                            eTag: text(statement, column: 4),
                            storageClass: text(statement, column: 5)
                        )
                    )
                )
            }
            return rows
        }
    }

    private func indexedScopes(connectionID: UUID, bucket: String) throws -> [IndexedScope] {
        try database.withStatement(
            """
            SELECT scope_id, active_generation, root_prefix
            FROM search_scopes
            WHERE connection_id = ? AND bucket = ? AND active_generation IS NOT NULL
            """
        ) { statement in
            try bind(connectionID.uuidString, to: 1, in: statement)
            try bind(Data(bucket.utf8), to: 2, in: statement)
            var scopes: [IndexedScope] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = text(statement, column: 0),
                    let generation = text(statement, column: 1),
                    let prefixData = data(statement, column: 2)
                else { throw ObjectSearchIndexError.unavailable }
                scopes.append(
                    IndexedScope(
                        id: id,
                        generation: generation,
                        prefix: String(decoding: prefixData, as: UTF8.self)
                    )
                )
            }
            return scopes
        }
    }

    private func insert(_ object: S3Object, scopeID: String, generation: String) throws {
        try database.withStatement(
            """
            INSERT INTO search_entries(
                scope_id, generation, search_key, object_key, size, modified_at, etag,
                storage_class
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            try bind(scopeID, to: 1, in: statement)
            try bind(generation, to: 2, in: statement)
            try bind(Self.folded(object.key), to: 3, in: statement)
            try bind(object.key, to: 4, in: statement)
            sqlite3_bind_int64(statement, 5, object.size)
            try bind(object.lastModified, to: 6, in: statement)
            try bind(object.eTag, to: 7, in: statement)
            try bind(object.storageClass, to: 8, in: statement)
            try stepDone(statement)
        }
    }

    private func deleteEntry(key: String, scopeID: String, generation: String) throws {
        try database.withStatement(
            "DELETE FROM search_entries WHERE scope_id = ? AND generation = ? AND object_key = ?"
        ) { statement in
            try bind(scopeID, to: 1, in: statement)
            try bind(generation, to: 2, in: statement)
            try bind(key, to: 3, in: statement)
            try stepDone(statement)
        }
    }

    private func updateCount(scopeID: String, generation: String) throws {
        let count = try entryCount(scopeID: scopeID, generation: generation)
        try database.withStatement(
            "UPDATE search_scopes SET object_count = ?, indexed_at = ? WHERE scope_id = ?"
        ) { statement in
            sqlite3_bind_int64(statement, 1, Int64(count))
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            try bind(scopeID, to: 3, in: statement)
            try stepDone(statement)
        }
    }

    private func markBuildDirty(scopeID: String) throws {
        try database.withStatement(
            "UPDATE search_builds SET is_dirty = 1 WHERE scope_id = ?"
        ) { statement in
            try bind(scopeID, to: 1, in: statement)
            try stepDone(statement)
        }
    }

    private func entryCount(scopeID: String, generation: String) throws -> Int {
        try database.withStatement(
            "SELECT count(*) FROM search_entries WHERE scope_id = ? AND generation = ?"
        ) { statement in
            try bind(scopeID, to: 1, in: statement)
            try bind(generation, to: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw ObjectSearchIndexError.unavailable
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func buildExists(_ build: ObjectIndexBuild) throws -> Bool {
        try database.withStatement(
            "SELECT 1 FROM search_builds WHERE scope_id = ? AND generation = ?"
        ) { statement in
            try bind(build.scope.id, to: 1, in: statement)
            try bind(build.generation, to: 2, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    private func buildIsDirty(_ build: ObjectIndexBuild) throws -> Bool {
        try database.withStatement(
            "SELECT is_dirty FROM search_builds WHERE scope_id = ? AND generation = ?"
        ) { statement in
            try bind(build.scope.id, to: 1, in: statement)
            try bind(build.generation, to: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw ObjectSearchIndexError.unavailable
            }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    private func deleteBuild(_ build: ObjectIndexBuild) throws {
        try database.withStatement(
            "DELETE FROM search_builds WHERE scope_id = ? AND generation = ?"
        ) { statement in
            try bind(build.scope.id, to: 1, in: statement)
            try bind(build.generation, to: 2, in: statement)
            try stepDone(statement)
        }
    }

    private func discardBuilds(for scopeID: String) throws {
        try database.withStatement(
            """
            DELETE FROM search_entries
            WHERE scope_id = ?
                AND generation IN (
                    SELECT generation FROM search_builds WHERE scope_id = ?
                )
            """
        ) { statement in
            try bind(scopeID, to: 1, in: statement)
            try bind(scopeID, to: 2, in: statement)
            try stepDone(statement)
        }
        try database.withStatement("DELETE FROM search_builds WHERE scope_id = ?") { statement in
            try bind(scopeID, to: 1, in: statement)
            try stepDone(statement)
        }
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive], locale: nil)
    }

    private static func matches(_ key: String, below prefix: String, query: String) -> Bool {
        guard bytesStart(key, with: prefix) else { return false }
        guard !query.isEmpty else { return true }
        let bytes = key.utf8.dropFirst(prefix.utf8.count)
        return String(decoding: bytes, as: UTF8.self)
            .range(of: query, options: .caseInsensitive) != nil
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close_v2(database) }
            throw ObjectSearchIndexError.unavailable
        }
        handle = database
        sqlite3_busy_timeout(database, 5_000)
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = DELETE")
            try execute("PRAGMA synchronous = NORMAL")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            sqlite3_close_v2(database)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func execute(_ sql: String) throws {
        guard let handle, sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw ObjectSearchIndexError.unavailable
        }
    }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func withStatement<T>(
        _ sql: String,
        _ operation: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let handle else { throw ObjectSearchIndexError.unavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw ObjectSearchIndexError.unavailable }
        defer { sqlite3_finalize(statement) }
        return try operation(statement)
    }

    func int32Value(sql: String) throws -> Int32 {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw ObjectSearchIndexError.unavailable
            }
            return sqlite3_column_int(statement, 0)
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
    let result = value.withCString {
        sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), sqliteTransient)
    }
    guard result == SQLITE_OK else { throw ObjectSearchIndexError.unavailable }
}

private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) throws {
    guard let value else {
        guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
            throw ObjectSearchIndexError.unavailable
        }
        return
    }
    try bind(value, to: index, in: statement)
}

private func bind(_ value: Date?, to index: Int32, in statement: OpaquePointer) throws {
    guard let value else {
        guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
            throw ObjectSearchIndexError.unavailable
        }
        return
    }
    guard sqlite3_bind_double(statement, index, value.timeIntervalSince1970) == SQLITE_OK else {
        throw ObjectSearchIndexError.unavailable
    }
}

private func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) throws {
    let result: Int32
    if value.isEmpty {
        result = sqlite3_bind_zeroblob(statement, index, 0)
    } else {
        result = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient)
        }
    }
    guard result == SQLITE_OK else { throw ObjectSearchIndexError.unavailable }
}

private func stepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw ObjectSearchIndexError.unavailable
    }
}

private func text(_ statement: OpaquePointer, column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
        let pointer = sqlite3_column_text(statement, column)
    else { return nil }
    let count = Int(sqlite3_column_bytes(statement, column))
    let bytes = UnsafeRawBufferPointer(start: pointer, count: count)
    return String(decoding: bytes, as: UTF8.self)
}

private func data(_ statement: OpaquePointer, column: Int32) -> Data? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: pointer, count: count)
}

private func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
}

private func bytesEqual(_ value: String, _ expected: String) -> Bool {
    value.utf8.elementsEqual(expected.utf8)
}

private func bytesStart(_ value: String, with prefix: String) -> Bool {
    value.utf8.starts(with: prefix.utf8)
}
