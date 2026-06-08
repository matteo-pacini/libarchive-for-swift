import Foundation

/// A source of bytes for reading an archive.
///
/// `ArchiveSource` is a `Sendable` value type, so it can be passed across
/// isolation boundaries as a parameter to the reader and the one-shot ``Archive``
/// helpers.
public enum ArchiveSource: Sendable {
    /// In-memory bytes, opened with `archive_read_open_memory`.
    case bytes([UInt8])
    /// In-memory `Data`, bridged to bytes then `archive_read_open_memory`.
    case data(Data)
    /// A `file://` URL, opened with `archive_read_open_filename` and streamed
    /// block by block. Prefer this for large archives to avoid loading the whole
    /// file into memory.
    case fileURL(URL)
}

/// A destination for the bytes of an archive that is being written.
///
/// `ArchiveDestination` is a `Sendable` value type, so it can be passed across
/// isolation boundaries as a parameter to the writer and the one-shot ``Archive``
/// helpers.
public enum ArchiveDestination: Sendable {
    /// Builds the archive in memory; the writer returns the bytes from `finish()`.
    case memory
    /// Streams directly to a `file://` URL via `archive_write_open_filename`.
    case fileURL(URL)
}
