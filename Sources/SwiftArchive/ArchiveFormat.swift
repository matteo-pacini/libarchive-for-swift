import libarchive

/// A write-side container format such as tar, cpio, or zip.
///
/// A format value identifies the container layout that an ``ArchiveWriter``
/// produces. Because the type is a value, it can be stored, compared, and passed
/// between isolation domains. Readers do not use this type; they detect the
/// container format automatically.
///
/// Select a format from the provided static members, or resolve one by its
/// libarchive name with ``named(_:)``.
///
/// ```swift
/// let writer = try await ArchiveWriter(format: .pax, filter: .gzip)
/// ```
public struct ArchiveFormat: Sendable, Equatable {
    /// A short, stable identifier for the format, such as `"ustar"`.
    ///
    /// The value appears in error stages and is the basis for equality comparison.
    public let name: String
    /// Applies the format to a write handle, returning the libarchive status code.
    let apply: @Sendable (OpaquePointer?) -> Int32

    /// Wraps a libarchive format setter under a name. The closure must call
    /// exactly one `archive_write_set_format_*` on the handle it receives and
    /// must not retain that handle.
    /// - Parameters:
    ///   - name: A short identifier for diagnostics.
    ///   - apply: The closure that installs the format.
    init(name: String, apply: @escaping @Sendable (OpaquePointer?) -> Int32) {
        self.name = name
        self.apply = apply
    }

    /// Returns a Boolean value that indicates whether two formats are equal.
    ///
    /// Two formats are equal when their ``name`` values match.
    ///
    /// - Parameters:
    ///   - lhs: A format to compare.
    ///   - rhs: Another format to compare.
    /// - Returns: `true` if the formats have the same name; otherwise, `false`.
    public static func == (lhs: ArchiveFormat, rhs: ArchiveFormat) -> Bool {
        lhs.name == rhs.name
    }

    /// The POSIX ustar tar format.
    public static let ustar = ArchiveFormat(name: "ustar") { archive_write_set_format_ustar($0) }
    /// The PAX-interchange tar format (full extended headers).
    public static let pax = ArchiveFormat(name: "pax") { archive_write_set_format_pax($0) }
    /// The PAX-restricted tar format (extended headers only when needed).
    public static let paxRestricted = ArchiveFormat(name: "pax_restricted") { archive_write_set_format_pax_restricted($0) }
    /// The GNU tar format.
    public static let gnutar = ArchiveFormat(name: "gnutar") { archive_write_set_format_gnutar($0) }
    /// The legacy v7 tar format.
    public static let v7tar = ArchiveFormat(name: "v7tar") { archive_write_set_format_v7tar($0) }
    /// The SVR4 "newc" cpio format.
    public static let cpioNewc = ArchiveFormat(name: "cpio_newc") { archive_write_set_format_cpio_newc($0) }
    /// The POSIX "odc" cpio format.
    public static let cpioOdc = ArchiveFormat(name: "cpio_odc") { archive_write_set_format_cpio_odc($0) }
    /// The ZIP container format (carries its own per-entry compression).
    public static let zip = ArchiveFormat(name: "zip") { archive_write_set_format_zip($0) }
    /// The 7-Zip container format (carries its own compression).
    public static let sevenZip = ArchiveFormat(name: "7zip") { archive_write_set_format_7zip($0) }

    /// Returns a format resolved by its libarchive name.
    ///
    /// The name is passed to `archive_write_set_format_by_name` when the format is
    /// applied to a writer. Use this when the format you need has no dedicated
    /// static member.
    ///
    /// - Parameter name: A libarchive format name, such as `"ustar"`.
    /// - Returns: A format that resolves `name` on the write handle.
    public static func named(_ name: String) -> ArchiveFormat {
        ArchiveFormat(name: name) { handle in
            name.withCString { archive_write_set_format_by_name(handle, $0) }
        }
    }
}
