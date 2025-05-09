# 📦 libarchive for Swift

A Swift Package Manager distribution of [libarchive](https://libarchive.org/) for Apple platforms.

![Supported Platforms](https://img.shields.io/badge/platforms-iOS%2016%20%7C%20macOS%2013%20%7C%20watchOS%209%20%7C%20tvOS%2016-lightgrey)
![License](https://img.shields.io/badge/license-MIT-brightgreen)

## 🌟 Features

- **Platform Support**: This package provides libarchive for a wide range of Apple devices:
  - **macOS**: >= 13.0 (`arm64` and `x86_64`)
  - **iOS**: >= 16 (`arm64`, `arm64e` for device - `arm64` and `x86_64` for simulator)
  - **watchOS**: >= 9.0 (`arm64` and `arm64_32` for device - `arm64` and `x86_64` for simulator)
  - **tvOS**: >= 16.0 (`arm64` for device | `arm64` and `x86_64` for simulator)

- **🛠 Comprehensive Integration**: `libarchive` is packaged as a static XCFramework, meaning it incorporates all necessary symbols for both the primary library and its dependencies.

- **🔄 Rebuilt Dependencies**: The included `libarchive` rebuilds `bzip2`, `libz4`, `xz`, `zlib` and `zstd` from scratch, to avoid linking against SDK libraries that may be considered private by Apple. This package requires a minimal set of system libraries to function: `iconv`, `xml2`, and `pthread`.

## 📚 Included Libraries

This package (v1.0.0) includes the following library versions:

| Library | Version | Repository |
|---------|---------|------------|
| **libarchive** | v3.7.9 | [https://github.com/libarchive/libarchive](https://github.com/libarchive/libarchive) |
| **zlib** | v1.3.1 | [https://github.com/madler/zlib](https://github.com/madler/zlib) |
| **bzip2** | 1.0.8 | [https://sourceware.org/git/bzip2.git](https://sourceware.org/git/bzip2.git) |
| **xz** | v5.8.1 | [https://git.tukaani.org/xz.git](https://git.tukaani.org/xz.git) |
| **zstd** | v1.5.7 | [https://github.com/facebook/zstd](https://github.com/facebook/zstd) |
| **lz4** | v1.10.0 | [https://github.com/lz4/lz4](https://github.com/lz4/lz4) |

## 🔧 Installation

### Swift Package Manager (SPM)

You can use Swift Package Manager to add libarchive to your project:

```swift
dependencies: [
    .package(url: "https://github.com/matteo-pacini/libarchive-for-swift.git", exact: "1.0.0")
]
```

Then, add the dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "libarchive", package: "libarchive-for-swift")
    ]
)
```

## 💡 Usage

This package provides direct access to the C API of libarchive. You'll need to use the C API directly in your Swift code.

### Importing in Swift

```swift
import libarchive
```

### C API Examples

For examples of how to use the libarchive C API, please refer to the official [libarchive examples](https://github.com/libarchive/libarchive/wiki/Examples).

These examples demonstrate common operations such as:
- Creating archives
- Extracting archives
- Reading archive contents
- Working with different archive formats and compression methods

You can use these C examples as a reference and adapt them to work with Swift by using Swift's interoperability with C.

## 🛠️ Building from Source

### Development Environment

This project uses [Nix](https://nixos.org/) as its primary package manager. There are two ways to enter the development environment:

1. **Manual Method**: Use the following command to enter the development shell:
   ```bash
   nix develop path:.
   ```

2. **Automatic Method (Preferred)**: Use [nix-direnv](https://github.com/nix-community/nix-direnv) which automatically loads the environment when you enter the project directory.

### Building the XCFramework

To build the libarchive.xcframework, you need:

1. **Prerequisites**:
   - Xcode 16.3 or later installed on your system

2. **Build Process**:
   ```bash
   cd scripts
   make -j1
   ```

This will compile libarchive and all its dependencies for various Apple platforms and package them into a single XCFramework that can be used with Swift Package Manager.

## ⚠️ Known Issues

### Platform-Specific Limitations

This package includes custom patches to ensure compatibility across all Apple platforms. One significant patch (`scripts/patches/0002-libarchive-apple-support.patch`) addresses a fundamental limitation with iOS, watchOS, and tvOS:

**External Process Spawning Restriction**

The original libarchive code uses POSIX functions like `fork()`, `vfork()`, and `posix_spawn()` to create child processes for certain operations (such as when using external programs for compression/decompression). While this works fine on macOS, it presents a significant problem on iOS, watchOS, and tvOS because:

- These platforms have strict security sandboxing that prevents or severely restricts process spawning
- Attempting to use these functions could cause runtime crashes or unpredictable behavior

The patch detects when running on a non-macOS Apple platform and gracefully fails these operations rather than attempting to use functionality that would crash the app. This ensures that the library works reliably across all supported platforms, though with some functionality differences between macOS and other Apple platforms.

## 🙌 Contributing

Contributions are welcomed and encouraged! 

If you have a bug to report, feature to suggest, or code you'd like to contribute, please feel free to [open an issue](https://github.com/matteo-pacini/libarchive-for-swift/issues) or [submit a pull request](https://github.com/matteo-pacini/libarchive-for-swift/pulls).

## 📜 License(s)

This package is distributed under the MIT License. 

The terms of this license can be found in the `LICENSE` file at the root of this repository.

### Third-Party Licenses

This package incorporates several third-party libraries which are distributed under their own respective licenses. 

**By using this package, you acknowledge and accept the terms of these third-party licenses.**

The following is a summary of the licenses for the third-party libraries statically bundled with libarchive:

1. **libarchive**: New BSD license
2. **xz (liblzma)**: Public Domain (library)
3. **bzip2**: BSD-style license
4. **zlib**: zlib License
5. **lz4**: BSD 2-Clause license (library)
6. **zstd**: BSD license

Detailed licensing information for each of these libraries can be found in the `ThirdPartyLicenses` directory within this repository. 

Each library's license is also included in the source code distribution of this package, as per the requirements of their respective licenses.

### Including licenses in your code

When using this package in your application, you need to properly acknowledge the licenses of all included libraries. Here's how to handle license compliance:

#### Legal Requirements

Since this package statically links multiple open-source libraries with different licenses, your application must comply with all of them:

1. **MIT License (this package)**: Requires the copyright notice and permission notice to be included in all copies or substantial portions of the software.

2. **BSD-style Licenses (libarchive, zstd)**: Require copyright notices and disclaimers to be included in documentation and/or other materials provided with the distribution.

3. **Public Domain (xz/liblzma)**: No legal requirement to include attribution, but it's good practice to acknowledge the source.

4. **zlib License**: Similar to BSD but with specific wording requirements.

5. **BSD 2-Clause (lz4 library)**: Requires redistribution of copyright notice, list of conditions, and disclaimer.
