public enum S3ObjectURI {
    public static func string(bucket: String, key: String) -> String {
        "s3://\(S3ObjectURLBuilder.uriEncode(bucket, encodeSlash: true))/\(S3ObjectURLBuilder.uriEncode(key, encodeSlash: false))"
    }
}
