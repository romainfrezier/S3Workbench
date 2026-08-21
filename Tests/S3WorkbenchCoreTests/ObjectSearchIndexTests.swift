import Foundation
import SQLite3
import Testing
@testable import S3WorkbenchCore

@Test func objectSearchIndexPersistsExactScopedKeys() async throws {
    let fixture = try SearchIndexFixture()
    defer { fixture.cleanup() }
    let scope = fixture.scope
    let index = try ObjectSearchIndex(fileURL: fixture.databaseURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.databaseURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let build = try await index.beginRebuild(for: scope)
    try await index.append(
        [
            indexedObject("restricted/Parent//雪 #?/Needle.TXT", size: 42),
            indexedObject("restricted/folder/ünicode-report.pdf", size: 7),
            indexedObject("restricted/unrelated.json", size: 3),
            indexedObject("restricted/", size: 0),
            indexedObject("elsewhere/needle.txt", size: 1),
        ],
        to: build
    )

    let snapshot = try await index.finishRebuild(build)

    #expect(snapshot.objectCount == 3)
    let global = try #require(
        try await index.search(
            scope: scope,
            matching: "nEeDlE",
            below: "restricted/"
        )
    )
    #expect(global.objects.map(\.key) == ["restricted/Parent//雪 #?/Needle.TXT"])
    let pathQualified = try #require(
        try await index.search(
            scope: scope,
            matching: "needle",
            below: "restricted/Parent//雪 #?/"
        )
    )
    #expect(pathQualified.objects.map(\.key) == global.objects.map(\.key))

    let reopened = try ObjectSearchIndex(fileURL: fixture.databaseURL)
    let reopenedSnapshot = try #require(try await reopened.snapshot(for: scope))
    #expect(reopenedSnapshot.objectCount == snapshot.objectCount)
    #expect(reopenedSnapshot.isStale == snapshot.isStale)
    #expect(abs(reopenedSnapshot.indexedAt.timeIntervalSince(snapshot.indexedAt)) < 0.001)
    let reopenedPage = try #require(
        try await reopened.search(
            scope: scope,
            matching: "ÜNICODE",
            below: "restricted/"
        )
    )
    #expect(reopenedPage.objects.map(\.key) == ["restricted/folder/ünicode-report.pdf"])
}

@Test func objectSearchIndexActivatesRebuildsAtomically() async throws {
    let fixture = try SearchIndexFixture()
    defer { fixture.cleanup() }
    let index = try ObjectSearchIndex(fileURL: fixture.databaseURL)

    let first = try await index.beginRebuild(for: fixture.scope)
    try await index.append([indexedObject("restricted/old.txt")], to: first)
    let firstSnapshot = try await index.finishRebuild(first)

    let cancelled = try await index.beginRebuild(for: fixture.scope)
    try await index.append([indexedObject("restricted/cancelled.txt")], to: cancelled)
    let whileBuilding = try #require(
        try await index.search(
            scope: fixture.scope,
            matching: ".txt",
            below: "restricted/"
        )
    )
    #expect(whileBuilding.objects.map(\.key) == ["restricted/old.txt"])
    #expect(whileBuilding.snapshot.objectCount == firstSnapshot.objectCount)
    #expect(whileBuilding.snapshot.isStale == firstSnapshot.isStale)
    #expect(
        abs(whileBuilding.snapshot.indexedAt.timeIntervalSince(firstSnapshot.indexedAt)) < 0.001
    )
    try await index.cancelRebuild(cancelled)

    let replacement = try await index.beginRebuild(for: fixture.scope)
    try await index.append([indexedObject("restricted/new.txt")], to: replacement)
    let replacementSnapshot = try await index.finishRebuild(replacement)
    let afterCommit = try #require(
        try await index.search(
            scope: fixture.scope,
            matching: ".txt",
            below: "restricted/"
        )
    )

    #expect(afterCommit.objects.map(\.key) == ["restricted/new.txt"])
    #expect(replacementSnapshot.objectCount == 1)
    #expect(replacementSnapshot.indexedAt >= firstSnapshot.indexedAt)
}

@Test func objectSearchIndexPaginatesAndTracksLocalMutations() async throws {
    let fixture = try SearchIndexFixture()
    defer { fixture.cleanup() }
    let index = try ObjectSearchIndex(fileURL: fixture.databaseURL)
    let build = try await index.beginRebuild(for: fixture.scope)
    let objects = (0..<1_205).map {
        indexedObject("restricted/items/match-\(String(format: "%04d", $0)).json")
    }
    for pageStart in stride(from: 0, to: objects.count, by: 1_000) {
        let pageEnd = min(pageStart + 1_000, objects.count)
        try await index.append(Array(objects[pageStart..<pageEnd]), to: build)
    }
    _ = try await index.finishRebuild(build)

    var cursor: Int64?
    var seenCursors = Set<Int64>()
    var results: [S3Object] = []
    repeat {
        let page = try #require(
            try await index.search(
                scope: fixture.scope,
                matching: "match",
                below: "restricted/",
                after: cursor,
                limit: 100
            )
        )
        results.append(contentsOf: page.objects)
        cursor = page.continuationCursor
        if let cursor { #expect(seenCursors.insert(cursor).inserted) }
    } while cursor != nil

    #expect(results.count == 1_205)
    try await index.removeObject(
        key: objects[0].key,
        connectionID: fixture.scope.connectionID,
        bucket: fixture.scope.bucket
    )
    let added = indexedObject("restricted/items/new-match.json", size: 99)
    try await index.upsert(
        added,
        connectionID: fixture.scope.connectionID,
        bucket: fixture.scope.bucket
    )
    let mutatedSnapshot = try #require(try await index.snapshot(for: fixture.scope))
    #expect(mutatedSnapshot.objectCount == 1_205)
    let addedResult = try #require(
        try await index.search(
            scope: fixture.scope,
            matching: "new-match",
            below: "restricted/"
        )
    )
    #expect(addedResult.objects == [added])

    try await index.remove(connectionID: fixture.scope.connectionID)
    #expect(try await index.snapshot(for: fixture.scope) == nil)
}

@Test func objectSearchIndexSummarizesAndClearsOnlyOneConnection() async throws {
    let fixture = try SearchIndexFixture()
    defer { fixture.cleanup() }
    let index = try ObjectSearchIndex(fileURL: fixture.databaseURL)
    let secondConnectionID = UUID()
    let secondScope = ObjectIndexScope(
        connectionID: secondConnectionID,
        bucket: "other-bucket",
        prefix: ""
    )

    let firstBuild = try await index.beginRebuild(for: fixture.scope)
    try await index.append(
        [indexedObject("restricted/one.txt"), indexedObject("restricted/two.txt")],
        to: firstBuild
    )
    _ = try await index.finishRebuild(firstBuild)
    let secondBuild = try await index.beginRebuild(for: secondScope)
    try await index.append([indexedObject("kept.txt")], to: secondBuild)
    _ = try await index.finishRebuild(secondBuild)

    let summaries = try await index.connectionSummaries()
    #expect(summaries.count == 2)
    #expect(
        summaries.first(where: { $0.connectionID == fixture.scope.connectionID })?.objectCount == 2
    )
    #expect(summaries.first(where: { $0.connectionID == secondConnectionID })?.objectCount == 1)

    try await index.remove(connectionID: fixture.scope.connectionID)

    #expect(try await index.snapshot(for: fixture.scope) == nil)
    #expect(try await index.snapshot(for: secondScope)?.objectCount == 1)
    #expect(try await index.connectionSummaries().map(\.connectionID) == [secondConnectionID])
}

@Test func objectSearchIndexDiscardsOnlyInterruptedGenerationOnReopen() async throws {
    let fixture = try SearchIndexFixture()
    defer { fixture.cleanup() }
    let index = try ObjectSearchIndex(fileURL: fixture.databaseURL)
    let complete = try await index.beginRebuild(for: fixture.scope)
    try await index.append([indexedObject("restricted/complete.txt")], to: complete)
    let snapshot = try await index.finishRebuild(complete)
    let interrupted = try await index.beginRebuild(for: fixture.scope)
    try await index.append([indexedObject("restricted/partial.txt")], to: interrupted)

    let reopened = try ObjectSearchIndex(fileURL: fixture.databaseURL)
    let reopenedSnapshot = try #require(try await reopened.snapshot(for: fixture.scope))
    #expect(reopenedSnapshot.objectCount == snapshot.objectCount)
    #expect(reopenedSnapshot.isStale == snapshot.isStale)
    #expect(abs(reopenedSnapshot.indexedAt.timeIntervalSince(snapshot.indexedAt)) < 0.001)
    let page = try #require(
        try await reopened.search(
            scope: fixture.scope,
            matching: ".txt",
            below: "restricted/"
        )
    )
    #expect(page.objects.map(\.key) == ["restricted/complete.txt"])
}

@Test func objectSearchIndexMarksAnInitialBuildStaleWhenObjectsMutateDuringItsScan() async throws {
    let fixture = try SearchIndexFixture()
    defer { fixture.cleanup() }
    let index = try ObjectSearchIndex(fileURL: fixture.databaseURL)
    let build = try await index.beginRebuild(for: fixture.scope)
    try await index.append([indexedObject("restricted/listed.txt")], to: build)

    try await index.upsert(
        indexedObject("restricted/uploaded-after-page.txt"),
        connectionID: fixture.scope.connectionID,
        bucket: fixture.scope.bucket
    )
    let snapshot = try await index.finishRebuild(build)

    #expect(snapshot.objectCount == 1)
    #expect(snapshot.isStale)
}

@Test func objectSearchIndexRejectsNewerSchemaWithoutRewritingIt() throws {
    let fixture = try SearchIndexFixture()
    defer { fixture.cleanup() }
    var database: OpaquePointer?
    #expect(sqlite3_open(fixture.databaseURL.path, &database) == SQLITE_OK)
    #expect(sqlite3_exec(database, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(database)

    #expect(throws: ObjectSearchIndexError.incompatibleSchema) {
        _ = try ObjectSearchIndex(fileURL: fixture.databaseURL)
    }
    var reopened: OpaquePointer?
    #expect(sqlite3_open(fixture.databaseURL.path, &reopened) == SQLITE_OK)
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(reopened, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 99)
    sqlite3_finalize(statement)
    sqlite3_close_v2(reopened)
}

private struct SearchIndexFixture {
    let directory: URL
    let databaseURL: URL
    let scope: ObjectIndexScope

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("S3Workbench-SearchIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("search-index.sqlite3")
        scope = ObjectIndexScope(
            connectionID: UUID(),
            bucket: "bucket",
            prefix: "restricted/"
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func indexedObject(_ key: String, size: Int64 = 1) -> S3Object {
    S3Object(
        key: key,
        size: size,
        lastModified: Date(timeIntervalSince1970: 1_700_000_000),
        eTag: "fixture-etag",
        storageClass: "STANDARD"
    )
}
