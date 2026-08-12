import Foundation

public enum S3AddressingStyle: String, Codable, CaseIterable, Sendable {
    case automatic
    case path
    case virtualHosted
}

public enum TLSVerification: String, Codable, CaseIterable, Sendable {
    case systemDefault
    case customCertificate
    case disabled
}

public struct ConnectionProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var endpoint: URL
    public var region: String
    public var addressingStyle: S3AddressingStyle
    public var tlsVerification: TLSVerification
    public var customCACertificateURL: URL?

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: URL,
        region: String = "us-east-1",
        addressingStyle: S3AddressingStyle = .automatic,
        tlsVerification: TLSVerification = .systemDefault,
        customCACertificateURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.region = region
        self.addressingStyle = addressingStyle
        self.tlsVerification = tlsVerification
        self.customCACertificateURL = customCACertificateURL
    }

    public func validated() throws -> Self {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw S3ServiceError.invalidConfiguration("Connection name is required.")
        }
        guard let scheme = endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme), endpoint.host != nil else {
            throw S3ServiceError.invalidConfiguration("Endpoint must be an absolute HTTP or HTTPS URL.")
        }
        guard endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw S3ServiceError.invalidConfiguration("Endpoint cannot contain credentials, a query, or a fragment.")
        }
        guard !trimmedRegion.isEmpty,
              trimmedRegion.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else {
            throw S3ServiceError.invalidConfiguration("Region contains unsupported characters.")
        }
        if tlsVerification == .customCertificate {
            guard let customCACertificateURL, customCACertificateURL.isFileURL else {
                throw S3ServiceError.invalidConfiguration("A local CA certificate file is required for custom TLS verification.")
            }
        }
        var copy = self
        copy.name = trimmedName
        copy.region = trimmedRegion
        return copy
    }
}

public struct S3Credentials: Sendable {
    public let accessKey: String
    public let secretKey: String
    public let sessionToken: String?

    public init(accessKey: String, secretKey: String, sessionToken: String? = nil) throws {
        guard !accessKey.isEmpty, !secretKey.isEmpty else {
            throw S3ServiceError.invalidConfiguration("Access key and secret key are required.")
        }
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.sessionToken = sessionToken
    }
}

extension S3Credentials: CustomDebugStringConvertible {
    public var debugDescription: String { "S3Credentials(accessKey: <redacted>, secretKey: <redacted>)" }
}

public struct S3Bucket: Hashable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let creationDate: Date?
    public let region: String?

    public init(name: String, creationDate: Date? = nil, region: String? = nil) {
        self.name = name
        self.creationDate = creationDate
        self.region = region
    }
}

public struct S3Object: Hashable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let size: Int64
    public let lastModified: Date?
    public let eTag: String?
    public let storageClass: String?

    public init(key: String, size: Int64, lastModified: Date?, eTag: String?, storageClass: String?) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.eTag = eTag
        self.storageClass = storageClass
    }
}

public struct S3ObjectPage: Sendable {
    public let prefixes: [String]
    public let objects: [S3Object]
    public let nextContinuationToken: String?
    public let keyCount: Int

    public init(prefixes: [String], objects: [S3Object], nextContinuationToken: String?, keyCount: Int) {
        self.prefixes = prefixes
        self.objects = objects
        self.nextContinuationToken = nextContinuationToken
        self.keyCount = keyCount
    }
}

public struct S3ObjectMetadata: Sendable {
    public let key: String
    public let size: Int64
    public let lastModified: Date?
    public let eTag: String?
    public let contentType: String?
    public let userMetadata: [String: String]
    public let headers: [String: String]

    public init(
        key: String,
        size: Int64,
        lastModified: Date?,
        eTag: String?,
        contentType: String?,
        userMetadata: [String: String],
        headers: [String: String]
    ) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.eTag = eTag
        self.contentType = contentType
        self.userMetadata = userMetadata
        self.headers = headers
    }
}

public struct ConnectionTestResult: Sendable {
    public let bucketCount: Int

    public init(bucketCount: Int) {
        self.bucketCount = bucketCount
    }
}

public struct TransferProgress: Sendable {
    public let bytesTransferred: Int64
    public let totalBytes: Int64

    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(bytesTransferred) / Double(totalBytes)) : 0
    }

    public init(bytesTransferred: Int64, totalBytes: Int64) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }
}

public enum PresignedOperation: String, Sendable {
    case download
    case upload
}

public struct S3PresignedRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let expiresAt: Date

    public init(url: URL, method: String, headers: [String: String], expiresAt: Date) {
        self.url = url
        self.method = method
        self.headers = headers
        self.expiresAt = expiresAt
    }
}

public enum S3ServiceError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case authenticationFailed
    case accessDenied
    case notFound
    case conflict(String)
    case cancelled
    case unsupported(String)
    case transport(String)
    case service(String)
}

extension S3ServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .conflict(let message), .unsupported(let message),
             .transport(let message), .service(let message): message
        case .authenticationFailed: "Authentication failed. Check the access key, secret, region, and clock."
        case .accessDenied: "The credentials do not permit this operation."
        case .notFound: "The requested bucket or object was not found."
        case .cancelled: "The operation was cancelled."
        }
    }
}
