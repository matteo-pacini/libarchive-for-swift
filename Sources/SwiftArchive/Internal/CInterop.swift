import Foundation
import Darwin
import libarchive

// MARK: - UTF-8 locale + name decode

/// Mirrors Darwin's `<xlocale.h>` `LC_ALL_MASK` (all six category bits). The
/// macro itself is not imported into Swift, but its value is stable ABI.
private let lcAllMask: Int32 = LC_COLLATE_MASK | LC_CTYPE_MASK | LC_MESSAGES_MASK
    | LC_MONETARY_MASK | LC_NUMERIC_MASK | LC_TIME_MASK

/// A process-lifetime UTF-8 `locale_t`, created once from the first available
/// UTF-8 locale name. It is never mutated after creation, so it is safe to share
/// across threads and install with `uselocale` (hence `nonisolated(unsafe)`).
private nonisolated(unsafe) let utf8Locale: locale_t? = {
    for name in ["en_US.UTF-8", "UTF-8", "C.UTF-8"] {
        if let loc = name.withCString({ newlocale(lcAllMask, $0, nil) }) {
            return loc
        }
    }
    return nil
}()

/// Runs `body` with a UTF-8 locale installed on the calling thread, restoring the
/// previous thread locale afterwards.
///
/// libarchive converts entry names between their stored form and the multibyte /
/// UTF-8 representations using the *calling thread's* locale charset. Under a C /
/// POSIX locale the `_utf8` getters fail and the plain getters mojibake non-ASCII
/// names. `uselocale` is per-thread, so this scopes the UTF-8 charset to the
/// reader/writer executor thread for the duration and never touches the process
/// locale or any other thread.
func withUTF8Locale<T>(_ body: () throws -> T) rethrows -> T {
    guard let loc = utf8Locale else { return try body() }
    let previous = uselocale(loc)
    defer { if previous != nil { _ = uselocale(previous) } }
    return try body()
}

/// Decodes a libarchive name, preferring the UTF-8 getter and falling back to the
/// locale-charset getter only when the UTF-8 conversion is unavailable.
///
/// - Parameters:
///   - utf8: The `_utf8` getter result (already UTF-8 when non-nil).
///   - fallback: The plain getter result, evaluated only when `utf8` is nil.
/// - Returns: The decoded string, or `nil` when both getters are nil.
private func decodeName(
    _ utf8: UnsafePointer<CChar>?,
    _ fallback: @autoclosure () -> UnsafePointer<CChar>?
) -> String? {
    if let utf8 { return String(cString: utf8) }
    if let fallback = fallback() { return String(cString: fallback) }
    return nil
}

// MARK: - Error text

/// Reads `archive_error_string` off a handle, returning `""` when none is set.
///
/// Mirrors the proven helper in the test support layer. The returned `String`
/// copies the C buffer, so it does not alias libarchive's transient storage.
///
/// - Parameter handle: A read or write handle (may be nil).
/// - Returns: The handle's last error text, or `""` when no handle / no message.
func errorString(_ handle: OpaquePointer?) -> String {
    guard let cstr = archive_error_string(handle) else { return "" }
    return String(cString: cstr)
}

// MARK: - Entry encode (draft -> C entry)

/// Builds a fresh C `archive_entry` from a draft, applying pathname, size,
/// filetype, perm, mtime, and symlink target. Caller frees the entry.
///
/// Mirrors the value-driven encode in the test support layer, honoring the
/// setter / getter integer-width asymmetry: `archive_entry_set_filetype` takes
/// `unsigned int` so the raw `FileType.rawValue` (`UInt32`) is passed straight
/// through, while `archive_entry_set_perm` takes `mode_t` (`UInt16` on Apple).
///
/// - Parameter draft: The entry to encode.
/// - Returns: A new `archive_entry` pointer, or `nil` if allocation failed.
func makeCEntry(from draft: EntryDraft) -> OpaquePointer? {
    guard let entry = archive_entry_new() else { return nil }

    archive_entry_set_pathname(entry, draft.path)
    archive_entry_set_size(entry, draft.size)
    // Setter wants `unsigned int` (UInt32): FileType.rawValue is already shaped for it.
    archive_entry_set_filetype(entry, draft.fileType.rawValue)
    // Setter wants `mode_t` (UInt16 on Apple).
    archive_entry_set_perm(entry, draft.permissions)

    if let date = draft.modificationDate {
        let whole = date.timeIntervalSince1970
        // archive_entry_set_mtime takes (time_t, long): time_t is Int on 64-bit
        // Apple, the nanosecond argument is C `long`, imported as Int.
        let seconds = time_t(whole)
        let nanos = Int((whole - Double(seconds)) * 1_000_000_000)
        archive_entry_set_mtime(entry, seconds, nanos)
    }

    if draft.fileType == .symlink, let target = draft.symlinkTarget {
        archive_entry_set_symlink(entry, target)
    }

    if let userID = draft.userID {
        archive_entry_set_uid(entry, userID)
    }
    if let groupID = draft.groupID {
        archive_entry_set_gid(entry, groupID)
    }
    if let userName = draft.userName {
        archive_entry_set_uname(entry, userName)
    }
    if let groupName = draft.groupName {
        archive_entry_set_gname(entry, groupName)
    }

    if let accessDate = draft.accessDate {
        let (seconds, nanos) = archiveTimeComponents(accessDate)
        archive_entry_set_atime(entry, seconds, nanos)
    }
    if let statusChangeDate = draft.statusChangeDate {
        let (seconds, nanos) = archiveTimeComponents(statusChangeDate)
        archive_entry_set_ctime(entry, seconds, nanos)
    }
    if let creationDate = draft.creationDate {
        let (seconds, nanos) = archiveTimeComponents(creationDate)
        archive_entry_set_birthtime(entry, seconds, nanos)
    }

    if let hardlinkTarget = draft.hardlinkTarget {
        archive_entry_set_hardlink(entry, hardlinkTarget)
    }

    for attribute in draft.extendedAttributes {
        attribute.value.withUnsafeBytes { raw in
            archive_entry_xattr_add_entry(entry, attribute.name, raw.baseAddress, raw.count)
        }
    }

    if let macMetadata = draft.macMetadata {
        macMetadata.withUnsafeBytes { raw in
            archive_entry_copy_mac_metadata(entry, raw.baseAddress, raw.count)
        }
    }

    return entry
}

/// Splits a `Date` into the whole-seconds and nanosecond components libarchive's
/// time setters expect.
///
/// - Parameter date: The date to split.
/// - Returns: A tuple of `time_t` whole seconds and the residual nanoseconds as C `long` (`Int`).
private func archiveTimeComponents(_ date: Date) -> (seconds: time_t, nanoseconds: Int) {
    let whole = date.timeIntervalSince1970
    let seconds = time_t(whole)
    let nanoseconds = Int((whole - Double(seconds)) * 1_000_000_000)
    return (seconds, nanoseconds)
}

// MARK: - Entry decode (C entry -> snapshot)

/// Reads an immutable ``ArchiveEntry`` snapshot from a live C entry pointer.
///
/// Every field is copied out of libarchive's transient buffers before this
/// function returns, so the resulting value never aliases handle-owned storage
/// and is fully `Sendable`. The file type is decoded honoring the getter
/// asymmetry: `archive_entry_filetype()` returns `mode_t` (`UInt16`), which is
/// widened to `UInt32` for ``FileType/init(modeWord:)``.
///
/// - Parameter entry: A non-nil `archive_entry` from `archive_read_next_header`.
/// - Returns: A fully copied, Sendable snapshot.
func makeSnapshot(from entry: OpaquePointer?) -> ArchiveEntry {
    let path = decodeName(archive_entry_pathname_utf8(entry), archive_entry_pathname(entry)) ?? ""

    // Getter returns mode_t (UInt16 on Apple): widen to UInt32 for FileType.
    let typeWord = UInt32(archive_entry_filetype(entry))
    let fileType = FileType(modeWord: typeWord) ?? .regular

    let size = Int64(archive_entry_size(entry))
    // archive_entry_perm returns mode_t; keep only the low permission bits.
    let permissions = UInt16(archive_entry_perm(entry)) & 0o7777

    let modificationDate: Date?
    if archive_entry_mtime_is_set(entry) != 0 {
        let seconds = Double(archive_entry_mtime(entry))
        let nanos = Double(archive_entry_mtime_nsec(entry)) / 1_000_000_000
        modificationDate = Date(timeIntervalSince1970: seconds + nanos)
    } else {
        modificationDate = nil
    }

    let symlinkTarget = decodeName(archive_entry_symlink_utf8(entry), archive_entry_symlink(entry))
    let hardlinkTarget = decodeName(archive_entry_hardlink_utf8(entry), archive_entry_hardlink(entry))
    let isEncrypted = archive_entry_is_encrypted(entry) != 0

    let userID = archive_entry_uid_is_set(entry) != 0 ? Int64(archive_entry_uid(entry)) : nil
    let groupID = archive_entry_gid_is_set(entry) != 0 ? Int64(archive_entry_gid(entry)) : nil
    let userName = decodeName(archive_entry_uname_utf8(entry), archive_entry_uname(entry))
    let groupName = decodeName(archive_entry_gname_utf8(entry), archive_entry_gname(entry))

    let accessDate: Date?
    if archive_entry_atime_is_set(entry) != 0 {
        let seconds = Double(archive_entry_atime(entry))
        let nanos = Double(archive_entry_atime_nsec(entry)) / 1_000_000_000
        accessDate = Date(timeIntervalSince1970: seconds + nanos)
    } else {
        accessDate = nil
    }

    let statusChangeDate: Date?
    if archive_entry_ctime_is_set(entry) != 0 {
        let seconds = Double(archive_entry_ctime(entry))
        let nanos = Double(archive_entry_ctime_nsec(entry)) / 1_000_000_000
        statusChangeDate = Date(timeIntervalSince1970: seconds + nanos)
    } else {
        statusChangeDate = nil
    }

    let creationDate: Date?
    if archive_entry_birthtime_is_set(entry) != 0 {
        let seconds = Double(archive_entry_birthtime(entry))
        let nanos = Double(archive_entry_birthtime_nsec(entry)) / 1_000_000_000
        creationDate = Date(timeIntervalSince1970: seconds + nanos)
    } else {
        creationDate = nil
    }

    let extendedAttributes = readExtendedAttributes(from: entry)

    let macMetadata: [UInt8]?
    var macSize = 0
    if let macPointer = archive_entry_mac_metadata(entry, &macSize), macSize > 0 {
        macMetadata = Array(UnsafeRawBufferPointer(start: macPointer, count: macSize))
    } else {
        macMetadata = nil
    }

    return ArchiveEntry(
        path: path,
        fileType: fileType,
        size: size,
        permissions: permissions,
        modificationDate: modificationDate,
        symlinkTarget: fileType == .symlink ? symlinkTarget : nil,
        hardlinkTarget: hardlinkTarget,
        isEncrypted: isEncrypted,
        userID: userID,
        groupID: groupID,
        userName: userName,
        groupName: groupName,
        accessDate: accessDate,
        statusChangeDate: statusChangeDate,
        creationDate: creationDate,
        extendedAttributes: extendedAttributes,
        macMetadata: macMetadata
    )
}

/// Copies an entry's extended attributes out of libarchive's transient list into Sendable values.
///
/// Resets libarchive's internal xattr cursor (`archive_entry_xattr_reset`) and walks it with
/// `archive_entry_xattr_next`, copying each name and value blob so the result never aliases
/// handle-owned storage.
///
/// - Parameter entry: A live `archive_entry` pointer.
/// - Returns: The entry's extended attributes in libarchive's stored order.
private func readExtendedAttributes(from entry: OpaquePointer?) -> [ExtendedAttribute] {
    var attributes: [ExtendedAttribute] = []
    _ = archive_entry_xattr_reset(entry)

    var namePointer: UnsafePointer<CChar>?
    var valuePointer: UnsafeRawPointer?
    var size = 0

    while archive_entry_xattr_next(entry, &namePointer, &valuePointer, &size) == ARCHIVE_OK {
        guard let namePointer else { continue }
        let name = String(cString: namePointer)
        let value: [UInt8]
        if let valuePointer, size > 0 {
            value = Array(UnsafeRawBufferPointer(start: valuePointer, count: size))
        } else {
            value = []
        }
        attributes.append(ExtendedAttribute(name: name, value: value))
    }

    return attributes
}

/// Builds a fully-populated ``EntryDraft`` from a live read-disk entry, preserving the metadata
/// the value model supports.
///
/// Used by ``DiskArchiver`` so a traversed entry keeps its ownership, timestamps, hardlink
/// target, extended attributes, and mac metadata, rather than only path, type, permissions, and
/// modification time. POSIX ACLs and BSD file flags are not part of the value model, so they are
/// not carried.
///
/// - Parameters:
///   - entry: A live `archive_entry` populated by a read-disk traversal.
///   - path: The archive-relative path to record.
///   - bytes: The file payload bytes; empty for non-regular entries.
/// - Returns: A draft populated from the entry.
func makeDraft(from entry: OpaquePointer, path: String, bytes: [UInt8]) -> EntryDraft {
    let typeWord = UInt32(archive_entry_filetype(entry))
    let fileType = FileType(modeWord: typeWord) ?? .regular
    let permissions = UInt16(archive_entry_perm(entry)) & 0o7777

    func date(_ isSet: Int32, _ seconds: time_t, _ nanoseconds: Int) -> Date? {
        guard isSet != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }
    let modificationDate = date(archive_entry_mtime_is_set(entry), archive_entry_mtime(entry), archive_entry_mtime_nsec(entry))
    let accessDate = date(archive_entry_atime_is_set(entry), archive_entry_atime(entry), archive_entry_atime_nsec(entry))
    let statusChangeDate = date(archive_entry_ctime_is_set(entry), archive_entry_ctime(entry), archive_entry_ctime_nsec(entry))
    let creationDate = date(archive_entry_birthtime_is_set(entry), archive_entry_birthtime(entry), archive_entry_birthtime_nsec(entry))

    let symlinkTarget = decodeName(archive_entry_symlink_utf8(entry), archive_entry_symlink(entry))
    let hardlinkTarget = decodeName(archive_entry_hardlink_utf8(entry), archive_entry_hardlink(entry))
    let userID = archive_entry_uid_is_set(entry) != 0 ? Int64(archive_entry_uid(entry)) : nil
    let groupID = archive_entry_gid_is_set(entry) != 0 ? Int64(archive_entry_gid(entry)) : nil
    let userName = decodeName(archive_entry_uname_utf8(entry), archive_entry_uname(entry))
    let groupName = decodeName(archive_entry_gname_utf8(entry), archive_entry_gname(entry))
    let extendedAttributes = readExtendedAttributes(from: entry)

    var macMetadata: [UInt8]?
    var macSize = 0
    if let macPointer = archive_entry_mac_metadata(entry, &macSize), macSize > 0 {
        macMetadata = Array(UnsafeRawBufferPointer(start: macPointer, count: macSize))
    } else {
        macMetadata = nil
    }

    return EntryDraft(
        path: path,
        bytes: bytes,
        fileType: fileType,
        permissions: permissions,
        size: Int64(bytes.count),
        modificationDate: modificationDate,
        symlinkTarget: symlinkTarget,
        userID: userID,
        groupID: groupID,
        userName: userName,
        groupName: groupName,
        accessDate: accessDate,
        statusChangeDate: statusChangeDate,
        creationDate: creationDate,
        hardlinkTarget: hardlinkTarget,
        extendedAttributes: extendedAttributes,
        macMetadata: macMetadata
    )
}

// MARK: - Handle ownership

/// A non-Sendable owner for a single `struct archive *` handle.
///
/// The reader and writer actors store their handle inside one of these boxes
/// rather than in a bare `OpaquePointer?` stored property. This serves one
/// purpose: it moves the backstop free out of the actor's nonisolated `deinit`
/// (which cannot legally touch a non-Sendable `OpaquePointer?` stored property
/// under Swift 6 strict concurrency) and into the box's own `deinit`, which the
/// compiler accepts because the box is an ordinary class.
///
/// Safety invariant: the box is created by the actor, stored only as a `private`
/// actor field, and never escapes the actor. Every access to ``pointer`` and
/// every call to ``free()`` happens on the actor's serial executor, so the
/// pointer is touched by exactly one context at a time. The box's `deinit` runs
/// only when the actor (its sole owner) is itself deallocated, by which point no
/// actor method can be in flight, so the backstop free races with nothing.
final class HandleBox {
    /// The live handle, or `nil` once freed. Actor-confined.
    var pointer: OpaquePointer?

    /// The C free function for this handle (`archive_read_free` / `archive_write_free`).
    private let freeFunction: (OpaquePointer?) -> Int32

    /// Extra cleanup run after the handle is freed (for example deallocating the
    /// reader's stable source storage). Cleared after it runs so it fires once.
    private var extraCleanup: (() -> Void)?

    /// Creates a box owning `pointer`, to be released with `freeFunction`.
    /// - Parameters:
    ///   - pointer: The freshly allocated handle to own.
    ///   - freeFunction: The matching `archive_*_free` function.
    init(pointer: OpaquePointer?, freeFunction: @escaping (OpaquePointer?) -> Int32) {
        self.pointer = pointer
        self.freeFunction = freeFunction
    }

    /// Registers extra cleanup to run when the handle is freed.
    ///
    /// Used by ``ArchiveReader`` to deallocate the stable memory that backs
    /// `archive_read_open_memory`, which must outlive the handle and must be
    /// released on the same actor / deinit path as the handle.
    ///
    /// - Parameter cleanup: A closure run once, immediately after the handle is freed.
    func onFree(_ cleanup: @escaping () -> Void) {
        extraCleanup = cleanup
    }

    /// Frees the handle if it is still live, then runs any extra cleanup. Idempotent.
    ///
    /// Called by the actor's explicit close / finish path on the actor's executor.
    func free() {
        if let pointer {
            _ = freeFunction(pointer)
            self.pointer = nil
        }
        extraCleanup?()
        extraCleanup = nil
    }

    /// Backstop free: releases the handle when the owning actor is deallocated.
    deinit {
        free()
    }
}

// MARK: - In-memory write sink

/// An actor-confined growable byte sink that the write callbacks append into.
///
/// Held by ``ArchiveWriter`` and passed to `archive_write_open` as the
/// `client_data` backing the write/close trampolines. Only the writer actor's
/// executor thread touches it, so it never escapes as shared mutable state.
final class WriteBufferBox {
    /// The accumulated archive bytes.
    var bytes: [UInt8]

    init() {
        self.bytes = []
    }
}

/// The `archive_write_callback` trampoline that appends to a ``WriteBufferBox``.
///
/// libarchive invokes this synchronously on the writer actor's executor thread
/// for each block it flushes. The `clientData` pointer is the same
/// ``WriteBufferBox`` instance passed to `archive_write_open`; it is touched
/// only on that one serial thread, so no shared mutable state escapes. The
/// `buffer` / `length` describe one flushed block, which is copied into the box.
///
/// - Returns: The number of bytes consumed (always `length`), as `la_ssize_t`.
let writeBufferCallback: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeRawPointer?, Int) -> la_ssize_t = {
    _, clientData, buffer, length in
    guard let clientData, let buffer, length > 0 else { return 0 }
    let box = Unmanaged<WriteBufferBox>.fromOpaque(clientData).takeUnretainedValue()
    let raw = UnsafeRawBufferPointer(start: buffer, count: length)
    box.bytes.append(contentsOf: raw)
    return la_ssize_t(length)
}
