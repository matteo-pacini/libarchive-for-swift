import libarchive

/// Options that control how an archive's entries are recreated on disk during extraction.
///
/// `ExtractionOptions` is a `Sendable` `OptionSet` over libarchive's `ARCHIVE_EXTRACT_*`
/// flags, passed verbatim to `archive_write_disk_set_options`. The default used by every
/// extraction entry point is ``secure``, which refuses unsafe paths; opting out of any
/// safeguard is therefore always explicit.
///
/// ## Security
/// The ``secure`` set combines ``secureSymlinks``, ``secureNoDotDot``, and
/// ``secureNoAbsolutePaths``. Together they reject entries with absolute paths, reject
/// `..` path-traversal components (the "Zip Slip" attack), and refuse to write through a
/// symbolic link that escapes the destination directory. Removing any of these members
/// weakens the guarantee and must be done deliberately.
///
/// ```swift
/// // Secure default plus restoring modification times and permissions.
/// let options: ExtractionOptions = [.secure, .time, .permissions]
/// try await Archive.extract(.fileURL(archiveURL), to: destinationURL, options: options)
/// ```
public struct ExtractionOptions: OptionSet, Sendable, Hashable {

    /// The raw `ARCHIVE_EXTRACT_*` bitmask passed to `archive_write_disk_set_options`.
    public let rawValue: Int32

    /// Creates an option set from a raw libarchive extract bitmask.
    /// - Parameter rawValue: A bitwise OR of `ARCHIVE_EXTRACT_*` flag values.
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Refuses to write through a symbolic link that points outside the destination (`ARCHIVE_EXTRACT_SECURE_SYMLINKS`).
    public static let secureSymlinks = ExtractionOptions(rawValue: Int32(ARCHIVE_EXTRACT_SECURE_SYMLINKS))

    /// Rejects any entry whose path contains a `..` traversal component (`ARCHIVE_EXTRACT_SECURE_NODOTDOT`).
    public static let secureNoDotDot = ExtractionOptions(rawValue: Int32(ARCHIVE_EXTRACT_SECURE_NODOTDOT))

    /// Rejects any entry with an absolute path (`ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS`).
    public static let secureNoAbsolutePaths = ExtractionOptions(rawValue: Int32(ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS))

    /// Restores entry modification times (`ARCHIVE_EXTRACT_TIME`).
    public static let time = ExtractionOptions(rawValue: Int32(ARCHIVE_EXTRACT_TIME))

    /// Restores full permission bits, including setuid and sticky bits (`ARCHIVE_EXTRACT_PERM`).
    public static let permissions = ExtractionOptions(rawValue: Int32(ARCHIVE_EXTRACT_PERM))

    /// Restores file ownership, which usually requires elevated privileges (`ARCHIVE_EXTRACT_OWNER`).
    public static let owner = ExtractionOptions(rawValue: Int32(ARCHIVE_EXTRACT_OWNER))

    /// Restores access control lists (`ARCHIVE_EXTRACT_ACL`).
    public static let acl = ExtractionOptions(rawValue: Int32(ARCHIVE_EXTRACT_ACL))

    /// Restores platform file flags (`ARCHIVE_EXTRACT_FFLAGS`).
    public static let fileFlags = ExtractionOptions(rawValue: Int32(ARCHIVE_EXTRACT_FFLAGS))

    /// Restores extended attributes (`ARCHIVE_EXTRACT_XATTR`).
    public static let extendedAttributes = ExtractionOptions(rawValue: Int32(ARCHIVE_EXTRACT_XATTR))

    /// Refuses to overwrite an existing file on disk (`ARCHIVE_EXTRACT_NO_OVERWRITE`).
    public static let noOverwrite = ExtractionOptions(rawValue: Int32(ARCHIVE_EXTRACT_NO_OVERWRITE))

    /// Removes an existing file before creating the new one, rather than writing in place (`ARCHIVE_EXTRACT_UNLINK`).
    public static let unlinkFirst = ExtractionOptions(rawValue: Int32(ARCHIVE_EXTRACT_UNLINK))

    /// Recreates sparse files as sparse where the platform supports it (`ARCHIVE_EXTRACT_SPARSE`).
    public static let sparse = ExtractionOptions(rawValue: Int32(ARCHIVE_EXTRACT_SPARSE))

    /// The secure-by-default option set used by every extraction entry point.
    ///
    /// Equivalent to `[.secureSymlinks, .secureNoDotDot, .secureNoAbsolutePaths]`. See the
    /// type's Security discussion for what each member guarantees.
    public static let secure: ExtractionOptions = [.secureSymlinks, .secureNoDotDot, .secureNoAbsolutePaths]
}
