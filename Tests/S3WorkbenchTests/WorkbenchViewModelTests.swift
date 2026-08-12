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
    id: "object:report.txt", key: "report.txt", displayName: "report.txt", size: 12,
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

private actor StubWorkbenchService: WorkbenchServing {
  let connections: [ConnectionRow]
  private var listObjectsResult: Result<ObjectPage, Error>
  private(set) var bucketListCallCount = 0
  private(set) var lastObjectLocation: ObjectLocation?

  init(connections: [ConnectionRow], listObjectsResult: Result<ObjectPage, Error>) {
    self.connections = connections
    self.listObjectsResult = listObjectsResult
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
  func listObjects(
    at location: ObjectLocation, query: String, continuationToken: String?
  ) async throws -> ObjectPage {
    lastObjectLocation = location
    return try listObjectsResult.get()
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

private extension ObjectPage {
  static let empty = ObjectPage(objects: [], continuationToken: nil)
}
