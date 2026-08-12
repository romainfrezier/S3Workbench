import Foundation
import Testing
@testable import S3WorkbenchCore

@Test func multipleConnectionProfilesPersistAndReloadIndependently() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("S3Workbench-ConnectionStoreTests-(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("connections.json")
    let first = ConnectionProfile(
        id: UUID(),
        name: "Local MinIO",
        endpoint: try #require(URL(string: "http://localhost:9000")),
        region: "us-east-1",
        addressingStyle: .path
    )
    let second = ConnectionProfile(
        id: UUID(),
        name: "Private storage",
        endpoint: try #require(URL(string: "https://storage.example.com:9443")),
        accessPath: "/documents/reports",
        colorHex: "#FF9500",
        region: "custom-1",
        addressingStyle: .virtualHosted
    )

    let writer = ConnectionStore(fileURL: fileURL)
    try await writer.save([first, second])

    let reader = ConnectionStore(fileURL: fileURL)
    let reloaded = try await reader.load()
    #expect(reloaded == [first, second])
    #expect(reloaded.map(\.endpoint) == [first.endpoint, second.endpoint])
    #expect(reloaded[1].accessPath == "/documents/reports")
    #expect(reloaded[1].colorHex == "#FF9500")
}

@Test func accessPathResolvesBucketAndPrefix() throws {
    let profile = try ConnectionProfile(
        name: "Restricted account",
        endpoint: try #require(URL(string: "https://storage.example.com:443")),
        accessPath: " /etickets/incoming "
    ).validated()

    let location = try #require(try profile.resolvedAccessPath())
    #expect(location.bucket == "etickets")
    #expect(location.prefix == "incoming/")
    #expect(profile.accessPath == "/etickets/incoming")
}

@Test func accessRootNormalizesOnlyTheContainerBoundary() throws {
    let root = try S3AccessRoot(path: "//bucket/a//b")
    #expect(root.bucket == "bucket")
    #expect(root.prefix == "a//b/")
    #expect(root.path == "/bucket/a//b")
    #expect(throws: (any Error).self) { try S3AccessRoot(path: "/") }
}

@Test func operationalErrorsRemainActionableAndSecretFree() {
    let errors: [S3ServiceError] = [
        .authenticationFailed, .signatureMismatch, .accessDenied, .wrongRegion,
        .tlsFailure, .networkUnavailable,
    ]
    for error in errors {
        let message = error.localizedDescription
        #expect(!message.isEmpty)
        #expect(!message.localizedCaseInsensitiveContains("authorization:"))
        #expect(!message.localizedCaseInsensitiveContains("x-amz-signature"))
    }
    #expect(S3ServiceError.accessDenied.localizedDescription.contains("/bucket/prefix"))
}

@Test func profilesSavedBeforeAccessPathsAndColorsStillDecode() throws {
    let profile = ConnectionProfile(
        name: "Legacy",
        endpoint: try #require(URL(string: "https://storage.example.com"))
    )
    let encoded = try JSONEncoder().encode(profile)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "accessPath")
    object.removeValue(forKey: "colorHex")

    let decoded = try JSONDecoder().decode(
        ConnectionProfile.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(decoded.accessPath == nil)
    #expect(decoded.colorHex == nil)
}

@Test func customCertificateConnectionMetadataReloads() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("S3Workbench-CertificateStoreTests-(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let certificateURL = directory.appendingPathComponent("private-ca.pem")
    let profile = ConnectionProfile(
        name: "Private CA",
        endpoint: try #require(URL(string: "https://minio.internal.company")),
        addressingStyle: .path,
        tlsVerification: .customCertificate,
        customCACertificateURL: certificateURL
    )
    let store = ConnectionStore(fileURL: directory.appendingPathComponent("connections.json"))
    try await store.save([profile])

    let reloaded = try #require(try await store.load().first)
    #expect(reloaded.tlsVerification == .customCertificate)
    #expect(reloaded.customCACertificateURL == certificateURL)
}

@Test func keychainCredentialsAreScopedByConnectionID() throws {
    let store = KeychainCredentialStore(service: "com.s3workbench.tests.(UUID().uuidString)")
    let firstID = UUID()
    let secondID = UUID()
    defer {
        try? store.remove(for: firstID)
        try? store.remove(for: secondID)
    }

    let first = try S3Credentials(accessKey: "minio-access", secretKey: "minio-secret")
    let second = try S3Credentials(
        accessKey: "remote-access",
        secretKey: "remote-secret",
        sessionToken: "remote-session"
    )
    try store.save(first, for: firstID)
    try store.save(second, for: secondID)

    let firstResult = try store.credentials(for: firstID)
    let secondResult = try store.credentials(for: secondID)
    let loadedFirst = try #require(firstResult)
    let loadedSecond = try #require(secondResult)
    #expect(loadedFirst.accessKey == first.accessKey)
    #expect(loadedFirst.secretKey == first.secretKey)
    #expect(loadedFirst.sessionToken == nil)
    #expect(loadedSecond.accessKey == second.accessKey)
    #expect(loadedSecond.secretKey == second.secretKey)
    #expect(loadedSecond.sessionToken == second.sessionToken)
}

@Test func restartPersistenceProbe() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let phase = environment["S3_RESTART_PROBE_PHASE"],
          let filePath = environment["S3_RESTART_PROBE_FILE"],
          let connectionID = UUID(uuidString: "A53BFC73-C765-4A15-8249-11AB632C1D61") else { return }
    let credentialStore = KeychainCredentialStore(service: "com.s3workbench.restart-probe")
    let connectionStore = ConnectionStore(fileURL: URL(fileURLWithPath: filePath))
    if phase == "write" {
        let profile = ConnectionProfile(
            id: connectionID,
            name: "Restart MinIO",
            endpoint: try #require(URL(string: "http://localhost:9000")),
            addressingStyle: .automatic
        )
        try await connectionStore.save([profile])
        try credentialStore.save(
            S3Credentials(accessKey: "restart-access", secretKey: "restart-secret"),
            for: connectionID
        )
    } else if phase == "read" {
        let profile = try #require(try await connectionStore.load().first)
        let credentials = try #require(try credentialStore.credentials(for: connectionID))
        #expect(profile.name == "Restart MinIO")
        #expect(credentials.accessKey == "restart-access")
        #expect(credentials.secretKey == "restart-secret")
        try credentialStore.remove(for: connectionID)
        try? FileManager.default.removeItem(atPath: filePath)
    } else if phase == "cleanup" {
        try? credentialStore.remove(for: connectionID)
        try? FileManager.default.removeItem(atPath: filePath)
    }
}
