import AppKit
import Foundation
import S3WorkbenchCore
import SwiftUI

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
  var accessPath: String?
  var colorHex: String
  var region: String
  var addressingMode: AddressingMode
  var tlsPolicy: TLSPolicy
  var customCAURL: URL?

  var initialLocation: S3AccessRoot? {
    guard let accessPath else { return nil }
    return try? S3AccessRoot(path: accessPath)
  }

  var color: Color { Color(connectionHex: colorHex) }
}

struct ConnectionDraft: Identifiable, Equatable, Sendable {
  var id = UUID()
  var isExisting = false
  var name = ""
  var server = ""
  var port = "443"
  var accessPath = ""
  var colorHex = "#0A84FF"
  var usesHTTPS = true
  var region = "us-east-1"
  var addressingMode = AddressingMode.automatic
  var tlsPolicy = TLSPolicy.system
  var accessKey = ""
  var secretKey = ""
  var customCAURL: URL?
  private var endpointBasePath = ""

  init() {}

  init(connection: ConnectionRow) {
    id = connection.id
    isExisting = true
    name = connection.name
    let components = URLComponents(url: connection.endpoint, resolvingAgainstBaseURL: false)
    server = components?.host ?? ""
    usesHTTPS = components?.scheme?.lowercased() != "http"
    port = String(components?.port ?? (usesHTTPS ? 443 : 80))
    let savedEndpointPath = components?.percentEncodedPath ?? ""
    if let savedAccessPath = connection.accessPath {
      accessPath = savedAccessPath
      endpointBasePath = savedEndpointPath
    } else if !savedEndpointPath.isEmpty, savedEndpointPath != "/" {
      // Migrate endpoint paths entered in the original single-URL editor to a direct S3 path.
      accessPath = savedEndpointPath.removingPercentEncoding ?? savedEndpointPath
    } else {
      endpointBasePath = savedEndpointPath
    }
    colorHex = connection.colorHex
    region = connection.region
    addressingMode = connection.addressingMode
    tlsPolicy = connection.tlsPolicy
    customCAURL = connection.customCAURL
  }

  var endpointURL: URL? {
    guard let port = Int(port), (1...65_535).contains(port) else { return nil }
    var components = URLComponents()
    components.scheme = usesHTTPS ? "https" : "http"
    let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
    components.host = trimmedServer.hasPrefix("[") && trimmedServer.hasSuffix("]")
      ? String(trimmedServer.dropFirst().dropLast()) : trimmedServer
    components.port = port
    components.percentEncodedPath = endpointBasePath
    return components.url
  }

  var validationMessage: String? {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "Enter a connection name."
    }
    let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedServer.isEmpty else { return "Enter a server name." }
    guard !trimmedServer.contains("://"),
      trimmedServer.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@")) == nil
    else {
      return "Enter only the server name, without https://, a port, or a path."
    }
    if trimmedServer.filter({ $0 == ":" }).count == 1 {
      return "Enter the port in the Port field."
    }
    guard endpointURL?.host != nil else { return "Enter a valid server name." }
    guard let port = Int(port), (1...65_535).contains(port) else {
      return "Enter a port between 1 and 65535."
    }
    let trimmedAccessPath = accessPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedAccessPath.isEmpty, (try? S3AccessRoot(path: trimmedAccessPath)) == nil {
      return "Access path must contain a bucket name, for example /etickets."
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
    let hasAccessKey = !accessKey.isEmpty
    let hasSecretKey = !secretKey.isEmpty
    if hasAccessKey != hasSecretKey {
      return "Enter both the access key and secret access key."
    }
    if !isExisting, !hasAccessKey {
      return "Enter an access key and secret access key."
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
  let relativePath: String
  let size: Int64
  let modifiedAt: Date?
  let storageClass: String?
  let isPrefix: Bool

  static func id(for key: String, isPrefix: Bool) -> String {
    let kind = isPrefix ? "prefix" : "object"
    return "\(kind):\(Data(key.utf8).base64EncodedString())"
  }
}

struct ObjectSortComparator: SortComparator, Sendable {
  enum Column: Sendable {
    case name
    case size
    case modified
    case storageClass
  }

  let column: Column
  var order: SortOrder = .forward

  func compare(_ lhs: ObjectRow, _ rhs: ObjectRow) -> ComparisonResult {
    if lhs.isPrefix != rhs.isPrefix {
      return lhs.isPrefix ? .orderedAscending : .orderedDescending
    }

    switch column {
    case .name:
      let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
      return ordered(
        nameComparison == .orderedSame
          ? lhs.key.localizedStandardCompare(rhs.key) : nameComparison)
    case .size:
      return ordered(compare(lhs.size, rhs.size))
    case .modified:
      return compare(lhs.modifiedAt, rhs.modifiedAt, using: compare)
    case .storageClass:
      return compare(lhs.storageClass, rhs.storageClass) {
        $0.localizedStandardCompare($1)
      }
    }
  }

  private func compare<Value>(
    _ lhs: Value?,
    _ rhs: Value?,
    using comparison: (Value, Value) -> ComparisonResult
  ) -> ComparisonResult {
    switch (lhs, rhs) {
    case (.none, .none): .orderedSame
    case (.none, .some): .orderedDescending
    case (.some, .none): .orderedAscending
    case (.some(let lhs), .some(let rhs)): ordered(comparison(lhs, rhs))
    }
  }

  private func compare<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
    if lhs == rhs { return .orderedSame }
    return lhs < rhs ? .orderedAscending : .orderedDescending
  }

  private func ordered(_ comparison: ComparisonResult) -> ComparisonResult {
    guard order == .reverse else { return comparison }
    switch comparison {
    case .orderedAscending: return .orderedDescending
    case .orderedDescending: return .orderedAscending
    case .orderedSame: return .orderedSame
    }
  }
}

struct ObjectPage: Sendable {
  let objects: [ObjectRow]
  let continuationToken: String?
}

struct ObjectSearchPage: Sendable {
  let objects: [ObjectRow]
  let scannedObjectCount: Int
  let continuationToken: String?
  let indexSnapshot: ObjectIndexSnapshot?
  let isBuildingIndex: Bool

  init(
    objects: [ObjectRow],
    scannedObjectCount: Int,
    continuationToken: String?,
    indexSnapshot: ObjectIndexSnapshot? = nil,
    isBuildingIndex: Bool = false
  ) {
    self.objects = objects
    self.scannedObjectCount = scannedObjectCount
    self.continuationToken = continuationToken
    self.indexSnapshot = indexSnapshot
    self.isBuildingIndex = isBuildingIndex
  }
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

struct ConnectionIndexSummary: Identifiable, Equatable, Sendable {
  var id: UUID { connectionID }
  let connectionID: UUID
  let scopeCount: Int
  let objectCount: Int
  let indexedAt: Date?
  let isStale: Bool
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

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.connectionID == rhs.connectionID
      && lhs.bucket.utf8.elementsEqual(rhs.bucket.utf8)
      && lhs.prefix.utf8.elementsEqual(rhs.prefix.utf8)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(connectionID)
    hasher.combine(Data(bucket.utf8))
    hasher.combine(Data(prefix.utf8))
  }
}

enum CollisionPolicy: String, CaseIterable, Identifiable, Sendable {
  case cancel
  case replace
  case keepBoth

  var id: Self { self }

  var label: String {
    switch self {
    case .cancel: "Cancel"
    case .replace: "Replace"
    case .keepBoth: "Keep Both"
    }
  }
}

protocol WorkbenchServing: Sendable {
  func loadConnections() async throws -> [ConnectionRow]
  func saveConnection(_ draft: ConnectionDraft) async throws -> ConnectionRow
  func duplicateConnection(id: UUID) async throws -> ConnectionRow
  func removeConnection(id: UUID) async throws
  func testConnection(_ draft: ConnectionDraft) async throws
  func listBuckets(connectionID: UUID) async throws -> [BucketRow]
  func listObjects(at location: ObjectLocation, continuationToken: String?) async throws
    -> ObjectPage
  func searchObjects(
    at location: ObjectLocation, query: String, continuationToken: String?, refreshIndex: Bool
  ) async throws -> ObjectSearchPage
  func cancelObjectSearch(at location: ObjectLocation) async
  func objectDetails(at location: ObjectLocation, object: ObjectRow) async throws -> ObjectDetails
  func upload(files: [URL], to location: ObjectLocation, collisionPolicy: CollisionPolicy) async throws
  func download(
    objects: [ObjectRow], from location: ObjectLocation, to directory: URL,
    collisionPolicy: CollisionPolicy
  ) async throws
  func download(object: ObjectRow, from location: ObjectLocation, to destination: URL) async throws
  func delete(objects: [ObjectRow], from location: ObjectLocation) async throws
  func move(
    object: ObjectRow, from location: ObjectLocation, toKey: String,
    collisionPolicy: CollisionPolicy
  ) async throws
  func presignedURL(for object: ObjectRow, at location: ObjectLocation, expiresIn: Duration)
    async throws -> URL
  func unsignedURL(for object: ObjectRow, at location: ObjectLocation) async throws -> URL
  func searchIndexSummaries() async throws -> [ConnectionIndexSummary]
  func clearSearchIndex(connectionID: UUID) async throws
  func downloadForPreview(object: ObjectRow, at location: ObjectLocation) async throws -> URL
  func transfers() async -> [TransferRow]
  func cancelTransfer(id: UUID) async
  func retryTransfer(id: UUID) async
}

extension WorkbenchServing {
  func unsignedURL(for object: ObjectRow, at location: ObjectLocation) async throws -> URL {
    throw WorkbenchUIError.serviceUnavailable
  }

  func searchIndexSummaries() async throws -> [ConnectionIndexSummary] { [] }
  func clearSearchIndex(connectionID: UUID) async throws {}
}

actor PlaceholderWorkbenchService: WorkbenchServing {
  func loadConnections() async throws -> [ConnectionRow] { [] }
  func saveConnection(_ draft: ConnectionDraft) async throws -> ConnectionRow {
    guard draft.validationMessage == nil, let endpoint = draft.endpointURL else {
      throw WorkbenchUIError.invalidConnection
    }
    return ConnectionRow(
      id: draft.id,
      name: draft.name,
      endpoint: endpoint,
      accessPath: draft.accessPath.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      colorHex: draft.colorHex,
      region: draft.region,
      addressingMode: draft.addressingMode,
      tlsPolicy: draft.tlsPolicy,
      customCAURL: draft.customCAURL
    )
  }
  func duplicateConnection(id: UUID) async throws -> ConnectionRow {
    throw WorkbenchUIError.serviceUnavailable
  }
  func removeConnection(id: UUID) async throws {}
  func testConnection(_ draft: ConnectionDraft) async throws {
    throw WorkbenchUIError.serviceUnavailable
  }
  func listBuckets(connectionID: UUID) async throws -> [BucketRow] {
    throw WorkbenchUIError.serviceUnavailable
  }
  func listObjects(at location: ObjectLocation, continuationToken: String?) async throws
    -> ObjectPage
  { throw WorkbenchUIError.serviceUnavailable }
  func searchObjects(
    at location: ObjectLocation, query: String, continuationToken: String?, refreshIndex: Bool
  ) async throws -> ObjectSearchPage { throw WorkbenchUIError.serviceUnavailable }
  func cancelObjectSearch(at location: ObjectLocation) async {}
  func objectDetails(at location: ObjectLocation, object: ObjectRow) async throws -> ObjectDetails {
    throw WorkbenchUIError.serviceUnavailable
  }
  func upload(files: [URL], to location: ObjectLocation, collisionPolicy: CollisionPolicy) async throws {
    throw WorkbenchUIError.serviceUnavailable
  }
  func download(
    objects: [ObjectRow], from location: ObjectLocation, to directory: URL,
    collisionPolicy: CollisionPolicy
  ) async throws
  { throw WorkbenchUIError.serviceUnavailable }
  func download(object: ObjectRow, from location: ObjectLocation, to destination: URL) async throws {
    throw WorkbenchUIError.serviceUnavailable
  }
  func delete(objects: [ObjectRow], from location: ObjectLocation) async throws {
    throw WorkbenchUIError.serviceUnavailable
  }
  func move(
    object: ObjectRow, from location: ObjectLocation, toKey: String,
    collisionPolicy: CollisionPolicy
  ) async throws {
    throw WorkbenchUIError.serviceUnavailable
  }
  func presignedURL(for object: ObjectRow, at location: ObjectLocation, expiresIn: Duration)
    async throws -> URL
  { throw WorkbenchUIError.serviceUnavailable }
  func unsignedURL(for object: ObjectRow, at location: ObjectLocation) async throws -> URL {
    throw WorkbenchUIError.serviceUnavailable
  }
  func searchIndexSummaries() async throws -> [ConnectionIndexSummary] { [] }
  func clearSearchIndex(connectionID: UUID) async throws {}
  func downloadForPreview(object: ObjectRow, at location: ObjectLocation) async throws -> URL {
    throw WorkbenchUIError.serviceUnavailable
  }
  func transfers() async -> [TransferRow] { [] }
  func cancelTransfer(id: UUID) async {}
  func retryTransfer(id: UUID) async {}
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Color {
  init(connectionHex hex: String) {
    let value = UInt64(hex.dropFirst(), radix: 16) ?? 0x0A84FF
    self.init(
      .sRGB,
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255,
      opacity: 1
    )
  }

  var connectionHex: String {
    guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#0A84FF" }
    return String(
      format: "#%02X%02X%02X",
      Int((color.redComponent * 255).rounded()),
      Int((color.greenComponent * 255).rounded()),
      Int((color.blueComponent * 255).rounded())
    )
  }
}

enum WorkbenchUIError: LocalizedError {
  case invalidConnection
  case invalidExportFilename
  case serviceUnavailable
  case staleFilePromise

  var errorDescription: String? {
    switch self {
    case .invalidConnection: "The connection settings are invalid."
    case .invalidExportFilename:
      "This object name can’t be exported as a macOS file. Rename the object first."
    case .serviceUnavailable: "The S3 service is not configured yet."
    case .staleFilePromise:
      "The location or selection changed before the drop completed. Drag the object again."
    }
  }
}
