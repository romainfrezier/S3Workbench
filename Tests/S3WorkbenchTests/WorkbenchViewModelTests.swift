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
  #expect(
    model.objectErrorSecondaryMessage
      == "S3 said nope. Check the credentials and permissions.")
  #expect(!model.isLoadingObjects)
  #expect(!model.isObjectLoadingIndicatorVisible)
}

@MainActor
@Test func failedObjectRefreshKeepsPreviouslyLoadedRows() async throws {
  let object = ObjectRow(
    id: "object:report.txt", key: "report.txt", displayName: "report.txt", relativePath: "",
    size: 12,
    modifiedAt: nil, storageClass: nil, isPrefix: false)
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(ObjectPage(objects: [object], continuationToken: "next"))
  )
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "private"
  await model.reloadObjects()
  await service.setListObjectsResult(.failure(S3ServiceError.networkUnavailable))

  await model.reloadObjects()

  #expect(model.objects == [object])
  #expect(model.continuationToken == "next")
  #expect(model.objectErrorMessage == S3ServiceError.networkUnavailable.localizedDescription)
  #expect(
    model.objectErrorSecondaryMessage
      == "The network took an unscheduled coffee break.")
}

@MainActor
@Test func failedPaginationKeepsRowsAndOffersAnInlineRetry() async throws {
  let object = ObjectRow(
    id: "object:report.txt", key: "report.txt", displayName: "report.txt", relativePath: "",
    size: 12,
    modifiedAt: nil, storageClass: nil, isPrefix: false)
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(ObjectPage(objects: [object], continuationToken: "next"))
  )
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "private"
  await model.reloadObjects()
  await service.setListObjectsResult(.failure(S3ServiceError.networkUnavailable))

  await model.loadMore()

  #expect(model.objects == [object])
  #expect(model.continuationToken == "next")
  #expect(model.paginationErrorMessage == S3ServiceError.networkUnavailable.localizedDescription)
  #expect(
    model.paginationErrorSecondaryMessage
      == "The network took an unscheduled coffee break.")
  #expect(model.errorMessage == nil)
  #expect(!model.isLoadingMore)
  #expect(!model.isPaginationLoadingIndicatorVisible)
}

@MainActor
@Test func latePaginationCannotAppendAfterRefreshingTheSamePrefix() async {
  let initial = searchObject(id: "initial", key: "initial.txt")
  let fresh = searchObject(id: "fresh", key: "fresh.txt")
  let stale = searchObject(id: "stale", key: "stale.txt")
  let probe = BrowseRaceProbe(initial: initial, fresh: fresh, stale: stale)
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty),
    listObjectsHandler: { _, token in await probe.page(continuationToken: token) }
  )
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "bucket"

  await model.reloadObjects()
  let pagination = Task { await model.loadMore() }
  #expect(await waitForBrowseCall(probe, count: 2))

  await model.reloadObjects()
  #expect(!model.isLoadingMore)
  #expect(!model.isPaginationLoadingIndicatorVisible)
  await probe.releasePagination()
  _ = await pagination.value

  #expect(model.objects == [fresh])
  #expect(model.continuationToken == "fresh-next")
}

@MainActor
@Test func lateBucketRefreshCannotOverwriteANewerRefreshForTheSameConnection() async {
  let connectionID = UUID()
  let stale = BucketRow(name: "stale", creationDate: nil)
  let fresh = BucketRow(name: "fresh", creationDate: nil)
  let probe = BucketRaceProbe(stale: stale, fresh: fresh)
  let connection = ConnectionRow(
    id: connectionID,
    name: "Unrestricted",
    endpoint: URL(string: "https://storage.example.com")!,
    accessPath: nil,
    colorHex: "#0A84FF",
    region: "us-east-1",
    addressingMode: .pathStyle,
    tlsPolicy: .system,
    customCAURL: nil
  )
  let service = StubWorkbenchService(
    connections: [connection],
    listObjectsResult: .success(.empty),
    bucketListHandler: { _ in await probe.buckets() }
  )
  let model = WorkbenchViewModel(service: service)
  model.connections = [connection]
  model.selectedConnectionID = connectionID

  let staleRefresh = Task { await model.reloadConnection() }
  #expect(await waitForBucketCall(probe))
  await model.reloadConnection()
  await probe.releaseStaleRefresh()
  _ = await staleRefresh.value

  #expect(model.buckets == [fresh])
  #expect(!model.isLoadingBuckets)
  #expect(!model.isBucketLoadingIndicatorVisible)
}

@MainActor
@Test func lateObjectRefreshCannotOverwriteANewerRefreshAtTheSamePrefix() async {
  let stale = searchObject(id: "stale", key: "stale.txt")
  let fresh = searchObject(id: "fresh", key: "fresh.txt")
  let probe = RefreshRaceProbe(stale: stale, fresh: fresh)
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty),
    listObjectsHandler: { _, _ in await probe.page() }
  )
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "bucket"

  let staleRefresh = Task { await model.reloadObjects() }
  #expect(await waitForRefreshCall(probe))
  await model.reloadObjects()
  await probe.releaseStaleRefresh()
  _ = await staleRefresh.value

  #expect(model.objects == [fresh])
  #expect(model.continuationToken == "fresh-next")
}

@MainActor
@Test func slowSearchDelaysItsLoadingIndicatorAndClearsItOnCancellation() async throws {
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty)
  ) { _, _, _ in
    try await Task.sleep(for: .seconds(5))
    return ObjectSearchPage(objects: [], scannedObjectCount: 0, continuationToken: nil)
  }
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "bucket"
  model.searchQuery = "needle"

  let clock = ContinuousClock()
  let startedAt = clock.now
  let search = Task { await model.startSearch() }
  #expect(await waitForSearchCall(service))
  #expect(!model.isSearchLoadingIndicatorVisible)

  while !model.isSearchLoadingIndicatorVisible,
    startedAt.duration(to: clock.now) < .seconds(1)
  {
    try await Task.sleep(for: .milliseconds(10))
  }

  #expect(model.isSearchLoadingIndicatorVisible)
  #expect(startedAt.duration(to: clock.now) >= .milliseconds(200))

  model.cancelSearch()
  await search.value
  #expect(!model.isSearching)
  #expect(!model.isSearchLoadingIndicatorVisible)
}

@MainActor
@Test func failedSearchRefreshKeepsPublishedResultsAndCounters() async {
  let result = searchObject(id: "result", key: "result.txt")
  let probe = SearchRefreshProbe(result: result)
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty)
  ) { _, _, _ in
    try await probe.page()
  }
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "bucket"
  model.searchQuery = "result"
  await model.startSearch()

  await model.startSearch()

  #expect(model.objects == [result])
  #expect(model.searchScannedObjectCount == 42)
  #expect(model.searchErrorMessage == S3ServiceError.networkUnavailable.localizedDescription)
}

@MainActor
@Test func failedMultiPageSearchRefreshKeepsTheCompletePublishedSnapshot() async {
  let oldFirst = searchObject(id: "old-first", key: "old-first.txt")
  let oldSecond = searchObject(id: "old-second", key: "old-second.txt")
  let newPartial = searchObject(id: "new-partial", key: "new-partial.txt")
  let probe = MultiPageSearchRefreshProbe(
    oldResults: [oldFirst, oldSecond], newPartial: newPartial)
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty)
  ) { _, _, token in
    try await probe.page(continuationToken: token)
  }
  let model = WorkbenchViewModel(service: service)
  model.selectedConnectionID = UUID()
  model.selectedBucket = "bucket"
  model.searchQuery = "result"
  await model.startSearch()

  await model.startSearch()

  #expect(model.objects == [oldFirst, oldSecond])
  #expect(model.searchScannedObjectCount == 2_000)
  #expect(model.searchErrorMessage == S3ServiceError.networkUnavailable.localizedDescription)

  await model.retrySearch()

  #expect(model.objects == [newPartial])
  #expect(model.searchScannedObjectCount == 1_001)
  #expect(model.searchErrorMessage == nil)
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

  let leadingCombiningMark = S3Object(
    key: "restricted/folder/\u{301}needle.txt",
    size: 1,
    lastModified: nil,
    eTag: nil,
    storageClass: nil
  )
  let combiningRow = try #require(
    CoreWorkbenchService.recursiveSearchRow(
      leadingCombiningMark, below: "restricted/", matching: "needle"))
  #expect(combiningRow.displayName.utf8.elementsEqual("\u{301}needle.txt".utf8))
  #expect(combiningRow.relativePath == "folder/")
}

@MainActor
@Test func canonicallyEquivalentS3KeysRemainDistinctRowsAndSelections() async {
  let composedKey = "restricted/é.txt"
  let decomposedKey = "restricted/e\u{301}.txt"
  let composed = searchObject(
    id: ObjectRow.id(for: composedKey, isPrefix: false), key: composedKey)
  let decomposed = searchObject(
    id: ObjectRow.id(for: decomposedKey, isPrefix: false), key: decomposedKey)
  let model = WorkbenchViewModel(
    service: StubWorkbenchService(connections: [], listObjectsResult: .success(.empty)))
  model.objects = [composed, decomposed]

  model.select(composed)

  #expect(composed.id != decomposed.id)
  #expect(model.selectedObjects.map(\.id) == [composed.id])
}

@MainActor
@Test func navigationTreatsCanonicallyEquivalentPrefixesAsByteDistinct() {
  let model = WorkbenchViewModel(
    service: StubWorkbenchService(connections: [], listObjectsResult: .success(.empty)))
  model.history = ["é/"]
  model.prefix = "é/"

  model.navigate(to: "e\u{301}/")

  #expect(model.history.count == 2)
  #expect(model.history[1].utf8.elementsEqual("e\u{301}/".utf8))
}

@Test func configuredAccessRootRejectsLocationsAndKeysOutsideItsExactPrefix() throws {
  let connectionID = UUID()
  let root = try S3AccessRoot(path: "/bucket/restricted")

  try CoreWorkbenchService.validate(
    ObjectLocation(connectionID: connectionID, bucket: "bucket", prefix: "restricted/nested/"),
    within: root)
  try CoreWorkbenchService.validate(
    key: "restricted/nested/object.txt", bucket: "bucket", within: root)

  #expect(throws: S3ServiceError.accessDenied) {
    try CoreWorkbenchService.validate(
      ObjectLocation(connectionID: connectionID, bucket: "bucket", prefix: "other/"),
      within: root)
  }
  #expect(throws: S3ServiceError.accessDenied) {
    try CoreWorkbenchService.validate(
      ObjectLocation(connectionID: connectionID, bucket: "other", prefix: "restricted/"),
      within: root)
  }
  #expect(throws: S3ServiceError.accessDenied) {
    try CoreWorkbenchService.validate(
      key: "restricted-sibling/object.txt", bucket: "bucket", within: root)
  }

  let composedRoot = try S3AccessRoot(bucket: "bucket", prefix: "é")
  let decomposedPrefix = "e\u{301}/"
  #expect(throws: S3ServiceError.accessDenied) {
    try CoreWorkbenchService.validate(
      ObjectLocation(
        connectionID: connectionID, bucket: "bucket", prefix: decomposedPrefix),
      within: composedRoot)
  }
  #expect(throws: S3ServiceError.accessDenied) {
    try CoreWorkbenchService.validate(
      key: decomposedPrefix + "object.txt", bucket: "bucket", within: composedRoot)
  }

  let composedBucketRoot = try S3AccessRoot(bucket: "é", prefix: "restricted")
  #expect(throws: S3ServiceError.accessDenied) {
    try CoreWorkbenchService.validate(
      key: "restricted/object.txt", bucket: "e\u{301}", within: composedBucketRoot)
  }
}

@Test func invalidatingAnInFlightContextCannotReinstallTheOldAccessRoot() async throws {
  let connectionID = UUID()
  let oldProfile = ConnectionProfile(
    id: connectionID,
    name: "Old",
    endpoint: URL(string: "https://storage.example.com")!,
    accessPath: "/bucket/old",
    addressingStyle: .path
  )
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("S3Workbench-ContextRace-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ConnectionStore(fileURL: directory.appendingPathComponent("connections.json"))
  try await store.save([oldProfile])
  let credentials = InMemoryCredentialStore()
  try credentials.save(
    S3Credentials(accessKey: "old-access", secretKey: "old-secret"), for: connectionID)
  let serviceProbe = ContextServiceProbe()
  let service = CoreWorkbenchService(
    connectionStore: store,
    credentialStore: credentials,
    s3ServiceFactory: { profile, credentials in
      await serviceProbe.make(profile: profile, credentials: credentials)
    }
  )
  let oldLocation = ObjectLocation(
    connectionID: connectionID, bucket: "bucket", prefix: "old/")
  let newLocation = ObjectLocation(
    connectionID: connectionID, bucket: "bucket", prefix: "new/")

  let oldLoad = Task { try await service.listObjects(at: oldLocation, continuationToken: nil) }
  let oldWaiter = Task { try await service.listObjects(at: oldLocation, continuationToken: nil) }
  #expect(await waitForContextServiceBuild(serviceProbe, count: 1))

  var draft = ConnectionDraft()
  draft.id = connectionID
  draft.isExisting = true
  draft.name = "New"
  draft.server = "storage.example.com"
  draft.port = "443"
  draft.accessPath = "/bucket/new"
  draft.addressingMode = .pathStyle
  draft.accessKey = "new-access"
  draft.secretKey = "new-secret"
  _ = try await service.saveConnection(draft)
  await serviceProbe.releaseOldBuild()

  await #expect(throws: S3ServiceError.accessDenied) { _ = try await oldLoad.value }
  await #expect(throws: S3ServiceError.accessDenied) { _ = try await oldWaiter.value }
  async let newFirst = service.listObjects(at: newLocation, continuationToken: nil)
  async let newSecond = service.listObjects(at: newLocation, continuationToken: nil)
  _ = try await (newFirst, newSecond)
  _ = try await service.listObjects(at: newLocation, continuationToken: nil)

  #expect(await serviceProbe.profileNames == ["Old", "New"])
  #expect(await serviceProbe.accessKeys == ["old-access", "new-access"])
}

@Test func directAccessRootRejectsBucketEnumerationAtTheServiceBoundary() async throws {
  let connectionID = UUID()
  let profile = ConnectionProfile(
    id: connectionID,
    name: "Restricted",
    endpoint: URL(string: "https://storage.example.com")!,
    accessPath: "/bucket/restricted",
    addressingStyle: .path
  )
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("S3Workbench-RootList-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ConnectionStore(fileURL: directory.appendingPathComponent("connections.json"))
  try await store.save([profile])
  let credentials = InMemoryCredentialStore()
  try credentials.save(
    S3Credentials(accessKey: "access", secretKey: "secret"), for: connectionID)
  let service = CoreWorkbenchService(
    connectionStore: store,
    credentialStore: credentials,
    s3ServiceFactory: { _, _ in EmptyS3Service() }
  )

  await #expect(throws: S3ServiceError.accessDenied) {
    _ = try await service.listBuckets(connectionID: connectionID)
  }
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
  #expect(!model.isSearchLoadingIndicatorVisible)
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
    id: ObjectRow.id(for: "restricted/folder/needle.txt", isPrefix: false),
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

@MainActor
@Test func revealTrailingSlashObjectSelectsItsPrefixWithoutChangingTheKey() async {
  let connectionID = UUID()
  let result = searchObject(
    id: ObjectRow.id(for: "restricted/folder//", isPrefix: false),
    key: "restricted/folder//",
    path: "folder/"
  )
  let prefix = ObjectRow(
    id: ObjectRow.id(for: result.key, isPrefix: true), key: result.key,
    displayName: "folder", relativePath: "",
    size: 0, modifiedAt: nil, storageClass: nil, isPrefix: true)
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(ObjectPage(objects: [prefix], continuationToken: nil))
  ) { _, _, _ in
    ObjectSearchPage(objects: [result], scannedObjectCount: 1, continuationToken: nil)
  }
  let model = WorkbenchViewModel(service: service)
  model.connections = [restrictedConnection(id: connectionID)]
  model.selectedConnectionID = connectionID
  model.selectedBucket = "bucket"
  model.prefix = "restricted/"
  model.history = ["restricted/"]
  model.searchQuery = "folder"
  await model.startSearch()
  model.select(result)

  await model.revealSelectedInPrefix()

  #expect(model.prefix == "restricted/folder/")
  #expect(model.selectedObjectIDs == [prefix.id])
  #expect(prefix.key == result.key)
}

@MainActor
@Test func revealStopsWhenAProviderCyclesPaginationTokens() async {
  let connectionID = UUID()
  let result = searchObject(
    id: ObjectRow.id(for: "restricted/missing.txt", isPrefix: false),
    key: "restricted/missing.txt"
  )
  let probe = RevealCycleProbe()
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty),
    searchHandler: { _, _, _ in
      ObjectSearchPage(objects: [result], scannedObjectCount: 1, continuationToken: nil)
    },
    listObjectsHandler: { _, token in await probe.page(continuationToken: token) }
  )
  let model = WorkbenchViewModel(service: service)
  model.connections = [restrictedConnection(id: connectionID)]
  model.selectedConnectionID = connectionID
  model.selectedBucket = "bucket"
  model.prefix = "restricted/"
  model.history = ["restricted/"]
  model.searchQuery = "missing"
  await model.startSearch()
  model.select(result)

  await model.revealSelectedInPrefix()

  #expect(await probe.callCount == 3)
  #expect(model.selectedObjectIDs.isEmpty)
  #expect(model.paginationErrorMessage == "The server returned a repeated object pagination token.")
}

@MainActor
@Test func revealPreservesTheRealPaginationError() async {
  let connectionID = UUID()
  let result = searchObject(
    id: ObjectRow.id(for: "restricted/missing.txt", isPrefix: false),
    key: "restricted/missing.txt"
  )
  let probe = RevealFailureProbe()
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty),
    searchHandler: { _, _, _ in
      ObjectSearchPage(objects: [result], scannedObjectCount: 1, continuationToken: nil)
    },
    listObjectsHandler: { _, token in try await probe.page(continuationToken: token) }
  )
  let model = WorkbenchViewModel(service: service)
  model.connections = [restrictedConnection(id: connectionID)]
  model.selectedConnectionID = connectionID
  model.selectedBucket = "bucket"
  model.prefix = "restricted/"
  model.history = ["restricted/"]
  model.searchQuery = "missing"
  await model.startSearch()
  model.select(result)

  await model.revealSelectedInPrefix()

  #expect(await probe.callCount == 2)
  #expect(model.selectedObjectIDs.isEmpty)
  #expect(model.paginationErrorMessage == S3ServiceError.networkUnavailable.localizedDescription)
}

@MainActor
@Test func revealStopsWhenItsBrowseContextBecomesStale() async {
  let connectionID = UUID()
  let key = "restricted/folder/\u{301}needle.txt"
  let result = searchObject(id: ObjectRow.id(for: key, isPrefix: false), key: key)
  let probe = RevealStaleProbe(result: result)
  let service = StubWorkbenchService(
    connections: [],
    listObjectsResult: .success(.empty),
    searchHandler: { _, _, _ in
      ObjectSearchPage(objects: [result], scannedObjectCount: 1, continuationToken: nil)
    },
    listObjectsHandler: { _, token in await probe.page(continuationToken: token) }
  )
  let model = WorkbenchViewModel(service: service)
  model.connections = [restrictedConnection(id: connectionID)]
  model.selectedConnectionID = connectionID
  model.selectedBucket = "bucket"
  model.prefix = "restricted/"
  model.history = ["restricted/"]
  model.searchQuery = "needle"
  await model.startSearch()
  model.select(result)

  let reveal = Task { await model.revealSelectedInPrefix() }
  #expect(await waitForRevealStaleCall(probe))
  model.navigate(to: "restricted/other/")
  await model.reloadObjects()
  await probe.releaseStaleReload()
  await reveal.value

  #expect(model.prefix == "restricted/other/")
  #expect(model.selectedObjectIDs.isEmpty)
  #expect(await probe.callCount == 2)
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

private typealias ListObjectsHandler = @Sendable (
  ObjectLocation, String?
) async throws -> ObjectPage

private typealias BucketListHandler = @Sendable (UUID) async throws -> [BucketRow]

private actor StubWorkbenchService: WorkbenchServing {
  let connections: [ConnectionRow]
  private var listObjectsResult: Result<ObjectPage, Error>
  private let bucketListHandler: BucketListHandler?
  private let listObjectsHandler: ListObjectsHandler?
  private let searchHandler: SearchHandler?
  private(set) var bucketListCallCount = 0
  private(set) var lastObjectLocation: ObjectLocation?
  private(set) var searchCalls: [SearchCall] = []

  init(
    connections: [ConnectionRow],
    listObjectsResult: Result<ObjectPage, Error>,
    searchHandler: SearchHandler? = nil,
    listObjectsHandler: ListObjectsHandler? = nil,
    bucketListHandler: BucketListHandler? = nil
  ) {
    self.connections = connections
    self.listObjectsResult = listObjectsResult
    self.listObjectsHandler = listObjectsHandler
    self.bucketListHandler = bucketListHandler
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
    if let bucketListHandler { return try await bucketListHandler(connectionID) }
    return []
  }
  func listObjects(at location: ObjectLocation, continuationToken: String?) async throws
    -> ObjectPage
  {
    lastObjectLocation = location
    if let listObjectsHandler {
      return try await listObjectsHandler(location, continuationToken)
    }
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

private actor SearchRefreshProbe {
  let result: ObjectRow
  private var callCount = 0

  init(result: ObjectRow) {
    self.result = result
  }

  func page() throws -> ObjectSearchPage {
    callCount += 1
    if callCount == 1 {
      return ObjectSearchPage(objects: [result], scannedObjectCount: 42, continuationToken: nil)
    }
    throw S3ServiceError.networkUnavailable
  }
}

private actor MultiPageSearchRefreshProbe {
  let oldResults: [ObjectRow]
  let newPartial: ObjectRow
  private var callCount = 0

  init(oldResults: [ObjectRow], newPartial: ObjectRow) {
    self.oldResults = oldResults
    self.newPartial = newPartial
  }

  func page(continuationToken: String?) throws -> ObjectSearchPage {
    callCount += 1
    switch callCount {
    case 1:
      return ObjectSearchPage(
        objects: [oldResults[0]], scannedObjectCount: 1_000, continuationToken: "old-next")
    case 2:
      return ObjectSearchPage(
        objects: [oldResults[1]], scannedObjectCount: 1_000, continuationToken: nil)
    case 3:
      return ObjectSearchPage(
        objects: [newPartial], scannedObjectCount: 1_000, continuationToken: "new-next")
    case 4:
      throw S3ServiceError.networkUnavailable
    case 5:
      return ObjectSearchPage(objects: [], scannedObjectCount: 1, continuationToken: nil)
    default:
      throw S3ServiceError.service("Unexpected search refresh call.")
    }
  }
}

private actor BrowseRaceProbe {
  let initial: ObjectRow
  let fresh: ObjectRow
  let stale: ObjectRow
  private(set) var callCount = 0
  private var isPaginationReleased = false

  init(initial: ObjectRow, fresh: ObjectRow, stale: ObjectRow) {
    self.initial = initial
    self.fresh = fresh
    self.stale = stale
  }

  func page(continuationToken: String?) async -> ObjectPage {
    callCount += 1
    switch callCount {
    case 1:
      return ObjectPage(objects: [initial], continuationToken: "page-2")
    case 2:
      while !isPaginationReleased { await Task.yield() }
      return ObjectPage(objects: [stale], continuationToken: "stale-next")
    default:
      return ObjectPage(objects: [fresh], continuationToken: "fresh-next")
    }
  }

  func releasePagination() {
    isPaginationReleased = true
  }
}

private actor RefreshRaceProbe {
  let stale: ObjectRow
  let fresh: ObjectRow
  private(set) var callCount = 0
  private var isStaleRefreshReleased = false

  init(stale: ObjectRow, fresh: ObjectRow) {
    self.stale = stale
    self.fresh = fresh
  }

  func page() async -> ObjectPage {
    callCount += 1
    if callCount == 1 {
      while !isStaleRefreshReleased { await Task.yield() }
      return ObjectPage(objects: [stale], continuationToken: "stale-next")
    }
    return ObjectPage(objects: [fresh], continuationToken: "fresh-next")
  }

  func releaseStaleRefresh() {
    isStaleRefreshReleased = true
  }
}

private actor BucketRaceProbe {
  let stale: BucketRow
  let fresh: BucketRow
  private(set) var callCount = 0
  private var isStaleRefreshReleased = false

  init(stale: BucketRow, fresh: BucketRow) {
    self.stale = stale
    self.fresh = fresh
  }

  func buckets() async -> [BucketRow] {
    callCount += 1
    if callCount == 1 {
      while !isStaleRefreshReleased { await Task.yield() }
      return [stale]
    }
    return [fresh]
  }

  func releaseStaleRefresh() {
    isStaleRefreshReleased = true
  }
}

private actor RevealCycleProbe {
  private(set) var callCount = 0

  func page(continuationToken: String?) -> ObjectPage {
    callCount += 1
    switch continuationToken {
    case nil: return ObjectPage(objects: [], continuationToken: "A")
    case "A": return ObjectPage(objects: [], continuationToken: "B")
    default: return ObjectPage(objects: [], continuationToken: "A")
    }
  }
}

private actor RevealFailureProbe {
  private(set) var callCount = 0

  func page(continuationToken: String?) throws -> ObjectPage {
    callCount += 1
    if continuationToken == nil {
      return ObjectPage(objects: [], continuationToken: "next")
    }
    throw S3ServiceError.networkUnavailable
  }
}

private actor RevealStaleProbe {
  let result: ObjectRow
  private(set) var callCount = 0
  private var isStaleReloadReleased = false

  init(result: ObjectRow) {
    self.result = result
  }

  func page(continuationToken: String?) async -> ObjectPage {
    callCount += 1
    if callCount == 1 {
      while !isStaleReloadReleased { await Task.yield() }
      return ObjectPage(objects: [], continuationToken: "stale-next")
    }
    return ObjectPage(objects: [result], continuationToken: "new-next")
  }

  func releaseStaleReload() {
    isStaleReloadReleased = true
  }
}

private actor ContextServiceProbe {
  private(set) var profileNames: [String] = []
  private(set) var accessKeys: [String] = []
  private var isOldBuildReleased = false

  func make(profile: ConnectionProfile, credentials: S3Credentials) async -> any S3Service {
    profileNames.append(profile.name)
    accessKeys.append(credentials.accessKey)
    if profile.name == "Old" {
      while !isOldBuildReleased { await Task.yield() }
    }
    return EmptyS3Service()
  }

  func releaseOldBuild() {
    isOldBuildReleased = true
  }
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID: S3Credentials] = [:]

  func credentials(for connectionID: UUID) throws -> S3Credentials? {
    lock.withLock { values[connectionID] }
  }

  func save(_ credentials: S3Credentials, for connectionID: UUID) throws {
    lock.withLock { values[connectionID] = credentials }
  }

  func remove(for connectionID: UUID) throws {
    lock.withLock { values[connectionID] = nil }
  }
}

private struct EmptyS3Service: S3Service {
  func testConnection() async throws -> ConnectionTestResult { .init(bucketCount: 0) }
  func listBuckets() async throws -> [S3Bucket] { [] }
  func listObjects(
    bucket: String, prefix: String, delimiter: String?, continuationToken: String?, pageSize: Int
  ) async throws -> S3ObjectPage {
    .init(prefixes: [], objects: [], nextContinuationToken: nil, keyCount: 0)
  }
  func metadata(bucket: String, key: String) async throws -> S3ObjectMetadata {
    throw S3ServiceError.notFound
  }
  func deleteObject(bucket: String, key: String) async throws {}
  func renameObject(bucket: String, sourceKey: String, destinationKey: String) async throws {}
  func presignedRequest(
    bucket: String, key: String, operation: PresignedOperation, expiresIn: TimeInterval,
    contentType: String?
  ) async throws -> S3PresignedRequest {
    throw S3ServiceError.unsupported("Not used by this test.")
  }
  func uploadFile(
    from sourceURL: URL, bucket: String, key: String, contentType: String?,
    metadata: [String: String], progress: TransferProgressHandler?
  ) async throws {}
  func downloadFile(
    bucket: String, key: String, to destinationURL: URL, overwrite: Bool,
    progress: TransferProgressHandler?
  ) async throws {}
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

private func waitForBrowseCall(_ probe: BrowseRaceProbe, count: Int) async -> Bool {
  for _ in 0..<10_000 {
    if await probe.callCount >= count { return true }
    await Task.yield()
  }
  return false
}

private func waitForRefreshCall(_ probe: RefreshRaceProbe) async -> Bool {
  for _ in 0..<10_000 {
    if await probe.callCount > 0 { return true }
    await Task.yield()
  }
  return false
}

private func waitForBucketCall(_ probe: BucketRaceProbe) async -> Bool {
  for _ in 0..<10_000 {
    if await probe.callCount > 0 { return true }
    await Task.yield()
  }
  return false
}

private func waitForContextServiceBuild(_ probe: ContextServiceProbe, count: Int) async -> Bool {
  for _ in 0..<10_000 {
    if await probe.profileNames.count >= count { return true }
    await Task.yield()
  }
  return false
}

private func waitForRevealStaleCall(_ probe: RevealStaleProbe) async -> Bool {
  for _ in 0..<10_000 {
    if await probe.callCount > 0 { return true }
    await Task.yield()
  }
  return false
}

private extension ObjectPage {
  static let empty = ObjectPage(objects: [], continuationToken: nil)
}
