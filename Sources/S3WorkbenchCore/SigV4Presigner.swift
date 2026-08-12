import CryptoKit
import Foundation

enum SigV4Presigner {
    static func presign(
        profile: ConnectionProfile,
        credentials: S3Credentials,
        bucket: String,
        key: String,
        operation: PresignedOperation,
        expiresIn: Int,
        contentType: String?,
        now: Date = Date()
    ) throws -> S3PresignedRequest {
        guard var components = URLComponents(url: profile.endpoint, resolvingAgainstBaseURL: false),
              let endpointHost = components.host else {
            throw S3ServiceError.invalidConfiguration("Endpoint URL is invalid.")
        }
        components.host = endpointHost.lowercased()
        let pathStyle = try usesPathStyle(profile.addressingStyle, bucket: bucket, endpointHost: endpointHost)
        if !pathStyle { components.host = "\(bucket).\(endpointHost.lowercased())" }

        let basePath = components.percentEncodedPath == "/"
            ? ""
            : components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var pathSegments: [String] = []
        if !basePath.isEmpty { pathSegments.append(basePath) }
        if pathStyle { pathSegments.append(uriEncode(bucket, encodeSlash: true)) }
        pathSegments.append(uriEncode(key, encodeSlash: false))
        let canonicalPath = "/" + pathSegments.joined(separator: "/")
        components.percentEncodedPath = canonicalPath

        let timestamp = dateFormatter("yyyyMMdd'T'HHmmss'Z'").string(from: now)
        let dateStamp = dateFormatter("yyyyMMdd").string(from: now)
        let scope = "\(dateStamp)/\(profile.region)/s3/aws4_request"
        var headers = ["host": try canonicalHost(from: components)]
        if operation == .upload, let contentType, !contentType.isEmpty {
            headers["content-type"] = canonicalHeaderValue(contentType)
        }
        let headerNames = headers.keys.sorted()
        let signedHeaders = headerNames.joined(separator: ";")
        let canonicalHeaders = headerNames.map { "\($0):\(headers[$0]!)\n" }.joined()

        var query = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(credentials.accessKey)/\(scope)"),
            ("X-Amz-Date", timestamp),
            ("X-Amz-Expires", String(expiresIn)),
            ("X-Amz-SignedHeaders", signedHeaders),
        ]
        if let token = credentials.sessionToken, !token.isEmpty {
            query.append(("X-Amz-Security-Token", token))
        }
        let canonicalQuery = canonicalQueryString(query)
        let method = operation == .download ? "GET" : "PUT"
        let canonicalRequest = [
            method, canonicalPath, canonicalQuery, canonicalHeaders, signedHeaders, "UNSIGNED-PAYLOAD",
        ].joined(separator: "\n")
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            SHA256.hash(data: Data(canonicalRequest.utf8)).hexString,
        ].joined(separator: "\n")
        let keyData = signatureKey(secret: credentials.secretKey, date: dateStamp, region: profile.region)
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: keyData)
        ).hexString
        components.percentEncodedQuery = canonicalQuery + "&X-Amz-Signature=\(signature)"
        guard let url = components.url else {
            throw S3ServiceError.service("Could not construct the presigned URL.")
        }
        var returnedHeaders: [String: String] = [:]
        if let contentType = headers["content-type"] { returnedHeaders["Content-Type"] = contentType }
        return S3PresignedRequest(
            url: url,
            method: method,
            headers: returnedHeaders,
            expiresAt: now.addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    private static func usesPathStyle(
        _ style: S3AddressingStyle,
        bucket: String,
        endpointHost: String
    ) throws -> Bool {
        switch style {
        case .path:
            return true
        case .virtualHosted:
            guard !isIPAddress(endpointHost), isDNSCompatibleBucket(bucket) else {
                throw S3ServiceError.invalidConfiguration(
                    "Virtual-hosted addressing requires a DNS-compatible bucket and hostname."
                )
            }
            return false
        case .automatic:
            return true
        }
    }

    private static func canonicalHost(from components: URLComponents) throws -> String {
        guard let rawHost = components.host else {
            throw S3ServiceError.invalidConfiguration("Endpoint host is invalid.")
        }
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        let defaultPort = components.scheme == "https" ? 443 : 80
        return components.port.map { $0 == defaultPort ? host : "\(host):\($0)" } ?? host
    }

    private static func canonicalQueryString(_ items: [(String, String)]) -> String {
        let encoded = items.map { item in
            (uriEncode(item.0, encodeSlash: true), uriEncode(item.1, encodeSlash: true))
        }
        let sorted = encoded.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        return sorted.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
    }

    private static func signatureKey(secret: String, date: String, region: String) -> Data {
        let dateKey = hmac(Data(("AWS4" + secret).utf8), Data(date.utf8))
        let regionKey = hmac(dateKey, Data(region.utf8))
        let serviceKey = hmac(regionKey, Data("s3".utf8))
        return hmac(serviceKey, Data("aws4_request".utf8))
    }

    private static func hmac(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private static func uriEncode(_ value: String, encodeSlash: Bool) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        return value.utf8.map { byte in
            if unreserved.contains(byte) || (!encodeSlash && byte == 0x2F) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    private static func canonicalHeaderValue(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let segments = host.split(separator: ".")
        return segments.count == 4 && segments.allSatisfy {
            Int($0).map { (0...255).contains($0) } == true
        }
    }

    private static func isDNSCompatibleBucket(_ bucket: String) -> Bool {
        guard (3...63).contains(bucket.count), let first = bucket.first, let last = bucket.last,
              first.isLetter || first.isNumber, last.isLetter || last.isNumber,
              !bucket.contains(".."), !bucket.contains(".-"), !bucket.contains("-.") else { return false }
        return bucket.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "." || $0 == "-" }
            && !isIPAddress(bucket)
    }

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}

private extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
