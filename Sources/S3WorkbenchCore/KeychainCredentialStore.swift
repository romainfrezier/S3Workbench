import Foundation
import Security

public protocol CredentialStore: Sendable {
    func credentials(for connectionID: UUID) throws -> S3Credentials?
    func save(_ credentials: S3Credentials, for connectionID: UUID) throws
    func remove(for connectionID: UUID) throws
}

public struct KeychainCredentialStore: CredentialStore, Sendable {
    private let service: String

    public init(service: String = "com.s3workbench.credentials") {
        self.service = service
    }

    public func credentials(for connectionID: UUID) throws -> S3Credentials? {
        var item: CFTypeRef?
        var query = baseQuery(for: connectionID, dataProtection: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecMissingEntitlement || status == errSecItemNotFound {
            query = baseQuery(for: connectionID, dataProtection: false)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw keychainError(status)
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw S3ServiceError.service("Stored credentials are unreadable.")
        }
        return try S3Credentials(
            accessKey: payload.accessKey,
            secretKey: payload.secretKey,
            sessionToken: payload.sessionToken
        )
    }

    public func save(_ credentials: S3Credentials, for connectionID: UUID) throws {
        let data = try JSONEncoder().encode(Payload(credentials))
        var query = baseQuery(for: connectionID, dataProtection: true)
        let attributes = [kSecValueData as String: data]
        var updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecMissingEntitlement {
            query = baseQuery(for: connectionID, dataProtection: false)
            updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
    }

    public func remove(for connectionID: UUID) throws {
        var status = SecItemDelete(baseQuery(for: connectionID, dataProtection: true) as CFDictionary)
        if status == errSecMissingEntitlement || status == errSecItemNotFound {
            status = SecItemDelete(baseQuery(for: connectionID, dataProtection: false) as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(for connectionID: UUID, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private func keychainError(_ status: OSStatus) -> S3ServiceError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
        return .service("Keychain: \(message) (\(status)).")
    }
}

private struct Payload: Codable {
    let accessKey: String
    let secretKey: String
    let sessionToken: String?

    init(_ credentials: S3Credentials) {
        accessKey = credentials.accessKey
        secretKey = credentials.secretKey
        sessionToken = credentials.sessionToken
    }
}
