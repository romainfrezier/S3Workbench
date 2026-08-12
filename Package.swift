// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "S3Workbench",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "S3Workbench", targets: ["S3Workbench"]),
        .library(name: "S3WorkbenchCore", targets: ["S3WorkbenchCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", exact: "1.7.59"),
        .package(url: "https://github.com/smithy-lang/smithy-swift", exact: "0.241.0"),
    ],
    targets: [
        .target(
            name: "S3WorkbenchCore",
            dependencies: [
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
                .product(name: "ClientRuntime", package: "smithy-swift"),
                .product(name: "SmithySwiftNIO", package: "smithy-swift"),
            ]
        ),
        .executableTarget(
            name: "S3Workbench",
            dependencies: ["S3WorkbenchCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "S3WorkbenchCoreTests",
            dependencies: ["S3WorkbenchCore"]
        ),
    ]
)
