import Foundation

public typealias TransferProgressHandler = @Sendable (TransferProgress) -> Void

public protocol S3Service: Sendable {
    func testConnection() async throws -> ConnectionTestResult
    func listBuckets() async throws -> [S3Bucket]
    func listObjects(
        bucket: String,
        prefix: String,
        continuationToken: String?,
        pageSize: Int
    ) async throws -> S3ObjectPage
    func metadata(bucket: String, key: String) async throws -> S3ObjectMetadata
    func deleteObject(bucket: String, key: String) async throws
    func renameObject(bucket: String, sourceKey: String, destinationKey: String) async throws
    func presignedRequest(
        bucket: String,
        key: String,
        operation: PresignedOperation,
        expiresIn: TimeInterval,
        contentType: String?
    ) async throws -> S3PresignedRequest
    func uploadFile(
        from sourceURL: URL,
        bucket: String,
        key: String,
        contentType: String?,
        metadata: [String: String],
        progress: TransferProgressHandler?
    ) async throws
    func downloadFile(
        bucket: String,
        key: String,
        to destinationURL: URL,
        overwrite: Bool,
        progress: TransferProgressHandler?
    ) async throws
}

public extension S3Service {
    func listObjects(
        bucket: String,
        prefix: String = "",
        continuationToken: String? = nil,
        pageSize: Int = 1_000
    ) async throws -> S3ObjectPage {
        try await listObjects(
            bucket: bucket,
            prefix: prefix,
            continuationToken: continuationToken,
            pageSize: pageSize
        )
    }

    func presignedRequest(
        bucket: String,
        key: String,
        operation: PresignedOperation = .download,
        expiresIn: TimeInterval = 3_600,
        contentType: String? = nil
    ) async throws -> S3PresignedRequest {
        try await presignedRequest(
            bucket: bucket,
            key: key,
            operation: operation,
            expiresIn: expiresIn,
            contentType: contentType
        )
    }

    func uploadFile(
        from sourceURL: URL,
        bucket: String,
        key: String,
        contentType: String? = nil,
        metadata: [String: String] = [:],
        progress: TransferProgressHandler? = nil
    ) async throws {
        try await uploadFile(
            from: sourceURL,
            bucket: bucket,
            key: key,
            contentType: contentType,
            metadata: metadata,
            progress: progress
        )
    }

    func downloadFile(
        bucket: String,
        key: String,
        to destinationURL: URL,
        overwrite: Bool = false,
        progress: TransferProgressHandler? = nil
    ) async throws {
        try await downloadFile(
            bucket: bucket,
            key: key,
            to: destinationURL,
            overwrite: overwrite,
            progress: progress
        )
    }
}

public struct MultipartUploadPlan: Equatable, Sendable {
    public static let minimumPartSize: Int64 = 5 * 1_024 * 1_024
    public static let maximumPartSize: Int64 = 5 * 1_024 * 1_024 * 1_024
    public static let maximumPartCount = 10_000

    public let fileSize: Int64
    public let partSize: Int64
    public let partCount: Int

    public init(fileSize: Int64, preferredPartSize: Int64 = 16 * 1_024 * 1_024) throws {
        guard fileSize > 0 else {
            throw S3ServiceError.invalidConfiguration("Multipart upload requires a non-empty file.")
        }
        let required = (fileSize + Int64(Self.maximumPartCount) - 1) / Int64(Self.maximumPartCount)
        let mib = Int64(1_024 * 1_024)
        let roundedRequired = ((required + mib - 1) / mib) * mib
        let selected = max(Self.minimumPartSize, preferredPartSize, roundedRequired)
        guard selected <= Self.maximumPartSize else {
            throw S3ServiceError.unsupported("File exceeds the S3 multipart upload limits.")
        }
        let count = Int((fileSize + selected - 1) / selected)
        guard count <= Self.maximumPartCount else {
            throw S3ServiceError.unsupported("File requires more than 10,000 multipart upload parts.")
        }
        self.fileSize = fileSize
        self.partSize = selected
        self.partCount = count
    }
}
