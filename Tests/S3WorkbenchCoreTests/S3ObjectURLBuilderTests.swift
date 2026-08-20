import Foundation
import Testing
@testable import S3WorkbenchCore

@Test func objectURLBuilderPreservesEndpointPathPortAndExactObjectKey() throws {
    let profile = ConnectionProfile(
        name: "Local",
        endpoint: try #require(URL(string: "https://storage.example.com:9443/gateway")),
        addressingStyle: .path
    )

    let url = try S3ObjectURLBuilder.url(
        profile: profile,
        bucket: "private-bucket",
        key: "folder//snow 雪?#.txt"
    )

    #expect(
        url.absoluteString
            == "https://storage.example.com:9443/gateway/private-bucket/folder//snow%20%E9%9B%AA%3F%23.txt"
    )
}

@Test func objectURLBuilderSupportsVirtualHostedAddressing() throws {
    let profile = ConnectionProfile(
        name: "Hosted",
        endpoint: try #require(URL(string: "https://s3.example.com")),
        addressingStyle: .virtualHosted
    )

    let url = try S3ObjectURLBuilder.url(
        profile: profile,
        bucket: "public-assets",
        key: "images/logo.png"
    )

    #expect(url.absoluteString == "https://public-assets.s3.example.com/images/logo.png")
}

@Test func objectURLBuilderRejectsInvalidVirtualHostedBucket() throws {
    let profile = ConnectionProfile(
        name: "Hosted",
        endpoint: try #require(URL(string: "https://s3.example.com")),
        addressingStyle: .virtualHosted
    )

    #expect(throws: S3ServiceError.self) {
        try S3ObjectURLBuilder.url(profile: profile, bucket: "Not_DNS", key: "object.txt")
    }
}
