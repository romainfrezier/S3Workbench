import Foundation
import S3WorkbenchCore
import Testing
@testable import S3Workbench

@Test(arguments: [false, true])
func uploadCollisionPreflightChecksTheExactRemoteDestination(existing: Bool) async throws {
  let remote = UploadCollisionS3Service(existingKeys: existing ? ["restricted//雪/existing.txt"] : [])
  let (service, location) = uploadCollisionService(remote: remote)
  let files = ["new.txt", "existing.txt"].map { URL(fileURLWithPath: "/tmp/\($0)") }

  #expect(try await service.hasUploadConflicts(files: files, to: location) == existing)
  #expect(await remote.checkedKeys == ["restricted//雪/new.txt", "restricted//雪/existing.txt"])
  #expect(await remote.uploadedKeys.isEmpty)
}

@Test(arguments: [false, true])
func uploadCollisionPreflightDetectsDuplicateNamesWithoutNormalizingUnicode(duplicate: Bool) async throws {
  let remote = UploadCollisionS3Service()
  let (service, location) = uploadCollisionService(remote: remote)
  // fileURLWithPath decomposes Unicode on macOS; encoded URLs preserve this fixture's bytes.
  let files = [
    URL(string: "file:///tmp/a/%C3%A9.txt")!,
    URL(string: duplicate ? "file:///tmp/b/%C3%A9.txt" : "file:///tmp/b/e%CC%81.txt")!,
  ]
  #expect(files[0].lastPathComponent.utf8.elementsEqual(files[1].lastPathComponent.utf8) == duplicate)
  #expect(try await service.hasUploadConflicts(files: files, to: location) == duplicate)
  #expect(await remote.uploadedKeys.isEmpty)
}

@Test(arguments: [CollisionPolicy.cancel, .keepBoth])
func simultaneousUploadsReserveTheirDestinationsAcrossRequests(policy: CollisionPolicy) async throws {
  let remote = UploadCollisionS3Service(suspendFirstUpload: true)
  let (service, location) = uploadCollisionService(remote: remote)
  let first = Task {
    try await service.upload(
      files: [URL(fileURLWithPath: "/tmp/a/report.txt")], to: location, collisionPolicy: .cancel)
  }
  for _ in 0..<10_000 {
    if await remote.startedUploadCount == 1 { break }
    await Task.yield()
  }
  let started = await remote.startedUploadCount == 1
  #expect(started)
  guard started else {
    await remote.releaseUploads()
    try await first.value
    return
  }
  #expect(try await service.hasUploadConflicts(
    files: [URL(fileURLWithPath: "/tmp/b/report.txt")], to: location))
  var secondError: Error?
  do {
    try await service.upload(
      files: [URL(fileURLWithPath: "/tmp/b/report.txt")], to: location, collisionPolicy: policy)
  } catch { secondError = error }
  await remote.releaseUploads()
  try await first.value

  let keys = await remote.uploadedKeys
  if policy == .cancel {
    #expect((secondError as? S3ServiceError)?.isConflict == true)
    #expect(keys == ["restricted//雪/report.txt"])
  } else {
    #expect(secondError == nil)
    #expect(Set(keys) == ["restricted//雪/report.txt", "restricted//雪/report 2.txt"])
  }
}

@Test func failedUploadReleasesItsDestinationForRetry() async throws {
  let remote = UploadCollisionS3Service(uploadError: .networkUnavailable)
  let (service, location) = uploadCollisionService(remote: remote)
  let files = [URL(fileURLWithPath: "/tmp/report.txt")]
  await #expect(throws: (any Error).self) {
    try await service.upload(files: files, to: location, collisionPolicy: .cancel)
  }
  try await service.upload(files: files, to: location, collisionPolicy: .cancel)
  #expect(await remote.uploadedKeys == ["restricted//雪/report.txt"])
}

@Test @MainActor
func uploadCollisionPreflightReportsFailuresWithoutTreatingThemAsAvailableDestinations() async throws {
  let remote = UploadCollisionS3Service(metadataError: .accessDenied)
  let (service, location) = uploadCollisionService(remote: remote)
  let model = WorkbenchViewModel(service: service)

  let result = await model.hasUploadConflicts([URL(fileURLWithPath: "/tmp/new.txt")], at: location)

  #expect(result == nil)
  #expect(model.errorMessage != nil)
  #expect(await remote.uploadedKeys.isEmpty)
}

@Test func uploadCollisionPreflightPreservesRestrictedAccessRoots() async throws {
  let remote = UploadCollisionS3Service()
  let (service, location) = uploadCollisionService(remote: remote)
  let outsideRoot = ObjectLocation(
    connectionID: location.connectionID, bucket: location.bucket, prefix: "other/")

  await #expect(throws: (any Error).self) {
    try await service.hasUploadConflicts(
      files: [URL(fileURLWithPath: "/tmp/new.txt")], to: outsideRoot)
  }
  #expect(await remote.checkedKeys.isEmpty)
}

@Test @MainActor
func uploadRetainsTheDestinationCapturedBeforeCollisionConfirmation() async throws {
  let remote = UploadCollisionS3Service()
  let (service, location) = uploadCollisionService(remote: remote)
  let model = WorkbenchViewModel(service: service)

  // The browser no longer has this location selected when the confirmation completes.
  #expect(model.location == nil)
  await model.upload(
    [URL(fileURLWithPath: "/tmp/new.txt")], to: location, collisionPolicy: .cancel)

  #expect(await remote.uploadedKeys == ["restricted//雪/new.txt"])
  #expect(model.errorMessage == nil)
}

private func uploadCollisionService(remote: UploadCollisionS3Service)
  -> (CoreWorkbenchService, ObjectLocation)
{
  let profile = ConnectionProfile(
    name: "Upload fixture", endpoint: URL(string: "https://storage.example.com")!,
    accessPath: "/bucket/restricted//雪", region: "us-east-1", addressingStyle: .path)
  let store = ConnectionStore(
    fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json"))
  return (
    CoreWorkbenchService(
      connectionStore: store, credentialStore: UploadCollisionCredentials(),
      connectionProfilesLoader: { [profile] }, s3ServiceFactory: { _, _ in remote }),
    ObjectLocation(connectionID: profile.id, bucket: "bucket", prefix: "restricted//雪/")
  )
}

private struct UploadCollisionCredentials: CredentialStore {
  func credentials(for connectionID: UUID) throws -> S3Credentials? {
    try S3Credentials(accessKey: "fixture", secretKey: "fixture-secret")
  }
  func save(_ credentials: S3Credentials, for connectionID: UUID) throws {}
  func remove(for connectionID: UUID) throws {}
}

private actor UploadCollisionS3Service: S3Service {
  let existingKeys: Set<String>
  let metadataError: S3ServiceError?
  private(set) var checkedKeys: [String] = []
  private(set) var uploadedKeys: [String] = []
  private(set) var startedUploadCount = 0
  private var uploadError: S3ServiceError?
  private let suspendFirstUpload: Bool
  private var uploadsReleased = false
  private var firstUpload: CheckedContinuation<Void, Never>?

  init(
    existingKeys: Set<String> = [], metadataError: S3ServiceError? = nil,
    suspendFirstUpload: Bool = false, uploadError: S3ServiceError? = nil
  ) {
    self.existingKeys = existingKeys
    self.metadataError = metadataError
    self.suspendFirstUpload = suspendFirstUpload
    self.uploadError = uploadError
  }

  func metadata(bucket: String, key: String) async throws -> S3ObjectMetadata {
    checkedKeys.append(key)
    if let metadataError { throw metadataError }
    guard existingKeys.contains(key) || uploadedKeys.contains(where: { $0.utf8.elementsEqual(key.utf8) })
    else { throw S3ServiceError.notFound }
    return S3ObjectMetadata(
      key: key, size: 1, lastModified: nil, eTag: nil, contentType: nil,
      userMetadata: [:], headers: [:])
  }

  func uploadFile(
    from sourceURL: URL, bucket: String, key: String, contentType: String?,
    metadata: [String: String], progress: TransferProgressHandler?
  ) async throws {
    startedUploadCount += 1
    if suspendFirstUpload, startedUploadCount == 1, !uploadsReleased {
      await withCheckedContinuation { firstUpload = $0 }
    }
    if let uploadError {
      self.uploadError = nil
      throw uploadError
    }
    uploadedKeys.append(key)
  }

  func releaseUploads() {
    uploadsReleased = true
    firstUpload?.resume()
    firstUpload = nil
  }

  func testConnection() async throws -> ConnectionTestResult { .init(bucketCount: 0) }
  func listBuckets() async throws -> [S3Bucket] { [] }
  func listObjects(
    bucket: String, prefix: String, delimiter: String?, continuationToken: String?, pageSize: Int
  ) async throws -> S3ObjectPage {
    .init(prefixes: [], objects: [], nextContinuationToken: nil, keyCount: 0)
  }
  func deleteObject(bucket: String, key: String) async throws {}
  func renameObject(bucket: String, sourceKey: String, destinationKey: String) async throws {}
  func presignedRequest(
    bucket: String, key: String, operation: PresignedOperation, expiresIn: TimeInterval,
    contentType: String?
  ) async throws -> S3PresignedRequest {
    throw S3ServiceError.unsupported("Not used by this test.")
  }
  func downloadFile(
    bucket: String, key: String, to destinationURL: URL, overwrite: Bool,
    progress: TransferProgressHandler?
  ) async throws {}
}
