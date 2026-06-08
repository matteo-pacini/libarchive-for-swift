import Foundation
import libarchive

/// A streaming writer that builds a single archive, backed by one libarchive write handle.
///
/// `ArchiveWriter` is an actor, so all access to the non-thread-safe handle is
/// serialized. It runs on a private serial executor, so the blocking compression
/// in each ``append(_:)`` happens on a dedicated dispatch thread and never blocks
/// the caller's actor or the main actor.
///
/// Lifecycle mirrors libarchive's push model: create the writer with a format and
/// filter, call ``append(_:)`` for one or more entries (header, data, and finish
/// run atomically per entry), then call ``finish()`` to flush, close, and obtain
/// the bytes for a memory destination or finalize the file for a file destination.
///
/// In-memory writes use `archive_write_open` with a growing callback buffer, not a
/// fixed `archive_write_open_memory` buffer, so arbitrarily large or incompressible
/// input cannot overflow.
///
/// ```swift
/// let writer = try await ArchiveWriter(format: .ustar, filter: .gzip)
/// try await writer.append(EntryDraft(path: "hello.txt", bytes: Array("hi".utf8)))
/// let data = try await writer.finish()
/// ```
///
/// ## Cancellation
/// The writer checks `Task.isCancelled` at the start of each ``append(_:)``; a
/// cancelled task throws `CancellationError` before encoding the next entry. The
/// compression of a single entry is one blocking C call and is not interruptible.
public actor ArchiveWriter {

    // MARK: - Stored state

    /// The private serial executor that runs every blocking libarchive call.
    private let executor: ArchiveExecutor

    /// The owner of the live `struct archive *` write handle. Actor-confined;
    /// never escapes. The box frees the handle in its own `deinit` as a backstop,
    /// keeping the non-Sendable `OpaquePointer` out of this actor's nonisolated
    /// `deinit`.
    private let handleBox = HandleBox(pointer: nil, freeFunction: archive_write_free)

    /// The live handle, or `nil` once finished. Convenience over ``handleBox``.
    private var handle: OpaquePointer? { handleBox.pointer }

    /// The growable in-memory sink for the `.memory` destination, or `nil` for the
    /// file destination. Touched only on the actor's executor thread.
    private let buffer: WriteBufferBox?

    /// `true` once ``finish()`` (or `deinit`) has closed and freed the handle.
    private var isFinished = false

    /// The output destination, retained so the stream can be opened lazily on the
    /// first write. See ``ensureOpened()``.
    private let destination: ArchiveDestination

    /// `true` once the libarchive write stream has been opened with
    /// `archive_write_open*`. Option and passphrase setters must run before this,
    /// while the handle is still in libarchive's "new" state.
    private var isOpened = false

    /// The bytes produced by a memory write, cached so ``finish()`` is idempotent.
    private var finishedData = Data()

    /// Routes this actor's work onto its private serial executor (`Actor` requirement).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    // MARK: - Lifecycle

    /// Creates and opens a writer with the chosen format, filter, and destination.
    ///
    /// ```swift
    /// let writer = try await ArchiveWriter(format: .zip, to: .memory)
    /// ```
    ///
    /// - Parameters:
    ///   - format: The container format. See ``ArchiveFormat``.
    ///   - filter: The compression filter. Use ``ArchiveFilter/none`` for zip or
    ///     7-Zip. The default is ``ArchiveFilter/none``.
    ///   - destination: The output destination, either in memory (the default) or a
    ///     file URL.
    /// - Throws: ``ArchiveError`` if allocation, format or filter setup, or opening
    ///   the destination fails.
    public init(
        format: ArchiveFormat,
        filter: ArchiveFilter = .none,
        to destination: ArchiveDestination = .memory
    ) async throws {
        self.executor = ArchiveExecutor(label: "com.swiftarchive.writer")
        self.destination = destination
        switch destination {
        case .memory:
            self.buffer = WriteBufferBox()
        case .fileURL:
            self.buffer = nil
        }
        // This async init's body runs on the actor's own serial executor, so the
        // synchronous `configure` below (allocation plus format / filter setup)
        // executes on the dedicated GCD thread, off the caller. Opening the stream
        // is deferred to the first write (see ``ensureOpened()``) so that option and
        // passphrase setters can run while the handle is still in the "new" state.
        // Actor initializers cannot delegate with `self.init`, so the gated
        // program-filter initializer repeats this setup rather than sharing it.
        try self.configure(format: format, filters: [filter])
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    /// Creates and opens a writer whose payload is piped through an external program
    /// compression filter.
    ///
    /// The writer registers the program filter before opening the handle, which is
    /// the only point in the handle's lifecycle where libarchive accepts a filter.
    /// For this reason the program filter is supplied at construction time rather
    /// than through an instance method.
    ///
    /// This initializer is available on macOS and Mac Catalyst only, because the
    /// filter spawns a child process. iOS, watchOS, and tvOS cannot spawn processes
    /// under the platform sandbox, so the member is removed from the API at compile
    /// time on those platforms.
    ///
    /// - Parameters:
    ///   - format: The container format. See ``ArchiveFormat``.
    ///   - command: The shell command run as the compressor, for example `"gzip -9"`.
    ///   - destination: The output destination, either in memory (the default) or a
    ///     file URL.
    /// - Throws: ``ArchiveError`` if allocation, format or filter setup, or opening
    ///   the destination fails.
    public init(
        format: ArchiveFormat,
        program command: String,
        to destination: ArchiveDestination = .memory
    ) async throws {
        self.executor = ArchiveExecutor(label: "com.swiftarchive.writer")
        self.destination = destination
        switch destination {
        case .memory:
            self.buffer = WriteBufferBox()
        case .fileURL:
            self.buffer = nil
        }
        try self.configure(format: format, filters: [.program(command)])
    }
    #endif

    /// Allocates the handle and applies the format and every filter in order, leaving
    /// the handle in libarchive's "new" state. Runs on the actor's executor.
    ///
    /// libarchive's documented lifecycle requires the format and all filters to be
    /// registered (step 2) before `archive_write_open` (step 3). They are applied
    /// here, but the stream is not opened until the first write (see
    /// ``ensureOpened()``). Keeping the handle in the "new" state preserves the window
    /// in which `archive_write_set_options` and `archive_write_set_passphrase` are
    /// accepted, which is the contract of ``setOptions(_:)`` and ``setPassphrase(_:)``.
    /// Program filters are still supplied at construction time because libarchive only
    /// accepts filters in this same pre-open window.
    ///
    /// - Parameters:
    ///   - format: The container format.
    ///   - filters: The compression filters, applied in order.
    /// - Throws: ``ArchiveError`` on any allocation or setup failure.
    private func configure(
        format: ArchiveFormat,
        filters: [ArchiveFilter]
    ) throws {
        guard let handle = archive_write_new() else {
            throw ArchiveError(stage: .allocateHandle, code: ARCHIVE_FATAL, message: "archive_write_new returned nil")
        }
        handleBox.pointer = handle

        let fmtRC = format.apply(handle)
        guard fmtRC == ARCHIVE_OK else {
            let message = errorString(handle)
            handleBox.free()
            throw ArchiveError(stage: .setFormat(format.name), code: fmtRC, message: message)
        }

        for filter in filters {
            let filtRC = filter.apply(handle)
            guard filtRC == ARCHIVE_OK else {
                let message = errorString(handle)
                handleBox.free()
                throw ArchiveError(stage: .addFilter(filter.name), code: filtRC, message: message)
            }
        }
    }

    /// Opens the libarchive write stream against the stored destination, once.
    ///
    /// This is the deferred step 3 of libarchive's write lifecycle. It runs on the
    /// first write so that option and passphrase setters have already executed while
    /// the handle was in the "new" state. Subsequent calls are no-ops.
    ///
    /// - Throws: ``ArchiveError`` if the stream is finished or the open call fails.
    private func ensureOpened() throws {
        guard !isOpened else { return }
        guard !isFinished, let handle = handleBox.pointer else {
            throw ArchiveError(stage: .open, code: ARCHIVE_FATAL, message: "writer is finished")
        }

        let openRC: Int32
        switch destination {
        case .memory:
            // Suppress trailing block padding for the in-memory result, matching
            // what `archive_write_open_memory` does internally. Without this, the
            // generic `archive_write_open` callback path pads the final block out
            // to the default 10240-byte tar block, appending zero bytes after the
            // compressed stream. Most filters tolerate that, but the zstd reader
            // rejects the trailing zeros at open time ("Unknown frame descriptor").
            // A file destination keeps the conventional on-disk block padding.
            _ = archive_write_set_bytes_in_last_block(handle, 1)
            // client_data is the actor-confined buffer box; only this executor
            // thread ever touches it, so no shared mutable state escapes.
            let clientData = Unmanaged.passUnretained(buffer!).toOpaque()
            openRC = archive_write_open(handle, clientData, nil, writeBufferCallback, nil)
        case .fileURL(let url):
            openRC = url.path.withCString { archive_write_open_filename(handle, $0) }
        }

        guard openRC == ARCHIVE_OK else {
            let message = errorString(handle)
            handleBox.free()
            throw ArchiveError(stage: .open, code: openRC, message: message)
        }
        isOpened = true
    }

    // MARK: - Append

    /// Appends one entry by writing its header, its payload for regular files, and
    /// then finishing the entry.
    ///
    /// The header, data, and finish steps run as one atomic actor call, so the
    /// handle is never observed mid-entry across a suspension. This is the blocking
    /// step; compression runs on the actor's private executor.
    ///
    /// ```swift
    /// try await writer.append(EntryDraft(path: "notes.txt", bytes: Array(text.utf8)))
    /// ```
    ///
    /// - Parameter entry: The draft to write. ``EntryDraft/size`` is the declared
    ///   header size and bounds how many payload bytes libarchive accepts; it
    ///   truncates writes beyond the declared size and pads short ones. Any entry
    ///   carrying a non-empty ``EntryDraft/bytes`` payload has its bytes written, up
    ///   to the declared size, so a payload is never silently dropped for a
    ///   non-regular type.
    /// - Throws: `CancellationError` if the task is cancelled before encoding;
    ///   ``ArchiveError`` on a header, data, or finish failure.
    public func append(_ entry: EntryDraft) throws {
        try Task.checkCancellation()
        guard !isFinished, let handle else {
            throw ArchiveError(stage: .writeHeader(path: entry.path), code: ARCHIVE_FATAL, message: "writer is finished")
        }
        try ensureOpened()

        try writeHeader(entry, handle: handle)

        if !entry.bytes.isEmpty {
            try writeAllData(entry.bytes, path: entry.path, handle: handle)
        }

        try finishEntry(path: entry.path, handle: handle)
    }

    /// Appends a sequence of entries in order.
    /// - Parameter entries: The drafts to write.
    /// - Throws: `CancellationError` or ``ArchiveError`` as in ``append(_:)``.
    public func append(contentsOf entries: [EntryDraft]) throws {
        for entry in entries {
            try append(entry)
        }
    }

    /// Writes an entry header, then streams its payload from an async byte source,
    /// for entries too large to hold in memory.
    ///
    /// ```swift
    /// try await writer.append(header: draft, streamingFrom: byteChunks)
    /// ```
    ///
    /// - Parameters:
    ///   - entry: The draft supplying metadata. ``EntryDraft/size`` must be set
    ///     correctly for formats that require a known size up front, such as ustar.
    ///   - body: An async sequence of byte chunks, compressed and written in order.
    /// - Throws: `CancellationError` if the task is cancelled before or during
    ///   streaming; any error thrown by `body` while producing chunks; or
    ///   ``ArchiveError`` on a write failure.
    public func append<Body: AsyncSequence & Sendable>(
        header entry: EntryDraft,
        streamingFrom body: Body
    ) async throws where Body.Element == [UInt8] {
        try Task.checkCancellation()
        guard !isFinished, let handle else {
            throw ArchiveError(stage: .writeHeader(path: entry.path), code: ARCHIVE_FATAL, message: "writer is finished")
        }
        try ensureOpened()

        try writeHeader(entry, handle: handle)

        for try await chunk in body {
            try Task.checkCancellation()
            if !chunk.isEmpty {
                try writeAllData(chunk, path: entry.path, handle: handle)
            }
        }

        try finishEntry(path: entry.path, handle: handle)
    }

    // MARK: - Append helpers

    /// Builds a C entry from the draft and writes its header.
    /// - Parameters:
    ///   - draft: The entry whose header to write.
    ///   - handle: The open write handle.
    /// - Throws: ``ArchiveError`` if the entry cannot be allocated or the header fails.
    private func writeHeader(_ draft: EntryDraft, handle: OpaquePointer) throws {
        guard let cEntry = makeCEntry(from: draft) else {
            throw ArchiveError(stage: .writeHeader(path: draft.path), code: ARCHIVE_FATAL, message: "archive_entry_new returned nil")
        }
        defer { archive_entry_free(cEntry) }

        let rc = archive_write_header(handle, cEntry)
        guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN else {
            throw ArchiveError(stage: .writeHeader(path: draft.path), code: rc, message: errorString(handle))
        }
    }

    /// Writes a byte buffer for the current entry, looping until libarchive has
    /// consumed it or has truncated the write at the declared header size.
    ///
    /// libarchive truncates writes beyond the size declared in the entry header
    /// (`archive.h`: "the library will truncate writes beyond the size provided
    /// to archive_write_header"). When the declared size is reached,
    /// `archive_write_data` returns 0 with bytes still remaining; that is the
    /// documented, non-error end of the entry's data, so the loop stops cleanly
    /// rather than treating it as a short-write failure. A negative return is the
    /// real failure and is surfaced with its actual status code.
    ///
    /// - Parameters:
    ///   - bytes: The payload bytes to write.
    ///   - path: The entry path, for error labelling.
    ///   - handle: The open write handle.
    /// - Throws: ``ArchiveError`` on a negative `archive_write_data` status.
    private func writeAllData(_ bytes: [UInt8], path: String, handle: OpaquePointer) throws {
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                let written = archive_write_data(handle, base + offset, bytes.count - offset)
                if written < 0 {
                    throw ArchiveError(stage: .writeData(path: path), code: Int32(written), message: errorString(handle))
                }
                if written == 0 {
                    // libarchive truncated to the declared header size; the rest of
                    // the buffer is intentionally discarded, not an error.
                    break
                }
                offset += Int(written)
            }
        }
    }

    /// Finalizes the current entry.
    /// - Parameters:
    ///   - path: The entry path, for error labelling.
    ///   - handle: The open write handle.
    /// - Throws: ``ArchiveError`` if finishing the entry fails.
    private func finishEntry(path: String, handle: OpaquePointer) throws {
        let rc = archive_write_finish_entry(handle)
        guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN else {
            throw ArchiveError(stage: .finishEntry(path: path), code: rc, message: errorString(handle))
        }
    }

    // MARK: - Finalize

    /// Finalizes the archive and returns its bytes.
    ///
    /// Returns the exact archive bytes (trimmed to libarchive's reported length,
    /// with no trailing block padding) for a memory destination, or an empty `Data`
    /// value for a file destination. This method is idempotent: a second call
    /// returns the same result without re-closing the handle.
    ///
    /// ```swift
    /// let data = try await writer.finish()
    /// ```
    ///
    /// - Returns: The produced bytes for a memory destination, or an empty `Data`
    ///   value for a file destination.
    /// - Throws: ``ArchiveError`` if finalization fails.
    @discardableResult
    public func finish() throws -> Data {
        if isFinished { return finishedData }

        // Open the stream if no entry was ever appended, so an empty archive still
        // produces a valid (empty) container rather than closing an unopened handle.
        try ensureOpened()
        isFinished = true

        guard let handle = handleBox.pointer else { return finishedData }

        let rc = archive_write_close(handle)
        // Free regardless of close status so the handle is not leaked.
        defer { handleBox.free() }
        guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN else {
            throw ArchiveError(stage: .close, code: rc, message: errorString(handle))
        }

        if let buffer {
            finishedData = Data(buffer.bytes)
        }
        return finishedData
    }

    /// Sets a write passphrase for formats that support encryption (zip / 7zip).
    /// - Parameter passphrase: The passphrase to use.
    /// - Throws: ``ArchiveError`` if the passphrase cannot be set.
    public func setPassphrase(_ passphrase: String) throws {
        guard !isFinished, let handle else {
            throw ArchiveError(stage: .setOption("passphrase"), code: ARCHIVE_FATAL, message: "writer is finished")
        }
        let rc = passphrase.withCString { archive_write_set_passphrase(handle, $0) }
        guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN else {
            throw ArchiveError(stage: .setOption("passphrase"), code: rc, message: errorString(handle))
        }
    }

    // MARK: - Options

    /// Sets one or more libarchive options from a comma-separated option string.
    ///
    /// The string uses libarchive's `module:option=value` grammar, with multiple
    /// options separated by commas, and is forwarded verbatim to
    /// `archive_write_set_options`. Use this to tune the active format and filters,
    /// for example to store zip entries without compression or to raise the
    /// compression level.
    ///
    /// Call this after construction and before the first ``append(_:)``. The writer
    /// opens its underlying stream lazily on the first write, so option setters run
    /// while libarchive still accepts them; calling this after the first append fails.
    ///
    /// ```swift
    /// let writer = try await ArchiveWriter(format: .zip, to: .memory)
    /// try await writer.setOptions("zip:compression=store")
    /// ```
    ///
    /// - Parameter options: A libarchive option string, such as `"zip:compression=store,compression-level=9"`.
    /// - Throws: ``ArchiveError`` with stage ``ArchiveError/Stage/setOption(_:)`` if the writer is finished or libarchive rejects the option string.
    public func setOptions(_ options: String) throws {
        guard !isFinished, let handle else {
            throw ArchiveError(stage: .setOption("options"), code: ARCHIVE_FATAL, message: "writer is finished")
        }
        let rc = options.withCString { archive_write_set_options(handle, $0) }
        guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN else {
            throw ArchiveError(stage: .setOption("options"), code: rc, message: errorString(handle))
        }
    }

    /// Sets a single option on a specific format module.
    ///
    /// Forwards to `archive_write_set_format_option`. A `nil` value clears the
    /// option where the module supports clearing it.
    ///
    /// ```swift
    /// let writer = try await ArchiveWriter(format: .zip, to: .memory)
    /// try await writer.setFormatOption(module: "zip", key: "compression", value: "store")
    /// ```
    ///
    /// - Parameters:
    ///   - module: The format module name, such as `"zip"`, or an empty string to address the active format.
    ///   - key: The option name, such as `"compression"`.
    ///   - value: The option value, or `nil` to clear it.
    /// - Throws: ``ArchiveError`` with stage ``ArchiveError/Stage/setOption(_:)`` if the writer is finished or libarchive rejects the option.
    public func setFormatOption(module: String, key: String, value: String?) throws {
        let label = "format-option(\(module):\(key))"
        guard !isFinished, let handle else {
            throw ArchiveError(stage: .setOption(label), code: ARCHIVE_FATAL, message: "writer is finished")
        }
        let rc = module.withCString { modulePtr in
            key.withCString { keyPtr in
                withOptionalCString(value) { valuePtr in
                    archive_write_set_format_option(handle, modulePtr, keyPtr, valuePtr)
                }
            }
        }
        guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN else {
            throw ArchiveError(stage: .setOption(label), code: rc, message: errorString(handle))
        }
    }

    /// Sets a single option on a specific filter module.
    ///
    /// Forwards to `archive_write_set_filter_option`. A `nil` value clears the
    /// option where the module supports clearing it.
    ///
    /// ```swift
    /// let writer = try await ArchiveWriter(format: .ustar, filter: .zstd)
    /// try await writer.setFilterOption(module: "zstd", key: "compression-level", value: "19")
    /// ```
    ///
    /// - Parameters:
    ///   - module: The filter module name, such as `"zstd"`, or an empty string to address the active filter.
    ///   - key: The option name, such as `"compression-level"`.
    ///   - value: The option value, or `nil` to clear it.
    /// - Throws: ``ArchiveError`` with stage ``ArchiveError/Stage/setOption(_:)`` if the writer is finished or libarchive rejects the option.
    public func setFilterOption(module: String, key: String, value: String?) throws {
        let label = "filter-option(\(module):\(key))"
        guard !isFinished, let handle else {
            throw ArchiveError(stage: .setOption(label), code: ARCHIVE_FATAL, message: "writer is finished")
        }
        let rc = module.withCString { modulePtr in
            key.withCString { keyPtr in
                withOptionalCString(value) { valuePtr in
                    archive_write_set_filter_option(handle, modulePtr, keyPtr, valuePtr)
                }
            }
        }
        guard rc == ARCHIVE_OK || rc == ARCHIVE_WARN else {
            throw ArchiveError(stage: .setOption(label), code: rc, message: errorString(handle))
        }
    }

    /// Invokes `body` with a C string for `value`, or with `nil` when `value` is `nil`.
    ///
    /// libarchive's option setters treat a null value pointer as "clear this
    /// option", so a Swift `nil` must reach the C call as a genuine null pointer
    /// rather than a pointer to an empty string.
    ///
    /// - Parameters:
    ///   - value: The optional Swift string to bridge.
    ///   - body: A closure receiving the borrowed C string pointer, or `nil`.
    /// - Returns: The value returned by `body`.
    private func withOptionalCString<Result>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        if let value {
            return value.withCString { body($0) }
        } else {
            return body(nil)
        }
    }

    // Backstop teardown is handled by ``handleBox``: its own `deinit` frees the
    // handle when the actor (its sole owner) is deallocated. No actor `deinit` is
    // needed, which keeps the non-Sendable `OpaquePointer` out of any nonisolated
    // `deinit`. The primary teardown path remains the explicit ``finish()``.
}
