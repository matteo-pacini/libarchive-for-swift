import XCTest
import libarchive

final class LibarchiveFormatTests: XCTestCase {

    // MARK: Write

    func test_libarchive_supports7zipFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_7zip(archive), ARCHIVE_OK)

    }


    func test_libarchive_supportsArBsd() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_ar_bsd(archive), ARCHIVE_OK)
    }

    func test_libarchive_supportsArSvr4() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_ar_svr4(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsCpioFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_cpio(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsCpioBinFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_cpio_bin(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsCpioNewcFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_cpio_newc(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsCpioOdcFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_cpio_odc(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsCpioPwbFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_cpio_pwb(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsGnutarFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_gnutar(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsIso9660Format() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_iso9660(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsMtreeFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_mtree(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsMtreeClassicFormat() {
        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_mtree_classic(archive), ARCHIVE_OK)
    }
    

    func test_libarchive_supportsPaxFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_pax(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsPaxRestrictedFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_pax_restricted(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsRawFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_raw(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsSharFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_shar(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsSharDumpFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_shar_dump(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsUsTarFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_ustar(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsV7TarFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_v7tar(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsWarcFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_warc(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsXarFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_xar(archive), ARCHIVE_OK)

    }

    func test_libarchive_supportsZipFormat() {

        let archive = archive_write_new()
        XCTAssertNotNil(archive)

        defer { archive_write_free(archive) }

        XCTAssertEqual(archive_write_set_format_zip(archive), ARCHIVE_OK)

    }

}
