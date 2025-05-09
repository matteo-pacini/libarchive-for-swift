IOS_MIN_VERSION=16.0
MACOS_MIN_VERSION=13.0
WATCHOS_MIN_VERSION=9.0
TVOS_MIN_VERSION=16.0

# Enable deterministic builds
export ZERO_AR_DATE=1

all: libarchive.xcframework

libarchive.xcframework: build.ios build.iossimulator \
                        build.macos \
					    build.watchos build.watchossimulator \
						build.tvos build.tvossimulator
	xcodebuild -create-xcframework \
		-library build.ios/usr/local/lib/libarchive.a \
		-headers build.ios/usr/local/include \
		-library build.iossimulator/usr/local/lib/libarchive.a \
		-headers build.iossimulator/usr/local/include \
		-library build.macos/usr/local/lib/libarchive.a \
		-headers build.macos/usr/local/include \
		-library build.watchos/usr/local/lib/libarchive.a \
		-headers build.watchos/usr/local/include \
		-library build.watchossimulator/usr/local/lib/libarchive.a \
		-headers build.watchossimulator/usr/local/include \
		-library build.tvos/usr/local/lib/libarchive.a \
		-headers build.tvos/usr/local/include \
		-library build.tvossimulator/usr/local/lib/libarchive.a \
		-headers build.tvossimulator/usr/local/include \
		-output libarchive.xcframework

build.ios: build.ios.arm64 build.ios.arm64e
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r build.ios.arm64/usr/local/include/* $@/usr/local/include/
	lipo -create -output $@/usr/local/lib/libarchive.a \
		build.ios.arm64/usr/local/lib/libarchive.a \
		build.ios.arm64e/usr/local/lib/libarchive.a

build.iossimulator: build.iossimulator.arm64 build.iossimulator.x86_64 
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r build.iossimulator.arm64/usr/local/include/* $@/usr/local/include/
	lipo -create -output $@/usr/local/lib/libarchive.a \
		build.iossimulator.x86_64/usr/local/lib/libarchive.a \
		build.iossimulator.arm64/usr/local/lib/libarchive.a

build.macos: build.macos.arm64 build.macos.x86_64 
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r build.macos.arm64/usr/local/include/* $@/usr/local/include/
	lipo -create -output $@/usr/local/lib/libarchive.a \
		build.macos.x86_64/usr/local/lib/libarchive.a \
		build.macos.arm64/usr/local/lib/libarchive.a

build.watchos: build.watchos.arm64_32 build.watchos.arm64
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r build.watchos.arm64/usr/local/include/* $@/usr/local/include/
	lipo -create -output $@/usr/local/lib/libarchive.a \
		build.watchos.arm64_32/usr/local/lib/libarchive.a \
		build.watchos.arm64/usr/local/lib/libarchive.a

build.watchossimulator: build.watchossimulator.arm64 build.watchossimulator.x86_64
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r build.watchossimulator.arm64/usr/local/include/* $@/usr/local/include/
	lipo -create -output $@/usr/local/lib/libarchive.a \
		build.watchossimulator.x86_64/usr/local/lib/libarchive.a \
		build.watchossimulator.arm64/usr/local/lib/libarchive.a

build.tvos: build.tvos.arm64
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r build.tvos.arm64/usr/local/include/* $@/usr/local/include/
	cp build.tvos.arm64/usr/local/lib/libarchive.a $@/usr/local/lib/libarchive.a

build.tvossimulator: build.tvossimulator.arm64 build.tvossimulator.x86_64
	mkdir -p $@/usr/local/lib
	mkdir -p $@/usr/local/include
	cp -r build.tvossimulator.arm64/usr/local/include/* $@/usr/local/include/
	lipo -create -output $@/usr/local/lib/libarchive.a \
		build.tvossimulator.x86_64/usr/local/lib/libarchive.a \
		build.tvossimulator.arm64/usr/local/lib/libarchive.a

build.ios.%:
	TARGET="$@" \
	ARCH="$*" \
	EXTRA_CFLAGS="-arch $* -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=$(IOS_MIN_VERSION)" \
	EXTRA_LDFLAGS="-arch $* -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path)" \
	make -f Makefile2 build

build.iossimulator.%:
	TARGET="$@" \
	ARCH="$*" \
	EXTRA_CFLAGS="-arch $* -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path) -miphonesimulator-version-min=$(IOS_MIN_VERSION)" \
	EXTRA_LDFLAGS="-arch $* -isysroot $(shell xcrun --sdk iphonesimulator --show-sdk-path)" \
	make -f Makefile2 build

build.macos.%:
	TARGET="$@" \
	ARCH="$*" \
	EXTRA_CFLAGS="-arch $* -isysroot $(shell xcrun --sdk macosx --show-sdk-path) -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	EXTRA_LDFLAGS="-arch $* -isysroot $(shell xcrun --sdk macosx --show-sdk-path)" \
	make -f Makefile2 build

build.watchos.%:
	TARGET="$@" \
	ARCH="$*" \
	EXTRA_CFLAGS="-arch $* -isysroot $(shell xcrun --sdk watchos --show-sdk-path) -mwatchos-version-min=$(WATCHOS_MIN_VERSION)" \
	EXTRA_LDFLAGS="-arch $* -isysroot $(shell xcrun --sdk watchos --show-sdk-path)" \
	make -f Makefile2 build

build.watchossimulator.%:
	TARGET="$@" \
	ARCH="$*" \
	EXTRA_CFLAGS="-arch $* -isysroot $(shell xcrun --sdk watchsimulator --show-sdk-path) -mwatchos-simulator-version-min=$(WATCHOS_MIN_VERSION)" \
	EXTRA_LDFLAGS="-arch $* -isysroot $(shell xcrun --sdk watchsimulator --show-sdk-path)" \
	make -f Makefile2 build

build.tvos.%:
	TARGET="$@" \
	ARCH="$*" \
	EXTRA_CFLAGS="-arch $* -isysroot $(shell xcrun --sdk appletvos --show-sdk-path) -mtvos-version-min=$(TVOS_MIN_VERSION)" \
	EXTRA_LDFLAGS="-arch $* -isysroot $(shell xcrun --sdk appletvos --show-sdk-path)" \
	make -f Makefile2 build

build.tvossimulator.%:
	TARGET="$@" \
	ARCH="$*" \
	EXTRA_CFLAGS="-arch $* -isysroot $(shell xcrun --sdk appletvsimulator --show-sdk-path) -mtvos-simulator-version-min=$(TVOS_MIN_VERSION)" \
	EXTRA_LDFLAGS="-arch $* -isysroot $(shell xcrun --sdk appletvsimulator --show-sdk-path)" \
	make -f Makefile2 build

clean:
	make -f Makefile2 clean
	rm -rf build* libarchive.xcframework

.PHONY: all clean
