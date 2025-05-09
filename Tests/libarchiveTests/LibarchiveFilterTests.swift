import XCTest
import libarchive

final class LibarchiveFilterTests: XCTestCase {

    // MARK: Supported

    func test_libarchive_supportsB64Encode() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_add_filter_b64encode(archive), ARCHIVE_OK)
    }
    
    func test_libarchive_supportsBzip2() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_add_filter_bzip2(archive), ARCHIVE_OK)
    }
    
    func test_libarchive_supportsCompress() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_add_filter_compress(archive), ARCHIVE_OK)
    }
    
    func test_libarchive_doesNotSupportGrzip() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        // This filter should fail because grzip dependencies aren't included in the build
        XCTAssertNotEqual(archive_write_add_filter_grzip(archive), ARCHIVE_OK)
    }
    
    func test_libarchive_supportsGzip() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_add_filter_gzip(archive), ARCHIVE_OK)
    }
    
    func test_libarchive_doesNotSupportLrzip() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        // This filter should fail because lrzip dependencies aren't included in the build
        XCTAssertNotEqual(archive_write_add_filter_lrzip(archive), ARCHIVE_OK)
    }
    
    func test_libarchive_supportsLz4() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_add_filter_lz4(archive), ARCHIVE_OK)
    }
    
    func test_libarchive_supportsLzip() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_add_filter_lzip(archive), ARCHIVE_OK)
    }
    
    func test_libarchive_supportsLzma() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_add_filter_lzma(archive), ARCHIVE_OK)
    }
    
    func test_libarchive_doesNotSupportLzop() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        // This filter should fail because lzop dependencies aren't included in the build
        XCTAssertNotEqual(archive_write_add_filter_lzop(archive), ARCHIVE_OK)
    }
    
    func test_libarchive_supportsNone() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_add_filter_none(archive), ARCHIVE_OK)
    }
    
    #if os(macOS)
    func test_libarchive_supportsProgram() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        // Using "cat" as a simple pass-through program for testing
        XCTAssertEqual(archive_write_add_filter_program(archive, "cat"), ARCHIVE_OK)
    }
    #else
    func test_libarchive_supportsProgram() {
        // Skip test on non-macOS platforms where process spawning is restricted
        print("Skipping test_libarchive_supportsProgram: not supported on this platform")
    }
    #endif
    
    func test_libarchive_supportsUuencode() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_add_filter_uuencode(archive), ARCHIVE_OK)
    }
    
    func test_libarchive_supportsXz() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_add_filter_xz(archive), ARCHIVE_OK)
    }

    func test_libarchive_supportsZstd() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_add_filter_zstd(archive), ARCHIVE_OK)
    }
}
