import Testing
import libarchive

// MARK: - Test-local probes
//
// These do NOT redefine anything from TestSupport.swift. The shared
// `readArchive` helper *throws* on a non-OK status (which is exactly what we
// want to assert is reachable), but it discards the raw libarchive diagnostics
// — `archive_error_string()` / `archive_errno()` — that this negative-path
// suite needs to inspect directly. So we drive `archive_read_*` by hand here to
// capture those fields. Everything stays in-memory and synchronous within one
// function body, so there are no Sendable / concurrency concerns with the
// OpaquePointer.

/// The outcome of pointing a fresh, fully-supported reader at a blob of bytes:
/// the status from the first `archive_read_next_header`, plus the diagnostics
/// libarchive surfaced on the handle.
private struct ReaderProbe {
    /// Status returned by `archive_read_open_memory` (ARCHIVE_OK unless the
    /// blob is rejected at open time).
    var openStatus: Int32
    /// Status returned by the first `archive_read_next_header` call. Only
    /// meaningful when `openStatus == ARCHIVE_OK`; otherwise left at its
    /// sentinel.
    var headerStatus: Int32
    /// `archive_error_string()` read off the handle after the failing call
    /// (empty string when libarchive reported no message / a null pointer).
    var errorString: String
    /// `archive_errno()` read off the handle after the failing call.
    var errnoValue: Int32
}

/// Sentinel that is never a real libarchive return code, so a test can tell
/// "next_header was never reached" apart from any genuine status.
private let kHeaderStatusUnset: Int32 = 1234

/// Opens `data` with a reader that supports every format+filter compiled into
/// this build, attempts to read the first header, and reports the status and
/// diagnostics without throwing. Frees the reader before returning.
private func probeReader(_ data: [UInt8]) -> ReaderProbe {
    let r = archive_read_new()
    defer { archive_read_free(r) }

    _ = archive_read_support_format_all(r)
    _ = archive_read_support_filter_all(r)

    func diagnostics() -> (String, Int32) {
        let msg = archive_error_string(r).map { String(cString: $0) } ?? ""
        return (msg, archive_errno(r))
    }

    var probe = ReaderProbe(
        openStatus: ARCHIVE_OK,
        headerStatus: kHeaderStatusUnset,
        errorString: "",
        errnoValue: 0
    )

    data.withUnsafeBytes { raw in
        // For a zero-length buffer baseAddress is nil; libarchive accepts a
        // null pointer paired with size 0, so this still exercises the empty
        // case rather than crashing.
        let openRC = archive_read_open_memory(r, raw.baseAddress, raw.count)
        probe.openStatus = openRC
        guard openRC == ARCHIVE_OK else {
            (probe.errorString, probe.errnoValue) = diagnostics()
            return
        }

        var entryPtr: OpaquePointer? = nil
        let hdrRC = archive_read_next_header(r, &entryPtr)
        probe.headerStatus = hdrRC
        (probe.errorString, probe.errnoValue) = diagnostics()
    }

    return probe
}

// MARK: - Lifecycle

@Suite("Archive reader/writer lifecycle and negative paths")
struct ArchiveErrorLifecycleTests {

    @Test("archive_read_new succeeds and archive_read_free returns OK")
    func readerLifecycle() throws {
        let r = try #require(archive_read_new(), "archive_read_new returned nil")
        // free() implicitly closes; an unopened reader frees cleanly with OK.
        #expect(archive_read_free(r) == ARCHIVE_OK)
    }

    @Test("archive_write_new succeeds and archive_write_free returns OK")
    func writerLifecycle() throws {
        let w = try #require(archive_write_new(), "archive_write_new returned nil")
        #expect(archive_write_free(w) == ARCHIVE_OK)
    }

    @Test("a freshly created reader can be configured then freed")
    func readerConfigureThenFree() throws {
        let r = try #require(archive_read_new())
        #expect(archive_read_support_format_all(r) == ARCHIVE_OK)
        #expect(archive_read_support_filter_all(r) == ARCHIVE_OK)
        #expect(archive_read_free(r) == ARCHIVE_OK)
    }

    @Test("a freshly created writer can be configured then freed")
    func writerConfigureThenFree() throws {
        let w = try #require(archive_write_new())
        #expect(archive_write_set_format_ustar(w) == ARCHIVE_OK)
        #expect(archive_write_add_filter_none(w) == ARCHIVE_OK)
        #expect(archive_write_free(w) == ARCHIVE_OK)
    }

    // MARK: - Garbage / malformed input

    /// A grab-bag of byte blobs that are NOT a valid archive of any format the
    /// `_all` reader bids on. Each must fail to produce a first entry.
    enum GarbageInput: String, CaseIterable {
        case asciiText
        case zeroBytes
        case ffBytes
        case randomBinary
        case bogusMagic
        case shortTarMagic

        var bytes: [UInt8] {
            switch self {
            case .asciiText:
                // Plain prose: no archive bidder should claim it.
                return Array("this is just some plain text, not an archive at all\n".utf8)
            case .zeroBytes:
                // A run of NUL bytes that is too short / structureless to be a
                // real archive header.
                return [UInt8](repeating: 0x00, count: 64)
            case .ffBytes:
                return [UInt8](repeating: 0xFF, count: 128)
            case .randomBinary:
                // Deterministic pseudo-random spread across the byte range.
                return (0..<256).map { UInt8(($0 &* 31 &+ 7) & 0xFF) }
            case .bogusMagic:
                // Looks like it might be something, but matches nothing.
                return Array("NOTAREALARCHIVEMAGIC\u{01}\u{02}\u{03}\u{04}".utf8)
            case .shortTarMagic:
                // The "ustar" token in isolation, with no surrounding 512-byte
                // tar header — not enough to parse as a tar entry.
                return Array("ustar".utf8) + [UInt8](repeating: 0x00, count: 10)
            }
        }
    }

    @Test("garbage bytes fail to read and surface a libarchive diagnostic",
          arguments: GarbageInput.allCases)
    func garbageBytesFailToRead(_ input: GarbageInput) throws {
        // The shared helper must reject it by throwing.
        #expect(throws: ArchiveError.self) {
            _ = try readArchive(input.bytes)
        }

        // And the raw probe must report a non-OK terminal status with a
        // non-empty diagnostic message.
        let probe = probeReader(input.bytes)

        // The failure can manifest either at open time or at first-header time,
        // depending on how aggressively a bidder rejects the blob.
        if probe.openStatus != ARCHIVE_OK {
            #expect(probe.openStatus != ARCHIVE_OK)
            #expect(!probe.errorString.isEmpty,
                    "expected a non-empty archive_error_string for \(input.rawValue)")
        } else {
            // Opened, but the first header read must NOT yield a usable entry.
            #expect(probe.headerStatus != ARCHIVE_OK,
                    "expected non-OK first-header status for \(input.rawValue), got \(probe.headerStatus)")
            // libarchive treats "nothing here" as EOF for an unrecognised
            // stream; a parse failure is a fatal/warn with a message. Either
            // way it is decidedly not ARCHIVE_OK, and a hard failure carries a
            // diagnostic.
            if probe.headerStatus == ARCHIVE_FATAL
                || probe.headerStatus == ARCHIVE_FAILED
                || probe.headerStatus == ARCHIVE_WARN {
                #expect(!probe.errorString.isEmpty,
                        "expected a non-empty archive_error_string for \(input.rawValue)")
                #expect(probe.errnoValue != 0,
                        "expected a non-zero archive_errno for \(input.rawValue)")
            }
        }
    }

    // MARK: - Truncated input

    @Test("a truncated valid archive fails to read cleanly")
    func truncatedArchiveFailsToRead() throws {
        // Build a real, multi-entry ustar+gzip archive, then lop off its tail so
        // the gzip stream / tar trailer is incomplete.
        let inputs = [
            ArchiveEntryData.file("alpha.txt", text: String(repeating: "alpha ", count: 200)),
            ArchiveEntryData.file("beta.txt", text: String(repeating: "beta ", count: 200)),
        ]
        let full = try writeArchive(format: .ustar, filter: .gzip, entries: inputs)
        try #require(full.count > 16, "archive too small to meaningfully truncate")

        // Keep only the first ~40% of the bytes.
        let truncated = Array(full.prefix(max(8, full.count * 2 / 5)))

        // Reading the truncated blob must not silently recover both entries.
        let probe = probeReader(truncated)
        let recovered = (try? readArchive(truncated)) ?? []
        let recoveredPaths = Set(recovered.map(\.path))

        let damageDetected =
            probe.openStatus != ARCHIVE_OK
            || probe.headerStatus == ARCHIVE_FATAL
            || probe.headerStatus == ARCHIVE_FAILED
            || probe.headerStatus == ARCHIVE_WARN
            || !recoveredPaths.isSuperset(of: ["alpha.txt", "beta.txt"])

        #expect(damageDetected,
                "truncated archive unexpectedly read back as intact: \(recoveredPaths)")

        // When the corruption is reported at probe time, libarchive must have a
        // diagnostic string for it.
        if probe.openStatus != ARCHIVE_OK
            || probe.headerStatus == ARCHIVE_FATAL
            || probe.headerStatus == ARCHIVE_FAILED {
            #expect(!probe.errorString.isEmpty,
                    "expected a diagnostic for the truncated archive")
        }
    }

    @Test("a header truncated mid-stream yields an error from the shared helper")
    func truncatedTarHeaderThrows() throws {
        // ustar headers are 512 bytes. Produce one valid entry then truncate
        // partway through what would be the second block, guaranteeing a parse
        // failure rather than a clean EOF.
        let inputs = [ArchiveEntryData.file("only.txt", text: "0123456789")]
        let full = try writeArchive(format: .ustar, filter: .none, entries: inputs)
        try #require(full.count >= 600, "ustar archive shorter than expected")

        // Cut inside the first 512-byte header block so the tar bidder accepts
        // it but then runs out of bytes parsing the entry.
        let truncated = Array(full.prefix(300))

        #expect(throws: ArchiveError.self) {
            _ = try readArchive(truncated)
        }
    }

    // MARK: - Empty / zero-length

    @Test("a zero-length buffer reads as empty without crashing")
    func emptyBufferReadsAsEmpty() throws {
        let empty: [UInt8] = []

        // The shared helper supports archive_read_support_format_empty (via
        // _all), so a zero-byte input is a valid empty archive: zero entries,
        // no throw.
        let recovered = try readArchive(empty)
        #expect(recovered.isEmpty, "expected no entries from a zero-length buffer")

        // Probing it directly: open succeeds, the first header read reports EOF
        // (the empty format bids and yields no entries).
        let probe = probeReader(empty)
        #expect(probe.openStatus == ARCHIVE_OK)
        #expect(probe.headerStatus == ARCHIVE_EOF,
                "expected EOF on first header of an empty archive, got \(probe.headerStatus)")
    }

    @Test("an all-zero buffer reads back with no usable entries")
    func zeroFilledBufferHasNoEntries() throws {
        // A block of NULs is what a tar end-of-archive marker looks like; the
        // reader must not invent entries from it.
        let zeros = [UInt8](repeating: 0x00, count: 1024)
        let recovered = (try? readArchive(zeros)) ?? []
        #expect(recovered.isEmpty, "expected no entries from an all-zero buffer")
    }

    // MARK: - Format / filter reporting after a known round-trip

    /// A format whose family code we can predict after reading it back, paired
    /// with the filter it was written through.
    struct FormatFilterCase: Sendable, CustomTestStringConvertible {
        let label: String
        let format: ArchiveFormat
        let filter: ArchiveFilter
        /// Expected `archive_format(a) & ARCHIVE_FORMAT_BASE_MASK`.
        let expectedFormatFamily: Int32
        /// Expected `archive_filter_code(a, 0)`.
        let expectedFilterCode: Int32

        var testDescription: String { label }
    }

    static let formatFilterCases: [FormatFilterCase] = [
        .init(label: "ustar+none",
              format: .ustar, filter: .none,
              expectedFormatFamily: ARCHIVE_FORMAT_TAR,
              expectedFilterCode: ARCHIVE_FILTER_NONE),
        .init(label: "pax+none",
              format: .pax, filter: .none,
              expectedFormatFamily: ARCHIVE_FORMAT_TAR,
              expectedFilterCode: ARCHIVE_FILTER_NONE),
        .init(label: "gnutar+gzip",
              format: .gnutar, filter: .gzip,
              expectedFormatFamily: ARCHIVE_FORMAT_TAR,
              expectedFilterCode: ARCHIVE_FILTER_GZIP),
        .init(label: "cpio_newc+none",
              format: .cpioNewc, filter: .none,
              expectedFormatFamily: ARCHIVE_FORMAT_CPIO,
              expectedFilterCode: ARCHIVE_FILTER_NONE),
        .init(label: "zip+none",
              format: .zip, filter: .none,
              expectedFormatFamily: ARCHIVE_FORMAT_ZIP,
              expectedFilterCode: ARCHIVE_FILTER_NONE),
    ]

    @Test("archive_format and archive_filter_code match a known round-trip",
          arguments: formatFilterCases)
    func formatAndFilterReportedAfterRoundTrip(_ testCase: FormatFilterCase) throws {
        let payload = ArchiveEntryData.file("report.bin", bytes: (0..<300).map { UInt8($0 & 0xFF) })
        let bytes = try writeArchive(format: testCase.format, filter: testCase.filter, entries: [payload])

        let r = try #require(archive_read_new())
        defer { archive_read_free(r) }
        _ = archive_read_support_format_all(r)
        _ = archive_read_support_filter_all(r)

        var formatFamily: Int32 = -1
        var formatRaw: Int32 = -1
        var filterCode: Int32 = -1
        var headerStatus: Int32 = kHeaderStatusUnset
        var recoveredPath = ""

        bytes.withUnsafeBytes { raw in
            guard archive_read_open_memory(r, raw.baseAddress, raw.count) == ARCHIVE_OK else { return }
            var entryPtr: OpaquePointer? = nil
            headerStatus = archive_read_next_header(r, &entryPtr)
            guard headerStatus == ARCHIVE_OK else { return }

            recoveredPath = archive_entry_pathname(entryPtr).map { String(cString: $0) } ?? ""
            formatRaw = archive_format(r)
            formatFamily = formatRaw & ARCHIVE_FORMAT_BASE_MASK
            filterCode = archive_filter_code(r, 0)  // 0 == outermost filter
            _ = archive_read_close(r)
        }

        #expect(headerStatus == ARCHIVE_OK,
                "failed to read first header for \(testCase.label) (status \(headerStatus))")
        #expect(recoveredPath == "report.bin")
        #expect(formatFamily == testCase.expectedFormatFamily,
                "format family for \(testCase.label): expected \(testCase.expectedFormatFamily), got \(formatFamily) (raw \(formatRaw))")
        #expect(filterCode == testCase.expectedFilterCode,
                "filter code for \(testCase.label): expected \(testCase.expectedFilterCode), got \(filterCode)")
    }

    @Test("a clean read leaves archive_errno at zero and no error string")
    func cleanReadHasNoError() throws {
        let inputs = [ArchiveEntryData.file("clean.txt", text: "no errors here")]
        let bytes = try writeArchive(format: .ustar, filter: .none, entries: inputs)

        let probe = probeReader(bytes)
        #expect(probe.openStatus == ARCHIVE_OK)
        #expect(probe.headerStatus == ARCHIVE_OK,
                "expected a clean first header, got \(probe.headerStatus)")
        #expect(probe.errorString.isEmpty,
                "expected no archive_error_string on a clean read, got \"\(probe.errorString)\"")
        #expect(probe.errnoValue == 0,
                "expected archive_errno == 0 on a clean read, got \(probe.errnoValue)")
    }
}
