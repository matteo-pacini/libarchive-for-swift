// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let packageVersion = "1.0.0"
let cArchiveChecksum = "0000000000000000000000000000000000000000000000000000000000000000"

// Contributors building from source (`make -j`) set LIBARCHIVE_LOCAL=1 to use the
// freshly built libarchive.xcframework; released tags resolve the remote binary.
let libarchiveTarget: Target = ProcessInfo.processInfo.environment["LIBARCHIVE_LOCAL"] != nil
    ? .binaryTarget(
        name: "libarchive",
        path: "libarchive.xcframework"
    )
    : .binaryTarget(
        name: "libarchive",
        url: "https://github.com/matteo-pacini/libarchive-for-swift/releases/download/\(packageVersion)/libarchive.xcframework.zip",
        checksum: cArchiveChecksum
    )

let package = Package(
    name: "SwiftArchive",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15),
        .watchOS(.v9),
        .macOS(.v12),
        .tvOS(.v15),
        .visionOS(.v1)
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
        libarchiveTarget,
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
