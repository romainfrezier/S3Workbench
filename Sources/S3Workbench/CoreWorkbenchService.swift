import Foundation
import S3WorkbenchCore
import UniformTypeIdentifiers

actor CoreWorkbenchService: WorkbenchServing {
  enum TransferOperation: Sendable {
    case upload(source: URL, location: ObjectLocation, collisionPolicy: CollisionPolicy)
    case download(
      object: ObjectRow, location: ObjectLocation, directory: URL,
      collisionPolicy: CollisionPolicy)

    var title: String {
      switch self {
      case .upload(let source, _, _): source.lastPathComponent
      case .download(let object, _, _, _): object.displayName
      }
    }

    var subtitle: String {
      switch self {
      case .upload(_, let location, _): "Upload to \(location.bucket)"
      case .download(_, let location, _, _): "Download from \(location.bucket)"
      }
    }
  }

  private let connectionStore: ConnectionStore
  private let credentialStore: any CredentialStore
  private let transferManager = TransferManager<TransferOperation>(maximumConcurrentTransfers: 4)

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
    let previousCredentials = try credentialStore.credentials(for: draft.id)
    _ = try draft.profile()
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
    if !hasAccessKey, previousCredentials == nil {
      throw S3ServiceError.invalidConfiguration("Access key and secret access key are required.")
    }
    do {
      if hasAccessKey {
        let credentials = try S3Credentials(accessKey: draft.accessKey, secretKey: draft.secretKey)
        try credentialStore.save(credentials, for: profile.id)
      }
      _ = try await connectionStore.upsert(profile)
    } catch {
      if let previousCredentials {
        try? credentialStore.save(previousCredentials, for: draft.id)
      } else {
        try? credentialStore.remove(for: draft.id)
      }
      if let newCertificate = profile.customCACertificateURL,
        newCertificate != previousProfile?.customCACertificateURL,
        isManagedCertificate(newCertificate)
      {
        try? FileManager.default.removeItem(at: newCertificate)
      }
      throw error
    }
    if let oldCertificate = previousProfile?.customCACertificateURL,
      oldCertificate != profile.customCACertificateURL
    {
      if isManagedCertificate(oldCertificate) {
        try? FileManager.default.removeItem(at: oldCertificate)
      }
    }
    return ConnectionRow(profile)
  }

  func duplicateConnection(id: UUID) async throws -> ConnectionRow {
    let profiles = try await connectionStore.load()
    guard var copy = profiles.first(where: { $0.id == id }) else {
      throw S3ServiceError.notFound
    }
    guard let credentials = try credentialStore.credentials(for: id) else {
      throw S3ServiceError.invalidConfiguration("No credentials are stored for this connection.")
    }
    copy.id = UUID()
    let baseName = "\(copy.name) Copy"
    copy.name = baseName
    var suffix = 2
    while profiles.contains(where: { $0.name == copy.name }) {
      copy.name = "\(baseName) \(suffix)"
      suffix += 1
    }
    if let certificate = copy.customCACertificateURL {
      copy.customCACertificateURL = try persistCACertificate(certificate, connectionID: copy.id)
    }
    do {
      try credentialStore.save(credentials, for: copy.id)
      _ = try await connectionStore.upsert(copy)
    } catch {
      try? credentialStore.remove(for: copy.id)
      if let certificate = copy.customCACertificateURL, isManagedCertificate(certificate) {
        try? FileManager.default.removeItem(at: certificate)
      }
      throw error
    }
    return ConnectionRow(copy)
  }

  func removeConnection(id: UUID) async throws {
    let profiles = try await connectionStore.load()
    let profile = profiles.first { $0.id == id }
    let certificateURL = profile?.customCACertificateURL
    let credentials = try credentialStore.credentials(for: id)
    try credentialStore.remove(for: id)
    do {
      _ = try await connectionStore.remove(id: id)
    } catch {
      if let credentials { try? credentialStore.save(credentials, for: id) }
      throw error
    }
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
    continuationToken: String?
  ) async throws -> ObjectPage {
    let page = try await s3Service(connectionID: location.connectionID).listObjects(
      bucket: location.bucket,
      prefix: location.prefix,
      delimiter: "/",
      continuationToken: continuationToken,
      pageSize: 1_000
    )
    let prefixes = page.prefixes.map {
      ObjectRow(
        id: "prefix:\($0)",
        key: $0,
        displayName: relativeName($0, prefix: location.prefix),
        relativePath: "",
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
          relativePath: "",
          size: $0.size,
          modifiedAt: $0.lastModified,
          storageClass: $0.storageClass,
          isPrefix: false
        )
    }
    return ObjectPage(objects: prefixes + objects, continuationToken: page.nextContinuationToken)
  }

  func searchObjects(
    at location: ObjectLocation,
    query: String,
    continuationToken: String?
  ) async throws -> ObjectSearchPage {
    guard !query.isEmpty else {
      throw S3ServiceError.invalidConfiguration("Enter a search query.")
    }
    let page = try await s3Service(connectionID: location.connectionID).listObjects(
      bucket: location.bucket,
      prefix: location.prefix,
      delimiter: nil,
      continuationToken: continuationToken,
      pageSize: 1_000
    )
    return ObjectSearchPage(
      objects: page.objects.compactMap {
        Self.recursiveSearchRow($0, below: location.prefix, matching: query)
      },
      scannedObjectCount: page.objects.count,
      continuationToken: page.nextContinuationToken
    )
  }

  nonisolated static func recursiveSearchRow(
    _ object: S3Object,
    below prefix: String,
    matching query: String
  ) -> ObjectRow? {
    guard object.key != prefix, object.key.hasPrefix(prefix) else { return nil }
    let relativeKey = String(object.key.dropFirst(prefix.count))
    guard relativeKey.range(of: query, options: .caseInsensitive) != nil else { return nil }

    var nameKey = relativeKey[...]
    while nameKey.last == "/" { nameKey = nameKey.dropLast() }
    let separator = nameKey.lastIndex(of: "/")
    let displayName = separator.map { String(nameKey[nameKey.index(after: $0)...]) }
      ?? String(nameKey)
    let relativePath = separator.map { String(nameKey[...$0]) } ?? ""
    return ObjectRow(
      id: "object:\(object.key)",
      key: object.key,
      displayName: displayName.isEmpty ? relativeKey : displayName,
      relativePath: relativePath,
      size: object.size,
      modifiedAt: object.lastModified,
      storageClass: object.storageClass,
      isPrefix: false
    )
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

  func upload(
    files: [URL], to location: ObjectLocation, collisionPolicy: CollisionPolicy
  ) async throws {
    var transferIDs: [UUID] = []
    for source in files {
      try Task.checkCancellation()
      let operation = TransferOperation.upload(
        source: source, location: location, collisionPolicy: collisionPolicy)
      transferIDs.append(await enqueue(operation))
    }
    try await transferManager.waitForCompletion(of: transferIDs)
  }

  func download(
    objects: [ObjectRow], from location: ObjectLocation, to directory: URL,
    collisionPolicy: CollisionPolicy
  ) async throws
  {
    var transferIDs: [UUID] = []
    for object in objects where !object.isPrefix {
      try Task.checkCancellation()
      let operation = TransferOperation.download(
        object: object, location: location, directory: directory,
        collisionPolicy: collisionPolicy)
      transferIDs.append(await enqueue(operation))
    }
    try await transferManager.waitForCompletion(of: transferIDs)
  }

  func delete(objects: [ObjectRow], from location: ObjectLocation) async throws {
    let service = try await s3Service(connectionID: location.connectionID)
    for object in objects where !object.isPrefix {
      try Task.checkCancellation()
      try await service.deleteObject(bucket: location.bucket, key: object.key)
    }
  }

  func move(
    object: ObjectRow, from location: ObjectLocation, toKey: String,
    collisionPolicy: CollisionPolicy
  ) async throws {
    let service = try await s3Service(connectionID: location.connectionID)
    let destinationKey = try await remoteDestinationKey(
      service: service, bucket: location.bucket, proposedKey: toKey,
      collisionPolicy: collisionPolicy)
    try await service.renameObject(
      bucket: location.bucket,
      sourceKey: object.key,
      destinationKey: destinationKey
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
    await transferManager.rows()
  }

  func cancelTransfer(id: UUID) async {
    await transferManager.cancel(id: id)
  }

  func retryTransfer(id: UUID) async {
    await transferManager.retry(id: id)
  }

  private func enqueue(_ operation: TransferOperation) async -> UUID {
    await transferManager.enqueue(
      operation,
      title: operation.title,
      subtitle: operation.subtitle
    ) { [weak self] operation, progress in
      guard let self else { throw CancellationError() }
      try await self.executeTransfer(operation, progress: progress)
    }
  }

  private func executeTransfer(
    _ operation: TransferOperation,
    progress: @escaping TransferManager<TransferOperation>.Progress
  ) async throws {
    let service: any S3Service
    switch operation {
    case .upload(let source, let location, let collisionPolicy):
      service = try await s3Service(connectionID: location.connectionID)
      let hasScope = source.startAccessingSecurityScopedResource()
      defer { if hasScope { source.stopAccessingSecurityScopedResource() } }
      let contentType = UTType(filenameExtension: source.pathExtension)?.preferredMIMEType
      let destinationKey = try await remoteDestinationKey(
        service: service,
        bucket: location.bucket,
        proposedKey: location.prefix + source.lastPathComponent,
        collisionPolicy: collisionPolicy
      )
      try await service.uploadFile(
        from: source,
        bucket: location.bucket,
        key: destinationKey,
        contentType: contentType
      ) { update in
        progress(update.fractionCompleted)
      }
    case .download(let object, let location, let directory, let collisionPolicy):
      service = try await s3Service(connectionID: location.connectionID)
      let hasScope = directory.startAccessingSecurityScopedResource()
      defer { if hasScope { directory.stopAccessingSecurityScopedResource() } }
      let destination = try localDestinationURL(
        directory: directory,
        filename: safeFilename(object.displayName),
        collisionPolicy: collisionPolicy
      )
      try await service.downloadFile(
        bucket: location.bucket,
        key: object.key,
        to: destination,
        overwrite: collisionPolicy == .replace
      ) { update in
        progress(update.fractionCompleted)
      }
    }
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

  private func remoteDestinationKey(
    service: any S3Service,
    bucket: String,
    proposedKey: String,
    collisionPolicy: CollisionPolicy
  ) async throws -> String {
    if collisionPolicy == .replace { return proposedKey }
    do {
      try await requireRemoteDestinationAvailable(
        service: service, bucket: bucket, key: proposedKey)
      return proposedKey
    } catch let error as S3ServiceError where error.isConflict && collisionPolicy == .keepBoth {
      let slash = proposedKey.lastIndex(of: "/")
      let directory = slash.map { String(proposedKey[...$0]) } ?? ""
      let filename = slash.map { String(proposedKey[proposedKey.index(after: $0)...]) } ?? proposedKey
      let ext = (filename as NSString).pathExtension
      let base = (filename as NSString).deletingPathExtension
      for suffix in 2...10_000 {
        let candidate = directory + "\(base) \(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
        do {
          try await requireRemoteDestinationAvailable(
            service: service, bucket: bucket, key: candidate)
          return candidate
        } catch let candidateError as S3ServiceError where candidateError.isConflict {
          continue
        }
      }
      throw S3ServiceError.conflict("Could not find an available object name.")
    }
  }

  private func localDestinationURL(
    directory: URL,
    filename: String,
    collisionPolicy: CollisionPolicy
  ) throws -> URL {
    let proposed = directory.appendingPathComponent(filename)
    guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
    switch collisionPolicy {
    case .cancel:
      throw S3ServiceError.conflict("A file named \(filename) already exists in the destination folder.")
    case .replace:
      return proposed
    case .keepBoth:
      let base = proposed.deletingPathExtension().lastPathComponent
      let ext = proposed.pathExtension
      for suffix in 2...10_000 {
        let name = "\(base) \(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
        let candidate = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      }
      throw S3ServiceError.conflict("Could not find an available filename.")
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
    if isManagedCertificate(source), source.lastPathComponent.hasPrefix(connectionID.uuidString) {
      return source
    }
    let destination = directory.appendingPathComponent(
      "\(connectionID.uuidString)-\(UUID().uuidString).\(fileExtension)")

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
      accessPath: profile.accessPath,
      colorHex: profile.colorHex ?? "#0A84FF",
      region: profile.region,
      addressingMode: addressingMode,
      tlsPolicy: tlsPolicy,
      customCAURL: profile.customCACertificateURL
    )
  }
}

extension ConnectionDraft {
  fileprivate func profile() throws -> ConnectionProfile {
    guard validationMessage == nil, let endpoint = endpointURL else {
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
      accessPath: accessPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil : accessPath.trimmingCharacters(in: .whitespacesAndNewlines),
      colorHex: colorHex,
      region: region,
      addressingStyle: addressingStyle,
      tlsVerification: tlsVerification,
      customCACertificateURL: customCAURL
    ).validated()
  }
}
