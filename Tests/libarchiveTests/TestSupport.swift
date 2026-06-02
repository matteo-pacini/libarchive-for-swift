import Testing
import libarchive

// MARK: - Mirrored C constants
//
// The AE_IF* macros in archive_entry.h are cast-style macros
// (e.g. `#define AE_IFREG ((mode_t)0100000)`) which the Clang importer
// does NOT surface in Swift. We mirror the ones we need here.
//
// NOTE the asymmetry between the libarchive setter and getter:
//   - archive_entry_set_filetype takes `unsigned int`  -> Swift UInt32
//   - archive_entry_filetype()   returns `mode_t`       -> Swift UInt16 on Apple
// So `FileType.rawValue` is UInt32 (setter-shaped) and the reader path
// widens the UInt16 getter result back to UInt32 for comparison.

/// POSIX file-type bits, mirrored from the `AE_IF*` cast macros that
/// don't import into Swift. Raw value is shaped for the *setter*
/// (`archive_entry_set_filetype`, which wants `unsigned int`).
public enum FileType: UInt32, Sendable, CaseIterable {
    case regular   = 0o100000  // AE_IFREG
    case directory = 0o040000  // AE_IFDIR
    case symlink   = 0o120000  // AE_IFLNK
    case fifo      = 0o010000  // AE_IFIFO
    case socket    = 0o140000  // AE_IFSOCK
    case character = 0o020000  // AE_IFCHR
    case block     = 0o060000  // AE_IFBLK

    /// Mask isolating the file-type bits within a full mode word (AE_IFMT).
    public static let mask: UInt32 = 0o170000

    /// Build a `FileType` from a raw mode word as returned by
    /// `archive_entry_filetype()` (a `mode_t`/UInt16 on Apple).
    public init?(modeWord: UInt32) {
        self.init(rawValue: modeWord & FileType.mask)
    }
}

// MARK: - Errors

/// Raised when a libarchive call returns a non-OK / fatal status.
public struct ArchiveError: Error, CustomStringConvertible {
    public let stage: String
    public let code: Int32
    public let message: String

    public var description: String {
        "ArchiveError(stage: \(stage), code: \(code), message: \"\(message)\")"
    }
}

/// Reads the last error string off a libarchive handle (may be empty/nil).
private func errorString(_ handle: OpaquePointer?) -> String {
    guard let cstr = archive_error_string(handle) else { return "" }
    return String(cString: cstr)
}

// MARK: - Entry model

/// A filesystem-free description of one archive entry, used both as input to
/// `writeArchive` and as output from `readArchive`.
public struct ArchiveEntryData: Sendable, Equatable {
    public var path: String
    public var bytes: [UInt8]
    public var fileType: FileType
    /// Declared entry size. On the write side this is derived from `bytes.count`
    /// unless explicitly overridden; on the read side it's the size libarchive
    /// reports for the entry header.
    public var size: Int

    public init(path: String, bytes: [UInt8], fileType: FileType = .regular, size: Int? = nil) {
        self.path = path
        self.bytes = bytes
        self.fileType = fileType
        self.size = size ?? bytes.count
    }

    /// Convenience: a regular file from a UTF-8 string payload.
    public static func file(_ path: String, text: String, perm: UInt16 = 0o644) -> ArchiveEntryData {
        ArchiveEntryData(path: path, bytes: Array(text.utf8), fileType: .regular)
    }

    /// Convenience: a regular file from raw bytes.
    public static func file(_ path: String, bytes: [UInt8]) -> ArchiveEntryData {
        ArchiveEntryData(path: path, bytes: bytes, fileType: .regular)
    }
}

// MARK: - Format / filter configuration

/// A format setter, wrapped so the configuration is a value you can pass
/// around. The closure receives the freshly created write handle and must
/// call exactly one `archive_write_set_format_*` on it, returning the status.
public struct ArchiveFormat: Sendable {
    public let name: String
    public let apply: @Sendable (OpaquePointer?) -> Int32

    public init(name: String, apply: @escaping @Sendable (OpaquePointer?) -> Int32) {
        self.name = name
        self.apply = apply
    }

    public static let ustar = ArchiveFormat(name: "ustar") { archive_write_set_format_ustar($0) }
    public static let pax = ArchiveFormat(name: "pax") { archive_write_set_format_pax($0) }
    public static let paxRestricted = ArchiveFormat(name: "pax_restricted") { archive_write_set_format_pax_restricted($0) }
    public static let gnutar = ArchiveFormat(name: "gnutar") { archive_write_set_format_gnutar($0) }
    public static let v7tar = ArchiveFormat(name: "v7tar") { archive_write_set_format_v7tar($0) }
    public static let cpioNewc = ArchiveFormat(name: "cpio_newc") { archive_write_set_format_cpio_newc($0) }
    public static let cpioOdc = ArchiveFormat(name: "cpio_odc") { archive_write_set_format_cpio_odc($0) }
    public static let zip = ArchiveFormat(name: "zip") { archive_write_set_format_zip($0) }
    public static let sevenZip = ArchiveFormat(name: "7zip") { archive_write_set_format_7zip($0) }
}

/// A filter adder, same idea as `ArchiveFormat`. The closure must call exactly
/// one `archive_write_add_filter_*` and return the status. For container
/// formats with built-in compression (zip/7zip/xar) use `.none`.
public struct ArchiveFilter: Sendable {
    public let name: String
    public let apply: @Sendable (OpaquePointer?) -> Int32

    public init(name: String, apply: @escaping @Sendable (OpaquePointer?) -> Int32) {
        self.name = name
        self.apply = apply
    }

    public static let none = ArchiveFilter(name: "none") { archive_write_add_filter_none($0) }
    public static let gzip = ArchiveFilter(name: "gzip") { archive_write_add_filter_gzip($0) }
    public static let bzip2 = ArchiveFilter(name: "bzip2") { archive_write_add_filter_bzip2($0) }
    public static let xz = ArchiveFilter(name: "xz") { archive_write_add_filter_xz($0) }
    public static let lzma = ArchiveFilter(name: "lzma") { archive_write_add_filter_lzma($0) }
    public static let lzip = ArchiveFilter(name: "lzip") { archive_write_add_filter_lzip($0) }
    public static let zstd = ArchiveFilter(name: "zstd") { archive_write_add_filter_zstd($0) }
    public static let lz4 = ArchiveFilter(name: "lz4") { archive_write_add_filter_lz4($0) }
    public static let compress = ArchiveFilter(name: "compress") { archive_write_add_filter_compress($0) }
    public static let uuencode = ArchiveFilter(name: "uuencode") { archive_write_add_filter_uuencode($0) }
    public static let b64encode = ArchiveFilter(name: "b64encode") { archive_write_add_filter_b64encode($0) }
}

// MARK: - Writing

/// Writes the given entries into an in-memory archive using the chosen format
/// and filter, returning the exact bytes produced (already trimmed to the
/// `used` length reported by libarchive — no trailing block padding).
///
/// All libarchive calls happen synchronously on the calling thread inside a
/// single `withUnsafeMutableBytes` block, so the buffer pointer stays valid
/// for the whole write -> close lifetime.
public func writeArchive(
    format: ArchiveFormat,
    filter: ArchiveFilter,
    entries: [ArchiveEntryData],
    capacity: Int? = nil
) throws -> [UInt8] {
    // Default capacity: generous headroom over the raw payload plus tar/cpio
    // headers and any (worst-case) expansion from a weak compressor.
    let payloadTotal = entries.reduce(0) { $0 + max($1.size, $1.bytes.count) }
    let bufferSize = capacity ?? max(64 * 1024, payloadTotal * 2 + 64 * 1024)

    let w = archive_write_new()
    guard w != nil else {
        throw ArchiveError(stage: "archive_write_new", code: ARCHIVE_FATAL, message: "returned nil")
    }
    defer { archive_write_free(w) }

    let fmtRC = format.apply(w)
    guard fmtRC == ARCHIVE_OK else {
        throw ArchiveError(stage: "set_format(\(format.name))", code: fmtRC, message: errorString(w))
    }
    let filtRC = filter.apply(w)
    guard filtRC == ARCHIVE_OK else {
        throw ArchiveError(stage: "add_filter(\(filter.name))", code: filtRC, message: errorString(w))
    }

    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var used = 0
    var thrown: ArchiveError? = nil

    buffer.withUnsafeMutableBytes { raw in
        let openRC = archive_write_open_memory(w, raw.baseAddress, raw.count, &used)
        guard openRC == ARCHIVE_OK else {
            thrown = ArchiveError(stage: "write_open_memory", code: openRC, message: errorString(w))
            return
        }

        for entry in entries {
            let e = archive_entry_new()
            defer { archive_entry_free(e) }

            archive_entry_set_pathname(e, entry.path)
            archive_entry_set_size(e, la_int64_t(entry.size))
            archive_entry_set_filetype(e, entry.fileType.rawValue)
            archive_entry_set_perm(e, 0o644)

            let hdrRC = archive_write_header(w, e)
            guard hdrRC == ARCHIVE_OK else {
                thrown = ArchiveError(stage: "write_header(\(entry.path))", code: hdrRC, message: errorString(w))
                return
            }

            if !entry.bytes.isEmpty {
                let written: la_ssize_t = entry.bytes.withUnsafeBytes { pb in
                    archive_write_data(w, pb.baseAddress, pb.count)
                }
                guard written == la_ssize_t(entry.bytes.count) else {
                    thrown = ArchiveError(
                        stage: "write_data(\(entry.path))",
                        code: ARCHIVE_FAILED,
                        message: "wrote \(written) of \(entry.bytes.count): \(errorString(w))"
                    )
                    return
                }
            }
        }

        let closeRC = archive_write_close(w)
        guard closeRC == ARCHIVE_OK else {
            thrown = ArchiveError(stage: "write_close", code: closeRC, message: errorString(w))
            return
        }
    }

    if let thrown { throw thrown }

    return Array(buffer[0..<used])
}

// MARK: - Reading

/// Reads an in-memory archive buffer and returns the recovered entries.
///
/// Uses `archive_read_support_format_all` + `archive_read_support_filter_all`,
/// so it transparently auto-detects the tar/cpio/zip/etc. family and any
/// compression filter. The recovered `size` is what the entry header reports;
/// `bytes` is the fully drained entry content.
public func readArchive(_ data: [UInt8]) throws -> [ArchiveEntryData] {
    let r = archive_read_new()
    guard r != nil else {
        throw ArchiveError(stage: "archive_read_new", code: ARCHIVE_FATAL, message: "returned nil")
    }
    defer { archive_read_free(r) }

    _ = archive_read_support_format_all(r)
    _ = archive_read_support_filter_all(r)

    var results: [ArchiveEntryData] = []
    var thrown: ArchiveError? = nil

    data.withUnsafeBytes { raw in
        let openRC = archive_read_open_memory(r, raw.baseAddress, raw.count)
        guard openRC == ARCHIVE_OK else {
            thrown = ArchiveError(stage: "read_open_memory", code: openRC, message: errorString(r))
            return
        }

        while true {
            var entryPtr: OpaquePointer? = nil
            let hdrRC = archive_read_next_header(r, &entryPtr)
            if hdrRC == ARCHIVE_EOF { break }
            guard hdrRC == ARCHIVE_OK || hdrRC == ARCHIVE_WARN else {
                thrown = ArchiveError(stage: "read_next_header", code: hdrRC, message: errorString(r))
                return
            }

            let pathPtr = archive_entry_pathname(entryPtr)
            let path = pathPtr.map { String(cString: $0) } ?? ""
            let declaredSize = Int(archive_entry_size(entryPtr))
            let typeWord = UInt32(archive_entry_filetype(entryPtr))  // mode_t (UInt16) -> widen
            let fileType = FileType(modeWord: typeWord) ?? .regular

            // Drain the entry's data with a streaming loop so we don't rely on
            // a single read returning everything.
            var content: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            var readError: ArchiveError? = nil
            chunkLoop: while true {
                let n: la_ssize_t = chunk.withUnsafeMutableBytes { cb in
                    archive_read_data(r, cb.baseAddress, cb.count)
                }
                if n == 0 { break }
                if n < 0 {
                    readError = ArchiveError(stage: "read_data(\(path))", code: ARCHIVE_FAILED, message: errorString(r))
                    break chunkLoop
                }
                content.append(contentsOf: chunk[0..<Int(n)])
            }
            if let readError {
                thrown = readError
                return
            }

            results.append(
                ArchiveEntryData(path: path, bytes: content, fileType: fileType, size: declaredSize)
            )
        }

        _ = archive_read_close(r)
    }

    if let thrown { throw thrown }

    return results
}

// MARK: - Round-trip ergonomics

/// Writes `entries` with the given format/filter, reads them back, and returns
/// the recovered entries. Convenience wrapper over `writeArchive`/`readArchive`.
public func roundTrip(
    format: ArchiveFormat,
    filter: ArchiveFilter,
    entries: [ArchiveEntryData]
) throws -> [ArchiveEntryData] {
    let bytes = try writeArchive(format: format, filter: filter, entries: entries)
    return try readArchive(bytes)
}

/// Asserts that `recovered` contains, for every input entry, an entry with the
/// same path whose `bytes` match. Order-independent (zip/cpio may reorder, and
/// some formats add synthetic entries). Uses Swift Testing's `#expect`.
public func expectRoundTrip(
    _ inputs: [ArchiveEntryData],
    recovered: [ArchiveEntryData],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let byPath = Dictionary(
        recovered.map { ($0.path, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    for input in inputs {
        guard let got = byPath[input.path] else {
            Issue.record("missing recovered entry for path \"\(input.path)\"", sourceLocation: sourceLocation)
            continue
        }
        #expect(got.bytes == input.bytes,
                "content mismatch for \"\(input.path)\"",
                sourceLocation: sourceLocation)
        #expect(got.fileType == input.fileType,
                "file-type mismatch for \"\(input.path)\"",
                sourceLocation: sourceLocation)
    }
}
