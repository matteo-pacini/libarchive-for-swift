import Foundation
import libarchive

/// A streaming reader over a single archive, backed by one libarchive read handle.
///
/// `ArchiveReader` is an actor, so all access to the non-thread-safe handle is
/// serialized by actor isolation. It runs on a private serial executor, so the
/// blocking decompression in each call happens on a dedicated dispatch thread and
/// never blocks the caller's actor or the main actor.
///
/// Format and filter are auto-detected, so tar, cpio, zip, gzip, xz, and zstd
/// inputs are handled transparently. The read path tolerates `ARCHIVE_WARN`.
///
/// The type conforms to `AsyncSequence`. Iterate with `for try await` to receive
/// each entry paired with its fully drained payload (see ``EntryWithData``). Each
/// iteration step reads one header and drains that entry's bytes as a single
/// atomic actor call, so the handle is never left between header and data across a
/// suspension. For entries too large to hold in memory, use ``nextEntry()`` with
/// ``readData(maxLength:)`` or ``dataStream(chunkSize:)``.
///
/// ```swift
/// let reader = try await ArchiveReader(reading: .fileURL(archiveURL))
/// for try await item in reader {
///     print(item.entry.path, item.bytes.count)
/// }
/// await reader.close()
/// ```
///
/// ## Cancellation
/// `Task.isCancelled` is checked before pulling each header and before each data
/// chunk. A cancelled read ends iteration cleanly by returning `nil`. A single
/// in-flight C call is not interruptible, so the finest honest granularity is one
/// data chunk.
///
/// ## Lifetime
/// The reader retains its source bytes (memory case) for its whole lifetime so the
/// open handle always points at valid memory. Call ``close()`` when done, or
/// release the reader; a plain deinit frees the handle as a backstop.
public actor ArchiveReader: AsyncSequence {

    /// An entry paired with its fully drained payload bytes, produced by iteration.
    public struct EntryWithData: Sendable, Equatable {
        /// The entry metadata snapshot.
        public let entry: ArchiveEntry
        /// The entry's complete payload bytes.
        public let bytes: [UInt8]

        init(entry: ArchiveEntry, bytes: [UInt8]) {
            self.entry = entry
            self.bytes = bytes
        }
    }

    public typealias Element = EntryWithData

    // MARK: - Stored state

    /// The private serial executor that runs every blocking libarchive call.
    private let executor: ArchiveExecutor

    /// The owner of the live `struct archive *` read handle. Actor-confined; never
    /// escapes. The box frees the handle in its own `deinit` as a backstop, which
    /// keeps the non-Sendable `OpaquePointer` out of this actor's nonisolated
    /// `deinit`.
    private let handleBox = HandleBox(pointer: nil, freeFunction: archive_read_free)

    /// The live handle, or `nil` once closed. Convenience over ``handleBox``.
    private var handle: OpaquePointer? { handleBox.pointer }

    /// `true` once ``close()`` (or the box `deinit`) has freed the handle.
    private var isClosed = false

    /// The source to open, retained so the handle can be opened lazily on the first
    /// read. See ``ensureOpened()``.
    private let source: ArchiveSource

    /// `true` once the libarchive read stream has been opened with
    /// `archive_read_open*`. ``addPassphrase(_:)`` must run before this, while the
    /// handle is still in libarchive's "new" state.
    private var isOpened = false

    /// The path of the entry most recently returned by ``nextEntry()``, used to
    /// label data-read errors. Empty before the first header.
    private var currentEntryPath = ""

    /// Routes this actor's work onto its private serial executor (`Actor` requirement).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    // MARK: - Lifecycle

    /// Opens a reader over the given source, auto-detecting format and filter.
    ///
    /// Allocates and opens the handle on the actor's executor, so it does not block
    /// the caller's thread. For ``ArchiveSource/bytes(_:)`` and
    /// ``ArchiveSource/data(_:)`` the contents are retained for the reader's
    /// lifetime. For ``ArchiveSource/fileURL(_:)`` libarchive streams the file, so
    /// the whole file is not loaded up front.
    ///
    /// - Parameter source: The in-memory bytes or file URL to read.
    /// - Throws: ``ArchiveError`` if the handle cannot be allocated or opened.
    public init(reading source: ArchiveSource) async throws {
        self.executor = ArchiveExecutor(label: "com.swiftarchive.reader")
        self.source = source
        // This async init's body runs on the actor's own serial executor, so the
        // synchronous `configure` below (allocation plus support registration)
        // executes on the dedicated GCD thread, off the caller's actor. Opening the
        // source is deferred to the first read (see ``ensureOpened()``) so that
        // ``addPassphrase(_:)`` can run while the handle is still in the "new" state.
        // Actor initializers cannot delegate with `self.init`, so the gated
        // program-filter initializer repeats this setup rather than sharing it.
        try self.configure(programFilter: nil)
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    /// Opens a reader that decompresses its input through an external program.
    ///
    /// In addition to the auto-detected formats and filters, the reader pipes its
    /// input through the given command via `archive_read_support_filter_program`.
    /// The program filter is registered before the handle is opened, which is the
    /// only point in the handle's life where libarchive accepts a support call: the
    /// documented read lifecycle is allocate, register support, open, then read.
    /// There is no post-open window, so this is offered as a construction-time
    /// initializer rather than an instance method.
    ///
    /// This initializer is available on macOS and Mac Catalyst only, because the
    /// filter spawns a child process with `posix_spawn`. iOS, watchOS, and tvOS
    /// cannot spawn processes under the platform sandbox, and the bundled libarchive
    /// is patched to disable spawning there. Because this is a platform-capability
    /// limit and not an OS-version threshold, the member is removed from the API at
    /// compile time with `#if os(macOS) || targetEnvironment(macCatalyst)` rather
    /// than guarded with `@available`.
    ///
    /// - Parameters:
    ///   - source: The in-memory bytes or file URL to read.
    ///   - command: The shell command run as the decompressor.
    /// - Throws: ``ArchiveError`` if the handle cannot be allocated, the filter
    ///   cannot be installed, or the source cannot be opened.
    public init(reading source: ArchiveSource, program command: String) async throws {
        self.executor = ArchiveExecutor(label: "com.swiftarchive.reader")
        self.source = source
        try self.configure(programFilter: command)
    }
    #endif

    /// Allocates the handle and enables all formats and filters, leaving the handle
    /// in libarchive's "new" state. Runs on the actor's executor.
    ///
    /// libarchive's documented read lifecycle requires every `archive_read_support_*`
    /// call (step 2) to run before `archive_read_open_*` (step 3). Support is
    /// registered here, but the source is not opened until the first read (see
    /// ``ensureOpened()``). Keeping the handle in the "new" state preserves the window
    /// in which `archive_read_add_passphrase` is accepted, which is the contract of
    /// ``addPassphrase(_:)``. A program filter is still supplied at construction time
    /// because libarchive only accepts support calls in this same pre-open window.
    ///
    /// - Parameter programFilter: An optional external-program decompressor command to
    ///   register via `archive_read_support_filter_program`.
    /// - Throws: ``ArchiveError`` on allocation or filter-setup failure.
    private func configure(programFilter: String?) throws {
        guard let handle = archive_read_new() else {
            throw ArchiveError(stage: .allocateHandle, code: ARCHIVE_FATAL, message: "archive_read_new returned nil")
        }
        handleBox.pointer = handle

        _ = archive_read_support_format_all(handle)
        _ = archive_read_support_filter_all(handle)

        if let programFilter {
            let rc = programFilter.withCString { archive_read_support_filter_program(handle, $0) }
            guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN else {
                let message = errorString(handle)
                handleBox.free()
                throw ArchiveError(stage: .addFilter("program(\(programFilter))"), code: rc, message: message)
            }
        }
    }

    /// Opens the libarchive read stream against the stored source, once.
    ///
    /// This is the deferred step 3 of libarchive's read lifecycle. It runs on the
    /// first read so that ``addPassphrase(_:)`` has already executed while the handle
    /// was in the "new" state. Subsequent calls are no-ops.
    ///
    /// - Throws: ``ArchiveError`` if the reader is closed or the open call fails.
    private func ensureOpened() throws {
        guard !isOpened else { return }
        guard !isClosed, let handle = handleBox.pointer else {
            throw ArchiveError(stage: .open, code: ARCHIVE_FATAL, message: "reader is closed")
        }

        let rc: Int32
        switch source {
        case .bytes(let bytes):
            rc = openMemory(handle, bytes)
        case .data(let data):
            rc = openMemory(handle, [UInt8](data))
        case .fileURL(let url):
            rc = url.path.withCString { archive_read_open_filename(handle, $0, 64 * 1024) }
        }

        guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN else {
            let message = errorString(handle)
            handleBox.free()
            throw ArchiveError(stage: .open, code: rc, message: message)
        }
        isOpened = true
    }

    /// Copies `bytes` into stable storage and opens the handle against it.
    ///
    /// `archive_read_open_memory` keeps the pointer for the handle's lifetime, so
    /// the storage must outlive the handle; it is owned by the actor and freed in
    /// ``close()`` / `deinit`.
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
        // Tie the storage's lifetime to the handle's: the box frees the handle
        // (explicit close or backstop deinit) and then deallocates this storage,
        // so both share one teardown path and the storage always outlives the
        // handle's pointer into it. The closure captures the pointer value, not
        // `self`, so the backstop free in the box's deinit cleans up correctly.
        handleBox.onFree { storage.deallocate() }
        return archive_read_open_memory(handle, storage.baseAddress, bytes.count)
    }

    // MARK: - Low-level pull

    /// Reads the next entry's metadata, advancing past any unread data of the
    /// previous entry.
    ///
    /// This is the low-level pull. After a non-nil return, drain the payload with
    /// ``readData(maxLength:)`` / ``dataStream(chunkSize:)`` or discard it with
    /// ``skipData()`` before calling `nextEntry()` again.
    ///
    /// - Returns: The next ``ArchiveEntry``, or `nil` at end of archive or on cancellation.
    /// - Throws: ``ArchiveError`` on a fatal read error.
    public func nextEntry() throws -> ArchiveEntry? {
        guard !isClosed, let handle else { return nil }
        if Task.isCancelled { return nil }
        try ensureOpened()

        var entryPtr: OpaquePointer?
        let rc = archive_read_next_header(handle, &entryPtr)
        if rc == ARCHIVE_EOF { return nil }
        guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN else {
            throw ArchiveError(stage: .readHeader, code: rc, message: errorString(handle))
        }
        let snapshot = makeSnapshot(from: entryPtr)
        currentEntryPath = snapshot.path
        return snapshot
    }

    /// Reads up to `maxLength` bytes of the current entry's payload.
    ///
    /// This is the single blocking decompression step; it runs on the actor's
    /// private executor and is not cancellable mid-call.
    ///
    /// - Parameter maxLength: The maximum bytes to read this call (defaults to 64 KiB).
    /// - Returns: The bytes read; an empty array marks the end of this entry's data.
    /// - Throws: ``ArchiveError`` if `archive_read_data` returns a non-usable
    ///   negative status (``ArchiveStatus/failed`` or ``ArchiveStatus/fatal``).
    public func readData(maxLength: Int = 64 * 1024) throws -> [UInt8] {
        guard !isClosed, let handle else { return [] }
        try ensureOpened()
        let cap = Swift.max(maxLength, 1)
        var chunk = [UInt8](repeating: 0, count: cap)
        let n: la_ssize_t = chunk.withUnsafeMutableBytes { buffer in
            archive_read_data(handle, buffer.baseAddress, buffer.count)
        }
        if n == 0 { return [] }
        if n < 0 {
            // A negative return is a status code. ``ArchiveStatus/warn`` /
            // ``ArchiveStatus/retry`` leave the handle usable, so treat them as the
            // end of this entry's data rather than a hard failure; only the
            // non-usable codes throw, carrying their real status.
            let status = ArchiveStatus(rawCode: Int32(n))
            guard status.isUsable else {
                throw ArchiveError(stage: .readData(path: currentEntryPath), code: Int32(n), message: errorString(handle))
            }
            return []
        }
        return Array(chunk[0..<Int(n)])
    }

    /// Reads the entire current entry's payload into memory.
    ///
    /// - Returns: All remaining bytes of the current entry.
    /// - Throws: ``ArchiveError`` on a read error.
    /// - Warning: Buffers the whole entry. Use ``readData(maxLength:)`` in a loop or
    ///   ``dataStream(chunkSize:)`` for large entries.
    public func readAllData() throws -> [UInt8] {
        var content: [UInt8] = []
        while true {
            let chunk = try readData()
            if chunk.isEmpty { break }
            content.append(contentsOf: chunk)
        }
        return content
    }

    /// Skips the remainder of the current entry's data.
    ///
    /// Advances past any unread payload of the current entry using
    /// `archive_read_data_skip`, leaving the reader positioned to read the next
    /// header.
    ///
    /// - Throws: ``ArchiveError`` if the skip fails.
    public func skipData() throws {
        guard !isClosed, let handle else { return }
        let rc = archive_read_data_skip(handle)
        guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN || rc == ARCHIVE_EOF else {
            throw ArchiveError(stage: .readData(path: currentEntryPath), code: rc, message: errorString(handle))
        }
    }

    // MARK: - Encryption

    /// Registers a passphrase used to decrypt encrypted entries.
    ///
    /// libarchive decrypts lazily as entry data is read, so the passphrase is
    /// consulted during ``readData(maxLength:)`` and the high-level read calls
    /// rather than at open time. Register the passphrase after construction and
    /// before draining the encrypted entry's data. You may call this more than
    /// once; libarchive tries each registered passphrase in turn. This wraps
    /// `archive_read_add_passphrase`.
    ///
    /// Unlike the program-filter initializer, no decompression child process is
    /// spawned, so this method is available on every platform.
    ///
    /// ```swift
    /// let reader = try await ArchiveReader(reading: .fileURL(encryptedZipURL))
    /// try await reader.addPassphrase("correct horse battery staple")
    /// for try await item in reader {
    ///     print(item.entry.path, item.bytes.count)
    /// }
    /// ```
    ///
    /// - Parameter passphrase: The decryption passphrase to register. Must not be empty.
    /// - Throws: ``ArchiveError`` with stage ``ArchiveError/Stage/setOption(_:)`` if the reader is closed or libarchive rejects the passphrase.
    public func addPassphrase(_ passphrase: String) throws {
        guard !isClosed, let handle else {
            throw ArchiveError(stage: .setOption("read-passphrase"), code: ARCHIVE_FATAL, message: "reader is closed")
        }
        let rc = passphrase.withCString { archive_read_add_passphrase(handle, $0) }
        guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN else {
            throw ArchiveError(stage: .setOption("read-passphrase"), code: rc, message: errorString(handle))
        }
    }

    /// Returns whether the archive contains encrypted entries.
    ///
    /// Wraps `archive_read_has_encrypted_entries`. The answer can be
    /// ``EncryptedEntriesState/unknown`` until enough of the archive has been read,
    /// so call it after reading at least one header for the most reliable result,
    /// and ``EncryptedEntriesState/unsupported`` for formats without encryption.
    ///
    /// ```swift
    /// let reader = try await ArchiveReader(reading: .fileURL(zipURL))
    /// _ = try await reader.nextEntry()
    /// if await reader.hasEncryptedEntries() == .yes {
    ///     try await reader.addPassphrase(passphrase)
    /// }
    /// ```
    ///
    /// - Returns: An ``EncryptedEntriesState`` describing the encryption status.
    public func hasEncryptedEntries() -> EncryptedEntriesState {
        guard !isClosed, let handle else { return .unsupported }
        return EncryptedEntriesState(rawValue: archive_read_has_encrypted_entries(handle))
    }

    // MARK: - High-level read

    /// Reads the next entry and fully drains its payload as one atomic actor call.
    ///
    /// This is the unit of work behind iteration: the header read and the full
    /// data drain happen inside a single actor-isolated method, so no other task
    /// can resume the handle between the header and its data.
    ///
    /// - Returns: The next entry paired with its bytes, or `nil` at end of archive
    ///   or on cancellation.
    /// - Throws: ``ArchiveError`` on a fatal read error.
    func nextEntryWithData() throws -> EntryWithData? {
        guard let entry = try nextEntry() else { return nil }
        let bytes = try readAllData()
        return EntryWithData(entry: entry, bytes: bytes)
    }

    /// Reads every remaining entry, fully draining each payload, into an array.
    ///
    /// Convenience over the iterator for the whole-archive case; suitable when the
    /// entries fit comfortably in memory.
    ///
    /// - Returns: All remaining entries paired with their bytes, in archive order.
    /// - Throws: ``ArchiveError`` on a fatal read error.
    public func readAll() throws -> [EntryWithData] {
        var results: [EntryWithData] = []
        while let next = try nextEntryWithData() {
            results.append(next)
        }
        return results
    }

    /// Reads one chunk of the current entry, for the chunked data stream.
    ///
    /// Honors cancellation at the chunk boundary by returning `nil` (ending the
    /// stream) when the consuming task is cancelled.
    ///
    /// - Parameter chunkSize: The bytes requested this chunk.
    /// - Returns: The next chunk, or `nil` when the entry is exhausted or the task
    ///   is cancelled.
    /// - Throws: ``ArchiveError`` if the underlying read fails.
    func nextDataChunk(chunkSize: Int) throws -> [UInt8]? {
        if Task.isCancelled { return nil }
        let chunk = try readData(maxLength: chunkSize)
        return chunk.isEmpty ? nil : chunk
    }

    /// Returns a byte-chunk stream over the current entry's payload, draining it
    /// lazily.
    ///
    /// Each call to the stream's `next()` performs one blocking `archive_read_data`
    /// on this actor. The stream finishes when the entry is exhausted, and
    /// cancelling the consuming task stops production at the next chunk boundary.
    /// The handle is owned by the actor, not the stream, and is not freed when the
    /// stream ends. A read failure is delivered by finishing the stream with an
    /// ``ArchiveError``.
    ///
    /// - Parameter chunkSize: The number of bytes requested per chunk. The default
    ///   is 64 KiB.
    /// - Returns: An `AsyncThrowingStream` of byte chunks over the current entry.
    public nonisolated func dataStream(chunkSize: Int = 64 * 1024) -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while let chunk = try await self.nextDataChunk(chunkSize: chunkSize) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Teardown

    /// Closes and frees the underlying handle. Idempotent.
    ///
    /// After closing, ``nextEntry()`` returns `nil` and ``readAll()`` returns an
    /// empty array.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        if let handle = handleBox.pointer {
            _ = archive_read_close(handle)
        }
        // Frees the handle and deallocates the stable source storage in one step.
        handleBox.free()
    }

    // Backstop teardown is handled by ``handleBox``: its own `deinit` frees the
    // handle and deallocates the stable source storage when the actor (its sole
    // owner) is deallocated. No actor `deinit` is needed, which also keeps the
    // non-Sendable `OpaquePointer` out of any nonisolated `deinit`. The primary
    // teardown path remains the explicit ``close()``.

    // MARK: - AsyncSequence

    /// Creates a new ``AsyncIterator`` bound to this reader.
    public nonisolated func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(reader: self)
    }

    /// The async iterator over a reader's entries.
    ///
    /// Holds only the `actor` reference (Sendable); the handle stays inside the
    /// actor and is never captured here.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private let reader: ArchiveReader

        init(reader: ArchiveReader) {
            self.reader = reader
        }

        /// Pulls the next entry paired with its fully drained payload.
        /// - Returns: The next ``EntryWithData``, or `nil` at end of archive or on cancellation.
        /// - Throws: ``ArchiveError`` on a fatal read error.
        public mutating func next() async throws -> EntryWithData? {
            try await reader.nextEntryWithData()
        }
    }
}
