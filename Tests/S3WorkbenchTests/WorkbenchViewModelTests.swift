import Foundation
import S3WorkbenchCore
import Testing
@testable import S3Workbench

@MainActor
@Test func directAccessRootBypassesBucketListing() async throws {
  let connection = ConnectionRow(
    id: UUID(),
    name: "Restricted",
    endpoint: try #require(URL(string: "https://storage.example.com")),
    accessPath: "/tickets/incoming",
    colorHex: "#0A84FF",
    region: "us-east-1",
    addressingMode: .pathStyle,
    tlsPolicy: .system,
    customCAURL: nil
  )
  let service = StubWorkbenchService(connections: [connection], listObjectsResult: .success(.empty))
  let model = WorkbenchViewModel(service: service)

  await model.start()
  await model.reloadConnection()

  #expect(model.selectedBucket == "tickets")
  #expect(model.prefix == "incoming/")
  #expect(await service.bucketListCallCount == 0)
  #expect(await service.lastObjectLocation?.bucket == "tickets")
  #expect(await service.lastObjectLocation?.prefix == "incoming/")
}

@MainActor
@Test func objectLoadingFailureIsNotPresentedAsAnEmptyPrefix() async throws {
  let connectionID = UUID()
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .failure(S3ServiceError.accessDenied)
  )
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = connectionID
  model.selectedBucket = "private"

  await model.reloadObjects()

  #expect(model.objects.isEmpty)
  #expect(model.objectErrorMessage == S3ServiceError.accessDenied.localizedDescription)
  #expect(!model.isLoadingObjects)
}

@MainActor
@Test func failedObjectRefreshKeepsPreviouslyLoadedRows() async throws {
  let object = ObjectRow(
    id: "object:report.txt", key: "report.txt", displayName: "report.txt", relativePath: "",
    size: 12,
    modifiedAt: nil, storageClass: nil, isPrefix: false)
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(ObjectPage(objects: [object], continuationToken: nil))
  )
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "private"
  await model.reloadObjects()
  await service.setListObjectsResult(.failure(S3ServiceError.networkUnavailable))

  await model.reloadObjects()

  #expect(model.objects == [object])
  #expect(model.objectErrorMessage == S3ServiceError.networkUnavailable.localizedDescription)
}

@Test func recursiveSearchMatchesTheCompleteRelativeKeyWithoutNormalizingIt() throws {
  let object = S3Object(
    key: "restricted/Parent Folder/ünicode-雪 #?.TXT",
    size: 42,
    lastModified: nil,
    eTag: nil,
    storageClass: "STANDARD"
  )

  for query in ["parent folder", "ÜNICODE", "雪 #?", ".txt"] {
    #expect(
      CoreWorkbenchService.recursiveSearchRow(
        object, below: "restricted/", matching: query) != nil)
  }
  let row = try #require(
    CoreWorkbenchService.recursiveSearchRow(
      object, below: "restricted/", matching: "parent folder"))
  #expect(row.displayName == "ünicode-雪 #?.TXT")
  #expect(row.relativePath == "Parent Folder/")
  #expect(row.key == object.key)
  #expect(
    CoreWorkbenchService.recursiveSearchRow(
      object, below: "restricted/", matching: "missing") == nil)
  #expect(
    CoreWorkbenchService.recursiveSearchRow(
      object, below: "elsewhere/", matching: "parent") == nil)
}

@MainActor
@Test func recursiveSearchFollowsEveryPageWithinTheCurrentAccessRoot() async throws {
  let connectionID = UUID()
  let first = searchObject(id: "first", key: "restricted/a/needle.txt", path: "a/")
  let second = searchObject(id: "second", key: "restricted/b/Needle.json", path: "b/")
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty)
  ) { _, _, token in
    switch token {
    case nil:
      ObjectSearchPage(objects: [first], scannedObjectCount: 1_000, continuationToken: "next")
    case "next":
      ObjectSearchPage(objects: [second], scannedObjectCount: 7, continuationToken: nil)
    default:
      throw S3ServiceError.service("Unexpected continuation token.")
    }
  }
  let model = WorkbenchViewModel(service: service)
  model.connections = [restrictedConnection(id: connectionID)]
  model.selectedConnectionID = connectionID
  model.selectedBucket = "bucket"
  model.prefix = "restricted/"
  model.searchQuery = "needle"

  await model.startSearch()

  let calls = await service.searchCalls
  #expect(calls.map(\.continuationToken) == [nil, "next"])
  #expect(calls.allSatisfy { $0.location.prefix == "restricted/" })
  #expect(model.objects.map(\.id) == ["first", "second"])
  #expect(model.searchScannedObjectCount == 1_007)
  #expect(model.searchMatchCount == 2)
  #expect(!model.isSearching)
}

@MainActor
@Test func cancellingSearchRejectsAPageThatFinishesLate() async {
  let first = searchObject(id: "first", key: "restricted/first.txt")
  let late = searchObject(id: "late", key: "restricted/late.txt")
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty)
  ) { _, _, token in
    if token == nil {
      return ObjectSearchPage(
        objects: [first], scannedObjectCount: 1_000, continuationToken: "next")
    }
    try? await Task.sleep(for: .seconds(5))
    return ObjectSearchPage(objects: [late], scannedObjectCount: 1, continuationToken: nil)
  }
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "bucket"
  model.prefix = "restricted/"
  model.searchQuery = "late"

  let task = Task { await model.startSearch() }
  let started = await waitForSearchCall(service, count: 2)
  #expect(started)
  #expect(model.objects.map(\.id) == ["first"])
  #expect(model.searchScannedObjectCount == 1_000)
  #expect(model.isSearching)
  model.cancelSearch()
  await task.value

  #expect(model.objects.map(\.id) == ["first"])
  #expect(model.searchScannedObjectCount == 1_000)
  #expect(model.searchWasCancelled)
  #expect(!model.isSearching)
}

@MainActor
@Test func staleSearchPageCannotChangeANewPrefix() async {
  let stale = searchObject(id: "stale", key: "restricted/stale.txt")
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty)
  ) { _, _, _ in
    try? await Task.sleep(for: .milliseconds(50))
    return ObjectSearchPage(objects: [stale], scannedObjectCount: 1, continuationToken: nil)
  }
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "bucket"
  model.prefix = "restricted/"
  model.searchQuery = "stale"

  let task = Task { await model.startSearch() }
  let started = await waitForSearchCall(service)
  #expect(started)
  model.prefix = "restricted/new-prefix/"
  await task.value

  #expect(model.objects.isEmpty)
  #expect(model.searchScannedObjectCount == 0)
}

@MainActor
@Test func latePageFromAnOldSearchCannotReplaceNewSearchResults() async {
  let stale = searchObject(id: "stale", key: "stale.txt")
  let current = searchObject(id: "current", key: "current.txt")
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty)
  ) { _, query, _ in
    if query == "old" {
      try? await Task.sleep(for: .milliseconds(50))
      return ObjectSearchPage(objects: [stale], scannedObjectCount: 1, continuationToken: nil)
    }
    return ObjectSearchPage(objects: [current], scannedObjectCount: 1, continuationToken: nil)
  }
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "bucket"
  model.searchQuery = "old"

  let oldSearch = Task { await model.startSearch() }
  let started = await waitForSearchCall(service)
  #expect(started)
  model.searchQuery = "new"
  await model.startSearch()
  await oldSearch.value

  #expect(model.activeSearchQuery == "new")
  #expect(model.objects.map(\.id) == ["current"])
  #expect(model.searchScannedObjectCount == 1)
}

@MainActor
@Test func emptyQueryExitsSearchAndRestoresNormalBrowsing() async {
  let match = searchObject(id: "match", key: "nested/match.txt")
  let normal = ObjectRow(
    id: "prefix:nested/", key: "nested/", displayName: "nested", relativePath: "",
    size: 0, modifiedAt: nil, storageClass: nil, isPrefix: true)
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(ObjectPage(objects: [normal], continuationToken: nil))
  ) { _, _, _ in
    ObjectSearchPage(objects: [match], scannedObjectCount: 1, continuationToken: nil)
  }
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "bucket"
  model.searchQuery = "match"
  await model.startSearch()

  model.searchQuery = ""
  await model.searchQueryDidChange()

  #expect(!model.isSearchMode)
  #expect(model.objects == [normal])
  #expect(model.searchScannedObjectCount == 0)
}

@MainActor
@Test func repeatedSearchContinuationTokenStopsTheScan() async {
  let first = searchObject(id: "first", key: "first.txt")
  let duplicate = searchObject(id: "duplicate", key: "duplicate.txt")
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty)
  ) { _, _, token in
    ObjectSearchPage(
      objects: token == nil ? [first] : [duplicate],
      scannedObjectCount: 1,
      continuationToken: "repeated"
    )
  }
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "bucket"
  model.searchQuery = "txt"

  await model.startSearch()

  #expect(model.objects.map(\.id) == ["first"])
  #expect(model.searchScannedObjectCount == 1)
  #expect(model.searchErrorMessage == "The server returned a repeated object pagination token.")
  #expect(!model.isSearching)
}

@MainActor
@Test func retrySearchResumesAfterTheLastPublishedPage() async {
  let first = searchObject(id: "first", key: "first.txt")
  let second = searchObject(id: "second", key: "second.txt")
  let probe = SearchRetryProbe(first: first, second: second)
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty)
  ) { _, _, token in
    try await probe.page(continuationToken: token)
  }
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "bucket"
  model.searchQuery = "txt"

  await model.startSearch()

  #expect(model.objects.map(\.id) == ["first"])
  #expect(model.searchScannedObjectCount == 1_000)
  #expect(model.searchErrorMessage == S3ServiceError.networkUnavailable.localizedDescription)

  await model.retrySearch()

  #expect((await service.searchCalls).map(\.continuationToken) == [nil, "next", "next"])
  #expect(model.objects.map(\.id) == ["first", "second"])
  #expect(model.searchScannedObjectCount == 1_001)
  #expect(model.searchErrorMessage == nil)
  #expect(!model.isSearching)
}

@MainActor
@Test func revealSearchResultReturnsToItsParentAndRestoresSelection() async {
  let connectionID = UUID()
  let result = searchObject(
    id: "object:restricted/folder/needle.txt",
    key: "restricted/folder/needle.txt",
    path: "folder/"
  )
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(ObjectPage(objects: [result], continuationToken: nil))
  ) { _, _, _ in
    ObjectSearchPage(objects: [result], scannedObjectCount: 1, continuationToken: nil)
  }
  let model = WorkbenchViewModel(service: service)
  model.connections = [restrictedConnection(id: connectionID)]
  model.selectedConnectionID = connectionID
  model.selectedBucket = "bucket"
  model.prefix = "restricted/"
  model.history = ["restricted/"]
  model.searchQuery = "needle"
  await model.startSearch()
  model.select(result)

  await model.revealSelectedInPrefix()

  #expect(model.prefix == "restricted/folder/")
  #expect(model.searchQuery.isEmpty)
  #expect(!model.isSearchMode)
  #expect(model.selectedObjectIDs == [result.id])
}

@Test func objectColumnsSortPredictablyInBothDirections() {
  let prefix = ObjectRow(
    id: "prefix", key: "folder/", displayName: "Folder", relativePath: "", size: 0,
    modifiedAt: nil, storageClass: nil, isPrefix: true)
  let alpha = ObjectRow(
    id: "alpha", key: "alpha.txt", displayName: "Alpha", relativePath: "", size: 10,
    modifiedAt: Date(timeIntervalSince1970: 200), storageClass: "STANDARD", isPrefix: false)
  let beta = ObjectRow(
    id: "beta", key: "beta.txt", displayName: "Beta", relativePath: "", size: 20,
    modifiedAt: Date(timeIntervalSince1970: 100), storageClass: "GLACIER", isPrefix: false)
  let missing = ObjectRow(
    id: "missing", key: "missing.txt", displayName: "Missing", relativePath: "", size: 15,
    modifiedAt: nil, storageClass: nil, isPrefix: false)
  let objects = [missing, beta, prefix, alpha]
  let cases: [(ObjectSortComparator.Column, [String], [String])] = [
    (.name, ["prefix", "alpha", "beta", "missing"], ["prefix", "missing", "beta", "alpha"]),
    (.size, ["prefix", "alpha", "missing", "beta"], ["prefix", "beta", "missing", "alpha"]),
    (.modified, ["prefix", "beta", "alpha", "missing"], ["prefix", "alpha", "beta", "missing"]),
    (.storageClass, ["prefix", "beta", "alpha", "missing"], ["prefix", "alpha", "beta", "missing"]),
  ]

  for (column, ascendingIDs, descendingIDs) in cases {
    let ascending = objects.sorted(using: [ObjectSortComparator(column: column)])
    let descending = objects.sorted(
      using: [ObjectSortComparator(column: column, order: .reverse)])

    #expect(ascending.map(\.id) == ascendingIDs)
    #expect(descending.map(\.id) == descendingIDs)
  }
}

@Test func transferManagerEnforcesItsConcurrencyLimit() async throws {
  let manager = TransferManager<Int>(maximumConcurrentTransfers: 2)
  let probe = ConcurrencyProbe()
  var ids: [UUID] = []
  for value in 0..<6 {
    ids.append(
      await manager.enqueue(value, title: "\(value)", subtitle: "Test") { _, progress in
        await probe.run()
        progress(1)
      })
  }

  try await manager.waitForCompletion(of: ids)

  #expect(await probe.maximum == 2)
  #expect(await manager.rows().allSatisfy { $0.state == .completed })
}

private struct SearchCall: Equatable, Sendable {
  let location: ObjectLocation
  let query: String
  let continuationToken: String?
}

private typealias SearchHandler = @Sendable (
  ObjectLocation, String, String?
) async throws -> ObjectSearchPage

private actor StubWorkbenchService: WorkbenchServing {
  let connections: [ConnectionRow]
  private var listObjectsResult: Result<ObjectPage, Error>
  private let searchHandler: SearchHandler?
  private(set) var bucketListCallCount = 0
  private(set) var lastObjectLocation: ObjectLocation?
  private(set) var searchCalls: [SearchCall] = []

  init(
    connections: [ConnectionRow],
    listObjectsResult: Result<ObjectPage, Error>,
    searchHandler: SearchHandler? = nil
  ) {
    self.connections = connections
    self.listObjectsResult = listObjectsResult
    self.searchHandler = searchHandler
  }

  func loadConnections() async throws -> [ConnectionRow] { connections }
  func setListObjectsResult(_ result: Result<ObjectPage, Error>) {
    listObjectsResult = result
  }
  func saveConnection(_ draft: ConnectionDraft) async throws -> ConnectionRow {
    throw S3ServiceError.unsupported("Not used by this test.")
  }
  func duplicateConnection(id: UUID) async throws -> ConnectionRow {
    throw S3ServiceError.unsupported("Not used by this test.")
  }
  func removeConnection(id: UUID) async throws {}
  func testConnection(_ draft: ConnectionDraft) async throws {}
  func listBuckets(connectionID: UUID) async throws -> [BucketRow] {
    bucketListCallCount += 1
    return []
  }
  func listObjects(at location: ObjectLocation, continuationToken: String?) async throws
    -> ObjectPage
  {
    lastObjectLocation = location
    return try listObjectsResult.get()
  }
  func searchObjects(
    at location: ObjectLocation, query: String, continuationToken: String?
  ) async throws -> ObjectSearchPage {
    searchCalls.append(
      SearchCall(location: location, query: query, continuationToken: continuationToken))
    guard let searchHandler else {
      throw S3ServiceError.unsupported("Not used by this test.")
    }
    return try await searchHandler(location, query, continuationToken)
  }
  func objectDetails(at location: ObjectLocation, object: ObjectRow) async throws
    -> ObjectDetails
  { throw S3ServiceError.unsupported("Not used by this test.") }
  func upload(
    files: [URL], to location: ObjectLocation, collisionPolicy: CollisionPolicy
  ) async throws {}
  func download(
    objects: [ObjectRow], from location: ObjectLocation, to directory: URL,
    collisionPolicy: CollisionPolicy
  ) async throws {}
  func delete(objects: [ObjectRow], from location: ObjectLocation) async throws {}
  func move(
    object: ObjectRow, from location: ObjectLocation, toKey: String,
    collisionPolicy: CollisionPolicy
  ) async throws {}
  func presignedURL(
    for object: ObjectRow, at location: ObjectLocation, expiresIn: Duration
  ) async throws -> URL { throw S3ServiceError.unsupported("Not used by this test.") }
  func downloadForPreview(object: ObjectRow, at location: ObjectLocation) async throws -> URL {
    throw S3ServiceError.unsupported("Not used by this test.")
  }
  func transfers() async -> [TransferRow] { [] }
  func cancelTransfer(id: UUID) async {}
  func retryTransfer(id: UUID) async {}
}

private actor ConcurrencyProbe {
  private var active = 0
  private(set) var maximum = 0

  func run() async {
    active += 1
    maximum = max(maximum, active)
    try? await Task.sleep(for: .milliseconds(20))
    active -= 1
  }
}

private actor SearchRetryProbe {
  let first: ObjectRow
  let second: ObjectRow
  var failed = false

  init(first: ObjectRow, second: ObjectRow) {
    self.first = first
    self.second = second
  }

  func page(continuationToken: String?) throws -> ObjectSearchPage {
    guard continuationToken != nil else {
      return ObjectSearchPage(
        objects: [first], scannedObjectCount: 1_000, continuationToken: "next")
    }
    if !failed {
      failed = true
      throw S3ServiceError.networkUnavailable
    }
    return ObjectSearchPage(objects: [second], scannedObjectCount: 1, continuationToken: nil)
  }
}

private func restrictedConnection(id: UUID) -> ConnectionRow {
  ConnectionRow(
    id: id,
    name: "Restricted",
    endpoint: URL(string: "https://storage.example.com")!,
    accessPath: "/bucket/restricted",
    colorHex: "#0A84FF",
    region: "us-east-1",
    addressingMode: .pathStyle,
    tlsPolicy: .system,
    customCAURL: nil
  )
}

private func searchObject(id: String, key: String, path: String = "") -> ObjectRow {
  ObjectRow(
    id: id,
    key: key,
    displayName: String(key.split(separator: "/").last ?? Substring(key)),
    relativePath: path,
    size: 1,
    modifiedAt: nil,
    storageClass: nil,
    isPrefix: false
  )
}

@MainActor
private func waitForSearchCall(_ service: StubWorkbenchService, count: Int = 1) async -> Bool {
  for _ in 0..<10_000 {
    if (await service.searchCalls).count >= count { return true }
    await Task.yield()
  }
  return false
}

private extension ObjectPage {
  static let empty = ObjectPage(objects: [], continuationToken: nil)
}
