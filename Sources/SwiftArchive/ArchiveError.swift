/// An error raised when a libarchive call returns a non-OK or fatal status, or when the wrapper rejects a call because of a nil handle or misuse.
///
/// `ArchiveError` is a `Sendable` value type, so it can be thrown out of the
/// reader and writer actors and the one-shot ``Archive`` helpers back to any
/// isolation domain, such as the main actor.
///
/// ```swift
/// do {
///     let entries = try await Archive.read(from: source)
///     print("read \(entries.count) entries")
/// } catch let error as ArchiveError {
///     print("\(error.stage): \(error.message)")
/// }
/// ```
public struct ArchiveError: Error, Sendable, CustomStringConvertible, Equatable {

    /// The libarchive entry point or wrapper stage that produced the failure.
    public enum Stage: Sendable, Equatable {
        /// An `archive_*_new` call returned nil.
        case allocateHandle
        /// An `archive_write_set_format_*` call failed; payload is the format name.
        case setFormat(String)
        /// An `archive_write_add_filter_*` call failed; payload is the filter name.
        case addFilter(String)
        /// An `archive_*_open_*` call failed.
        case open
        /// `archive_write_header` failed; payload is the entry path.
        case writeHeader(path: String)
        /// `archive_write_data` short-wrote or errored; payload is the entry path.
        case writeData(path: String)
        /// `archive_write_finish_entry` failed; payload is the entry path.
        case finishEntry(path: String)
        /// An `archive_*_close` call failed.
        case close
        /// `archive_read_next_header` failed.
        case readHeader
        /// `archive_read_data` returned a negative status; payload is the entry path.
        case readData(path: String)
        /// An option or passphrase setter failed; payload is a short identifier.
        case setOption(String)
        /// `archive_write_disk_set_options` or write-disk header setup failed.
        case setupWriteDisk
        /// `archive_read_disk_open` or read-disk setup failed.
        case openDisk
        /// `archive_write_data_block` failed while extracting; payload is the entry path.
        case writeDiskData(path: String)
        /// `archive_read_disk_descend` failed during traversal; payload is the directory path.
        case descend(path: String)
        /// Any other stage; payload is a short description.
        case custom(String)
    }

    /// The libarchive entry point or wrapper stage that produced the failure.
    public let stage: Stage
    /// The raw libarchive status code that triggered the error.
    public let code: Int32
    /// The typed severity derived from ``code``.
    public let status: ArchiveStatus
    /// The handle's `archive_error_string` text, or a wrapper note; `""` when none.
    public let message: String

    /// Creates an error describing a failed stage; ``status`` is derived from `code`.
    init(stage: Stage, code: Int32, message: String) {
        self.stage = stage
        self.code = code
        self.status = ArchiveStatus(rawCode: code)
        self.message = message
    }

    /// A single-line, human-readable summary suitable for logging.
    public var description: String {
        "ArchiveError(stage: \(stage), code: \(code), status: \(status), message: \"\(message)\")"
    }
}
