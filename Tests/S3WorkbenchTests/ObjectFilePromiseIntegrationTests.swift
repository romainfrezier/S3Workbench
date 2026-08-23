import Foundation
import S3WorkbenchCore
import Testing
@testable import S3Workbench

@Test func promisedDownloadsStreamFromMinIOToTheExactMacOSDestination() async throws {
  let environment = ProcessInfo.processInfo.environment
  guard environment["S3_INTEGRATION_TESTS"] == "1" else { return }
  let endpoint = try #require(environment["S3_TEST_ENDPOINT"].flatMap(URL.init(string:)))
  let accessKey = try #require(environment["S3_TEST_ACCESS_KEY"])
  let secretKey = try #require(environment["S3_TEST_SECRET_KEY"])
  let bucket = try #require(environment["S3_TEST_BUCKET"])
  let region = environment["S3_TEST_REGION"] ?? "us-east-1"
  let connectionID = UUID()
  let remotePrefix = "file-promises/\(UUID().uuidString)/nested with spaces/雪/"
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("S3Workbench-FilePromise-MinIO-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

  let smallSource = directory.appendingPathComponent("ünicode-雪 #?.txt")
  let largeSource = directory.appendingPathComponent("large-20MiB.bin")
  let smallPayload = Data("S3Workbench promised download".utf8)
  try smallPayload.write(to: smallSource)
  try writeLargeFixture(to: largeSource)

  let store = ConnectionStore(fileURL: directory.appendingPathComponent("connections.json"))
  try await store.save([
    ConnectionProfile(
      id: connectionID,
      name: "MinIO file promises",
      endpoint: endpoint,
      accessPath: "/\(bucket)/\(remotePrefix)",
      region: region,
      addressingStyle: .path
    )
  ])
  let credentials = FilePromiseIntegrationCredentialStore()
  try credentials.save(
    S3Credentials(accessKey: accessKey, secretKey: secretKey), for: connectionID)
  let service = CoreWorkbenchService(connectionStore: store, credentialStore: credentials)
  let location = ObjectLocation(
    connectionID: connectionID, bucket: bucket, prefix: remotePrefix)
  let objects = [smallSource, largeSource].map { source in
    ObjectRow(
      id: ObjectRow.id(for: remotePrefix + source.lastPathComponent, isPrefix: false),
      key: remotePrefix + source.lastPathComponent,
      displayName: source.lastPathComponent,
      relativePath: "",
      size: (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
      modifiedAt: nil,
      storageClass: nil,
      isPrefix: false
    )
  }

  do {
    try await service.upload(files: [smallSource, largeSource], to: location, collisionPolicy: .cancel)
    let smallDestination = directory.appendingPathComponent("macOS-small-destination.data")
    let largeDestination = directory.appendingPathComponent("macOS-large-destination.data")

    try await service.download(object: objects[0], from: location, to: smallDestination)
    try await service.download(object: objects[1], from: location, to: largeDestination)

    #expect(try Data(contentsOf: smallDestination) == smallPayload)
    #expect(try fileSize(at: largeDestination) == 20 * 1_024 * 1_024)
    #expect(smallDestination.lastPathComponent != objects[0].displayName)
    #expect(largeDestination.lastPathComponent != objects[1].displayName)
    try await service.delete(objects: objects, from: location)
  } catch {
    try? await service.delete(objects: objects, from: location)
    throw error
  }
}

private func writeLargeFixture(to url: URL) throws {
  guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
    throw S3ServiceError.transport("Could not create the MinIO fixture.")
  }
  let handle = try FileHandle(forWritingTo: url)
  defer { try? handle.close() }
  let chunk = Data(repeating: 0x5A, count: 1_024 * 1_024)
  for _ in 0..<20 { try handle.write(contentsOf: chunk) }
}

private func fileSize(at url: URL) throws -> Int64 {
  let values = try url.resourceValues(forKeys: [.fileSizeKey])
  return Int64(values.fileSize ?? 0)
}

private final class FilePromiseIntegrationCredentialStore: CredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var credentialsByConnectionID: [UUID: S3Credentials] = [:]

  func credentials(for connectionID: UUID) throws -> S3Credentials? {
    lock.withLock { credentialsByConnectionID[connectionID] }
  }

  func save(_ credentials: S3Credentials, for connectionID: UUID) throws {
    lock.withLock { credentialsByConnectionID[connectionID] = credentials }
  }

  func remove(for connectionID: UUID) throws {
    lock.withLock { credentialsByConnectionID[connectionID] = nil }
  }
}
