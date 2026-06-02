import Testing
import libarchive

/// Migrated from the XCTest `LibarchiveFilterTests`. These tests assert which
/// `archive_write_add_filter_*` functions this XCFramework build supports,
/// purely at the configuration level (no data is ever written): a filter is
/// "supported" iff adding it to a fresh write handle returns `ARCHIVE_OK`.
@Suite("Archive filter support")
struct ArchiveFilterSupportTests {

    // MARK: - Supported filters

    /// The filters this build is expected to wire up successfully. These reuse
    /// the verified `ArchiveFilter` selectors from `TestSupport.swift`, each of
    /// which carries a display `name` and the matching `archive_write_add_filter_*`
    /// call in its `apply` closure.
    static let supportedFilters: [ArchiveFilter] = [
        .none, .gzip, .bzip2, .xz, .lzma, .lzip,
        .zstd, .lz4, .compress, .uuencode, .b64encode,
    ]

    @Test("supported filters add cleanly", arguments: supportedFilters)
    func supportedFilterAddsCleanly(_ filter: ArchiveFilter) throws {
        let archive = try #require(archive_write_new(), "archive_write_new returned nil")
        defer { archive_write_free(archive) }

        #expect(filter.apply(archive) == ARCHIVE_OK,
                "expected filter \"\(filter.name)\" to add with ARCHIVE_OK")
    }

    // MARK: - Unsupported filters

    /// A filter whose required dependency isn't bundled in this build. Adding it
    /// must NOT return `ARCHIVE_OK`. Modelled locally because there are no
    /// `ArchiveFilter` selectors for these (they're intentionally absent).
    struct UnsupportedFilter: Sendable, CustomStringConvertible {
        let name: String
        let apply: @Sendable (OpaquePointer?) -> Int32
        var description: String { name }
    }

    static let unsupportedFilters: [UnsupportedFilter] = [
        UnsupportedFilter(name: "grzip") { archive_write_add_filter_grzip($0) },
        UnsupportedFilter(name: "lrzip") { archive_write_add_filter_lrzip($0) },
        UnsupportedFilter(name: "lzop") { archive_write_add_filter_lzop($0) },
    ]

    @Test("unsupported filters do not add cleanly", arguments: unsupportedFilters)
    func unsupportedFilterDoesNotAddCleanly(_ filter: UnsupportedFilter) throws {
        let archive = try #require(archive_write_new(), "archive_write_new returned nil")
        defer { archive_write_free(archive) }

        // grzip/lrzip/lzop dependencies aren't included in this build, so
        // libarchive must refuse to add the filter (anything but ARCHIVE_OK).
        #expect(filter.apply(archive) != ARCHIVE_OK,
                "expected filter \"\(filter.name)\" to be unsupported")
    }

    // MARK: - External program filter (macOS only)

    #if os(macOS)
    @Test("program filter (cat) is supported on macOS")
    func programFilterSupported() throws {
        let archive = try #require(archive_write_new(), "archive_write_new returned nil")
        defer { archive_write_free(archive) }

        // "cat" is a simple pass-through program. External process spawning via
        // archive_write_add_filter_program only works on macOS; the other Apple
        // platforms are sandboxed, so this case is compiled out there.
        #expect(archive_write_add_filter_program(archive, "cat") == ARCHIVE_OK)
    }
    #endif
}
