import Testing
import libarchive

/// Format-acceptance tests, migrated from the per-format XCTest methods to a
/// single parameterized Swift Testing case.
///
/// Each case asserts that the corresponding `archive_write_set_format_*` call
/// succeeds (`ARCHIVE_OK`) on a freshly created write handle, with a proper
/// `archive_write_new` / `archive_write_free` lifecycle. This deliberately only
/// checks that the writer *accepts* the format selector — round-trip behaviour
/// (and the read-back classification) lives in the dedicated round-trip suites.
@Suite("Archive format support")
struct ArchiveFormatSupportTests {

    /// The complete set of writable formats from the support matrix. Each is an
    /// `ArchiveFormat` value wrapping exactly one `archive_write_set_format_*`
    /// setter. The pre-built `ArchiveFormat.*` values from `TestSupport` are
    /// reused where they exist; the remainder are constructed inline.
    static let allFormats: [ArchiveFormat] = [
        .sevenZip,
        ArchiveFormat(name: "ar_bsd") { archive_write_set_format_ar_bsd($0) },
        ArchiveFormat(name: "ar_svr4") { archive_write_set_format_ar_svr4($0) },
        ArchiveFormat(name: "cpio") { archive_write_set_format_cpio($0) },
        ArchiveFormat(name: "cpio_bin") { archive_write_set_format_cpio_bin($0) },
        .cpioNewc,
        .cpioOdc,
        ArchiveFormat(name: "cpio_pwb") { archive_write_set_format_cpio_pwb($0) },
        .gnutar,
        ArchiveFormat(name: "iso9660") { archive_write_set_format_iso9660($0) },
        ArchiveFormat(name: "mtree") { archive_write_set_format_mtree($0) },
        ArchiveFormat(name: "mtree_classic") { archive_write_set_format_mtree_classic($0) },
        .pax,
        .paxRestricted,
        ArchiveFormat(name: "raw") { archive_write_set_format_raw($0) },
        ArchiveFormat(name: "shar") { archive_write_set_format_shar($0) },
        ArchiveFormat(name: "shar_dump") { archive_write_set_format_shar_dump($0) },
        .ustar,
        .v7tar,
        ArchiveFormat(name: "warc") { archive_write_set_format_warc($0) },
        ArchiveFormat(name: "xar") { archive_write_set_format_xar($0) },
        .zip,
    ]

    @Test("write handle accepts the format selector", arguments: allFormats)
    func writerAcceptsFormat(_ format: ArchiveFormat) throws {
        let archive = try #require(
            archive_write_new(),
            "archive_write_new returned nil for format \(format.name)"
        )
        defer { archive_write_free(archive) }

        #expect(
            format.apply(archive) == ARCHIVE_OK,
            "archive_write_set_format_\(format.name) did not return ARCHIVE_OK"
        )
    }
}

extension ArchiveFormat: CustomTestStringConvertible {
    public var testDescription: String { name }
}
