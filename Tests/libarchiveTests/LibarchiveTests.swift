import XCTest
import libarchive

final class LibarchiveTests: XCTestCase {

    func test_libarchive_version() {

        let versionDetail = String(cString: archive_version_details(), encoding: .ascii) ?? "N/A"

        XCTAssertTrue(versionDetail.contains("libarchive 3.7.9"))

    }

    func test_libarchive_hasZlib() {

        let versionDetail = String(cString: archive_version_details(), encoding: .ascii) ?? "N/A"

        XCTAssertTrue(versionDetail.contains("zlib/1.3"))

    }

    func test_libarchive_hasBz2() {

        let versionDetail = String(cString: archive_version_details(), encoding: .ascii) ?? "N/A"

        XCTAssertTrue(versionDetail.contains("bz2lib/1.0.8"))

    }

    func test_libarchive_hasLzma() {

        let versionDetail = String(cString: archive_version_details(), encoding: .ascii) ?? "N/A"

        XCTAssertTrue(versionDetail.contains("liblzma/5.8.1"))

    }

    func test_libarchive_hasZstd() {

        let versionDetail = String(cString: archive_version_details(), encoding: .ascii) ?? "N/A"

        XCTAssertTrue(versionDetail.contains("libzstd/1.5.7"))

    }

    func test_libarchive_hasLibz4() {

        let versionDetail = String(cString: archive_version_details(), encoding: .ascii) ?? "N/A"

        XCTAssertTrue(versionDetail.contains("liblz4/1.10.0"))

    }

}
