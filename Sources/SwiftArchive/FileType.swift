/// A POSIX file type, mirrored from the `AE_IF*` macros in `archive_entry.h`.
///
/// The Clang importer does not surface the cast-style `AE_IF*` macros into
/// Swift, so they are reproduced here. The raw value matches the setter
/// `archive_entry_set_filetype`, which takes an `unsigned int` (`UInt32`). The
/// matching getter `archive_entry_filetype()` returns `mode_t` (`UInt16` on
/// Apple platforms), so the read path widens that result to `UInt32` before
/// constructing a value with ``init(modeWord:)``.
public enum FileType: UInt32, Sendable, CaseIterable, Hashable {
    /// A regular file (`AE_IFREG`).
    case regular = 0o100000
    /// A directory (`AE_IFDIR`).
    case directory = 0o040000
    /// A symbolic link (`AE_IFLNK`).
    case symlink = 0o120000
    /// A FIFO / named pipe (`AE_IFIFO`).
    case fifo = 0o010000
    /// A socket (`AE_IFSOCK`).
    case socket = 0o140000
    /// A character device (`AE_IFCHR`).
    case character = 0o020000
    /// A block device (`AE_IFBLK`).
    case block = 0o060000

    /// The bit mask isolating the file-type field within a full mode word (`AE_IFMT`).
    static let mask: UInt32 = 0o170000

    /// Builds a `FileType` from a raw mode word as returned by `archive_entry_filetype()`.
    /// - Parameter modeWord: A mode word (`mode_t` widened to `UInt32`); only the type bits are inspected.
    /// - Returns: The matching file type, or `nil` if the type field is unrecognized.
    init?(modeWord: UInt32) {
        self.init(rawValue: modeWord & FileType.mask)
    }
}
