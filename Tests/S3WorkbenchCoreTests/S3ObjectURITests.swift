import Foundation
import Testing
@testable import S3WorkbenchCore

@Test(arguments: [
    ("folder/file.txt", "folder/file.txt"),
    (" leading/trailing ", "%20leading/trailing%20"),
    ("雪/été.txt", "%E9%9B%AA/%C3%A9t%C3%A9.txt"),
    ("e\u{301}.txt", "e%CC%81.txt"),
    ("#?%+&=:@[]", "%23%3F%25%2B%26%3D%3A%40%5B%5D"),
    ("literal%2Fslash", "literal%252Fslash"),
    ("/folder//file/", "/folder//file/"),
    ("./folder/../file", "./folder/../file"),
    ("line\nbreak\t.txt", "line%0Abreak%09.txt"),
    ("", "")
])
func objectURIEncodesAndRoundTripsExactKey(key: String, encodedKey: String) throws {
    let bucket = "test-bucket"
    let uri = S3ObjectURI.string(bucket: bucket, key: key)

    #expect(uri == "s3://\(bucket)/\(encodedKey)")
    let components = try #require(URLComponents(string: uri))
    #expect(components.scheme == "s3")
    #expect(components.host == bucket)
    #expect(components.query == nil)
    #expect(components.fragment == nil)
    let decodedKey = try #require(String(components.percentEncodedPath.dropFirst()).removingPercentEncoding)
    #expect(Array(decodedKey.utf8) == Array(key.utf8))
    if key.isEmpty {
        #expect(S3ObjectURI.parse(uri) == nil)
    } else {
        let parsed = try #require(S3ObjectURI.parse(uri))
        #expect(parsed.bucket == bucket)
        #expect(Array(parsed.key.utf8) == Array(key.utf8))
    }
}

@Test(arguments: [
    ("s3://bucket/%2Ffolder%2F%2Ffile%2F", "bucket", "/folder//file/"),
    ("S3://Bucket/./folder/../file", "Bucket", "./folder/../file"),
    ("s3://%62ucket/literal%252Fslash", "bucket", "literal%2Fslash"),
    ("s3://bucket//", "bucket", "/")
])
func objectURIParsesWithoutNormalizing(uri: String, bucket: String, key: String) throws {
    let parsed = try #require(S3ObjectURI.parse(uri))
    #expect(parsed.bucket == bucket)
    #expect(Array(parsed.key.utf8) == Array(key.utf8))
}

@Test(arguments: [
    "", "s3://", "s3:///key", "s3://bucket", "s3://bucket/", "s3:/bucket/key",
    "https://bucket/key", "s3:bucket/key", "//bucket/key", " s3://bucket/key",
    "s3://user@bucket/key", "s3://user:password@bucket/key", "s3://bucket:9000/key",
    "s3://[::1]/key", "s3://bucket/key?query", "s3://bucket/key#fragment",
    "s3://bucket/key?", "s3://bucket/key#", "s3://bucket/a b", "s3://bucket/été",
    "s3://bucket/line\nbreak", "s3://bucket/a\\b", "s3://bucket/file%", "s3://bucket/%1",
    "s3://bucket/%GG", "s3://bucket/%FF", "s3://bucket/%C3%28", "s3://bucket/%ED%A0%80",
    "s3://buck%FFet/key", "s3://buck%20et/key", "s3://buck%2Fet/key", "s3://user%40bucket/key",
    "s3://bucket%3A9000/key", "s3://bucket%00/key"
])
func objectURIRejectsMalformedInput(uri: String) {
    #expect(S3ObjectURI.parse(uri) == nil)
}
