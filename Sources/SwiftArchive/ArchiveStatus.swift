/// One of libarchive's documented return statuses, surfaced as a typed value.
///
/// The read path tolerates ``warn`` exactly as the reference code does; callers
/// can inspect ``isUsable`` to decide whether the handle may keep going.
public enum ArchiveStatus: Int32, Sendable, Hashable {
    /// Operation succeeded (`ARCHIVE_OK`, 0).
    case ok = 0
    /// End of archive reached (`ARCHIVE_EOF`, 1).
    case eof = 1
    /// Operation should be retried (`ARCHIVE_RETRY`, -10).
    case retry = -10
    /// Succeeded with a non-fatal warning (`ARCHIVE_WARN`, -20).
    case warn = -20
    /// Operation failed but the handle is still usable (`ARCHIVE_FAILED`, -25).
    case failed = -25
    /// Unrecoverable error; the handle must be discarded (`ARCHIVE_FATAL`, -30).
    case fatal = -30

    /// A Boolean value that indicates whether the handle remains usable, which is
    /// the case for ``ok`` and ``warn``.
    ///
    /// libarchive treats both `ARCHIVE_OK` and `ARCHIVE_WARN` as states in which
    /// the handle remains valid and iteration may continue; every other status
    /// means the current operation did not fully succeed.
    public var isUsable: Bool {
        self == .ok || self == .warn
    }

    /// Maps an arbitrary raw libarchive return code onto the nearest case (defaults to ``fatal``).
    ///
    /// Any code that is not one of the documented constants is treated as
    /// ``fatal`` so callers never silently keep going on an unknown state.
    ///
    /// - Parameter rawCode: A raw `Int32` status from a libarchive call.
    init(rawCode: Int32) {
        self = ArchiveStatus(rawValue: rawCode) ?? .fatal
    }
}
