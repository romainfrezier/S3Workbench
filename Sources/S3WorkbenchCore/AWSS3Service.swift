import AWSS3
import AWSSDKIdentity
import AWSClientRuntime
import ClientRuntime
import Foundation
import Security
import SmithySwiftNIO

public actor AWSS3Service: S3Service {
    private static let multipartThreshold: Int64 = 8 * 1_024 * 1_024
    private static let maximumBufferedPartSize: Int64 = 64 * 1_024 * 1_024

    public let profile: ConnectionProfile
    private let credentials: S3Credentials
    private let client: S3Client

    public init(profile: ConnectionProfile, credentials: S3Credentials) throws {
        let profile = try profile.validated()
        let httpConfiguration: HttpClientConfiguration?
        let httpEngine: SwiftNIOHTTPClient?
        switch profile.tlsVerification {
        case .systemDefault:
            httpConfiguration = nil
            httpEngine = nil
        case .customCertificate:
            guard let certificateURL = profile.customCACertificateURL else {
                throw S3ServiceError.invalidConfiguration("A custom CA certificate file is required.")
            }
            guard FileManager.default.isReadableFile(atPath: certificateURL.path) else {
                throw S3ServiceError.invalidConfiguration("The custom CA certificate is not readable.")
            }
            guard isValidCertificateFile(certificateURL) else {
                throw S3ServiceError.invalidConfiguration("The custom CA file does not contain a valid PEM certificate.")
            }
            let configuration = HttpClientConfiguration(
                tlsConfiguration: SwiftNIOHTTPClientTLSOptions(certificate: certificateURL.path)
            )
            httpConfiguration = configuration
            httpEngine = SwiftNIOHTTPClient(httpClientConfiguration: configuration)
        case .disabled:
            throw S3ServiceError.unsupported(
                "Disabling TLS verification is not available in this build. Use HTTP for trusted local development or install a trusted certificate."
            )
        }
        let identity = AWSCredentialIdentity(
            accessKey: credentials.accessKey,
            secret: credentials.secretKey,
            sessionToken: credentials.sessionToken
        )
        let resolver = StaticAWSCredentialIdentityResolver(identity)
        let forcePathStyle: Bool? = switch profile.addressingStyle {
        case .automatic: true
        case .path: true
        case .virtualHosted: false
        }
        let config = try S3Client.S3ClientConfig(
            awsCredentialIdentityResolver: resolver,
            maxAttempts: 4,
            requestChecksumCalculation: .whenRequired,
            responseChecksumValidation: .whenRequired,
            region: profile.region,
            signingRegion: profile.region,
            forcePathStyle: forcePathStyle,
            endpoint: profile.endpoint.absoluteString,
            httpClientEngine: httpEngine,
            httpClientConfiguration: httpConfiguration
        )
        self.profile = profile
        self.credentials = credentials
        client = S3Client(config: config)
    }

    public func testConnection() async throws -> ConnectionTestResult {
        if let accessPath = try profile.resolvedAccessPath() {
            _ = try await listObjects(
                bucket: accessPath.bucket,
                prefix: accessPath.prefix,
                continuationToken: nil,
                pageSize: 1
            )
            return ConnectionTestResult(bucketCount: 1)
        }
        return ConnectionTestResult(bucketCount: try await listBuckets().count)
    }

    public func listBuckets() async throws -> [S3Bucket] {
        try await mapped {
            var result: [S3Bucket] = []
            var token: String?
            var seenTokens = Set<String>()
            repeat {
                try Task.checkCancellation()
                let output = try await client.listBuckets(input: ListBucketsInput(continuationToken: token))
                result.append(contentsOf: (output.buckets ?? []).compactMap { bucket in
                    bucket.name.map { S3Bucket(name: $0, creationDate: bucket.creationDate, region: bucket.bucketRegion) }
                })
                token = output.continuationToken
                if let token, !seenTokens.insert(token).inserted {
                    throw S3ServiceError.service("The server returned a repeated bucket pagination token.")
                }
            } while token != nil
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public func listObjects(
        bucket: String,
        prefix: String,
        continuationToken: String?,
        pageSize: Int
    ) async throws -> S3ObjectPage {
        try validateBucket(bucket)
        guard (1...1_000).contains(pageSize) else {
            throw S3ServiceError.invalidConfiguration("Object page size must be between 1 and 1,000.")
        }
        return try await mapped {
            let output = try await client.listObjectsV2(input: ListObjectsV2Input(
                bucket: bucket,
                continuationToken: continuationToken,
                delimiter: "/",
                encodingType: .url,
                maxKeys: pageSize,
                prefix: prefix
            ))
            let encoded = output.encodingType == .url
            let prefixes = (output.commonPrefixes ?? []).compactMap(\.prefix).map { encoded ? percentDecoded($0) : $0 }
            let objects = (output.contents ?? []).compactMap { object -> S3Object? in
                guard let key = object.key else { return nil }
                return S3Object(
                    key: encoded ? percentDecoded(key) : key,
                    size: Int64(object.size ?? 0),
                    lastModified: object.lastModified,
                    eTag: object.eTag,
                    storageClass: object.storageClass?.rawValue
                )
            }
            return S3ObjectPage(
                prefixes: prefixes,
                objects: objects,
                nextContinuationToken: output.isTruncated == true ? output.nextContinuationToken : nil,
                keyCount: output.keyCount ?? prefixes.count + objects.count
            )
        }
    }

    public func metadata(bucket: String, key: String) async throws -> S3ObjectMetadata {
        try validate(bucket: bucket, key: key)
        return try await mapped {
            let output = try await client.headObject(input: HeadObjectInput(bucket: bucket, key: key))
            var headers: [String: String] = [:]
            headers.set("Content-Type", output.contentType)
            headers.set("Content-Length", output.contentLength.map(String.init))
            headers.set("ETag", output.eTag)
            headers.set("Last-Modified", output.lastModified.map(ISO8601DateFormatter().string(from:)))
            headers.set("Cache-Control", output.cacheControl)
            headers.set("Content-Disposition", output.contentDisposition)
            headers.set("Content-Encoding", output.contentEncoding)
            headers.set("Storage-Class", output.storageClass?.rawValue)
            headers.set("Version-ID", output.versionId)
            return S3ObjectMetadata(
                key: key,
                size: Int64(output.contentLength ?? 0),
                lastModified: output.lastModified,
                eTag: output.eTag,
                contentType: output.contentType,
                userMetadata: output.metadata ?? [:],
                headers: headers
            )
        }
    }

    public func deleteObject(bucket: String, key: String) async throws {
        try validate(bucket: bucket, key: key)
        try await mapped {
            _ = try await client.deleteObject(input: DeleteObjectInput(bucket: bucket, key: key))
        }
    }

    public func renameObject(bucket: String, sourceKey: String, destinationKey: String) async throws {
        try validate(bucket: bucket, key: sourceKey)
        try validate(bucket: bucket, key: destinationKey)
        guard sourceKey != destinationKey else { return }
        try await mapped {
            let source = try await client.headObject(input: HeadObjectInput(bucket: bucket, key: sourceKey))
            guard Int64(source.contentLength ?? 0) <= 5_000_000_000 else {
                throw S3ServiceError.unsupported("Renaming objects larger than 5 GB requires multipart copy.")
            }
            guard let sourceETag = source.eTag else {
                throw S3ServiceError.conflict("The source did not provide a stable ETag and cannot be moved safely.")
            }
            _ = try await client.copyObject(input: CopyObjectInput(
                bucket: bucket,
                copySource: percentEncodedCopySource(bucket: bucket, key: sourceKey),
                copySourceIfMatch: sourceETag,
                ifNoneMatch: "*",
                key: destinationKey,
                metadataDirective: .copy
            ))
            try Task.checkCancellation()
            _ = try await client.deleteObject(input: DeleteObjectInput(
                bucket: bucket,
                ifMatch: sourceETag,
                key: sourceKey
            ))
        }
    }

    public func presignedRequest(
        bucket: String,
        key: String,
        operation: PresignedOperation,
        expiresIn: TimeInterval,
        contentType: String?
    ) async throws -> S3PresignedRequest {
        try validate(bucket: bucket, key: key)
        guard (1...604_800).contains(expiresIn) else {
            throw S3ServiceError.invalidConfiguration("Presigned URL lifetime must be between 1 second and 7 days.")
        }
        return try SigV4Presigner.presign(
            profile: profile,
            credentials: credentials,
            bucket: bucket,
            key: key,
            operation: operation,
            expiresIn: Int(expiresIn),
            contentType: contentType
        )
    }

    public func uploadFile(
        from sourceURL: URL,
        bucket: String,
        key: String,
        contentType: String?,
        metadata: [String: String],
        progress: TransferProgressHandler?
    ) async throws {
        try validate(bucket: bucket, key: key)
        try validateMetadata(metadata)
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw S3ServiceError.invalidConfiguration("Upload source must be a readable regular file.")
        }
        let total = Int64(fileSize)
        progress?(TransferProgress(bytesTransferred: 0, totalBytes: total))
        if total < Self.multipartThreshold {
            try await mapped {
                try Task.checkCancellation()
                let data = try Data(contentsOf: sourceURL)
                _ = try await client.putObject(input: PutObjectInput(
                    body: .data(data),
                    bucket: bucket,
                    contentLength: data.count,
                    contentType: contentType,
                    key: key,
                    metadata: metadata
                ))
            }
            progress?(TransferProgress(bytesTransferred: total, totalBytes: total))
            return
        }
        try await multipartUpload(
            sourceURL: sourceURL,
            fileSize: total,
            bucket: bucket,
            key: key,
            contentType: contentType,
            metadata: metadata,
            progress: progress
        )
    }

    public func downloadFile(
        bucket: String,
        key: String,
        to destinationURL: URL,
        overwrite: Bool,
        progress: TransferProgressHandler?
    ) async throws {
        try validate(bucket: bucket, key: key)
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).download")
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: tempURL) }
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw S3ServiceError.transport("Could not create the download destination.")
        }
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }
        try await mapped {
            let output = try await client.getObject(input: GetObjectInput(bucket: bucket, key: key))
            let total = Int64(output.contentLength ?? 0)
            var written: Int64 = 0
            progress?(TransferProgress(bytesTransferred: 0, totalBytes: total))
            guard let body = output.body else {
                throw S3ServiceError.service("The server returned an empty download body.")
            }
            switch body {
            case .data(let data):
                if let data {
                    try handle.write(contentsOf: data)
                    written = Int64(data.count)
                    progress?(TransferProgress(bytesTransferred: written, totalBytes: total))
                }
            case .stream(let stream):
                while let chunk = try await stream.readAsync(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    progress?(TransferProgress(bytesTransferred: written, totalBytes: total))
                }
                stream.close()
            case .noStream:
                throw S3ServiceError.service("The server returned an empty download body.")
            }
        }
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard overwrite else {
                throw S3ServiceError.conflict("A file already exists at the download destination.")
            }
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        }
        completed = true
    }

    private func multipartUpload(
        sourceURL: URL,
        fileSize: Int64,
        bucket: String,
        key: String,
        contentType: String?,
        metadata: [String: String],
        progress: TransferProgressHandler?
    ) async throws {
        let plan = try MultipartUploadPlan(fileSize: fileSize)
        guard plan.partSize <= Self.maximumBufferedPartSize else {
            throw S3ServiceError.unsupported("Files requiring multipart buffers larger than 64 MiB are not supported in this build.")
        }
        let uploadID = try await mapped {
            let output = try await client.createMultipartUpload(input: CreateMultipartUploadInput(
                bucket: bucket,
                contentType: contentType,
                key: key,
                metadata: metadata
            ))
            guard let uploadID = output.uploadId else {
                throw S3ServiceError.service("The server did not return a multipart upload ID.")
            }
            return uploadID
        }
        do {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            var completedParts: [S3ClientTypes.CompletedPart] = []
            var transferred: Int64 = 0
            for number in 1...plan.partCount {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: Int(plan.partSize)), !data.isEmpty else {
                    throw S3ServiceError.transport("Upload source ended before all multipart parts were read.")
                }
                let output = try await mapped {
                    try await client.uploadPart(input: UploadPartInput(
                        body: .data(data),
                        bucket: bucket,
                        contentLength: data.count,
                        key: key,
                        partNumber: number,
                        uploadId: uploadID
                    ))
                }
                guard let eTag = output.eTag else {
                    throw S3ServiceError.service("The server did not return an ETag for multipart part \(number).")
                }
                completedParts.append(S3ClientTypes.CompletedPart(eTag: eTag, partNumber: number))
                transferred += Int64(data.count)
                progress?(TransferProgress(bytesTransferred: transferred, totalBytes: fileSize))
            }
            try await mapped {
                _ = try await client.completeMultipartUpload(input: CompleteMultipartUploadInput(
                    bucket: bucket,
                    key: key,
                    multipartUpload: S3ClientTypes.CompletedMultipartUpload(parts: completedParts),
                    uploadId: uploadID
                ))
            }
        } catch {
            let abortClient = client
            _ = await Task.detached {
                try? await abortClient.abortMultipartUpload(input: AbortMultipartUploadInput(
                    bucket: bucket,
                    key: key,
                    uploadId: uploadID
                ))
            }.value
            throw map(error)
        }
    }

    private func mapped<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw map(error)
        }
    }

    private func map(_ error: Error) -> S3ServiceError {
        if let error = error as? S3ServiceError { return error }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let serviceError = error as? any AWSServiceError,
           let httpError = error as? any HTTPError {
            let code = serviceError.errorCode?.lowercased() ?? ""
            if code.contains("invalidaccesskey") { return .authenticationFailed }
            if code.contains("signaturedoesnotmatch") { return .signatureMismatch }
            if code.contains("authorizationheadermalformed") || code.contains("incorrectregion") {
                return .wrongRegion
            }
            switch httpError.httpResponse.statusCode.rawValue {
            case 401: return .authenticationFailed
            case 403: return .accessDenied
            case 404: return .notFound
            case 409: return .conflict("The destination already exists.")
            default: break
            }
        }
        if error is NoSuchBucket || error is NoSuchKey || error is AWSS3.NotFound { return .notFound }
        if error is AccessDenied { return .accessDenied }
        if error is BucketAlreadyExists || error is BucketAlreadyOwnedByYou {
            return .conflict("A bucket with that name already exists.")
        }
        let typeName = String(describing: type(of: error))
        let message = redacted(error.localizedDescription)
        let diagnostic = "\(typeName) \(message)".lowercased()
        if typeName.contains("InvalidAccessKey") { return .authenticationFailed }
        if typeName.contains("SignatureDoesNotMatch") || diagnostic.contains("signaturedoesnotmatch") {
            return .signatureMismatch
        }
        if diagnostic.contains("authorizationheadermalformed") || diagnostic.contains("incorrect region") {
            return .wrongRegion
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .secureConnectionFailed,
                 .clientCertificateRejected, .clientCertificateRequired:
                return .tlsFailure
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .networkConnectionLost, .timedOut:
                return .networkUnavailable
            default: break
            }
        }
        if diagnostic.contains("certificate") || diagnostic.contains("tls") {
            return .tlsFailure
        }
        if diagnostic.contains("connection refused") || diagnostic.contains("network is unreachable") {
            return .networkUnavailable
        }
        return .service(message.isEmpty ? "The S3 request failed." : message)
    }

    private func redacted(_ message: String) -> String {
        var result = message
            .replacingOccurrences(of: credentials.accessKey, with: "<redacted>")
            .replacingOccurrences(of: credentials.secretKey, with: "<redacted>")
        if let token = credentials.sessionToken, !token.isEmpty {
            result = result.replacingOccurrences(of: token, with: "<redacted>")
        }
        for name in ["X-Amz-Signature", "X-Amz-Credential", "X-Amz-Security-Token"] {
            result = result.replacingOccurrences(
                of: "(?i)([?&]\(name)=)[^&\\s]+",
                with: "$1<redacted>",
                options: .regularExpression
            )
        }
        result = result.replacingOccurrences(
            of: "(?i)(Authorization:)[^\\r\\n]+",
            with: "$1 <redacted>",
            options: .regularExpression
        )
        return result
    }

    private func validate(bucket: String, key: String) throws {
        try validateBucket(bucket)
        guard !key.isEmpty, key.utf8.count <= 1_024 else {
            throw S3ServiceError.invalidConfiguration("Object key must contain 1 to 1,024 UTF-8 bytes.")
        }
    }

    private func validateBucket(_ bucket: String) throws {
        guard !bucket.isEmpty, !bucket.contains("/"), !bucket.contains("\0") else {
            throw S3ServiceError.invalidConfiguration("Bucket name is invalid.")
        }
    }

    private func validateMetadata(_ metadata: [String: String]) throws {
        guard metadata.allSatisfy({ !$0.key.isEmpty && !$0.key.contains(where: { $0 == "\r" || $0 == "\n" })
            && !$0.value.contains(where: { $0 == "\r" || $0 == "\n" }) }) else {
            throw S3ServiceError.invalidConfiguration("Metadata cannot contain empty names or line breaks.")
        }
    }
}

private func percentDecoded(_ value: String) -> String {
    // MinIO uses application/x-www-form-urlencoded spelling for encoding-type=url,
    // while AWS uses percent encoding. Accept both without touching literal keys when
    // the server did not declare URL encoding.
    value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
}

private func isValidCertificateFile(_ url: URL) -> Bool {
    guard let fileData = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
    guard let text = String(data: fileData, encoding: .utf8),
          let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
          let end = text.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<text.endIndex) else {
        return false
    }
    let base64 = text[start.upperBound..<end.lowerBound]
        .filter { !$0.isWhitespace }
    guard let decoded = Data(base64Encoded: base64) else { return false }
    return SecCertificateCreateWithData(nil, decoded as CFData) != nil
}

private func percentEncodedCopySource(bucket: String, key: String) -> String {
    let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/".utf8)
    return ("/\(bucket)/\(key)").utf8.map { byte in
        unreserved.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
    }.joined()
}

private extension Dictionary where Key == String, Value == String {
    mutating func set(_ key: String, _ value: String?) {
        if let value { self[key] = value }
    }
}
