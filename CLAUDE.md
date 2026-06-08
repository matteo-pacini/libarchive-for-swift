# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Swift Package Manager distribution of [libarchive](https://libarchive.org/) for Apple platforms. It packages libarchive (v3.8.7) and its dependencies as a static XCFramework with all symbols bundled together.

**Bundled dependencies:** zlib (1.3.2), bzip2 (1.0.8), xz/liblzma (5.8.3), zstd (1.5.7), lz4 (1.10.0)

**System dependencies (dynamic):** iconv, xml2, pthread

## Common Commands

### Run Tests
```bash
swift test
```

### Build the XCFramework from Source
Requires Xcode 26.5 (the pinned, supported version) and the Nix development environment.
```bash
# Enter Nix environment first
nix develop path:.

# Build (supports parallel builds)
make -j
```

### Clean Build Artifacts
```bash
make clean
```

## Architecture

### Build System
The build system uses a single `Makefile` at the project root that handles:
- Cloning source repositories to `build/sources/`
- Building dependencies for each platform/architecture combination
- Creating the final XCFramework

Build targets cover these platform/architecture combinations:
- macOS: arm64, x86_64
- Mac Catalyst: arm64, x86_64 (built with the `-macabi` target triple against the macOS SDK)
- iOS: arm64 (device); arm64, x86_64 (simulator)
- watchOS: arm64, arm64_32 (device); arm64, x86_64 (simulator)
- tvOS: arm64 (device); arm64, x86_64 (simulator)
- visionOS: arm64 (device); arm64, x86_64 (simulator)

### Patches
A custom patch in `patches/` handles Apple platform compatibility:
- `0002-libarchive-apple-support.patch`: Disables process spawning (fork/vfork/posix_spawn) on iOS/watchOS/tvOS/visionOS since those platforms don't support it

The arm64_32/arm64e architectures are canonicalized to an `aarch64` configure `--host` directly in the Makefile (`CONFIG_HOST`), so no `config.sub` patch is required for libarchive or xz.

### Platform Limitation
External process spawning via `archive_write_add_filter_program()` only works on macOS and Mac Catalyst (both run as regular macOS processes). iOS, watchOS, tvOS, and visionOS gracefully fail these operations due to sandbox restrictions.
