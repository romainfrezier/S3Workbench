import Foundation

public enum S3ObjectURI {
    public static func string(bucket: String, key: String) -> String {
        "s3://\(S3ObjectURLBuilder.uriEncode(bucket, encodeSlash: true))/\(S3ObjectURLBuilder.uriEncode(key, encodeSlash: false))"
    }

    public static func parse(_ value: String) -> (bucket: String, key: String)? {
        guard let components = URLComponents(string: value, encodingInvalidCharacters: false),
              components.scheme?.lowercased() == "s3",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let bucket = components.percentEncodedHost?.removingPercentEncoding,
              !bucket.isEmpty,
              bucket.rangeOfCharacter(from: CharacterSet(charactersIn: ":/?#@[]\\")
                .union(.whitespacesAndNewlines).union(.controlCharacters)) == nil,
              components.percentEncodedPath.hasPrefix("/"),
              let key = String(components.percentEncodedPath.dropFirst()).removingPercentEncoding,
              !key.isEmpty else {
            return nil
        }
        // Read the encoded path directly: resolving a URL can remove literal dot segments.
        return (bucket, key)
    }
}
