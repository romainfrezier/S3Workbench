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
  var continuationToken: String?
  var transfers: [TransferRow] = []
  var isLoadingConnections = false
  var isLoadingBuckets = false
  var isLoadingObjects = false
  var isLoadingMore = false
  var isDropTargeted = false
  var errorMessage: String?
  var bucketErrorMessage: String?
  var objectErrorMessage: String?
  var previewURL: URL? {
    didSet {
      guard oldValue != previewURL, let oldValue, isManagedPreview(oldValue) else { return }
      try? FileManager.default.removeItem(at: oldValue)
    }
  }
  var history: [String] = [""]
  var historyIndex = 0

  private let service: any WorkbenchServing
  private var appliedSearchQuery = ""
  private var loadedBucketConnectionID: UUID?
  private var loadedObjectContext: ObjectLoadContext?

  init(service: any WorkbenchServing) {
    self.service = service
  }

  var selectedConnection: ConnectionRow? {
    connections.first { $0.id == selectedConnectionID }
  }

  var accessRoot: S3AccessRoot? { selectedConnection?.initialLocation }
  var accessRootPrefix: String { accessRoot?.prefix ?? "" }

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
    defer { isLoadingConnections = false }
    do {
      connections = try await service.loadConnections()
      selectedConnectionID = selectedConnectionID ?? connections.first?.id
      await refreshTransfers()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func reloadConnection() async {
    selectedBucket = nil
    prefix = ""
    objects = []
    selectedObjectIDs = []
    objectDetails = nil
    searchQuery = ""
    history = [""]
    historyIndex = 0
    bucketErrorMessage = nil
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
    defer { isLoadingBuckets = false }
    do {
      let loadedBuckets = try await service.listBuckets(connectionID: selectedConnectionID)
      guard self.selectedConnectionID == selectedConnectionID else { return }
      buckets = loadedBuckets
      loadedBucketConnectionID = selectedConnectionID
    } catch {
      guard self.selectedConnectionID == selectedConnectionID else { return }
      bucketErrorMessage = error.localizedDescription
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

  func reloadObjects() async {
    guard let location else { return }
    let context = ObjectLoadContext(location: location, query: searchQuery)
    if loadedObjectContext != context { objects = [] }
    appliedSearchQuery = searchQuery
    selectedObjectIDs = []
    objectDetails = nil
    continuationToken = nil
    objectErrorMessage = nil
    isLoadingObjects = true
    defer { isLoadingObjects = false }
    do {
      let page = try await service.listObjects(
        at: location, query: searchQuery, continuationToken: nil)
      guard self.location == location, self.searchQuery == context.query else { return }
      objects = page.objects
      continuationToken = page.continuationToken
      loadedObjectContext = context
    } catch {
      guard self.location == location, self.searchQuery == context.query else { return }
      objectErrorMessage = error.localizedDescription
    }
  }

  func reloadSearchIfNeeded() async {
    guard location != nil, appliedSearchQuery != searchQuery else { return }
    await reloadObjects()
  }

  func loadMore() async {
    guard let location, let continuationToken, !isLoadingMore else { return }
    isLoadingMore = true
    defer { isLoadingMore = false }
    do {
      let page = try await service.listObjects(
        at: location, query: searchQuery, continuationToken: continuationToken)
      objects.append(contentsOf: page.objects)
      self.continuationToken = page.continuationToken
    } catch {
      errorMessage = error.localizedDescription
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
}

private struct ObjectLoadContext: Equatable {
  let location: ObjectLocation
  let query: String
}
