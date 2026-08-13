import CryptoKit
import Foundation
import Testing
@testable import S3WorkbenchCore

@Test func minIOEndToEndS3Compatibility() async throws {
    guard let fixture = try IntegrationFixture.environment() else { return }
    let service = try AWSS3Service(profile: fixture.profile, credentials: fixture.credentials)
    let runPrefix = "integration/\(UUID().uuidString)/"
    let unicodeKey = "\(runPrefix)folder with spaces/ünicode-雪 #?.txt"
    let pageKeyA = "\(runPrefix)page-a.txt"
    let pageKeyB = "\(runPrefix)page-b.txt"
    let renamedKey = "\(runPrefix)renamed object.txt"
    let largeKey = "\(runPrefix)multipart-20MiB.bin"
    var remoteKeys = [unicodeKey, pageKeyA, pageKeyB, renamedKey, largeKey]
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("S3Workbench-MinIO-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    do {
        let automaticService = try AWSS3Service(
            profile: ConnectionProfile(
                name: "Automatic MinIO",
                endpoint: fixture.profile.endpoint,
                region: fixture.profile.region,
                addressingStyle: .automatic
            ),
            credentials: fixture.credentials
        )
        #expect(try await automaticService.listBuckets().contains { $0.name == fixture.bucket })

        let rejectedService = try AWSS3Service(
            profile: fixture.profile,
            credentials: S3Credentials(accessKey: "invalid-access", secretKey: "invalid-secret")
        )
        await #expect(throws: (any Error).self) {
            _ = try await rejectedService.listBuckets()
        }

        let connection = try await service.testConnection()
        #expect(connection.bucketCount > 0)
        let buckets = try await service.listBuckets()
        #expect(buckets.contains { $0.name == fixture.bucket })

        let payload = Data("S3Workbench integration: é space 雪 / ? #".utf8)
        let source = directory.appendingPathComponent("small.txt")
        try payload.write(to: source)
        try await service.uploadFile(
            from: source,
            bucket: fixture.bucket,
            key: unicodeKey,
            contentType: "text/plain; charset=utf-8",
            metadata: ["integration": "unicode-space"],
            progress: nil
        )
        for key in [pageKeyA, pageKeyB] {
            try await service.uploadFile(
                from: source,
                bucket: fixture.bucket,
                key: key,
                contentType: "text/plain",
                metadata: [:],
                progress: nil
            )
        }

        let directService = try AWSS3Service(
            profile: ConnectionProfile(
                name: "Direct path MinIO",
                endpoint: fixture.profile.endpoint,
                accessPath: "/\(fixture.bucket)/\(runPrefix)",
                region: fixture.profile.region,
                addressingStyle: .path
            ),
            credentials: fixture.credentials
        )
        #expect(try await directService.testConnection().bucketCount == 1)

        if let restrictedCredentials = fixture.restrictedCredentials {
            let restrictedService = try AWSS3Service(
                profile: fixture.profile,
                credentials: restrictedCredentials
            )
            let visibleBuckets = try await restrictedService.listBuckets()
            #expect(visibleBuckets.contains { $0.name == fixture.bucket })
            #expect(!visibleBuckets.contains { $0.name == "\(fixture.bucket)-forbidden" })
            await #expect(throws: S3ServiceError.accessDenied) {
                _ = try await restrictedService.listObjects(
                    bucket: "\(fixture.bucket)-forbidden",
                    prefix: "",
                    continuationToken: nil,
                    pageSize: 1
                )
            }
            let restrictedDirectService = try AWSS3Service(
                profile: ConnectionProfile(
                    name: "Restricted direct path",
                    endpoint: fixture.profile.endpoint,
                    accessPath: "/\(fixture.bucket)/\(runPrefix)",
                    region: fixture.profile.region,
                    addressingStyle: .path
                ),
                credentials: restrictedCredentials
            )
            #expect(try await restrictedDirectService.testConnection().bucketCount == 1)
            _ = try await restrictedDirectService.listObjects(
                bucket: fixture.bucket,
                prefix: runPrefix,
                continuationToken: nil,
                pageSize: 1
            )
            await #expect(throws: S3ServiceError.accessDenied) {
                _ = try await restrictedDirectService.listObjects(
                    bucket: fixture.bucket,
                    prefix: "outside-restricted-root/",
                    delimiter: nil,
                    continuationToken: nil,
                    pageSize: 1
                )
            }
        }

        let rootPage = try await service.listObjects(
            bucket: fixture.bucket,
            prefix: runPrefix,
            continuationToken: nil,
            pageSize: 1_000
        )
        #expect(rootPage.prefixes.contains("\(runPrefix)folder with spaces/"))
        let folderPage = try await service.listObjects(
            bucket: fixture.bucket,
            prefix: "\(runPrefix)folder with spaces/",
            continuationToken: nil,
            pageSize: 1_000
        )
        #expect(folderPage.objects.contains { $0.key == unicodeKey })

        let firstPage = try await service.listObjects(
            bucket: fixture.bucket,
            prefix: runPrefix,
            continuationToken: nil,
            pageSize: 1
        )
        let continuation = try #require(firstPage.nextContinuationToken)
        let secondPage = try await service.listObjects(
            bucket: fixture.bucket,
            prefix: runPrefix,
            continuationToken: continuation,
            pageSize: 1
        )
        #expect(firstPage.keyCount == 1)
        #expect(secondPage.keyCount == 1)

        var recursiveToken: String?
        var recursivePageNumber = 0
        var recursiveObjectCount = 0
        var matchPage: Int?
        repeat {
            let page = try await service.listObjects(
                bucket: fixture.bucket,
                prefix: "recursive-search/",
                delimiter: nil,
                continuationToken: recursiveToken,
                pageSize: 1_000
            )
            recursivePageNumber += 1
            recursiveObjectCount += page.objects.count
            if page.objects.contains(where: { $0.key.contains("needle") }) {
                matchPage = recursivePageNumber
            }
            recursiveToken = page.nextContinuationToken
        } while recursiveToken != nil
        #expect(recursivePageNumber == 2)
        #expect(recursiveObjectCount == 1_005)
        #expect(matchPage == 2)
        await #expect(throws: (any Error).self) {
            _ = try await service.listObjects(
                bucket: fixture.bucket,
                prefix: "recursive-search/",
                delimiter: nil,
                continuationToken: "not-a-valid-continuation-token",
                pageSize: 1_000
            )
        }

        let metadata = try await service.metadata(bucket: fixture.bucket, key: unicodeKey)
        #expect(metadata.size == payload.count)
        #expect(metadata.contentType == "text/plain; charset=utf-8")
        #expect(metadata.userMetadata["integration"] == "unicode-space")

        let download = directory.appendingPathComponent("small-download.txt")
        try await service.downloadFile(bucket: fixture.bucket, key: unicodeKey, to: download, progress: nil)
        #expect(try Data(contentsOf: download) == payload)
        try Data("stale local file".utf8).write(to: download)
        await #expect(throws: (any Error).self) {
            try await service.downloadFile(
                bucket: fixture.bucket,
                key: unicodeKey,
                to: download,
                overwrite: false,
                progress: nil
            )
        }
        try await service.downloadFile(
            bucket: fixture.bucket,
            key: unicodeKey,
            to: download,
            overwrite: true,
            progress: nil
        )
        #expect(try Data(contentsOf: download) == payload)

        try await service.renameObject(
            bucket: fixture.bucket,
            sourceKey: unicodeKey,
            destinationKey: renamedKey
        )
        remoteKeys.removeAll { $0 == unicodeKey }
        await #expect(throws: S3ServiceError.notFound) {
            _ = try await service.metadata(bucket: fixture.bucket, key: unicodeKey)
        }
        #expect(try await service.metadata(bucket: fixture.bucket, key: renamedKey).size == payload.count)

        let presigned = try await service.presignedRequest(
            bucket: fixture.bucket,
            key: renamedKey,
            operation: .download,
            expiresIn: 60,
            contentType: nil
        )
        var request = URLRequest(url: presigned.url)
        request.httpMethod = presigned.method
        for (name, value) in presigned.headers where name.caseInsensitiveCompare("Host") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (presignedData, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(presignedData == payload)

        let largeSource = directory.appendingPathComponent("large-source.bin")
        guard FileManager.default.createFile(atPath: largeSource.path, contents: nil) else {
            throw S3ServiceError.transport("Could not create multipart test fixture.")
        }
        let handle = try FileHandle(forWritingTo: largeSource)
        try handle.truncate(atOffset: 20 * 1_024 * 1_024)
        try handle.close()
        let progress = ProgressRecorder()
        try await service.uploadFile(
            from: largeSource,
            bucket: fixture.bucket,
            key: largeKey,
            contentType: "application/octet-stream",
            metadata: [:]
        ) { update in
            progress.record(update)
        }
        let largeDownload = directory.appendingPathComponent("large-download.bin")
        try await service.downloadFile(bucket: fixture.bucket, key: largeKey, to: largeDownload, progress: nil)
        #expect(try sha256(of: largeSource) == sha256(of: largeDownload))
        let finalProgress = try #require(progress.last)
        #expect(finalProgress.bytesTransferred == 20 * 1_024 * 1_024)

        for key in remoteKeys {
            try await service.deleteObject(bucket: fixture.bucket, key: key)
        }
        remoteKeys.removeAll()
    } catch {
        for key in remoteKeys {
            try? await service.deleteObject(bucket: fixture.bucket, key: key)
        }
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
    try FileManager.default.removeItem(at: directory)
}

private struct IntegrationFixture {
    let profile: ConnectionProfile
    let credentials: S3Credentials
    let restrictedCredentials: S3Credentials?
    let bucket: String

    static func environment() throws -> Self? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["S3_INTEGRATION_TESTS"] == "1" else { return nil }
        guard let endpointValue = environment["S3_TEST_ENDPOINT"], let endpoint = URL(string: endpointValue),
              let accessKey = environment["S3_TEST_ACCESS_KEY"],
              let secretKey = environment["S3_TEST_SECRET_KEY"],
              let bucket = environment["S3_TEST_BUCKET"] else {
            throw S3ServiceError.invalidConfiguration("S3 integration environment is incomplete.")
        }
        let addressingStyle: S3AddressingStyle = environment["S3_TEST_ADDRESSING_STYLE"] == "virtual" ? .virtualHosted : .path
        let restrictedCredentials: S3Credentials?
        if let accessKey = environment["S3_TEST_RESTRICTED_ACCESS_KEY"],
           let secretKey = environment["S3_TEST_RESTRICTED_SECRET_KEY"] {
            restrictedCredentials = try S3Credentials(accessKey: accessKey, secretKey: secretKey)
        } else {
            restrictedCredentials = nil
        }
        return try Self(
            profile: ConnectionProfile(
                name: "Integration MinIO",
                endpoint: endpoint,
                region: environment["S3_TEST_REGION"] ?? "us-east-1",
                addressingStyle: addressingStyle
            ).validated(),
            credentials: S3Credentials(accessKey: accessKey, secretKey: secretKey),
            restrictedCredentials: restrictedCredentials,
            bucket: bucket
        )
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TransferProgress?

    func record(_ progress: TransferProgress) {
        lock.lock()
        value = progress
        lock.unlock()
    }

    var last: TransferProgress? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func sha256(of url: URL) throws -> SHA256.Digest {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
        digest.update(data: data)
    }
    return digest.finalize()
}
