import Foundation
import Observation
import S3WorkbenchCore

@MainActor
@Observable
final class WorkbenchViewModel {
  var connections: [ConnectionRow] = []
  var selectedConnectionID: UUID?
  var buckets: [BucketRow] = []
  var selectedBucket: String?
  var prefix = ""
  var objects: [ObjectRow] = []
  var selectedObjectIDs = Set<ObjectRow.ID>()
  var objectDetails: ObjectDetails?
  var searchQuery = ""
  private(set) var activeSearchQuery: String?
  private(set) var searchScannedObjectCount = 0
  private(set) var searchErrorMessage: String?
  private(set) var searchErrorSecondaryMessage: String?
  private(set) var searchWasCancelled = false
  var continuationToken: String?
  var transfers: [TransferRow] = []
  var isLoadingConnections = false
  var isLoadingBuckets = false
  var isLoadingObjects = false
  var isLoadingMore = false
  var isSearching = false
  var isDropTargeted = false
  var errorMessage: String?
  var bucketErrorMessage: String?
  private(set) var bucketErrorSecondaryMessage: String?
  var objectErrorMessage: String?
  private(set) var objectErrorSecondaryMessage: String?
  private(set) var paginationErrorMessage: String?
  private(set) var paginationErrorSecondaryMessage: String?
  var previewURL: URL? {
    didSet {
      guard oldValue != previewURL, let oldValue, isManagedPreview(oldValue) else { return }
      try? FileManager.default.removeItem(at: oldValue)
    }
  }
  var history: [String] = [""]
  var historyIndex = 0

  private let service: any WorkbenchServing
  private var loadedBucketConnectionID: UUID?
  private var loadedObjectContext: ObjectLoadContext?
  private var activeSearchContext: ObjectSearchContext?
  private var searchTask: Task<Void, Never>?
  private var nextSearchContinuationToken: String?
  private var seenSearchContinuationTokens = Set<String>()
  private var visibleLoadingIndicators = Set<LoadingIndicator>()
  @ObservationIgnored private var loadingIndicatorTasks: [LoadingIndicator: Task<Void, Never>] = [:]
  @ObservationIgnored private var loadingIndicatorIDs: [LoadingIndicator: UUID] = [:]

  init(service: any WorkbenchServing) {
    self.service = service
  }

  var selectedConnection: ConnectionRow? {
    connections.first { $0.id == selectedConnectionID }
  }

  var accessRoot: S3AccessRoot? { selectedConnection?.initialLocation }
  var accessRootPrefix: String { accessRoot?.prefix ?? "" }
  var isSearchMode: Bool { activeSearchQuery != nil }
  var searchMatchCount: Int { isSearchMode ? objects.count : 0 }
  var isConnectionLoadingIndicatorVisible: Bool {
    visibleLoadingIndicators.contains(.connections)
  }
  var isBucketLoadingIndicatorVisible: Bool { visibleLoadingIndicators.contains(.buckets) }
  var isObjectLoadingIndicatorVisible: Bool { visibleLoadingIndicators.contains(.objects) }
  var isPaginationLoadingIndicatorVisible: Bool {
    visibleLoadingIndicators.contains(.pagination)
  }
  var isSearchLoadingIndicatorVisible: Bool { visibleLoadingIndicators.contains(.search) }

  var selectedObjects: [ObjectRow] {
    objects.filter { selectedObjectIDs.contains($0.id) }
  }

  var selectedObject: ObjectRow? {
    selectedObjects.count == 1 ? selectedObjects[0] : nil
  }

  var location: ObjectLocation? {
    guard let selectedConnectionID, let selectedBucket else { return nil }
    return ObjectLocation(
      connectionID: selectedConnectionID, bucket: selectedBucket, prefix: prefix)
  }

  var canGoBack: Bool {
    accessRoot != nil ? historyIndex > 0 : selectedBucket != nil || historyIndex > 0
  }
  var canGoForward: Bool { historyIndex + 1 < history.count }

  func start() async {
    isLoadingConnections = true
    let loadingID = startLoadingIndicator(.connections)
    defer {
      if stopLoadingIndicator(.connections, id: loadingID) { isLoadingConnections = false }
    }
    do {
      connections = try await service.loadConnections()
      selectedConnectionID = selectedConnectionID ?? connections.first?.id
      await refreshTransfers()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func reloadConnection() async {
    resetSearch(clearQuery: true)
    selectedBucket = nil
    prefix = ""
    objects = []
    selectedObjectIDs = []
    objectDetails = nil
    history = [""]
    historyIndex = 0
    bucketErrorMessage = nil
    bucketErrorSecondaryMessage = nil
    guard let selectedConnectionID else {
      buckets = []
      return
    }
    if let accessRoot {
      buckets = []
      selectedBucket = accessRoot.bucket
      prefix = accessRoot.prefix
      history = [accessRoot.prefix]
      await reloadObjects()
      return
    }
    if loadedBucketConnectionID != selectedConnectionID { buckets = [] }
    isLoadingBuckets = true
    let loadingID = startLoadingIndicator(.buckets)
    defer {
      if stopLoadingIndicator(.buckets, id: loadingID) { isLoadingBuckets = false }
    }
    do {
      let loadedBuckets = try await service.listBuckets(connectionID: selectedConnectionID)
      guard self.selectedConnectionID == selectedConnectionID else { return }
      buckets = loadedBuckets
      loadedBucketConnectionID = selectedConnectionID
    } catch {
      guard self.selectedConnectionID == selectedConnectionID else { return }
      bucketErrorMessage = error.localizedDescription
      bucketErrorSecondaryMessage = serviceFailureCopy(for: error)
    }
  }

  func openBucket(_ name: String) async {
    selectedBucket = name
    prefix = ""
    history = [""]
    historyIndex = 0
    await reloadObjects()
  }

  func openPrefix(_ object: ObjectRow) async {
    guard object.isPrefix else { return }
    navigate(to: object.key)
    await reloadObjects()
  }

  func navigateToRoot() async {
    if let accessRoot {
      selectedBucket = accessRoot.bucket
      prefix = accessRoot.prefix
      history = [accessRoot.prefix]
      historyIndex = 0
      await reloadObjects()
      return
    }
    resetSearch(clearQuery: true)
    selectedBucket = nil
    prefix = ""
    objects = []
    selectedObjectIDs = []
    objectDetails = nil
  }

  func select(_ object: ObjectRow) {
    selectedObjectIDs = [object.id]
  }

  func navigate(to newPrefix: String) {
    prefix = newPrefix
    if history[historyIndex] == newPrefix { return }
    history.removeSubrange((historyIndex + 1)..<history.count)
    history.append(newPrefix)
    historyIndex = history.count - 1
  }

  func goBack() async {
    guard canGoBack else { return }
    if historyIndex == 0 {
      await navigateToRoot()
      return
    }
    historyIndex -= 1
    prefix = history[historyIndex]
    await reloadObjects()
  }

  func goForward() async {
    guard canGoForward else { return }
    historyIndex += 1
    prefix = history[historyIndex]
    await reloadObjects()
  }

  func reloadObjects(clearSearchQuery: Bool = true) async {
    let wasSearchMode = isSearchMode
    resetSearch(clearQuery: clearSearchQuery)
    guard let location else { return }
    let context = ObjectLoadContext(location: location)
    if wasSearchMode || loadedObjectContext != context { objects = [] }
    selectedObjectIDs = []
    objectDetails = nil
    continuationToken = nil
    objectErrorMessage = nil
    objectErrorSecondaryMessage = nil
    paginationErrorMessage = nil
    paginationErrorSecondaryMessage = nil
    isLoadingObjects = true
    let loadingID = startLoadingIndicator(.objects)
    defer {
      if stopLoadingIndicator(.objects, id: loadingID) { isLoadingObjects = false }
    }
    do {
      let page = try await service.listObjects(at: location, continuationToken: nil)
      guard self.location == location, !isSearchMode else { return }
      objects = page.objects
      continuationToken = page.continuationToken
      loadedObjectContext = context
    } catch {
      guard self.location == location, !isSearchMode else { return }
      objectErrorMessage = error.localizedDescription
      objectErrorSecondaryMessage = serviceFailureCopy(for: error)
    }
  }

  func startSearch() async {
    let query = searchQuery
    guard !query.isEmpty, let location else {
      if isSearchMode { await reloadObjects(clearSearchQuery: false) }
      return
    }

    resetSearch(clearQuery: false)
    let context = ObjectSearchContext(id: UUID(), location: location, query: query)
    activeSearchContext = context
    activeSearchQuery = query
    objects = []
    selectedObjectIDs = []
    objectDetails = nil
    continuationToken = nil
    objectErrorMessage = nil
    objectErrorSecondaryMessage = nil
    paginationErrorMessage = nil
    paginationErrorSecondaryMessage = nil
    searchScannedObjectCount = 0
    searchErrorMessage = nil
    searchErrorSecondaryMessage = nil
    searchWasCancelled = false
    isSearching = true
    startLoadingIndicator(.search, id: context.id)

    let task = Task { [weak self] in
      guard let self else { return }
      await self.runSearch(context)
    }
    searchTask = task
    await task.value
  }

  func searchQueryDidChange() async {
    guard let activeSearchQuery, activeSearchQuery != searchQuery else { return }
    await reloadObjects(clearSearchQuery: false)
  }

  func cancelSearch() {
    guard isSearching else { return }
    searchTask?.cancel()
    isSearching = false
    searchWasCancelled = true
    if let context = activeSearchContext {
      stopLoadingIndicator(.search, id: context.id)
    }
  }

  func retrySearch() async {
    guard let context = activeSearchContext, !isSearching,
      location == context.location, searchQuery == context.query,
      searchErrorMessage != nil || searchWasCancelled
    else { return }
    let retryContext = ObjectSearchContext(
      id: UUID(), location: context.location, query: context.query)
    activeSearchContext = retryContext
    searchErrorMessage = nil
    searchErrorSecondaryMessage = nil
    searchWasCancelled = false
    isSearching = true
    startLoadingIndicator(.search, id: retryContext.id)
    let task = Task { [weak self] in
      guard let self else { return }
      await self.runSearch(retryContext)
    }
    searchTask = task
    await task.value
  }

  func revealSelectedInPrefix() async {
    guard isSearchMode, let object = selectedObject else { return }
    let objectID = object.id
    let destination = parentPrefix(of: object.key)
    resetSearch(clearQuery: true)
    navigate(to: destination)
    await reloadObjects()
    var previousToken: String?
    while !objects.contains(where: { $0.id == objectID }),
      let token = continuationToken,
      token != previousToken
    {
      previousToken = token
      await loadMore()
    }
    if objects.contains(where: { $0.id == objectID }) {
      selectedObjectIDs = [objectID]
    }
  }

  func loadMore() async {
    guard !isSearchMode, let location, let continuationToken, !isLoadingMore else { return }
    paginationErrorMessage = nil
    paginationErrorSecondaryMessage = nil
    isLoadingMore = true
    let loadingID = startLoadingIndicator(.pagination)
    defer {
      if stopLoadingIndicator(.pagination, id: loadingID) { isLoadingMore = false }
    }
    do {
      let page = try await service.listObjects(at: location, continuationToken: continuationToken)
      guard self.location == location, !isSearchMode else { return }
      objects.append(contentsOf: page.objects)
      self.continuationToken = page.continuationToken
    } catch {
      guard self.location == location, !isSearchMode else { return }
      paginationErrorMessage = error.localizedDescription
      paginationErrorSecondaryMessage = serviceFailureCopy(for: error)
    }
  }

  func loadSelectionDetails() async {
    objectDetails = nil
    guard let location, let selectedObject, !selectedObject.isPrefix else { return }
    do {
      objectDetails = try await service.objectDetails(at: location, object: selectedObject)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func saveConnection(_ draft: ConnectionDraft) async -> Bool {
    guard draft.validationMessage == nil else { return false }
    do {
      let saved = try await service.saveConnection(draft)
      if let index = connections.firstIndex(where: { $0.id == saved.id }) {
        connections[index] = saved
      } else {
        connections.append(saved)
      }
      selectedConnectionID = saved.id
      await reloadConnection()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func removeConnection(_ connection: ConnectionRow) async {
    await perform {
      try await service.removeConnection(id: connection.id)
      connections.removeAll { $0.id == connection.id }
      if selectedConnectionID == connection.id {
        selectedConnectionID = connections.first?.id
        await reloadConnection()
      }
    }
  }

  func duplicateConnection(_ connection: ConnectionRow) async {
    await perform {
      let copy = try await service.duplicateConnection(id: connection.id)
      connections.append(copy)
      connections.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      selectedConnectionID = copy.id
    }
  }

  func testConnection(_ draft: ConnectionDraft) async throws {
    try await service.testConnection(draft)
  }

  func upload(_ urls: [URL], collisionPolicy: CollisionPolicy) async {
    guard let location, !urls.isEmpty else { return }
    await perform {
      try await service.upload(files: urls, to: location, collisionPolicy: collisionPolicy)
      await refreshTransfers()
      await reloadObjects()
    }
  }

  func downloadSelected(to directory: URL, collisionPolicy: CollisionPolicy) async {
    guard let location, !selectedObjects.isEmpty else { return }
    await perform {
      try await service.download(
        objects: selectedObjects, from: location, to: directory,
        collisionPolicy: collisionPolicy)
      await refreshTransfers()
    }
  }

  func deleteSelected() async {
    guard let location, !selectedObjects.isEmpty else { return }
    await perform {
      try await service.delete(objects: selectedObjects, from: location)
      await reloadObjects()
    }
  }

  func renameSelected(to newKey: String, collisionPolicy: CollisionPolicy) async -> Bool {
    guard let location, let selectedObject, !newKey.isEmpty else { return false }
    do {
      try await service.move(
        object: selectedObject, from: location, toKey: newKey,
        collisionPolicy: collisionPolicy)
      await reloadObjects()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func previewSelected() async {
    guard let location, let selectedObject, !selectedObject.isPrefix else { return }
    do {
      previewURL = try await service.downloadForPreview(object: selectedObject, at: location)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func presignedURL() async -> URL? {
    guard let location, let selectedObject, !selectedObject.isPrefix else { return nil }
    do {
      return try await service.presignedURL(
        for: selectedObject, at: location, expiresIn: .seconds(3_600))
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func refreshTransfers() async {
    transfers = await service.transfers()
  }

  func cancelTransfer(_ transfer: TransferRow) async {
    await service.cancelTransfer(id: transfer.id)
    await refreshTransfers()
  }

  func retryTransfer(_ transfer: TransferRow) async {
    await service.retryTransfer(id: transfer.id)
    await refreshTransfers()
  }

  private func perform(_ operation: () async throws -> Void) async {
    do {
      try await operation()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func isManagedPreview(_ url: URL) -> Bool {
    url.path.contains("/S3Workbench-Previews/")
  }

  private func runSearch(_ context: ObjectSearchContext) async {
    do {
      repeat {
        try Task.checkCancellation()
        let page = try await service.searchObjects(
          at: context.location,
          query: context.query,
          continuationToken: nextSearchContinuationToken
        )
        try Task.checkCancellation()
        guard isActive(context), isSearching else {
          discardStaleSearch(context)
          return
        }
        if let nextToken = page.continuationToken,
          !seenSearchContinuationTokens.insert(nextToken).inserted
        {
          throw S3ServiceError.service(
            "The server returned a repeated object pagination token.")
        }
        objects.append(contentsOf: page.objects)
        searchScannedObjectCount += page.scannedObjectCount
        nextSearchContinuationToken = page.continuationToken
      } while nextSearchContinuationToken != nil

      guard isActive(context) else {
        discardStaleSearch(context)
        return
      }
      isSearching = false
      searchTask = nil
      stopLoadingIndicator(.search, id: context.id)
    } catch {
      guard isActive(context) else {
        discardStaleSearch(context)
        return
      }
      isSearching = false
      searchTask = nil
      stopLoadingIndicator(.search, id: context.id)
      if error is CancellationError || error as? S3ServiceError == .cancelled {
        searchWasCancelled = true
      } else {
        searchErrorMessage = error.localizedDescription
        searchErrorSecondaryMessage = serviceFailureCopy(for: error)
      }
    }
  }

  private func isActive(_ context: ObjectSearchContext) -> Bool {
    activeSearchContext == context && location == context.location && searchQuery == context.query
  }

  private func discardStaleSearch(_ context: ObjectSearchContext) {
    guard activeSearchContext == context else { return }
    stopLoadingIndicator(.search, id: context.id)
    searchTask = nil
    activeSearchContext = nil
    activeSearchQuery = nil
    isSearching = false
    objects = []
    selectedObjectIDs = []
    objectDetails = nil
    searchScannedObjectCount = 0
    searchErrorMessage = nil
    searchErrorSecondaryMessage = nil
    searchWasCancelled = false
    nextSearchContinuationToken = nil
    seenSearchContinuationTokens = []
  }

  private func resetSearch(clearQuery: Bool) {
    if let context = activeSearchContext {
      stopLoadingIndicator(.search, id: context.id)
    }
    searchTask?.cancel()
    searchTask = nil
    activeSearchContext = nil
    activeSearchQuery = nil
    isSearching = false
    searchScannedObjectCount = 0
    searchErrorMessage = nil
    searchErrorSecondaryMessage = nil
    searchWasCancelled = false
    nextSearchContinuationToken = nil
    seenSearchContinuationTokens = []
    if clearQuery { searchQuery = "" }
  }

  private func parentPrefix(of key: String) -> String {
    guard let separator = key.lastIndex(of: "/") else { return accessRootPrefix }
    let candidate = String(key[...separator])
    return candidate.hasPrefix(accessRootPrefix) ? candidate : accessRootPrefix
  }

  private func serviceFailureCopy(for error: Error) -> String {
    switch error as? S3ServiceError {
    case .networkUnavailable:
      "The network took an unscheduled coffee break."
    case .accessDenied:
      "S3 said nope. Check the credentials and permissions."
    default:
      "The cloud returned a plot twist."
    }
  }

  @discardableResult
  private func startLoadingIndicator(
    _ indicator: LoadingIndicator, id: UUID = UUID()
  ) -> UUID {
    loadingIndicatorTasks[indicator]?.cancel()
    loadingIndicatorIDs[indicator] = id
    guard !visibleLoadingIndicators.contains(indicator) else { return id }
    loadingIndicatorTasks[indicator] = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(200))
      } catch {
        return
      }
      guard let self, loadingIndicatorIDs[indicator] == id else { return }
      visibleLoadingIndicators.insert(indicator)
    }
    return id
  }

  @discardableResult
  private func stopLoadingIndicator(_ indicator: LoadingIndicator, id: UUID) -> Bool {
    guard loadingIndicatorIDs[indicator] == id else { return false }
    loadingIndicatorTasks[indicator]?.cancel()
    loadingIndicatorTasks[indicator] = nil
    loadingIndicatorIDs[indicator] = nil
    visibleLoadingIndicators.remove(indicator)
    return true
  }
}

private enum LoadingIndicator: Hashable, Sendable {
  case connections
  case buckets
  case objects
  case pagination
  case search
}

private struct ObjectLoadContext: Equatable {
  let location: ObjectLocation
}

private struct ObjectSearchContext: Equatable {
  let id: UUID
  let location: ObjectLocation
  let query: String
}
