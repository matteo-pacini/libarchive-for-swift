import Foundation
import libarchive

/// An internal actor that walks a directory tree on disk and feeds each entry into an archive
/// writer, all on a private serial executor.
///
/// `DiskArchiver` owns a libarchive read-disk handle (`archive_read_disk_new`). It performs a
/// physical traversal by default (symbolic links are recorded as links, not followed). Each
/// discovered entry's header and data are handed to the ``ArchiveWriter`` the archiver was given.
/// All blocking traversal work runs on the archiver's executor, so the caller is never blocked.
///
/// ## Data source limitation
/// A read-disk handle yields entry metadata only, not file contents. For each regular file the
/// archiver reads the file's bytes into memory with `Data(contentsOf:)` on its executor before
/// handing them to the writer, so a single very large file is held in memory while it is written.
/// Chunked streaming of large files is deferred.
actor DiskArchiver {

    /// The private serial executor that runs every blocking libarchive call.
    private let executor: ArchiveExecutor

    /// The owner of the live read-disk handle. Actor-confined; freed by the box's `deinit` as a backstop.
    private let diskBox = HandleBox(pointer: nil, freeFunction: archive_read_free)

    /// The absolute root directory of the traversal, with a single trailing separator, used to
    /// turn each absolute on-disk path into a relative archive path.
    private let rootPrefix: String

    /// `true` once ``close()`` (or the box's `deinit`) has freed the handle.
    private var isClosed = false

    /// Routes this actor's work onto its private serial executor (`Actor` requirement).
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// Opens a read-disk traversal rooted at the given directory.
    ///
    /// - Parameters:
    ///   - directory: The directory whose tree is walked.
    ///   - followSymlinks: A Boolean value that indicates whether symbolic links are followed
    ///     (logical traversal) instead of recorded as links (physical traversal). Defaults to `false`.
    /// - Throws: ``ArchiveError`` if the handle cannot be allocated or the directory cannot be opened.
    init(directory: URL, followSymlinks: Bool) async throws {
        self.executor = ArchiveExecutor(label: "com.swiftarchive.archiver")
        self.rootPrefix = DiskArchiver.normalizedPrefix(directory)
        // This async init's body runs on the actor's own serial executor, so handle setup below
        // executes on the dedicated GCD thread, off the caller's actor.
        try self.open(directory: directory, followSymlinks: followSymlinks)
    }

    /// Allocates and opens the read-disk handle. Runs on the actor's executor.
    ///
    /// - Parameters:
    ///   - directory: The directory whose tree is walked.
    ///   - followSymlinks: Whether to follow symbolic links (logical) or record them (physical).
    /// - Throws: ``ArchiveError`` on allocation or open failure.
    private func open(directory: URL, followSymlinks: Bool) throws {
        guard let handle = archive_read_disk_new() else {
            throw ArchiveError(stage: .allocateHandle, code: ARCHIVE_FATAL, message: "archive_read_disk_new returned nil")
        }
        diskBox.pointer = handle

        _ = archive_read_disk_set_standard_lookup(handle)
        if followSymlinks {
            _ = archive_read_disk_set_symlink_logical(handle)
        } else {
            _ = archive_read_disk_set_symlink_physical(handle)
        }

        let openRC = directory.path.withCString { archive_read_disk_open(handle, $0) }
        guard openRC == ARCHIVE_OK || openRC == ARCHIVE_WARN else {
            let message = errorString(handle)
            diskBox.free()
            throw ArchiveError(stage: .openDisk, code: openRC, message: message)
        }
    }

    /// Walks the tree and appends every entry to the given writer, descending into directories.
    ///
    /// Honors cancellation between entries by throwing `CancellationError`. Returns the number of
    /// entries appended.
    ///
    /// - Parameter writer: The open writer that receives each traversed entry.
    /// - Returns: The count of entries appended.
    /// - Throws: `CancellationError`, or ``ArchiveError`` on a traversal or write failure.
    @discardableResult
    func writeAll(into writer: ArchiveWriter) async throws -> Int {
        guard !isClosed, let handle = diskBox.pointer else { return 0 }

        guard let entry = archive_entry_new() else {
            throw ArchiveError(stage: .allocateHandle, code: ARCHIVE_FATAL, message: "archive_entry_new returned nil")
        }
        defer { archive_entry_free(entry) }

        var count = 0
        while true {
            try Task.checkCancellation()

            archive_entry_clear(entry)
            let headerRC = archive_read_next_header2(handle, entry)
            if headerRC == ARCHIVE_EOF { break }
            guard headerRC == ARCHIVE_OK || headerRC == ARCHIVE_WARN else {
                throw ArchiveError(stage: .readHeader, code: headerRC, message: errorString(handle))
            }

            // The traversal root itself reports an empty relative path; skip it so the archive
            // holds only the directory's contents.
            if let draft = try traversedDraft(from: entry) {
                try await writer.append(draft)
                count += 1
            }

            if archive_read_disk_can_descend(handle) != 0 {
                let descendRC = archive_read_disk_descend(handle)
                guard descendRC == ARCHIVE_OK || descendRC == ARCHIVE_WARN else {
                    let path = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
                    throw ArchiveError(stage: .descend(path: path), code: descendRC, message: errorString(handle))
                }
            }
        }
        return count
    }

    /// Builds an ``EntryDraft`` from a live traversed entry, reading regular-file bytes from disk.
    ///
    /// The on-disk absolute path is rebased onto the traversal root so the archive stores a
    /// relative path. The entry's full metadata (ownership, timestamps, extended attributes, mac
    /// metadata) is carried through via the shared draft decoder. Returns `nil` for the traversal
    /// root itself, which has an empty relative path and should not become an archive entry.
    ///
    /// - Parameter entry: A live `archive_entry` populated by `archive_read_next_header2`.
    /// - Returns: A draft describing the entry, or `nil` when the entry is the traversal root.
    /// - Throws: ``ArchiveError`` if a regular file's contents cannot be read.
    private func traversedDraft(from entry: OpaquePointer) throws -> EntryDraft? {
        let absolutePath = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
        let relativePath = relativePath(for: absolutePath)
        if relativePath.isEmpty { return nil }

        let typeWord = UInt32(archive_entry_filetype(entry))
        let fileType = FileType(modeWord: typeWord) ?? .regular

        var bytes: [UInt8] = []
        if fileType == .regular {
            let fileURL = URL(fileURLWithPath: absolutePath)
            do {
                bytes = [UInt8](try Data(contentsOf: fileURL))
            } catch {
                throw ArchiveError(stage: .readData(path: relativePath), code: ARCHIVE_FATAL, message: "cannot read file contents: \(error.localizedDescription)")
            }
        }

        return makeDraft(from: entry, path: relativePath, bytes: bytes)
    }

    /// Rebases an absolute on-disk path onto the traversal root, yielding the archive-relative path.
    ///
    /// - Parameter absolutePath: A path reported by the read-disk traversal.
    /// - Returns: The path relative to the traversal root, or the original path if it is not
    ///   under the root.
    private func relativePath(for absolutePath: String) -> String {
        if absolutePath.hasPrefix(rootPrefix) {
            return String(absolutePath.dropFirst(rootPrefix.count))
        }
        if absolutePath == String(rootPrefix.dropLast()) {
            return ""
        }
        return absolutePath
    }

    /// Closes and frees the traversal handle. Idempotent.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let handle = diskBox.pointer {
            _ = archive_read_close(handle)
        }
        diskBox.free()
    }

    // Backstop teardown is handled by ``diskBox``: its `deinit` frees the handle when the actor,
    // its sole owner, is deallocated. The primary teardown path remains the explicit ``close()``.

    /// Normalizes a directory URL into a path prefix with exactly one trailing separator.
    ///
    /// - Parameter directory: The traversal root directory URL.
    /// - Returns: The directory's filesystem path ending in a single `/`.
    private static func normalizedPrefix(_ directory: URL) -> String {
        var prefix = directory.path
        if !prefix.hasSuffix("/") {
            prefix += "/"
        }
        return prefix
    }
}
