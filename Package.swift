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
        .library(
            name: "SwiftArchive",
            targets: ["SwiftArchive"]),
    ],
    targets: [
        .binaryTarget(
            name: "libarchive",
            path: "libarchive.xcframework"
        ),
        .target(
            name: "SwiftArchive",
            dependencies: ["libarchive"]
        ),
        .testTarget(
            name: "libarchiveTests",
            dependencies: ["libarchive"]
        ),
        .testTarget(
            name: "SwiftArchiveTests",
            dependencies: ["SwiftArchive"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
