// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftArchive",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15),
        .watchOS(.v9),
        .macOS(.v12),
        .tvOS(.v15)
    ],
    products: [
        .library(
            name: "libarchive",
            targets: ["libarchive"]),
    ],
    targets: [
        .binaryTarget(
            name: "libarchive",
            path: "libarchive.xcframework"
        ),
        .testTarget(
            name: "libarchiveTests",
            dependencies: ["libarchive"]
        ),
    ]
)
