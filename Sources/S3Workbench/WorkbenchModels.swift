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

struct ConnectionDraft: Identifiable, Sendable {
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
  func listObjects(at location: ObjectLocation, query: String, continuationToken: String?)
    async throws -> ObjectPage
  func objectDetails(at location: ObjectLocation, object: ObjectRow) async throws -> ObjectDetails
  func upload(files: [URL], to location: ObjectLocation, collisionPolicy: CollisionPolicy) async throws
  func download(
    objects: [ObjectRow], from location: ObjectLocation, to directory: URL,
    collisionPolicy: CollisionPolicy
  ) async throws
  func delete(objects: [ObjectRow], from location: ObjectLocation) async throws
  func move(
    object: ObjectRow, from location: ObjectLocation, toKey: String,
    collisionPolicy: CollisionPolicy
  ) async throws
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
  func listObjects(at location: ObjectLocation, query: String, continuationToken: String?)
    async throws -> ObjectPage
  { throw WorkbenchUIError.serviceUnavailable }
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
  case serviceUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidConnection: "The connection settings are invalid."
    case .serviceUnavailable: "The S3 service is not configured yet."
    }
  }
}
