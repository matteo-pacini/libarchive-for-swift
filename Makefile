# =============================================================================
# libarchive-for-swift Makefile
# =============================================================================
# Builds libarchive and its dependencies as a static XCFramework for Apple platforms.
# Supports parallel builds across all platform/architecture combinations.
#
# Usage:
#   make -j          # Build everything in parallel
#   make clean       # Remove all build artifacts
# =============================================================================

# === Platform Minimum Versions ===
IOS_MIN_VERSION         := 15.0
MACOS_MIN_VERSION       := 12.0
WATCHOS_MIN_VERSION     := 9.0
TVOS_MIN_VERSION        := 15.0
MACCATALYST_MIN_VERSION := 15.0

# === Git Sources ===
LIBARCHIVE_TAG := v3.8.7
LIBARCHIVE_GIT := https://github.com/libarchive/libarchive.git

ZLIB_TAG := v1.3.2
ZLIB_GIT := https://github.com/madler/zlib

BZIP2_TAG := bzip2-1.0.8
BZIP2_GIT := https://sourceware.org/git/bzip2.git

XZ_TAG := v5.8.3
XZ_GIT := https://git.tukaani.org/xz.git

ZSTD_TAG := v1.5.7
ZSTD_GIT := https://github.com/facebook/zstd.git

LZ4_TAG := v1.10.0
LZ4_GIT := https://github.com/lz4/lz4

# === Build Paths ===
BUILD_DIR := build
SOURCES   := $(BUILD_DIR)/sources

# === Dependency Paths (relative to libarchive build dir) ===
ZLIB_CFLAGS   := -I../zlib
ZLIB_LDFLAGS  := -L../zlib -lz
BZIP2_CFLAGS  := -I../bzip2
BZIP2_LDFLAGS := -L../bzip2 -lbz2
XZ_CFLAGS     := -I../xz/src/liblzma/api
XZ_LDFLAGS    := -L../xz/src/liblzma/.libs -llzma
ZSTD_CFLAGS   := -I../zstd/lib
ZSTD_LDFLAGS  := -L../zstd/lib -lzstd
LZ4_CFLAGS    := -I../lz4/lib
LZ4_LDFLAGS   := -L../lz4/lib -llz4

DEPS_CFLAGS  := $(ZLIB_CFLAGS) $(XZ_CFLAGS) $(BZIP2_CFLAGS) $(ZSTD_CFLAGS) $(LZ4_CFLAGS)
DEPS_LDFLAGS := $(ZLIB_LDFLAGS) $(XZ_LDFLAGS) $(BZIP2_LDFLAGS) $(ZSTD_LDFLAGS) $(LZ4_LDFLAGS)

# === Deterministic Build Settings ===
export ZERO_AR_DATE := 1
REPO_ROOT := $(shell pwd)

# CPU count for parallel builds
NPROC := $(shell sysctl -n hw.ncpu)

# =============================================================================
# Main Target
# =============================================================================

all: libarchive.xcframework

# =============================================================================
# Clone Phase
# =============================================================================

$(BUILD_DIR)/.clone-done: $(SOURCES)/libarchive $(SOURCES)/xz $(SOURCES)/zlib \
                          $(SOURCES)/bzip2 $(SOURCES)/zstd $(SOURCES)/lz4
	touch $@

$(SOURCES)/libarchive:
	mkdir -p $(SOURCES)
	git clone $(LIBARCHIVE_GIT) $@
	cd $@ && git checkout $(LIBARCHIVE_TAG)

$(SOURCES)/xz:
	mkdir -p $(SOURCES)
	git clone $(XZ_GIT) $@
	cd $@ && git checkout $(XZ_TAG)

$(SOURCES)/zlib:
	mkdir -p $(SOURCES)
	git clone $(ZLIB_GIT) $@
	cd $@ && git checkout $(ZLIB_TAG)

$(SOURCES)/bzip2:
	mkdir -p $(SOURCES)
	git clone $(BZIP2_GIT) $@
	cd $@ && git checkout $(BZIP2_TAG)

$(SOURCES)/zstd:
	mkdir -p $(SOURCES)
	git clone $(ZSTD_GIT) $@
	cd $@ && git checkout $(ZSTD_TAG)

$(SOURCES)/lz4:
	mkdir -p $(SOURCES)
	git clone $(LZ4_GIT) $@
	cd $@ && git checkout $(LZ4_TAG)

# =============================================================================
# Build Function
# =============================================================================
# $(1) = target dir (e.g., build/ios.arm64)
# $(2) = arch (e.g., arm64)
# $(3) = extra CFLAGS
# $(4) = extra LDFLAGS

define build-arch
	@echo "=== Building $(1) ==="
	$(eval SRC := $(1)/src)
	$(eval ARCH_CFLAGS := -fdebug-prefix-map=$(REPO_ROOT)=. $(3))
	$(eval ARCH_LDFLAGS := -Wl,-oso_prefix,$(REPO_ROOT)/ $(4))
	# config.sub doesn't recognize arm64_32/arm64e; canonicalize the configure
	# --host to aarch64 while -arch (in CFLAGS) selects the real slice.
	$(eval CONFIG_HOST := $(if $(filter arm64_32 arm64e,$(2)),aarch64,$(2)))

	# Copy sources to target-specific directory
	mkdir -p $(SRC)
	cp -R $(SOURCES)/libarchive $(SRC)/
	cp -R $(SOURCES)/zlib $(SRC)/
	cp -R $(SOURCES)/bzip2 $(SRC)/
	cp -R $(SOURCES)/xz $(SRC)/
	cp -R $(SOURCES)/zstd $(SRC)/
	cp -R $(SOURCES)/lz4 $(SRC)/

	# Build zlib
	cd $(SRC)/zlib && \
	git reset --hard && \
	git clean -xdf && \
	CC="clang" \
	CPP="clang -E" \
	CFLAGS="-O2 -g $(ARCH_CFLAGS)" \
	LDFLAGS="$(ARCH_LDFLAGS)" \
	./configure --static && \
	make -j$(NPROC)

	# Build bzip2
	cd $(SRC)/bzip2 && \
	git reset --hard && \
	git clean -xdf && \
	clang -O2 -g $(ARCH_CFLAGS) -c blocksort.c huffman.c crctable.c \
	                               randtable.c compress.c decompress.c bzlib.c && \
	libtool -D -static -o libbz2.a blocksort.o huffman.o crctable.o \
	                               randtable.o compress.o decompress.o bzlib.o

	# Build xz
	cd $(SRC)/xz && \
	git reset --hard && \
	git clean -xdf && \
	./autogen.sh --no-po4a --no-doxygen && \
	CC="clang" \
	CPP="clang -E" \
	CFLAGS="-O2 -g $(ARCH_CFLAGS)" \
	LDFLAGS="$(ARCH_LDFLAGS)" \
	./configure --host=$(CONFIG_HOST)-apple-darwin --enable-static --disable-shared \
	--disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-lzma-links && \
	make -j$(NPROC)

	# Build zstd
	cd $(SRC)/zstd && \
	git reset --hard && \
	git clean -xdf && \
	cd lib && \
	CC="clang" \
	CPP="clang -E" \
	CFLAGS="-O2 -g $(ARCH_CFLAGS)" \
	LDFLAGS="$(ARCH_LDFLAGS)" \
	make libzstd.a-mt -j$(NPROC)

	# Build lz4
	cd $(SRC)/lz4 && \
	git reset --hard && \
	git clean -xdf && \
	CC="clang" \
	CPP="clang -E" \
	CFLAGS="-O2 -g $(ARCH_CFLAGS)" \
	LDFLAGS="$(ARCH_LDFLAGS)" \
	make -j$(NPROC)

	# Build libarchive
	cd $(SRC)/libarchive && \
	git reset --hard && \
	git clean -xdf && \
	/bin/sh build/autogen.sh && \
	git apply $(REPO_ROOT)/patches/0002-libarchive-apple-support.patch

	cd $(SRC)/libarchive && \
	CC="clang" \
	CPP="clang -E" \
	CFLAGS="-O2 -g $(DEPS_CFLAGS) $(ARCH_CFLAGS)" \
	LDFLAGS="$(DEPS_LDFLAGS) $(ARCH_LDFLAGS)" \
	./configure --host=$(CONFIG_HOST)-apple-darwin --enable-static --disable-shared \
	--disable-bsdunzip --disable-bsdcpio --disable-bsdcat --disable-bsdtar && \
	make -j$(NPROC)

	DESTDIR="$(REPO_ROOT)/$(1)" make -C $(SRC)/libarchive install

	# Copy module map
	cp support/module.modulemap $(1)/usr/local/include/

	# Merge all static libraries into single archive
	xcrun libtool -D -static -o $(1)/tmp.a \
		$(1)/usr/local/lib/libarchive.a \
		$(SRC)/zlib/libz.a \
		$(SRC)/bzip2/libbz2.a \
		$(SRC)/xz/src/liblzma/.libs/liblzma.a \
		$(SRC)/zstd/lib/libzstd.a \
		$(SRC)/lz4/lib/liblz4.a

	mv $(1)/tmp.a $(1)/usr/local/lib/libarchive.a
	@echo "=== Finished $(1) ==="
endef

# =============================================================================
# Architecture Build Targets
# =============================================================================

# iOS Device
$(BUILD_DIR)/ios.arm64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,arm64,\
		-arch arm64 -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=$(IOS_MIN_VERSION),\
		-arch arm64 -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path))

# iOS Simulator
$(BUILD_DIR)/iossimulator.arm64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,arm64,\
		-arch arm64 -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path) -miphonesimulator-version-min=$(IOS_MIN_VERSION),\
		-arch arm64 -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path))

$(BUILD_DIR)/iossimulator.x86_64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,x86_64,\
		-arch x86_64 -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path) -miphonesimulator-version-min=$(IOS_MIN_VERSION),\
		-arch x86_64 -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path))

# macOS
$(BUILD_DIR)/macos.arm64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,arm64,\
		-arch arm64 -isysroot $(shell xcrun --sdk macosx --show-sdk-path) -mmacosx-version-min=$(MACOS_MIN_VERSION),\
		-arch arm64 -isysroot $(shell xcrun --sdk macosx --show-sdk-path))

$(BUILD_DIR)/macos.x86_64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,x86_64,\
		-arch x86_64 -isysroot $(shell xcrun --sdk macosx --show-sdk-path) -mmacosx-version-min=$(MACOS_MIN_VERSION),\
		-arch x86_64 -isysroot $(shell xcrun --sdk macosx --show-sdk-path))

# Mac Catalyst (built against the macOS SDK; arch + min are carried by the
# -macabi target triple, so no -arch / -m...-version-min flags here)
$(BUILD_DIR)/maccatalyst.arm64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,arm64,\
		-target arm64-apple-ios$(MACCATALYST_MIN_VERSION)-macabi -isysroot $(shell xcrun --sdk macosx --show-sdk-path),\
		-target arm64-apple-ios$(MACCATALYST_MIN_VERSION)-macabi -isysroot $(shell xcrun --sdk macosx --show-sdk-path))

$(BUILD_DIR)/maccatalyst.x86_64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,x86_64,\
		-target x86_64-apple-ios$(MACCATALYST_MIN_VERSION)-macabi -isysroot $(shell xcrun --sdk macosx --show-sdk-path),\
		-target x86_64-apple-ios$(MACCATALYST_MIN_VERSION)-macabi -isysroot $(shell xcrun --sdk macosx --show-sdk-path))

# watchOS Device
$(BUILD_DIR)/watchos.arm64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,arm64,\
		-arch arm64 -isysroot $(shell xcrun --sdk watchos --show-sdk-path) -mwatchos-version-min=$(WATCHOS_MIN_VERSION),\
		-arch arm64 -isysroot $(shell xcrun --sdk watchos --show-sdk-path))

$(BUILD_DIR)/watchos.arm64_32: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,arm64_32,\
		-arch arm64_32 -isysroot $(shell xcrun --sdk watchos --show-sdk-path) -mwatchos-version-min=$(WATCHOS_MIN_VERSION),\
		-arch arm64_32 -isysroot $(shell xcrun --sdk watchos --show-sdk-path))

# watchOS Simulator
$(BUILD_DIR)/watchossimulator.arm64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,arm64,\
		-arch arm64 -isysroot $(shell xcrun --sdk watchsimulator --show-sdk-path) -mwatchos-simulator-version-min=$(WATCHOS_MIN_VERSION),\
		-arch arm64 -isysroot $(shell xcrun --sdk watchsimulator --show-sdk-path))

$(BUILD_DIR)/watchossimulator.x86_64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,x86_64,\
		-arch x86_64 -isysroot $(shell xcrun --sdk watchsimulator --show-sdk-path) -mwatchos-simulator-version-min=$(WATCHOS_MIN_VERSION),\
		-arch x86_64 -isysroot $(shell xcrun --sdk watchsimulator --show-sdk-path))

# tvOS Device
$(BUILD_DIR)/tvos.arm64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,arm64,\
		-arch arm64 -isysroot $(shell xcrun --sdk appletvos --show-sdk-path) -mtvos-version-min=$(TVOS_MIN_VERSION),\
		-arch arm64 -isysroot $(shell xcrun --sdk appletvos --show-sdk-path))

# tvOS Simulator
$(BUILD_DIR)/tvossimulator.arm64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,arm64,\
		-arch arm64 -isysroot $(shell xcrun --sdk appletvsimulator --show-sdk-path) -mtvos-simulator-version-min=$(TVOS_MIN_VERSION),\
		-arch arm64 -isysroot $(shell xcrun --sdk appletvsimulator --show-sdk-path))

$(BUILD_DIR)/tvossimulator.x86_64: | $(BUILD_DIR)/.clone-done
	$(call build-arch,$@,x86_64,\
		-arch x86_64 -isysroot $(shell xcrun --sdk appletvsimulator --show-sdk-path) -mtvos-simulator-version-min=$(TVOS_MIN_VERSION),\
		-arch x86_64 -isysroot $(shell xcrun --sdk appletvsimulator --show-sdk-path))

# =============================================================================
# Platform Combination Targets (lipo)
# =============================================================================

$(BUILD_DIR)/ios: $(BUILD_DIR)/ios.arm64
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r $(BUILD_DIR)/ios.arm64/usr/local/include/* $@/usr/local/include/
	cp $(BUILD_DIR)/ios.arm64/usr/local/lib/libarchive.a $@/usr/local/lib/libarchive.a

$(BUILD_DIR)/iossimulator: $(BUILD_DIR)/iossimulator.arm64 $(BUILD_DIR)/iossimulator.x86_64
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r $(BUILD_DIR)/iossimulator.arm64/usr/local/include/* $@/usr/local/include/
	lipo -create -output $@/usr/local/lib/libarchive.a \
		$(BUILD_DIR)/iossimulator.arm64/usr/local/lib/libarchive.a \
		$(BUILD_DIR)/iossimulator.x86_64/usr/local/lib/libarchive.a

$(BUILD_DIR)/macos: $(BUILD_DIR)/macos.arm64 $(BUILD_DIR)/macos.x86_64
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r $(BUILD_DIR)/macos.arm64/usr/local/include/* $@/usr/local/include/
	lipo -create -output $@/usr/local/lib/libarchive.a \
		$(BUILD_DIR)/macos.arm64/usr/local/lib/libarchive.a \
		$(BUILD_DIR)/macos.x86_64/usr/local/lib/libarchive.a

$(BUILD_DIR)/maccatalyst: $(BUILD_DIR)/maccatalyst.arm64 $(BUILD_DIR)/maccatalyst.x86_64
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r $(BUILD_DIR)/maccatalyst.arm64/usr/local/include/* $@/usr/local/include/
	lipo -create -output $@/usr/local/lib/libarchive.a \
		$(BUILD_DIR)/maccatalyst.arm64/usr/local/lib/libarchive.a \
		$(BUILD_DIR)/maccatalyst.x86_64/usr/local/lib/libarchive.a

$(BUILD_DIR)/watchos: $(BUILD_DIR)/watchos.arm64 $(BUILD_DIR)/watchos.arm64_32
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r $(BUILD_DIR)/watchos.arm64/usr/local/include/* $@/usr/local/include/
	lipo -create -output $@/usr/local/lib/libarchive.a \
		$(BUILD_DIR)/watchos.arm64/usr/local/lib/libarchive.a \
		$(BUILD_DIR)/watchos.arm64_32/usr/local/lib/libarchive.a

$(BUILD_DIR)/watchossimulator: $(BUILD_DIR)/watchossimulator.arm64 $(BUILD_DIR)/watchossimulator.x86_64
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r $(BUILD_DIR)/watchossimulator.arm64/usr/local/include/* $@/usr/local/include/
	lipo -create -output $@/usr/local/lib/libarchive.a \
		$(BUILD_DIR)/watchossimulator.arm64/usr/local/lib/libarchive.a \
		$(BUILD_DIR)/watchossimulator.x86_64/usr/local/lib/libarchive.a

$(BUILD_DIR)/tvos: $(BUILD_DIR)/tvos.arm64
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r $(BUILD_DIR)/tvos.arm64/usr/local/include/* $@/usr/local/include/
	cp $(BUILD_DIR)/tvos.arm64/usr/local/lib/libarchive.a $@/usr/local/lib/libarchive.a

$(BUILD_DIR)/tvossimulator: $(BUILD_DIR)/tvossimulator.arm64 $(BUILD_DIR)/tvossimulator.x86_64
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r $(BUILD_DIR)/tvossimulator.arm64/usr/local/include/* $@/usr/local/include/
	lipo -create -output $@/usr/local/lib/libarchive.a \
		$(BUILD_DIR)/tvossimulator.arm64/usr/local/lib/libarchive.a \
		$(BUILD_DIR)/tvossimulator.x86_64/usr/local/lib/libarchive.a

# =============================================================================
# XCFramework Creation
# =============================================================================

libarchive.xcframework: $(BUILD_DIR)/ios $(BUILD_DIR)/iossimulator \
                        $(BUILD_DIR)/macos $(BUILD_DIR)/maccatalyst \
                        $(BUILD_DIR)/watchos $(BUILD_DIR)/watchossimulator \
                        $(BUILD_DIR)/tvos $(BUILD_DIR)/tvossimulator
	rm -rf $@
	xcodebuild -create-xcframework \
		-library $(BUILD_DIR)/ios/usr/local/lib/libarchive.a \
		-headers $(BUILD_DIR)/ios/usr/local/include \
		-library $(BUILD_DIR)/iossimulator/usr/local/lib/libarchive.a \
		-headers $(BUILD_DIR)/iossimulator/usr/local/include \
		-library $(BUILD_DIR)/macos/usr/local/lib/libarchive.a \
		-headers $(BUILD_DIR)/macos/usr/local/include \
		-library $(BUILD_DIR)/maccatalyst/usr/local/lib/libarchive.a \
		-headers $(BUILD_DIR)/maccatalyst/usr/local/include \
		-library $(BUILD_DIR)/watchos/usr/local/lib/libarchive.a \
		-headers $(BUILD_DIR)/watchos/usr/local/include \
		-library $(BUILD_DIR)/watchossimulator/usr/local/lib/libarchive.a \
		-headers $(BUILD_DIR)/watchossimulator/usr/local/include \
		-library $(BUILD_DIR)/tvos/usr/local/lib/libarchive.a \
		-headers $(BUILD_DIR)/tvos/usr/local/include \
		-library $(BUILD_DIR)/tvossimulator/usr/local/lib/libarchive.a \
		-headers $(BUILD_DIR)/tvossimulator/usr/local/include \
		-output $@

# =============================================================================
# Clean
# =============================================================================

clean:
	rm -rf $(BUILD_DIR) libarchive.xcframework

.PHONY: all clean
