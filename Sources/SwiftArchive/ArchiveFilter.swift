import libarchive

/// A write-side compression or encoding filter such as gzip, bzip2, xz, or zstd.
///
/// A filter value identifies the compression or encoding applied to the bytes an
/// ``ArchiveWriter`` produces. Because the type is a value, it can be stored,
/// compared, and passed between isolation domains. For self-compressing container
/// formats such as zip and 7-Zip, use ``none``. Readers detect the filter
/// automatically, so this type is write-side only.
///
/// ```swift
/// let writer = try await ArchiveWriter(format: .ustar, filter: .gzip)
/// ```
public struct ArchiveFilter: Sendable, Equatable {
    /// A short, stable identifier for the filter, such as `"gzip"`.
    ///
    /// The value appears in error stages and is the basis for equality comparison.
    public let name: String
    /// Applies the filter to a write handle, returning the libarchive status code.
    let apply: @Sendable (OpaquePointer?) -> Int32

    /// Wraps a libarchive filter setter under a name. The closure must call
    /// exactly one `archive_write_add_filter_*` on the handle it receives and
    /// must not retain that handle.
    /// - Parameters:
    ///   - name: A short identifier for diagnostics.
    ///   - apply: The closure that installs the filter.
    init(name: String, apply: @escaping @Sendable (OpaquePointer?) -> Int32) {
        self.name = name
        self.apply = apply
    }

    /// Returns a Boolean value that indicates whether two filters are equal.
    ///
    /// Two filters are equal when their ``name`` values match.
    ///
    /// - Parameters:
    ///   - lhs: A filter to compare.
    ///   - rhs: Another filter to compare.
    /// - Returns: `true` if the filters have the same name; otherwise, `false`.
    public static func == (lhs: ArchiveFilter, rhs: ArchiveFilter) -> Bool {
        lhs.name == rhs.name
    }

    /// A filter that applies no compression.
    ///
    /// Bytes are stored uncompressed. Use this filter with the self-compressing
    /// ``ArchiveFormat/zip`` and ``ArchiveFormat/sevenZip`` formats.
    public static let none = ArchiveFilter(name: "none") { archive_write_add_filter_none($0) }
    /// gzip compression (bundled zlib).
    public static let gzip = ArchiveFilter(name: "gzip") { archive_write_add_filter_gzip($0) }
    /// bzip2 compression (bundled).
    public static let bzip2 = ArchiveFilter(name: "bzip2") { archive_write_add_filter_bzip2($0) }
    /// xz compression (bundled liblzma).
    public static let xz = ArchiveFilter(name: "xz") { archive_write_add_filter_xz($0) }
    /// Legacy LZMA-alone compression (bundled liblzma).
    public static let lzma = ArchiveFilter(name: "lzma") { archive_write_add_filter_lzma($0) }
    /// lzip compression (bundled liblzma).
    public static let lzip = ArchiveFilter(name: "lzip") { archive_write_add_filter_lzip($0) }
    /// Zstandard compression (bundled libzstd).
    public static let zstd = ArchiveFilter(name: "zstd") { archive_write_add_filter_zstd($0) }
    /// LZ4 compression (bundled liblz4).
    public static let lz4 = ArchiveFilter(name: "lz4") { archive_write_add_filter_lz4($0) }
    /// The legacy `.Z` compress filter.
    public static let compress = ArchiveFilter(name: "compress") { archive_write_add_filter_compress($0) }
    /// A uuencode text-encoding wrapper.
    public static let uuencode = ArchiveFilter(name: "uuencode") { archive_write_add_filter_uuencode($0) }
    /// A Base64 text-encoding wrapper.
    public static let b64encode = ArchiveFilter(name: "b64encode") { archive_write_add_filter_b64encode($0) }

    /// Returns a filter resolved by its libarchive name.
    ///
    /// The name is passed to `archive_write_add_filter_by_name` when the filter is
    /// applied to a writer. Use this as an extensibility point for filters that
    /// have no dedicated static member. The resolved filter follows the writer's
    /// normal lifecycle, so no raw handle is ever exposed.
    ///
    /// - Parameter name: A libarchive filter name, such as `"gzip"` or `"zstd"`.
    /// - Returns: A filter that resolves `name` on the write handle.
    public static func named(_ name: String) -> ArchiveFilter {
        ArchiveFilter(name: name) { handle in
            name.withCString { archive_write_add_filter_by_name(handle, $0) }
        }
    }
}

#if os(macOS) || targetEnvironment(macCatalyst)
extension ArchiveFilter {
    /// Returns a filter that pipes archive bytes through an external program.
    ///
    /// This filter is available on macOS and Mac Catalyst only, because it spawns a
    /// child process. iOS, watchOS, and tvOS cannot spawn processes under the
    /// platform sandbox, so the member is removed from the API at compile time on
    /// those platforms.
    ///
    /// - Parameter command: The shell command to run as the compressor, such as
    ///   `"gzip -9"`.
    /// - Returns: A filter that runs `command` as an external compressor.
    public static func program(_ command: String) -> ArchiveFilter {
        ArchiveFilter(name: "program(\(command))") { handle in
            command.withCString { archive_write_add_filter_program(handle, $0) }
        }
    }
}
#endif
