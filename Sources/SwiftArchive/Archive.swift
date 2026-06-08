import Foundation
import libarchive

/// Stateless one-shot conveniences for whole-archive read and write, plus
/// library version info.
///
/// Each function creates a transient ``ArchiveReader`` / ``ArchiveWriter`` actor,
/// drives it to completion, and tears it down. The function body itself does no
/// blocking work; it only awaits methods on that actor. Because the actor runs on
/// its own private serial executor, the blocking (de)compression always executes
/// there and never blocks the caller, including a `@MainActor` caller.
///
/// For large archives where you want to process entries as they arrive (with
/// backpressure), use ``ArchiveReader`` / ``ArchiveWriter`` directly.
public enum Archive {

    /// Reads every entry of an archive, each paired with its full payload.
    ///
    /// The blocking read runs on the reader actor's private executor, so the caller
    /// is never blocked, and cancellation is honored between entries. The whole
    /// archive is materialized in memory; prefer a streaming ``ArchiveReader`` for
    /// huge inputs.
    ///
    /// ```swift
    /// let entries = try await Archive.read(from: .fileURL(archiveURL))
    /// for item in entries {
    ///     print(item.entry.path, item.bytes.count)
    /// }
    /// ```
    ///
    /// - Parameter source: In-memory bytes or a file URL.
    /// - Returns: Every entry paired with its bytes, in archive order.
    /// - Throws: ``ArchiveError`` on a fatal read error.
    public static func read(from source: ArchiveSource) async throws -> [ArchiveReader.EntryWithData] {
        let reader = try await ArchiveReader(reading: source)
        let entries = try await reader.readAll()
        await reader.close()
        return entries
    }

    /// Opens a streaming reader over the given source.
    ///
    /// Equivalent to ``ArchiveReader/init(reading:)``, exposed here for
    /// discoverability. Prefer this for large archives that should be processed
    /// entry by entry.
    ///
    /// ```swift
    /// let reader = try await Archive.reader(for: .fileURL(archiveURL))
    /// for try await item in reader { print(item.entry.path) }
    /// await reader.close()
    /// ```
    ///
    /// - Parameter source: In-memory bytes or a file URL.
    /// - Returns: An open ``ArchiveReader``.
    /// - Throws: ``ArchiveError`` if the handle cannot be allocated or opened.
    public static func reader(for source: ArchiveSource) async throws -> ArchiveReader {
        try await ArchiveReader(reading: source)
    }

    /// Writes the given entries into an in-memory archive and returns its bytes.
    ///
    /// Compression is CPU-bound and blocking, but it runs on the writer actor's
    /// private executor, so the caller stays unblocked.
    ///
    /// ```swift
    /// let bytes = try await Archive.write(drafts, format: .ustar, filter: .gzip)
    /// ```
    ///
    /// - Parameters:
    ///   - entries: The entries to write, in order.
    ///   - format: The container format.
    ///   - filter: The compression filter. Use ``ArchiveFilter/none`` for zip or
    ///     7-Zip. The default is ``ArchiveFilter/none``.
    /// - Returns: The complete archive bytes.
    /// - Throws: ``ArchiveError`` if any stage fails.
    public static func write(
        _ entries: [EntryDraft],
        format: ArchiveFormat,
        filter: ArchiveFilter = .none
    ) async throws -> Data {
        let writer = try await ArchiveWriter(format: format, filter: filter, to: .memory)
        try await writer.append(contentsOf: entries)
        return try await writer.finish()
    }

    /// Writes the given entries directly to a file on disk.
    ///
    /// ```swift
    /// try await Archive.write(drafts, format: .ustar, filter: .gzip, to: outputURL)
    /// ```
    ///
    /// - Parameters:
    ///   - entries: The entries to write, in order.
    ///   - format: The container format.
    ///   - filter: The compression filter (defaults to `.none`).
    ///   - url: A `file://` URL to create or overwrite.
    /// - Throws: ``ArchiveError`` if the URL is invalid or any stage fails.
    public static func write(
        _ entries: [EntryDraft],
        format: ArchiveFormat,
        filter: ArchiveFilter = .none,
        to url: URL
    ) async throws {
        let writer = try await ArchiveWriter(format: format, filter: filter, to: .fileURL(url))
        try await writer.append(contentsOf: entries)
        try await writer.finish()
    }

    /// The libarchive version string.
    ///
    /// Reports the value of `archive_version_string`. Reading this property does no
    /// blocking work and is safe to access from any isolation context.
    public static var version: String {
        guard let cstr = archive_version_string() else { return "" }
        return String(cString: cstr)
    }

    /// Versions of the bundled codec libraries, each `nil` if not linked.
    public static var codecVersions: CodecVersions {
        func read(_ fn: () -> UnsafePointer<CChar>?) -> String? {
            fn().map { String(cString: $0) }
        }
        return CodecVersions(
            zlib: read(archive_zlib_version),
            bzip2: read(archive_bzlib_version),
            xz: read(archive_liblzma_version),
            zstd: read(archive_libzstd_version),
            lz4: read(archive_liblz4_version)
        )
    }

    /// Extracts every entry of an archive onto disk under a destination directory, securely by default.
    ///
    /// The blocking extraction runs on a private serial executor, so the caller, including a
    /// `@MainActor` caller, is never blocked, and cancellation is honored between entries. Entries
    /// are written relative to `destination`; the destination directory is created if it does not exist.
    ///
    /// ## Security
    /// The default ``ExtractionOptions/secure`` set rejects entries with absolute paths, rejects `..`
    /// path-traversal components, and refuses to follow symbolic links out of `destination`. Passing a
    /// different option set that omits those members removes those protections and must be done deliberately.
    ///
    /// ```swift
    /// try await Archive.extract(.fileURL(archiveURL), to: outputDirectoryURL)
    /// ```
    ///
    /// - Parameters:
    ///   - source: The archive to read, as in-memory bytes or a file URL.
    ///   - destination: The directory under which entries are recreated.
    ///   - options: The extraction flags. Defaults to ``ExtractionOptions/secure``.
    /// - Returns: The number of entries written to disk.
    /// - Throws: `CancellationError`, or ``ArchiveError`` on a read or write-disk failure.
    @discardableResult
    public static func extract(
        _ source: ArchiveSource,
        to destination: URL,
        options: ExtractionOptions = .secure
    ) async throws -> Int {
        let extractor = try await DiskExtractor(reading: source, to: destination, options: options)
        do {
            let count = try await extractor.extractAll()
            await extractor.close()
            return count
        } catch {
            await extractor.close()
            throw error
        }
    }

    /// Archives a directory tree on disk into a new archive, writing the result to a destination.
    ///
    /// Walks `directory` with a physical traversal by default (symbolic links are stored as links, not
    /// followed). All blocking traversal and compression runs on private serial executors, so the caller
    /// is never blocked, and cancellation is honored between entries.
    ///
    /// ```swift
    /// let bytes = try await Archive.archive(directory: folderURL, to: .memory, format: .ustar, filter: .gzip)
    /// ```
    ///
    /// - Parameters:
    ///   - directory: The directory whose contents are archived.
    ///   - destination: The output destination, in memory or a file URL.
    ///   - format: The container format.
    ///   - filter: The compression filter. Defaults to ``ArchiveFilter/none``.
    ///   - followSymlinks: A Boolean value that indicates whether symbolic links are followed instead of
    ///     stored as links. Defaults to `false`.
    /// - Returns: The produced bytes for a memory destination, or an empty `Data` value for a file destination.
    /// - Throws: `CancellationError`, or ``ArchiveError`` on a traversal or write failure.
    @discardableResult
    public static func archive(
        directory: URL,
        to destination: ArchiveDestination = .memory,
        format: ArchiveFormat,
        filter: ArchiveFilter = .none,
        followSymlinks: Bool = false
    ) async throws -> Data {
        let writer = try await ArchiveWriter(format: format, filter: filter, to: destination)
        let archiver = try await DiskArchiver(directory: directory, followSymlinks: followSymlinks)
        do {
            try await archiver.writeAll(into: writer)
            await archiver.close()
        } catch {
            await archiver.close()
            // Close the writer so its handle is released promptly, then remove any partial output
            // file so a failed archive leaves nothing behind.
            _ = try? await writer.finish()
            if case .fileURL(let url) = destination {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        return try await writer.finish()
    }

    /// Bundled codec library version strings.
    public struct CodecVersions: Sendable {
        /// The zlib version string, or `nil` if zlib is not linked (`archive_zlib_version`).
        public let zlib: String?
        /// The bzip2 version string, or `nil` if bzip2 is not linked (`archive_bzlib_version`).
        public let bzip2: String?
        /// The xz/liblzma version string, or `nil` if it is not linked (`archive_liblzma_version`).
        public let xz: String?
        /// The zstd version string, or `nil` if zstd is not linked (`archive_libzstd_version`).
        public let zstd: String?
        /// The lz4 version string, or `nil` if lz4 is not linked (`archive_liblz4_version`).
        public let lz4: String?

        init(zlib: String?, bzip2: String?, xz: String?, zstd: String?, lz4: String?) {
            self.zlib = zlib
            self.bzip2 = bzip2
            self.xz = xz
            self.zstd = zstd
            self.lz4 = lz4
        }
    }
}
