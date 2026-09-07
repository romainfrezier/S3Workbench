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
}
