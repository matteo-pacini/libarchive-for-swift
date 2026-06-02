import Testing
import libarchive

// MARK: - RoundTripFormatTests
//
// INTEGRATION suite. For every write format the support matrix classifies as
// `readBack: "full"`, we build a multi-entry in-memory archive (two regular
// files with known bytes plus, where the format supports it, a directory),
// write it with filter `.none`, read it back through
// `archive_read_support_format_all`, and assert the recovered pathnames,
// sizes, file-types, and content match what we put in.
//
// Formats classified `readBack: "none"` (raw, shar, shar_dump) have no reader
// reachable via `_all`, so they get a separate test that only asserts the
// WRITE pipeline (header + data + close) succeeds and produces bytes.
//
// All work is in-memory via the shared `TestSupport.swift` helpers
// (`writeArchive` / `readArchive` / `expectRoundTrip`). Nothing touches the
// filesystem.

@Suite("Round-trip: write formats")
struct RoundTripFormatTests {

    // MARK: Fixture payloads

    /// Two regular files: one ASCII text, one with high/zero bytes to catch
    /// any text-only mangling. Shared across every full round-trip case so the
    /// expected content is identical regardless of the format's path layout.
    static let textBytes = Array("The quick brown fox jumps over 13 lazy dogs.".utf8)
    static let binaryBytes: [UInt8] = [0x00, 0x01, 0x02, 0xFF, 0xFE, 0x80, 0x7F, 0x0A, 0x00, 0xAB]

    // MARK: Full round-trip matrix

    /// One full-round-trip case: a format paired with the exact entries it can
    /// faithfully store. Path layout / directory support varies by family, so
    /// each case carries its own tailored `entries` (and capacity where the
    /// format needs unusually large headroom, e.g. ISO-9660).
    struct FullCase: Sendable, CustomTestStringConvertible {
        let format: ArchiveFormat
        let entries: [ArchiveEntryData]
        let capacity: Int?

        var testDescription: String { format.name }

        init(_ format: ArchiveFormat, entries: [ArchiveEntryData], capacity: Int? = nil) {
            self.format = format
            self.entries = entries
            self.capacity = capacity
        }
    }

    /// Nested layout with a directory entry. Used by the tar family, the cpio
    /// family, zip and 7zip — all of which preserve `path/` directory entries
    /// and sub-paths verbatim.
    static func nestedWithDir() -> [ArchiveEntryData] {
        [
            .file("dir1/a.txt", bytes: textBytes),
            .file("dir1/b.bin", bytes: binaryBytes),
            ArchiveEntryData(path: "dir1/", bytes: [], fileType: .directory),
        ]
    }

    /// Nested files only (no directory entry). Used by WARC, which refuses to
    /// archive directories.
    static func nestedFilesOnly() -> [ArchiveEntryData] {
        [
            .file("dir1/a.txt", bytes: textBytes),
            .file("dir1/b.bin", bytes: binaryBytes),
        ]
    }

    /// Nested files plus a directory whose path has NO trailing slash. xar and
    /// ISO-9660 normalise `dir1/` to `dir1`, so we record the directory in the
    /// canonical (slash-free) form the reader hands back.
    static func nestedWithDirNoSlash() -> [ArchiveEntryData] {
        [
            .file("dir1/a.txt", bytes: textBytes),
            .file("dir1/b.bin", bytes: binaryBytes),
            ArchiveEntryData(path: "dir1", bytes: [], fileType: .directory),
        ]
    }

    /// Flat regular files, no directory. The `ar` family is a flat archive
    /// that stores basenames only and has no directory concept.
    static func flatFiles() -> [ArchiveEntryData] {
        [
            .file("a.txt", bytes: textBytes),
            .file("b.bin", bytes: binaryBytes),
        ]
    }

    static let fullCases: [FullCase] = [
        // --- tar family: read by the unified tar reader in _all ---
        FullCase(.ustar, entries: nestedWithDir()),
        FullCase(.pax, entries: nestedWithDir()),
        FullCase(.paxRestricted, entries: nestedWithDir()),
        FullCase(.gnutar, entries: nestedWithDir()),
        // V7 tar truncates names at 100 chars; our paths are short, so a
        // directory entry round-trips fine.
        FullCase(.v7tar, entries: nestedWithDir()),

        // --- cpio family: shared cpio reader auto-detects the variant ---
        FullCase(ArchiveFormat(name: "cpio") { archive_write_set_format_cpio($0) },
                 entries: nestedWithDir()),
        FullCase(ArchiveFormat(name: "cpio_bin") { archive_write_set_format_cpio_bin($0) },
                 entries: nestedWithDir()),
        FullCase(.cpioNewc, entries: nestedWithDir()),
        FullCase(.cpioOdc, entries: nestedWithDir()),
        FullCase(ArchiveFormat(name: "cpio_pwb") { archive_write_set_format_cpio_pwb($0) },
                 entries: nestedWithDir()),

        // --- ar family: flat, basename-only, no directories ---
        FullCase(ArchiveFormat(name: "ar_bsd") { archive_write_set_format_ar_bsd($0) },
                 entries: flatFiles()),
        FullCase(ArchiveFormat(name: "ar_svr4") { archive_write_set_format_ar_svr4($0) },
                 entries: flatFiles()),

        // --- containers with built-in compression: external filter MUST be none ---
        FullCase(.zip, entries: nestedWithDir()),
        FullCase(.sevenZip, entries: nestedWithDir()),
        FullCase(ArchiveFormat(name: "xar") { archive_write_set_format_xar($0) },
                 entries: nestedWithDirNoSlash()),

        // --- WARC: resource records, no directory support ---
        FullCase(ArchiveFormat(name: "warc") { archive_write_set_format_warc($0) },
                 entries: nestedFilesOnly()),

        // --- ISO-9660: large fixed overhead, normalises directory names ---
        FullCase(ArchiveFormat(name: "iso9660") { archive_write_set_format_iso9660($0) },
                 entries: nestedWithDirNoSlash(),
                 capacity: 4 * 1024 * 1024),
    ]

    @Test("write -> read recovers entries", arguments: fullCases)
    func fullRoundTrip(_ testCase: FullCase) throws {
        let bytes = try writeArchive(
            format: testCase.format,
            filter: .none,
            entries: testCase.entries,
            capacity: testCase.capacity
        )
        #expect(!bytes.isEmpty, "\(testCase.format.name) produced an empty archive")

        let recovered = try readArchive(bytes)

        // Index by path so we can assert per-input regardless of any synthetic
        // entries (e.g. ISO-9660 adds a `.` root) or reordering (zip/cpio).
        let byPath = Dictionary(
            recovered.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for input in testCase.entries {
            let got = try #require(
                byPath[input.path],
                "\(testCase.format.name): missing recovered entry for \"\(input.path)\""
            )
            #expect(got.fileType == input.fileType,
                    "\(testCase.format.name): file-type mismatch for \"\(input.path)\"")
            #expect(got.bytes == input.bytes,
                    "\(testCase.format.name): content mismatch for \"\(input.path)\"")
            // Regular-file headers must report the byte count we wrote;
            // directory entries carry no content.
            if input.fileType == .regular {
                #expect(got.size == input.bytes.count,
                        "\(testCase.format.name): size mismatch for \"\(input.path)\"")
            }
        }

        // Belt-and-braces: the shared order-independent matcher.
        expectRoundTrip(testCase.entries, recovered: recovered)
    }

    // MARK: Write-only matrix (readBack: "none")

    /// A format with no reader reachable through `archive_read_support_format_all`.
    /// We only assert the write side completes and emits bytes.
    struct WriteOnlyCase: Sendable, CustomTestStringConvertible {
        let format: ArchiveFormat
        var testDescription: String { format.name }
        init(_ format: ArchiveFormat) { self.format = format }
    }

    static let writeOnlyCases: [WriteOnlyCase] = [
        // raw: single unstructured stream, no entry metadata, not in _all.
        WriteOnlyCase(ArchiveFormat(name: "raw") { archive_write_set_format_raw($0) }),
        // shar / shar_dump: emit /bin/sh scripts; no reader symbol exists.
        WriteOnlyCase(ArchiveFormat(name: "shar") { archive_write_set_format_shar($0) }),
        WriteOnlyCase(ArchiveFormat(name: "shar_dump") { archive_write_set_format_shar_dump($0) }),
    ]

    @Test("write succeeds (no read-back)", arguments: writeOnlyCases)
    func writeOnly(_ testCase: WriteOnlyCase) throws {
        // `raw` only supports a single entry; keep all write-only cases to one
        // regular file so the header/data/close pipeline is exercised uniformly.
        let entries: [ArchiveEntryData] = [.file("note.txt", bytes: Self.textBytes)]

        let bytes = try writeArchive(format: testCase.format, filter: .none, entries: entries)
        #expect(!bytes.isEmpty, "\(testCase.format.name) produced no output")
    }
}
