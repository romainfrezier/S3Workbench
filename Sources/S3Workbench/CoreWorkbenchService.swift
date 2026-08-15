import Foundation
import S3WorkbenchCore
import UniformTypeIdentifiers

actor CoreWorkbenchService: WorkbenchServing {
  typealias ConnectionProfilesLoader = @Sendable () async throws -> [ConnectionProfile]
  typealias S3ServiceFactory = @Sendable (ConnectionProfile, S3Credentials) async throws
    -> any S3Service

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

  private struct S3ServiceContext: Sendable {
    let service: any S3Service
    let accessRoot: S3AccessRoot?
  }

  private struct S3ServiceContextLoad: Sendable {
    let id: UUID
    let generation: UInt64
    let task: Task<S3ServiceContext, Error>
  }

  private struct SearchContinuation: Codable {
    enum Mode: String, Codable {
      case remote
      case localIndex
    }

    let mode: Mode
    let remoteToken: String?
    let buildID: UUID?
    let localCursor: Int64?
  }

  private struct SearchIndexBuildSession: Sendable {
    let build: ObjectIndexBuild
    let scope: ObjectIndexScope
  }

  struct RecursiveSearchPlan: Equatable, Sendable {
    let listingPrefix: String
    let matchingPrefix: String
    let matchingQuery: String
  }

  private let connectionStore: ConnectionStore
  private let credentialStore: any CredentialStore
  private let connectionProfilesLoader: ConnectionProfilesLoader
  private let s3ServiceFactory: S3ServiceFactory
  private let searchIndex: ObjectSearchIndex?
  private let transferManager = TransferManager<TransferOperation>(maximumConcurrentTransfers: 4)
  private var s3ServiceContexts: [UUID: S3ServiceContext] = [:]
  private var s3ServiceContextLoads: [UUID: S3ServiceContextLoad] = [:]
  private var s3ServiceContextGenerations: [UUID: UInt64] = [:]
  private var searchIndexBuilds: [UUID: SearchIndexBuildSession] = [:]

  init(
    connectionStore: ConnectionStore,
    searchIndex: ObjectSearchIndex? = nil,
    credentialStore: any CredentialStore = KeychainCredentialStore(),
    connectionProfilesLoader: ConnectionProfilesLoader? = nil,
    s3ServiceFactory: @escaping S3ServiceFactory = { profile, credentials in
      try AWSS3Service(profile: profile, credentials: credentials)
    }
  ) {
    self.connectionStore = connectionStore
    self.searchIndex = searchIndex
    self.credentialStore = credentialStore
    self.connectionProfilesLoader = connectionProfilesLoader ?? { try await connectionStore.load() }
    self.s3ServiceFactory = s3ServiceFactory
  }

  static func live() throws -> CoreWorkbenchService {
    let connectionStore = try ConnectionStore.applicationSupport()
    return CoreWorkbenchService(
      connectionStore: connectionStore,
      searchIndex: try? ObjectSearchIndex.applicationSupport()
    )
  }

  func loadConnections() async throws -> [ConnectionRow] {
    try await connectionStore.load()
      .map(ConnectionRow.init)
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func saveConnection(_ draft: ConnectionDraft) async throws -> ConnectionRow {
    invalidateS3ServiceContext(for: draft.id)
    defer { invalidateS3ServiceContext(for: draft.id) }
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
      await abandonSearchIndexBuilds(connectionID: draft.id)
      try? await searchIndex?.remove(connectionID: draft.id)
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
    invalidateS3ServiceContext(for: id)
    defer { invalidateS3ServiceContext(for: id) }
    let profiles = try await connectionStore.load()
    let profile = profiles.first { $0.id == id }
    let certificateURL = profile?.customCACertificateURL
    let credentials = try credentialStore.credentials(for: id)
    try credentialStore.remove(for: id)
    do {
      _ = try await connectionStore.remove(id: id)
      await abandonSearchIndexBuilds(connectionID: id)
      try? await searchIndex?.remove(connectionID: id)
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
    let context = try await s3ServiceContext(connectionID: connectionID)
    guard context.accessRoot == nil else { throw S3ServiceError.accessDenied }
    return try await context.service.listBuckets().map {
      BucketRow(name: $0.name, creationDate: $0.creationDate)
    }
  }

  func listObjects(
    at location: ObjectLocation,
    continuationToken: String?
  ) async throws -> ObjectPage {
    let page = try await s3Service(at: location).listObjects(
      bucket: location.bucket,
      prefix: location.prefix,
      delimiter: "/",
      continuationToken: continuationToken,
      pageSize: 1_000
    )
    let prefixes = page.prefixes.map {
      ObjectRow(
        id: ObjectRow.id(for: $0, isPrefix: true),
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
      .filter { !Self.bytesEqual($0.key, location.prefix) }
      .map {
        ObjectRow(
          id: ObjectRow.id(for: $0.key, isPrefix: false),
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
    continuationToken: String?,
    refreshIndex: Bool
  ) async throws -> ObjectSearchPage {
    guard !query.isEmpty else {
      throw S3ServiceError.invalidConfiguration("Enter a search query.")
    }
    let context = try await s3ServiceContext(at: location)
    let plan = Self.recursiveSearchPlan(below: location.prefix, query: query)
    let scope = ObjectIndexScope(
      connectionID: location.connectionID,
      bucket: location.bucket,
      prefix: context.accessRoot?.prefix ?? ""
    )

    if let continuationToken {
      let continuation = try Self.decodeSearchContinuation(continuationToken)
      switch continuation.mode {
      case .localIndex:
        guard let cursor = continuation.localCursor else {
          throw S3ServiceError.service("The local search cursor is invalid.")
        }
        do {
          guard let page = try await indexedSearchPage(
            scope: scope,
            location: location,
            plan: plan,
            after: cursor
          ) else {
            throw S3ServiceError.service(
              "The local search cursor expired. Run the search again.")
          }
          return page
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw S3ServiceError.service("The local search cursor expired. Run the search again.")
        }
      case .remote:
        guard let remoteToken = continuation.remoteToken else {
          throw S3ServiceError.service("The object search cursor is invalid.")
        }
        return try await remoteSearchPage(
          service: context.service,
          scope: scope,
          location: location,
          plan: plan,
          listingPrefix: continuation.buildID == nil ? plan.listingPrefix : scope.prefix,
          remoteToken: remoteToken,
          buildID: continuation.buildID
        )
      }
    }

    await abandonSearchIndexBuilds(for: scope)
    try Task.checkCancellation()
    if !refreshIndex {
      do {
        if let page = try await indexedSearchPage(
          scope: scope,
          location: location,
          plan: plan,
          after: nil
        ) {
          return page
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A disposable local cache must never make remote search unavailable.
      }
    }

    try Task.checkCancellation()
    let isPathQualified = !Self.bytesEqual(plan.listingPrefix, location.prefix)
    guard let searchIndex, refreshIndex || !isPathQualified,
      let build = try? await searchIndex.beginRebuild(for: scope)
    else {
      return try await remoteSearchPage(
        service: context.service,
        scope: scope,
        location: location,
        plan: plan,
        listingPrefix: plan.listingPrefix,
        remoteToken: nil,
        buildID: nil
      )
    }

    let buildID = UUID()
    searchIndexBuilds[buildID] = SearchIndexBuildSession(build: build, scope: scope)
    return try await remoteSearchPage(
      service: context.service,
      scope: scope,
      location: location,
      plan: plan,
      listingPrefix: scope.prefix,
      remoteToken: nil,
      buildID: buildID
    )
  }

  private func indexedSearchPage(
    scope: ObjectIndexScope,
    location: ObjectLocation,
    plan: RecursiveSearchPlan,
    after cursor: Int64?
  ) async throws -> ObjectSearchPage? {
    guard let searchIndex,
      let page = try await searchIndex.search(
        scope: scope,
        matching: plan.matchingQuery,
        below: plan.matchingPrefix,
        after: cursor
      )
    else { return nil }
    let continuationToken = try page.continuationCursor.map {
      try Self.encodeSearchContinuation(
        SearchContinuation(
          mode: .localIndex,
          remoteToken: nil,
          buildID: nil,
          localCursor: $0
        )
      )
    }
    return ObjectSearchPage(
      objects: page.objects.compactMap {
        Self.recursiveSearchRow(
          $0,
          below: location.prefix,
          matching: plan.matchingQuery,
          matchingBelow: plan.matchingPrefix
        )
      },
      scannedObjectCount: 0,
      continuationToken: continuationToken,
      indexSnapshot: page.snapshot
    )
  }

  private func remoteSearchPage(
    service: any S3Service,
    scope: ObjectIndexScope,
    location: ObjectLocation,
    plan: RecursiveSearchPlan,
    listingPrefix: String,
    remoteToken: String?,
    buildID: UUID?
  ) async throws -> ObjectSearchPage {
    let page: S3ObjectPage
    do {
      page = try await service.listObjects(
        bucket: location.bucket,
        prefix: listingPrefix,
        delimiter: nil,
        continuationToken: remoteToken,
        pageSize: 1_000
      )
      try Task.checkCancellation()
    } catch {
      if let buildID { await abandonSearchIndexBuild(id: buildID) }
      throw error
    }

    var activeBuildID = buildID
    var indexSnapshot: ObjectIndexSnapshot?
    if let buildID, let session = searchIndexBuilds[buildID], let searchIndex {
      do {
        try await searchIndex.append(page.objects, to: session.build)
        if page.nextContinuationToken == nil {
          indexSnapshot = try await searchIndex.finishRebuild(session.build)
          searchIndexBuilds[buildID] = nil
          activeBuildID = nil
        }
      } catch {
        await abandonSearchIndexBuild(id: buildID)
        activeBuildID = nil
      }
    } else {
      activeBuildID = nil
    }

    let continuationToken = try page.nextContinuationToken.map {
      try Self.encodeSearchContinuation(
        SearchContinuation(
          mode: .remote,
          remoteToken: $0,
          buildID: activeBuildID,
          localCursor: nil
        )
      )
    }
    return ObjectSearchPage(
      objects: page.objects.compactMap {
        Self.recursiveSearchRow(
          $0,
          below: location.prefix,
          matching: plan.matchingQuery,
          matchingBelow: plan.matchingPrefix
        )
      },
      scannedObjectCount: page.objects.count,
      continuationToken: continuationToken,
      indexSnapshot: indexSnapshot,
      isBuildingIndex: activeBuildID != nil
    )
  }

  private func abandonSearchIndexBuilds(for scope: ObjectIndexScope) async {
    let ids = searchIndexBuilds.compactMap { id, session in
      session.scope == scope ? id : nil
    }
    for id in ids { await abandonSearchIndexBuild(id: id) }
  }

  private func abandonSearchIndexBuilds(connectionID: UUID) async {
    let ids = searchIndexBuilds.compactMap { id, session in
      session.scope.connectionID == connectionID ? id : nil
    }
    for id in ids { await abandonSearchIndexBuild(id: id) }
  }

  func cancelObjectSearch(at location: ObjectLocation) async {
    let ids = searchIndexBuilds.compactMap { id, session in
      session.scope.connectionID == location.connectionID
        && Self.bytesEqual(session.scope.bucket, location.bucket) ? id : nil
    }
    for id in ids { await abandonSearchIndexBuild(id: id) }
  }

  private func abandonSearchIndexBuild(id: UUID) async {
    guard let session = searchIndexBuilds.removeValue(forKey: id) else { return }
    try? await searchIndex?.cancelRebuild(session.build)
  }

  private nonisolated static func encodeSearchContinuation(
    _ continuation: SearchContinuation
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      return try encoder.encode(continuation).base64EncodedString()
    } catch {
      throw S3ServiceError.service("The object search cursor could not be created.")
    }
  }

  private nonisolated static func decodeSearchContinuation(
    _ token: String
  ) throws -> SearchContinuation {
    guard let data = Data(base64Encoded: token),
      let continuation = try? JSONDecoder().decode(SearchContinuation.self, from: data)
    else {
      throw S3ServiceError.service("The object search cursor is invalid.")
    }
    return continuation
  }

  nonisolated static func recursiveSearchPlan(
    below prefix: String,
    query: String
  ) -> RecursiveSearchPlan {
    let queryBytes = query.utf8
    guard let separator = queryBytes.lastIndex(of: 0x2F) else {
      return RecursiveSearchPlan(
        listingPrefix: prefix,
        matchingPrefix: prefix,
        matchingQuery: query
      )
    }

    let pathEnd = queryBytes.index(after: separator)
    let listingPrefix = String(
      decoding: Array(prefix.utf8) + queryBytes[..<pathEnd],
      as: UTF8.self
    )
    return RecursiveSearchPlan(
      listingPrefix: listingPrefix,
      matchingPrefix: listingPrefix,
      matchingQuery: String(decoding: queryBytes[pathEnd...], as: UTF8.self)
    )
  }

  nonisolated static func recursiveSearchRow(
    _ object: S3Object,
    below prefix: String,
    matching query: String,
    matchingBelow matchingPrefix: String? = nil
  ) -> ObjectRow? {
    guard !bytesEqual(object.key, prefix), bytesStart(object.key, with: prefix) else {
      return nil
    }
    let matchingPrefix = matchingPrefix ?? prefix
    guard bytesStart(object.key, with: matchingPrefix) else { return nil }
    let relativeBytes = object.key.utf8.dropFirst(prefix.utf8.count)
    let relativeKey = String(decoding: relativeBytes, as: UTF8.self)
    let matchingBytes = object.key.utf8.dropFirst(matchingPrefix.utf8.count)
    let matchingKey = String(decoding: matchingBytes, as: UTF8.self)
    guard query.isEmpty || matchingKey.range(of: query, options: .caseInsensitive) != nil else {
      return nil
    }

    var nameEnd = relativeBytes.endIndex
    while nameEnd != relativeBytes.startIndex {
      let last = relativeBytes.index(before: nameEnd)
      guard relativeBytes[last] == 0x2F else { break }
      nameEnd = last
    }
    let nameBytes = relativeBytes[..<nameEnd]
    let separator = nameBytes.lastIndex(of: 0x2F)
    let displayName = separator.map {
      String(decoding: nameBytes[nameBytes.index(after: $0)...], as: UTF8.self)
    } ?? String(decoding: nameBytes, as: UTF8.self)
    let relativePath = separator.map {
      String(decoding: nameBytes[...$0], as: UTF8.self)
    } ?? ""
    return ObjectRow(
      id: ObjectRow.id(for: object.key, isPrefix: false),
      key: object.key,
      displayName: displayName.isEmpty ? relativeKey : displayName,
      relativePath: relativePath,
      size: object.size,
      modifiedAt: object.lastModified,
      storageClass: object.storageClass,
      isPrefix: false
    )
  }

  nonisolated static func validate(
    _ location: ObjectLocation,
    within accessRoot: S3AccessRoot?
  ) throws {
    guard let accessRoot else { return }
    guard bytesEqual(location.bucket, accessRoot.bucket),
      bytesStart(location.prefix, with: accessRoot.prefix)
    else {
      throw S3ServiceError.accessDenied
    }
  }

  nonisolated static func validate(
    key: String,
    bucket: String,
    within accessRoot: S3AccessRoot?
  ) throws {
    guard let accessRoot else { return }
    guard bytesEqual(bucket, accessRoot.bucket), bytesStart(key, with: accessRoot.prefix) else {
      throw S3ServiceError.accessDenied
    }
  }

  nonisolated static func bytesEqual(_ value: String, _ expected: String) -> Bool {
    value.utf8.elementsEqual(expected.utf8)
  }

  nonisolated static func bytesStart(_ value: String, with prefix: String) -> Bool {
    value.utf8.starts(with: prefix.utf8)
  }

  func objectDetails(at location: ObjectLocation, object: ObjectRow) async throws -> ObjectDetails {
    let context = try await s3ServiceContext(at: location)
    try Self.validate(key: object.key, bucket: location.bucket, within: context.accessRoot)
    let metadata = try await context.service.metadata(
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
    _ = try await s3ServiceContext(at: location)
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
    let context = try await s3ServiceContext(at: location)
    for object in objects where !object.isPrefix {
      try Self.validate(key: object.key, bucket: location.bucket, within: context.accessRoot)
    }
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
    let context = try await s3ServiceContext(at: location)
    for object in objects where !object.isPrefix {
      try Self.validate(key: object.key, bucket: location.bucket, within: context.accessRoot)
    }
    for object in objects where !object.isPrefix {
      try Task.checkCancellation()
      try await context.service.deleteObject(bucket: location.bucket, key: object.key)
      try? await searchIndex?.removeObject(
        key: object.key,
        connectionID: location.connectionID,
        bucket: location.bucket
      )
    }
  }

  func move(
    object: ObjectRow, from location: ObjectLocation, toKey: String,
    collisionPolicy: CollisionPolicy
  ) async throws {
    let context = try await s3ServiceContext(at: location)
    try Self.validate(key: object.key, bucket: location.bucket, within: context.accessRoot)
    try Self.validate(key: toKey, bucket: location.bucket, within: context.accessRoot)
    let destinationKey = try await remoteDestinationKey(
      service: context.service, bucket: location.bucket, proposedKey: toKey,
      collisionPolicy: collisionPolicy)
    try await context.service.renameObject(
      bucket: location.bucket,
      sourceKey: object.key,
      destinationKey: destinationKey
    )
    try? await searchIndex?.removeObject(
      key: object.key,
      connectionID: location.connectionID,
      bucket: location.bucket
    )
    try? await searchIndex?.upsert(
      S3Object(
        key: destinationKey,
        size: object.size,
        lastModified: Date(),
        eTag: nil,
        storageClass: object.storageClass
      ),
      connectionID: location.connectionID,
      bucket: location.bucket
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
    let context = try await s3ServiceContext(at: location)
    try Self.validate(key: object.key, bucket: location.bucket, within: context.accessRoot)
    return try await context.service.presignedRequest(
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
    let context = try await s3ServiceContext(at: location)
    try Self.validate(key: object.key, bucket: location.bucket, within: context.accessRoot)
    try await context.service.downloadFile(
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
      service = try await s3Service(at: location)
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
      let fileSize = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize
      try? await searchIndex?.upsert(
        S3Object(
          key: destinationKey,
          size: Int64(fileSize ?? 0),
          lastModified: Date(),
          eTag: nil,
          storageClass: nil
        ),
        connectionID: location.connectionID,
        bucket: location.bucket
      )
    case .download(let object, let location, let directory, let collisionPolicy):
      let context = try await s3ServiceContext(at: location)
      try Self.validate(key: object.key, bucket: location.bucket, within: context.accessRoot)
      service = context.service
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

  private func s3Service(at location: ObjectLocation) async throws -> any S3Service {
    try await s3ServiceContext(at: location).service
  }

  private func s3ServiceContext(at location: ObjectLocation) async throws -> S3ServiceContext {
    let context = try await s3ServiceContext(connectionID: location.connectionID)
    try Self.validate(location, within: context.accessRoot)
    return context
  }

  private func s3ServiceContext(connectionID: UUID) async throws -> S3ServiceContext {
    if let context = s3ServiceContexts[connectionID] { return context }
    let generation = s3ServiceContextGenerations[connectionID, default: 0]
    let load: S3ServiceContextLoad
    if let current = s3ServiceContextLoads[connectionID], current.generation == generation {
      load = current
    } else {
      let connectionProfilesLoader = connectionProfilesLoader
      let credentialStore = credentialStore
      let s3ServiceFactory = s3ServiceFactory
      let task = Task<S3ServiceContext, Error> {
        guard let profile = try await connectionProfilesLoader().first(where: {
          $0.id == connectionID
        }) else {
          throw S3ServiceError.notFound
        }
        try Task.checkCancellation()
        guard let credentials = try credentialStore.credentials(for: connectionID) else {
          throw S3ServiceError.invalidConfiguration(
            "No credentials are stored for this connection.")
        }
        try Task.checkCancellation()
        return try await S3ServiceContext(
          service: s3ServiceFactory(profile, credentials),
          accessRoot: profile.resolvedAccessPath()
        )
      }
      load = S3ServiceContextLoad(id: UUID(), generation: generation, task: task)
      s3ServiceContextLoads[connectionID] = load
    }

    do {
      let context = try await load.task.value
      guard s3ServiceContextGenerations[connectionID, default: 0] == load.generation else {
        return try await s3ServiceContext(connectionID: connectionID)
      }
      s3ServiceContexts[connectionID] = context
      if s3ServiceContextLoads[connectionID]?.id == load.id {
        s3ServiceContextLoads[connectionID] = nil
      }
      return context
    } catch {
      if s3ServiceContextGenerations[connectionID, default: 0] != load.generation {
        return try await s3ServiceContext(connectionID: connectionID)
      }
      if s3ServiceContextLoads[connectionID]?.id == load.id {
        s3ServiceContextLoads[connectionID] = nil
      }
      throw error
    }
  }

  private func invalidateS3ServiceContext(for connectionID: UUID) {
    s3ServiceContexts[connectionID] = nil
    s3ServiceContextLoads[connectionID]?.task.cancel()
    s3ServiceContextLoads[connectionID] = nil
    s3ServiceContextGenerations[connectionID, default: 0] &+= 1
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
    guard Self.bytesStart(key, with: prefix) else { return key }
    return String(decoding: key.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
