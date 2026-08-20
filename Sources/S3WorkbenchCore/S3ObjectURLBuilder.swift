import Foundation

public enum S3ObjectURLBuilder {
    public static func url(
        profile: ConnectionProfile,
        bucket: String,
        key: String
    ) throws -> URL {
        let (components, _) = try components(profile: profile, bucket: bucket, key: key)
        guard let url = components.url else {
            throw S3ServiceError.service("Could not construct the object URL.")
        }
        return url
    }

    static func components(
        profile: ConnectionProfile,
        bucket: String,
        key: String
    ) throws -> (URLComponents, String) {
        guard var components = URLComponents(
            url: profile.endpoint,
            resolvingAgainstBaseURL: false
        ), let endpointHost = components.host else {
            throw S3ServiceError.invalidConfiguration("Endpoint URL is invalid.")
        }
        components.host = endpointHost.lowercased()
        let pathStyle = try usesPathStyle(
            profile.addressingStyle,
            bucket: bucket,
            endpointHost: endpointHost
        )
        if !pathStyle { components.host = "\(bucket).\(endpointHost.lowercased())" }

        let basePath = components.percentEncodedPath == "/"
            ? ""
            : components.percentEncodedPath.trimmingCharacters(
                in: CharacterSet(charactersIn: "/"))
        var pathSegments: [String] = []
        if !basePath.isEmpty { pathSegments.append(basePath) }
        if pathStyle { pathSegments.append(uriEncode(bucket, encodeSlash: true)) }
        pathSegments.append(uriEncode(key, encodeSlash: false))
        let canonicalPath = "/" + pathSegments.joined(separator: "/")
        components.percentEncodedPath = canonicalPath
        components.query = nil
        components.fragment = nil
        return (components, canonicalPath)
    }

    static func uriEncode(_ value: String, encodeSlash: Bool) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        return value.utf8.map { byte in
            if unreserved.contains(byte) || (!encodeSlash && byte == 0x2F) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    private static func usesPathStyle(
        _ style: S3AddressingStyle,
        bucket: String,
        endpointHost: String
    ) throws -> Bool {
        switch style {
        case .path, .automatic:
            return true
        case .virtualHosted:
            guard !isIPAddress(endpointHost), isDNSCompatibleBucket(bucket) else {
                throw S3ServiceError.invalidConfiguration(
                    "Virtual-hosted addressing requires a DNS-compatible bucket and hostname."
                )
            }
            return false
        }
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
              !bucket.contains(".."), !bucket.contains(".-"), !bucket.contains("-.") else {
            return false
        }
        return bucket.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "." || $0 == "-" }
            && !isIPAddress(bucket)
    }
}
