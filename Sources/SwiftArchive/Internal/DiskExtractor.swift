import Foundation
import libarchive

/// An internal actor that extracts an archive's entries onto disk on a private serial executor.
///
/// `DiskExtractor` owns a libarchive read handle (the archive source) and a write-disk handle
/// (`archive_write_disk_new`), both confined to its executor. Every blocking step (reading a
/// header, writing the on-disk header, copying data blocks, finishing the entry) runs on that
/// executor, so no caller is ever blocked. The public surface is ``Archive/extract(_:to:options:)``.
///
/// ## Path rooting and security
/// Rather than changing the process working directory (which is process-global and not
/// concurrency-safe), each entry's pathname is rewritten to sit under the destination directory
/// before the on-disk header is written. The secure flags supplied through ``ExtractionOptions``
/// still operate on libarchive's view of the original relative path, so the combination of
/// rooting under the destination plus `ARCHIVE_EXTRACT_SECURE_*` keeps every write inside the
/// destination tree.
actor DiskExtractor {

    /// The private serial executor that runs every blocking libarchive call.
    private let executor: ArchiveExecutor

    /// The owner of the live read handle. Actor-confined; freed by the box's `deinit` as a backstop.
    private let readBox = HandleBox(pointer: nil, freeFunction: archive_read_free)

    /// The owner of the live write-disk handle. Actor-confined; freed by the box's `deinit` as a backstop.
    private let writeBox = HandleBox(pointer: nil, freeFunction: archive_write_free)

    /// The absolute destination directory, with a single trailing separator, used to root entries.
    /// Set once during ``open(reading:to:options:)`` after the directory has been created so its
    /// path can be fully symlink-resolved.
    private var destinationPrefix = ""

    /// The caller-supplied secure flags, evaluated in Swift against each entry's original
    /// relative path before the path is rooted under the destination.
    private let secureOptions: ExtractionOptions

    /// `true` once ``close()`` (or the boxes' `deinit`) has freed the handles.
    private var isClosed = false

    /// Routes this actor's work onto its private serial executor (`Actor` requirement).
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// Opens the source archive and a write-disk handle configured with the given options.
    ///
    /// Creates the destination directory if it does not already exist, then allocates and opens
    /// both handles on the actor's executor so no caller thread is blocked.
    ///
    /// - Parameters:
    ///   - source: The archive to read entries from.
    ///   - destination: The directory the entries are recreated under.
    ///   - options: The `ARCHIVE_EXTRACT_*` flags applied via `archive_write_disk_set_options`.
    /// - Throws: ``ArchiveError`` if either handle cannot be allocated, the source cannot be
    ///   opened, or the destination is not a reachable directory.
    init(reading source: ArchiveSource, to destination: URL, options: ExtractionOptions) async throws {
        self.executor = ArchiveExecutor(label: "com.swiftarchive.extractor")
        self.secureOptions = options
        // This async init's body runs on the actor's own serial executor, so all handle setup
        // below executes on the dedicated GCD thread, off the caller's actor.
        try self.open(reading: source, to: destination, options: options)
    }

    /// Allocates and opens both handles, and ensures the destination directory exists.
    /// Runs on the actor's executor.
    ///
    /// - Parameters:
    ///   - source: The archive to read entries from.
    ///   - destination: The directory the entries are recreated under.
    ///   - options: The extraction flags applied to the write-disk handle.
    /// - Throws: ``ArchiveError`` on allocation, directory creation, or open failure.
    private func open(reading source: ArchiveSource, to destination: URL, options: ExtractionOptions) throws {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError(stage: .openDisk, code: ARCHIVE_FATAL, message: "cannot create destination directory: \(error.localizedDescription)")
        }
        // Resolve the prefix only now that the directory exists, so its full path (including the
        // leaf) is canonicalized and trusted ancestor symlinks are followed once up front.
        destinationPrefix = try DiskExtractor.normalizedPrefix(destination)

        guard let readHandle = archive_read_new() else {
            throw ArchiveError(stage: .allocateHandle, code: ARCHIVE_FATAL, message: "archive_read_new returned nil")
        }
        readBox.pointer = readHandle
        _ = archive_read_support_format_all(readHandle)
        _ = archive_read_support_filter_all(readHandle)

        let openRC: Int32
        switch source {
        case .bytes(let bytes):
            openRC = openMemory(readHandle, bytes)
        case .data(let data):
            openRC = openMemory(readHandle, [UInt8](data))
        case .fileURL(let url):
            openRC = url.path.withCString { archive_read_open_filename(readHandle, $0, 64 * 1024) }
        }
        guard openRC == ARCHIVE_OK || openRC == ARCHIVE_WARN else {
            let message = errorString(readHandle)
            readBox.free()
            throw ArchiveError(stage: .open, code: openRC, message: message)
        }

        guard let writeHandle = archive_write_disk_new() else {
            readBox.free()
            throw ArchiveError(stage: .allocateHandle, code: ARCHIVE_FATAL, message: "archive_write_disk_new returned nil")
        }
        writeBox.pointer = writeHandle

        // The destination rooting below deliberately produces an absolute pathname, so the
        // absolute-path check is enforced in Swift against each entry's original relative path
        // (see `rootedPath(for:)`) rather than by libarchive, which would otherwise reject the
        // rooted path. The symlink-escape and `..` guards stay active on the live handle.
        let handleFlags = options.subtracting(.secureNoAbsolutePaths)
        let optRC = archive_write_disk_set_options(writeHandle, handleFlags.rawValue)
        guard optRC == ARCHIVE_OK || optRC == ARCHIVE_WARN else {
            let message = errorString(writeHandle)
            writeBox.free()
            readBox.free()
            throw ArchiveError(stage: .setupWriteDisk, code: optRC, message: message)
        }
        _ = archive_write_disk_set_standard_lookup(writeHandle)
    }

    /// Copies `bytes` into stable storage and opens the read handle against it.
    ///
    /// `archive_read_open_memory` keeps the pointer for the handle's lifetime, so the storage is
    /// owned by the read box and deallocated when the handle is freed.
    ///
    /// - Parameters:
    ///   - handle: The freshly allocated read handle.
    ///   - bytes: The archive bytes to copy into stable storage.
    /// - Returns: The libarchive status from `archive_read_open_memory`.
    private func openMemory(_ handle: OpaquePointer, _ bytes: [UInt8]) -> Int32 {
        let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: Swift.max(bytes.count, 1), alignment: 1)
        if !bytes.isEmpty {
            bytes.withUnsafeBytes { storage.copyMemory(from: $0) }
        }
        readBox.onFree { storage.deallocate() }
        return archive_read_open_memory(handle, storage.baseAddress, bytes.count)
    }

    /// Drives the read-header, write-header, copy-data, finish-entry loop to completion.
    ///
    /// Honors cancellation between entries by throwing `CancellationError`. Returns the number
    /// of entries written.
    ///
    /// - Returns: The count of entries recreated on disk.
    /// - Throws: `CancellationError`, or ``ArchiveError`` on any read or write-disk failure.
    @discardableResult
    func extractAll() throws -> Int {
        guard !isClosed, let readHandle = readBox.pointer, let writeHandle = writeBox.pointer else { return 0 }

        var count = 0
        while true {
            try Task.checkCancellation()

            var entryPtr: OpaquePointer?
            let headerRC = archive_read_next_header(readHandle, &entryPtr)
            if headerRC == ARCHIVE_EOF { break }
            guard headerRC == ARCHIVE_OK || headerRC == ARCHIVE_WARN else {
                throw ArchiveError(stage: .readHeader, code: headerRC, message: errorString(readHandle))
            }
            guard let entry = entryPtr else { continue }

            let originalPath = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
            let rooted = try rootedPath(for: originalPath)
            archive_entry_set_pathname(entry, rooted)

            let writeHeaderRC = archive_write_header(writeHandle, entry)
            guard writeHeaderRC == ARCHIVE_OK || writeHeaderRC == ARCHIVE_WARN else {
                throw ArchiveError(stage: .writeHeader(path: originalPath), code: writeHeaderRC, message: errorString(writeHandle))
            }

            try copyData(from: readHandle, to: writeHandle, path: originalPath)

            let finishRC = archive_write_finish_entry(writeHandle)
            guard finishRC == ARCHIVE_OK || finishRC == ARCHIVE_WARN else {
                throw ArchiveError(stage: .finishEntry(path: originalPath), code: finishRC, message: errorString(writeHandle))
            }

            count += 1
        }
        return count
    }

    /// Copies the current entry's data blocks from the read handle to the write-disk handle.
    ///
    /// Uses the zero-copy `archive_read_data_block` paired with `archive_write_data_block`, which
    /// preserves sparse-file offsets. Cancellation is checked at every block.
    ///
    /// - Parameters:
    ///   - readHandle: The open source read handle.
    ///   - writeHandle: The open write-disk handle.
    ///   - path: The original entry path, used to label errors.
    /// - Throws: `CancellationError`, or ``ArchiveError`` on a read or write-disk block failure.
    private func copyData(from readHandle: OpaquePointer, to writeHandle: OpaquePointer, path: String) throws {
        while true {
            try Task.checkCancellation()

            var buffer: UnsafeRawPointer?
            var size = 0
            var offset: la_int64_t = 0
            let blockRC = archive_read_data_block(readHandle, &buffer, &size, &offset)
            if blockRC == ARCHIVE_EOF { return }
            guard blockRC == ARCHIVE_OK || blockRC == ARCHIVE_WARN else {
                throw ArchiveError(stage: .readData(path: path), code: blockRC, message: errorString(readHandle))
            }
            guard let buffer, size > 0 else { continue }

            let written = archive_write_data_block(writeHandle, buffer, size, offset)
            if written < 0 {
                throw ArchiveError(stage: .writeDiskData(path: path), code: Int32(written), message: errorString(writeHandle))
            }
        }
    }

    /// Closes and frees both handles. Idempotent.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let writeHandle = writeBox.pointer {
            _ = archive_write_close(writeHandle)
        }
        writeBox.free()
        if let readHandle = readBox.pointer {
            _ = archive_read_close(readHandle)
        }
        readBox.free()
    }

    // Backstop teardown is handled by ``readBox`` / ``writeBox``: their `deinit`s free the
    // handles (and deallocate any stable memory storage) when the actor, their sole owner, is
    // deallocated. The primary teardown path remains the explicit ``close()``.

    /// Validates an entry's original relative path against the active secure options, then roots
    /// it under the destination directory.
    ///
    /// When ``ExtractionOptions/secureNoAbsolutePaths`` is set, an absolute original path is
    /// rejected here in Swift, because the rooted result is itself absolute and could not be
    /// distinguished by libarchive. When ``ExtractionOptions/secureNoDotDot`` is set, any `..`
    /// component is rejected as a Zip Slip attempt. Both checks mirror the libarchive flags they
    /// stand in for, so the security posture is unchanged.
    ///
    /// - Parameter originalPath: The entry's pathname as recorded in the archive.
    /// - Returns: The absolute destination-rooted pathname to write.
    /// - Throws: ``ArchiveError`` with stage ``ArchiveError/Stage/writeHeader(path:)`` if a secure
    ///   check rejects the path.
    private func rootedPath(for originalPath: String) throws -> String {
        if secureOptions.contains(.secureNoAbsolutePaths), originalPath.hasPrefix("/") {
            throw ArchiveError(stage: .writeHeader(path: originalPath), code: ARCHIVE_FAILED, message: "absolute paths are rejected by the secure extraction options")
        }
        if secureOptions.contains(.secureNoDotDot) {
            let components = originalPath.split(separator: "/", omittingEmptySubsequences: true)
            if components.contains("..") {
                throw ArchiveError(stage: .writeHeader(path: originalPath), code: ARCHIVE_FAILED, message: "\"..\" path traversal is rejected by the secure extraction options")
            }
        }
        return destinationPrefix + originalPath
    }

    /// Normalizes a destination URL into a fully symlink-resolved path prefix with one trailing
    /// separator.
    ///
    /// The path is canonicalized with `realpath(3)` so that trusted symbolic links in the
    /// destination's own ancestry (such as macOS's `/var`, a link to `/private/var`) are followed
    /// once, up front. Without this, the `ARCHIVE_EXTRACT_SECURE_SYMLINKS` guard would refuse to
    /// write through those ancestor links. `Foundation`'s `resolvingSymlinksInPath()` is not used
    /// because it deliberately preserves the `/var` and `/tmp` short forms. The guard still
    /// protects against symbolic links that appear inside the extracted content, because only the
    /// destination prefix is resolved here.
    ///
    /// The destination directory must already exist when this is called so that `realpath` can
    /// resolve every component.
    ///
    /// - Parameter destination: The destination directory URL.
    /// - Returns: The destination's resolved filesystem path ending in a single `/`.
    /// - Throws: ``ArchiveError`` with stage ``ArchiveError/Stage/openDisk`` if the destination
    ///   path cannot be canonicalized, so the caller learns the destination is unreachable rather
    ///   than seeing confusing per-entry symlink rejections later.
    private static func normalizedPrefix(_ destination: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedPath: String? = destination.path.withCString { input in
            buffer.withUnsafeMutableBufferPointer { out in
                realpath(input, out.baseAddress).map { String(cString: $0) }
            }
        }
        guard var resolved = resolvedPath else {
            throw ArchiveError(stage: .openDisk, code: ARCHIVE_FATAL, message: "cannot canonicalize destination directory: \(destination.path)")
        }
        if !resolved.hasSuffix("/") {
            resolved += "/"
        }
        return resolved
    }
}
