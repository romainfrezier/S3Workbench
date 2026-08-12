import Foundation
import S3WorkbenchCore
import UniformTypeIdentifiers

actor CoreWorkbenchService: WorkbenchServing {
  private struct TransferEntry {
    var row: TransferRow
    let operation: TransferOperation
  }

  private enum TransferOperation: Sendable {
    case upload(source: URL, location: ObjectLocation)
    case download(object: ObjectRow, location: ObjectLocation, directory: URL)

    var title: String {
      switch self {
      case .upload(let source, _): source.lastPathComponent
      case .download(let object, _, _): object.displayName
      }
    }

    var subtitle: String {
      switch self {
      case .upload(_, let location): "Upload to \(location.bucket)"
      case .download(_, let location, _): "Download from \(location.bucket)"
      }
    }
  }

  private let connectionStore: ConnectionStore
  private let credentialStore: any CredentialStore
  private var transferEntries: [UUID: TransferEntry] = [:]
  private var transferTasks: [UUID: Task<Void, Never>] = [:]
  private var activeTransferCount = 0
  private var transferWaiters: [CheckedContinuation<Void, Never>] = []
  private let maximumConcurrentTransfers = 4

  init(
    connectionStore: ConnectionStore,
    credentialStore: any CredentialStore = KeychainCredentialStore()
  ) {
    self.connectionStore = connectionStore
    self.credentialStore = credentialStore
  }

  static func live() throws -> CoreWorkbenchService {
    CoreWorkbenchService(connectionStore: try .applicationSupport())
  }

  func loadConnections() async throws -> [ConnectionRow] {
    try await connectionStore.load()
      .map(ConnectionRow.init)
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func saveConnection(_ draft: ConnectionDraft) async throws -> ConnectionRow {
    let previousProfile = try await connectionStore.load().first { $0.id == draft.id }
    var savedDraft = draft
    if draft.tlsPolicy == .customCA, let customCAURL = draft.customCAURL {
      savedDraft.customCAURL = try persistCACertificate(customCAURL, connectionID: draft.id)
    }
    let profile = try savedDraft.profile()
    let hasAccessKey = !draft.accessKey.isEmpty
    let hasSecretKey = !draft.secretKey.isEmpty
    guard hasAccessKey == hasSecretKey else {
      throw S3ServiceError.invalidConfiguration("Enter both the access key and secret access key.")
    }
    if hasAccessKey {
      let credentials = try S3Credentials(accessKey: draft.accessKey, secretKey: draft.secretKey)
      try credentialStore.save(credentials, for: profile.id)
    } else if try credentialStore.credentials(for: profile.id) == nil {
      throw S3ServiceError.invalidConfiguration("Access key and secret access key are required.")
    }
    _ = try await connectionStore.upsert(profile)
    if let oldCertificate = previousProfile?.customCACertificateURL,
      oldCertificate != profile.customCACertificateURL
    {
      if isManagedCertificate(oldCertificate) {
        try? FileManager.default.removeItem(at: oldCertificate)
      }
    }
    return ConnectionRow(profile)
  }

  func removeConnection(id: UUID) async throws {
    let certificateURL = try await connectionStore.load().first { $0.id == id }?
      .customCACertificateURL
    _ = try await connectionStore.remove(id: id)
    try credentialStore.remove(for: id)
    if let certificateURL, isManagedCertificate(certificateURL) {
      try? FileManager.default.removeItem(at: certificateURL)
    }
  }

  func testConnection(_ draft: ConnectionDraft) async throws {
    let profile = try draft.profile()
    let certificateURL = draft.tlsPolicy == .customCA ? draft.customCAURL : nil
    let hasCertificateScope = certificateURL?.startAccessingSecurityScopedResource() == true
    defer { if hasCertificateScope { certificateURL?.stopAccessingSecurityScopedResource() } }
    let credentials: S3Credentials
    if draft.accessKey.isEmpty, draft.secretKey.isEmpty {
      guard let stored = try credentialStore.credentials(for: profile.id) else {
        throw S3ServiceError.invalidConfiguration("Access key and secret access key are required.")
      }
      credentials = stored
    } else {
      credentials = try S3Credentials(accessKey: draft.accessKey, secretKey: draft.secretKey)
    }
    _ = try await AWSS3Service(profile: profile, credentials: credentials).testConnection()
  }

  func listBuckets(connectionID: UUID) async throws -> [BucketRow] {
    try await s3Service(connectionID: connectionID).listBuckets().map {
      BucketRow(name: $0.name, creationDate: $0.creationDate)
    }
  }

  func listObjects(
    at location: ObjectLocation,
    query: String,
    continuationToken: String?
  ) async throws -> ObjectPage {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectivePrefix = location.prefix + query
    let page = try await s3Service(connectionID: location.connectionID).listObjects(
      bucket: location.bucket,
      prefix: effectivePrefix,
      continuationToken: continuationToken,
      pageSize: 1_000
    )
    let prefixes = page.prefixes.map {
      ObjectRow(
        id: "prefix:\($0)",
        key: $0,
        displayName: relativeName($0, prefix: location.prefix),
        size: 0,
        modifiedAt: nil,
        storageClass: nil,
        isPrefix: true
      )
    }
    let objects = page.objects
      .filter { $0.key != location.prefix }
      .map {
        ObjectRow(
          id: "object:\($0.key)",
          key: $0.key,
          displayName: relativeName($0.key, prefix: location.prefix),
          size: $0.size,
          modifiedAt: $0.lastModified,
          storageClass: $0.storageClass,
          isPrefix: false
        )
      }
    return ObjectPage(objects: prefixes + objects, continuationToken: page.nextContinuationToken)
  }

  func objectDetails(at location: ObjectLocation, object: ObjectRow) async throws -> ObjectDetails {
    let metadata = try await s3Service(connectionID: location.connectionID).metadata(
      bucket: location.bucket,
      key: object.key
    )
    return ObjectDetails(
      contentType: metadata.contentType,
      eTag: metadata.eTag,
      lastModified: metadata.lastModified,
      size: metadata.size,
      storageClass: object.storageClass,
      metadata: metadata.userMetadata,
      headers: metadata.headers
    )
  }

  func upload(files: [URL], to location: ObjectLocation) async throws {
    var transferIDs: [UUID] = []
    for source in files {
      try Task.checkCancellation()
      transferIDs.append(enqueue(.upload(source: source, location: location)))
    }
    for id in transferIDs {
      await transferTasks[id]?.value
    }
    try throwIfTransferFailed(transferIDs)
  }

  func download(objects: [ObjectRow], from location: ObjectLocation, to directory: URL) async throws
  {
    var transferIDs: [UUID] = []
    for object in objects where !object.isPrefix {
      try Task.checkCancellation()
      transferIDs.append(
        enqueue(.download(object: object, location: location, directory: directory)))
    }
    for id in transferIDs {
      await transferTasks[id]?.value
    }
    try throwIfTransferFailed(transferIDs)
  }

  func delete(objects: [ObjectRow], from location: ObjectLocation) async throws {
    let service = try await s3Service(connectionID: location.connectionID)
    for object in objects where !object.isPrefix {
      try Task.checkCancellation()
      try await service.deleteObject(bucket: location.bucket, key: object.key)
    }
  }

  func move(object: ObjectRow, from location: ObjectLocation, toKey: String) async throws {
    let service = try await s3Service(connectionID: location.connectionID)
    try await requireRemoteDestinationAvailable(service: service, bucket: location.bucket, key: toKey)
    try await service.renameObject(
      bucket: location.bucket,
      sourceKey: object.key,
      destinationKey: toKey
    )
  }

  func presignedURL(
    for object: ObjectRow,
    at location: ObjectLocation,
    expiresIn: Duration
  ) async throws -> URL {
    let components = expiresIn.components
    let seconds =
      TimeInterval(components.seconds)
      + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    return try await s3Service(connectionID: location.connectionID).presignedRequest(
      bucket: location.bucket,
      key: object.key,
      expiresIn: seconds
    ).url
  }

  func downloadForPreview(object: ObjectRow, at location: ObjectLocation) async throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("S3Workbench-Previews", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(
      "\(UUID().uuidString)-\(safeFilename(object.displayName))")
    try await s3Service(connectionID: location.connectionID).downloadFile(
      bucket: location.bucket,
      key: object.key,
      to: destination
    )
    return destination
  }

  func transfers() async -> [TransferRow] {
    transferEntries.values.map(\.row).sorted { lhs, rhs in
      if lhs.state == rhs.state {
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
      }
      return transferPriority(lhs.state) < transferPriority(rhs.state)
    }
  }

  func cancelTransfer(id: UUID) async {
    transferTasks[id]?.cancel()
    updateTransfer(id: id, state: .cancelled)
  }

  func retryTransfer(id: UUID) async {
    guard let entry = transferEntries[id] else { return }
    if let task = transferTasks[id] {
      task.cancel()
      await task.value
    }
    transferEntries.removeValue(forKey: id)
    transferTasks.removeValue(forKey: id)
    _ = enqueue(entry.operation)
  }

  @discardableResult
  private func enqueue(_ operation: TransferOperation) -> UUID {
    let id = UUID()
    let row = TransferRow(
      id: id,
      title: operation.title,
      subtitle: operation.subtitle,
      progress: 0,
      state: .queued,
      errorMessage: nil
    )
    transferEntries[id] = TransferEntry(row: row, operation: operation)
    transferTasks[id] = Task { [weak self] in
      await self?.runTransfer(id: id, operation: operation)
    }
    return id
  }

  private func runTransfer(id: UUID, operation: TransferOperation) async {
    await acquireTransferSlot()
    defer { releaseTransferSlot() }
    if Task.isCancelled {
      updateTransfer(id: id, state: .cancelled)
      transferTasks.removeValue(forKey: id)
      return
    }
    updateTransfer(id: id, state: .running)
    do {
      let service: any S3Service
      switch operation {
      case .upload(let source, let location):
        service = try await s3Service(connectionID: location.connectionID)
        let hasScope = source.startAccessingSecurityScopedResource()
        defer { if hasScope { source.stopAccessingSecurityScopedResource() } }
        let contentType = UTType(filenameExtension: source.pathExtension)?.preferredMIMEType
        let destinationKey = location.prefix + source.lastPathComponent
        try await requireRemoteDestinationAvailable(
          service: service, bucket: location.bucket, key: destinationKey)
        try await service.uploadFile(
          from: source,
          bucket: location.bucket,
          key: destinationKey,
          contentType: contentType,
          progress: progressHandler(id: id)
        )
      case .download(let object, let location, let directory):
        service = try await s3Service(connectionID: location.connectionID)
        let hasScope = directory.startAccessingSecurityScopedResource()
        defer { if hasScope { directory.stopAccessingSecurityScopedResource() } }
        let destination = directory.appendingPathComponent(safeFilename(object.displayName))
        guard !FileManager.default.fileExists(atPath: destination.path) else {
          throw S3ServiceError.conflict(
            "A file named \(destination.lastPathComponent) already exists in the destination folder.")
        }
        try await service.downloadFile(
          bucket: location.bucket,
          key: object.key,
          to: destination,
          progress: progressHandler(id: id)
        )
      }
      updateTransfer(id: id, progress: 1, state: .completed)
    } catch is CancellationError {
      updateTransfer(id: id, state: .cancelled)
    } catch let error as S3ServiceError where error == .cancelled {
      updateTransfer(id: id, state: .cancelled)
    } catch {
      updateTransfer(id: id, state: .failed, errorMessage: error.localizedDescription)
    }
    transferTasks.removeValue(forKey: id)
  }

  private func progressHandler(id: UUID) -> TransferProgressHandler {
    { [weak self] progress in
      Task { await self?.updateTransfer(id: id, progress: progress.fractionCompleted) }
    }
  }

  private func throwIfTransferFailed(_ ids: [UUID]) throws {
    for id in ids {
      guard let row = transferEntries[id]?.row else { continue }
      if row.state == .cancelled { throw S3ServiceError.cancelled }
      if row.state == .failed {
        throw S3ServiceError.transport(row.errorMessage ?? "The transfer failed.")
      }
    }
  }

  private func acquireTransferSlot() async {
    if activeTransferCount < maximumConcurrentTransfers {
      activeTransferCount += 1
      return
    }
    await withCheckedContinuation { transferWaiters.append($0) }
    activeTransferCount += 1
  }

  private func releaseTransferSlot() {
    activeTransferCount -= 1
    if !transferWaiters.isEmpty { transferWaiters.removeFirst().resume() }
  }

  private func updateTransfer(
    id: UUID,
    progress: Double? = nil,
    state: TransferState? = nil,
    errorMessage: String? = nil
  ) {
    guard var entry = transferEntries[id] else { return }
    entry.row = TransferRow(
      id: entry.row.id,
      title: entry.row.title,
      subtitle: entry.row.subtitle,
      progress: progress ?? entry.row.progress,
      state: state ?? entry.row.state,
      errorMessage: errorMessage
    )
    transferEntries[id] = entry
  }

  private func s3Service(connectionID: UUID) async throws -> any S3Service {
    guard let profile = try await connectionStore.load().first(where: { $0.id == connectionID })
    else {
      throw S3ServiceError.notFound
    }
    guard let credentials = try credentialStore.credentials(for: connectionID) else {
      throw S3ServiceError.invalidConfiguration("No credentials are stored for this connection.")
    }
    return try AWSS3Service(profile: profile, credentials: credentials)
  }

  private func requireRemoteDestinationAvailable(
    service: any S3Service, bucket: String, key: String
  ) async throws {
    do {
      _ = try await service.metadata(bucket: bucket, key: key)
      throw S3ServiceError.conflict("An object already exists at \(key).")
    } catch let error as S3ServiceError where error == .notFound {
      return
    }
  }

  private func persistCACertificate(_ source: URL, connectionID: UUID) throws -> URL {
    let fileManager = FileManager.default
    let directory = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appendingPathComponent("S3Workbench/Certificates", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileExtension = source.pathExtension.isEmpty ? "pem" : source.pathExtension
    let destination = directory.appendingPathComponent(
      "\(connectionID.uuidString).\(fileExtension)")
    if source.standardizedFileURL == destination.standardizedFileURL { return destination }

    let hasScope = source.startAccessingSecurityScopedResource()
    defer { if hasScope { source.stopAccessingSecurityScopedResource() } }
    let temporary = directory.appendingPathComponent("\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: temporary) }
    try fileManager.copyItem(at: source, to: temporary)
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try fileManager.moveItem(at: temporary, to: destination)
    }
    return destination
  }

  private func isManagedCertificate(_ url: URL) -> Bool {
    guard let directory = try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false
    ).appendingPathComponent("S3Workbench/Certificates", isDirectory: true).standardizedFileURL
    else { return false }
    return url.standardizedFileURL.deletingLastPathComponent() == directory
  }

  private func relativeName(_ key: String, prefix: String) -> String {
    String(key.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func safeFilename(_ name: String) -> String {
    let filename = URL(fileURLWithPath: name).lastPathComponent
    return filename.isEmpty || filename == "." || filename == ".." ? "S3 Object" : filename
  }

  private func transferPriority(_ state: TransferState) -> Int {
    switch state {
    case .running: 0
    case .queued: 1
    case .failed: 2
    case .cancelled: 3
    case .completed: 4
    }
  }
}

extension ConnectionRow {
  fileprivate init(_ profile: ConnectionProfile) {
    let addressingMode: AddressingMode
    switch profile.addressingStyle {
    case .automatic: addressingMode = .automatic
    case .path: addressingMode = .pathStyle
    case .virtualHosted: addressingMode = .virtualHosted
    }
    let tlsPolicy: TLSPolicy
    switch profile.tlsVerification {
    case .systemDefault: tlsPolicy = .system
    case .customCertificate: tlsPolicy = .customCA
    case .disabled: tlsPolicy = .insecure
    }
    self.init(
      id: profile.id,
      name: profile.name,
      endpoint: profile.endpoint,
      region: profile.region,
      addressingMode: addressingMode,
      tlsPolicy: tlsPolicy,
      customCAURL: profile.customCACertificateURL
    )
  }
}

extension ConnectionDraft {
  fileprivate func profile() throws -> ConnectionProfile {
    guard validationMessage == nil, let endpoint = URL(string: endpoint) else {
      throw S3ServiceError.invalidConfiguration(
        validationMessage ?? "The connection settings are invalid.")
    }
    let addressingStyle: S3AddressingStyle
    switch addressingMode {
    case .automatic: addressingStyle = .automatic
    case .pathStyle: addressingStyle = .path
    case .virtualHosted: addressingStyle = .virtualHosted
    }
    let tlsVerification: TLSVerification
    switch tlsPolicy {
    case .system: tlsVerification = .systemDefault
    case .customCA: tlsVerification = .customCertificate
    case .insecure: tlsVerification = .disabled
    }
    return try ConnectionProfile(
      id: id,
      name: name,
      endpoint: endpoint,
      region: region,
      addressingStyle: addressingStyle,
      tlsVerification: tlsVerification,
      customCACertificateURL: customCAURL
    ).validated()
  }
}
