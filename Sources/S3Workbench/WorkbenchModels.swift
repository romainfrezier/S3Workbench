import Foundation

enum AddressingMode: String, CaseIterable, Identifiable, Sendable {
  case automatic = "Automatic"
  case pathStyle = "Path style"
  case virtualHosted = "Virtual hosted"

  var id: Self { self }
}

enum TLSPolicy: String, CaseIterable, Identifiable, Sendable {
  case system = "System verification"
  case customCA = "Custom CA"
  case insecure = "Disable verification (unavailable)"

  var id: Self { self }
}

struct ConnectionRow: Identifiable, Hashable, Sendable {
  let id: UUID
  var name: String
  var endpoint: URL
  var region: String
  var addressingMode: AddressingMode
  var tlsPolicy: TLSPolicy
  var customCAURL: URL?
}

struct ConnectionDraft: Identifiable, Sendable {
  var id = UUID()
  var name = ""
  var endpoint = ""
  var region = "us-east-1"
  var addressingMode = AddressingMode.automatic
  var tlsPolicy = TLSPolicy.system
  var accessKey = ""
  var secretKey = ""
  var customCAURL: URL?

  init() {}

  init(connection: ConnectionRow) {
    id = connection.id
    name = connection.name
    endpoint = connection.endpoint.absoluteString
    region = connection.region
    addressingMode = connection.addressingMode
    tlsPolicy = connection.tlsPolicy
    customCAURL = connection.customCAURL
  }

  var validationMessage: String? {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "Enter a connection name."
    }
    guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme), url.host != nil
    else {
      return "Enter a complete HTTP or HTTPS endpoint URL."
    }
    guard !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "Enter a region."
    }
    if tlsPolicy == .customCA, customCAURL == nil {
      return "Choose a CA certificate."
    }
    if tlsPolicy == .insecure {
      return "Disabling TLS verification is unavailable. Use HTTP for trusted local development or a custom CA."
    }
    return nil
  }
}

struct BucketRow: Identifiable, Hashable, Sendable {
  var id: String { name }
  let name: String
  let creationDate: Date?
}

struct ObjectRow: Identifiable, Hashable, Sendable {
  let id: String
  let key: String
  let displayName: String
  let size: Int64
  let modifiedAt: Date?
  let storageClass: String?
  let isPrefix: Bool
}

struct ObjectPage: Sendable {
  let objects: [ObjectRow]
  let continuationToken: String?
}

struct ObjectDetails: Sendable {
  let contentType: String?
  let eTag: String?
  let lastModified: Date?
  let size: Int64
  let storageClass: String?
  let metadata: [String: String]
  let headers: [String: String]
}

enum TransferState: String, Sendable {
  case queued = "Queued"
  case running = "Transferring"
  case completed = "Completed"
  case cancelled = "Cancelled"
  case failed = "Failed"
}

struct TransferRow: Identifiable, Hashable, Sendable {
  let id: UUID
  let title: String
  let subtitle: String
  let progress: Double
  let state: TransferState
  let errorMessage: String?
}

struct ObjectLocation: Hashable, Sendable {
  let connectionID: UUID
  let bucket: String
  let prefix: String
}

protocol WorkbenchServing: Sendable {
  func loadConnections() async throws -> [ConnectionRow]
  func saveConnection(_ draft: ConnectionDraft) async throws -> ConnectionRow
  func removeConnection(id: UUID) async throws
  func testConnection(_ draft: ConnectionDraft) async throws
  func listBuckets(connectionID: UUID) async throws -> [BucketRow]
  func listObjects(at location: ObjectLocation, query: String, continuationToken: String?)
    async throws -> ObjectPage
  func objectDetails(at location: ObjectLocation, object: ObjectRow) async throws -> ObjectDetails
  func upload(files: [URL], to location: ObjectLocation) async throws
  func download(objects: [ObjectRow], from location: ObjectLocation, to directory: URL) async throws
  func delete(objects: [ObjectRow], from location: ObjectLocation) async throws
  func move(object: ObjectRow, from location: ObjectLocation, toKey: String) async throws
  func presignedURL(for object: ObjectRow, at location: ObjectLocation, expiresIn: Duration)
    async throws -> URL
  func downloadForPreview(object: ObjectRow, at location: ObjectLocation) async throws -> URL
  func transfers() async -> [TransferRow]
  func cancelTransfer(id: UUID) async
  func retryTransfer(id: UUID) async
}

actor PlaceholderWorkbenchService: WorkbenchServing {
  func loadConnections() async throws -> [ConnectionRow] { [] }
  func saveConnection(_ draft: ConnectionDraft) async throws -> ConnectionRow {
    guard draft.validationMessage == nil, let endpoint = URL(string: draft.endpoint) else {
      throw WorkbenchUIError.invalidConnection
    }
    return ConnectionRow(
      id: draft.id,
      name: draft.name,
      endpoint: endpoint,
      region: draft.region,
      addressingMode: draft.addressingMode,
      tlsPolicy: draft.tlsPolicy,
      customCAURL: draft.customCAURL
    )
  }
  func removeConnection(id: UUID) async throws {}
  func testConnection(_ draft: ConnectionDraft) async throws {
    throw WorkbenchUIError.serviceUnavailable
  }
  func listBuckets(connectionID: UUID) async throws -> [BucketRow] {
    throw WorkbenchUIError.serviceUnavailable
  }
  func listObjects(at location: ObjectLocation, query: String, continuationToken: String?)
    async throws -> ObjectPage
  { throw WorkbenchUIError.serviceUnavailable }
  func objectDetails(at location: ObjectLocation, object: ObjectRow) async throws -> ObjectDetails {
    throw WorkbenchUIError.serviceUnavailable
  }
  func upload(files: [URL], to location: ObjectLocation) async throws {
    throw WorkbenchUIError.serviceUnavailable
  }
  func download(objects: [ObjectRow], from location: ObjectLocation, to directory: URL) async throws
  { throw WorkbenchUIError.serviceUnavailable }
  func delete(objects: [ObjectRow], from location: ObjectLocation) async throws {
    throw WorkbenchUIError.serviceUnavailable
  }
  func move(object: ObjectRow, from location: ObjectLocation, toKey: String) async throws {
    throw WorkbenchUIError.serviceUnavailable
  }
  func presignedURL(for object: ObjectRow, at location: ObjectLocation, expiresIn: Duration)
    async throws -> URL
  { throw WorkbenchUIError.serviceUnavailable }
  func downloadForPreview(object: ObjectRow, at location: ObjectLocation) async throws -> URL {
    throw WorkbenchUIError.serviceUnavailable
  }
  func transfers() async -> [TransferRow] { [] }
  func cancelTransfer(id: UUID) async {}
  func retryTransfer(id: UUID) async {}
}

enum WorkbenchUIError: LocalizedError {
  case invalidConnection
  case serviceUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidConnection: "The connection settings are invalid."
    case .serviceUnavailable: "The S3 service is not configured yet."
    }
  }
}
