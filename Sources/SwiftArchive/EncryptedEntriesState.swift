/// The result of querying whether an archive contains encrypted entries.
///
/// Returned by ``ArchiveReader/hasEncryptedEntries()``, this mirrors the three
/// outcomes of libarchive's `archive_read_has_encrypted_entries`: a definite
/// yes or no, an "uncertain" state when not enough of the archive has been read
/// yet, and an "unsupported" state for formats that have no concept of
/// encryption.
///
/// ```swift
/// let reader = try await ArchiveReader(reading: .fileURL(zipURL))
/// _ = try await reader.nextEntry()
/// switch await reader.hasEncryptedEntries() {
/// case .yes:         try await reader.addPassphrase(passphrase)
/// case .no:          break
/// case .unknown:     break
/// case .unsupported: break
/// }
/// ```
public enum EncryptedEntriesState: Sendable, Hashable {
    /// The archive contains at least one encrypted entry.
    case yes
    /// The reader supports encryption detection and has found no encrypted entries so far.
    case no
    /// The reader cannot yet tell, for example because too little of the archive has been read (`ARCHIVE_READ_FORMAT_ENCRYPTION_DONT_KNOW`).
    case unknown
    /// The archive format does not support encryption at all (`ARCHIVE_READ_FORMAT_ENCRYPTION_UNSUPPORTED`).
    case unsupported

    /// Maps the raw `archive_read_has_encrypted_entries` return value onto a case.
    ///
    /// libarchive returns a count of at least one when encrypted entries are
    /// present, `0` when none are, and the negative sentinels
    /// `ARCHIVE_READ_FORMAT_ENCRYPTION_DONT_KNOW` (`-1`) or
    /// `ARCHIVE_READ_FORMAT_ENCRYPTION_UNSUPPORTED` (`-2`); any other negative
    /// value is treated as unsupported.
    ///
    /// - Parameter rawValue: The `Int32` returned by `archive_read_has_encrypted_entries`.
    init(rawValue: Int32) {
        // The negative sentinels are fixed by libarchive's ABI: DONT_KNOW is -1 and
        // UNSUPPORTED is -2. They are matched as literals because the C `#define`
        // macros import as `Int`, not the `Int32` returned by the query.
        switch rawValue {
        case let value where value >= 1:
            self = .yes
        case 0:
            self = .no
        case -1:
            self = .unknown
        default:
            self = .unsupported
        }
    }
}
