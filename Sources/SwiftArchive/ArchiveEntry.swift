import Foundation

/// An immutable snapshot of one entry's metadata recovered while reading.
///
/// All fields are copied out of libarchive's transient buffers, so an
/// `ArchiveEntry` is fully `Sendable` and safe to hand to any isolation domain.
/// The entry's payload bytes are delivered separately by ``ArchiveReader`` (or
/// paired in ``ArchiveReader/EntryWithData``), so reading metadata never forces
/// a large payload into memory.
///
/// ```swift
/// switch entry.fileType {
/// case .regular:   print("file", entry.path, entry.size)
/// case .directory: print("dir", entry.path)
/// case .symlink:   print("link", entry.path, "->", entry.symlinkTarget ?? "?")
/// default:         print("other", entry.path)
/// }
/// ```
public struct ArchiveEntry: Sendable, Equatable {
    /// The entry's path within the archive (`archive_entry_pathname`).
    public let path: String
    /// The POSIX file type, decoded from `archive_entry_filetype()`.
    public let fileType: FileType
    /// The declared size from the header; may be 0 or unknown for some formats.
    public let size: Int64
    /// The POSIX permission bits (`archive_entry_perm`, low mode bits).
    public let permissions: UInt16
    /// The modification time, if the header set one; otherwise `nil`.
    public let modificationDate: Date?
    /// The symlink target, when ``fileType`` is ``FileType/symlink``; otherwise `nil`.
    public let symlinkTarget: String?
    /// The hardlink target, when the entry is a hardlink; otherwise `nil`.
    public let hardlinkTarget: String?
    /// A Boolean value that indicates whether libarchive flags the entry's data or metadata as encrypted.
    public let isEncrypted: Bool

    /// The numeric owner user ID, when the header set one; otherwise `nil`.
    public let userID: Int64?

    /// The numeric owner group ID, when the header set one; otherwise `nil`.
    public let groupID: Int64?

    /// The owner user name, when the header recorded one; otherwise `nil`.
    public let userName: String?

    /// The owner group name, when the header recorded one; otherwise `nil`.
    public let groupName: String?

    /// The last-access time, when the header set one; otherwise `nil`.
    public let accessDate: Date?

    /// The inode status-change time, when the header set one; otherwise `nil`.
    public let statusChangeDate: Date?

    /// The creation (birth) time, when the header set one; otherwise `nil`.
    public let creationDate: Date?

    /// The extended attributes recorded on the entry, in libarchive's stored order.
    public let extendedAttributes: [ExtendedAttribute]

    /// The Apple AppleDouble metadata blob (ACLs, extended attributes), when present; otherwise `nil`.
    public let macMetadata: [UInt8]?

    /// Memberwise initializer used by the engine layer to build a snapshot.
    init(
        path: String,
        fileType: FileType,
        size: Int64,
        permissions: UInt16,
        modificationDate: Date?,
        symlinkTarget: String?,
        hardlinkTarget: String?,
        isEncrypted: Bool,
        userID: Int64?,
        groupID: Int64?,
        userName: String?,
        groupName: String?,
        accessDate: Date?,
        statusChangeDate: Date?,
        creationDate: Date?,
        extendedAttributes: [ExtendedAttribute],
        macMetadata: [UInt8]?
    ) {
        self.path = path
        self.fileType = fileType
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
        self.symlinkTarget = symlinkTarget
        self.hardlinkTarget = hardlinkTarget
        self.isEncrypted = isEncrypted
        self.userID = userID
        self.groupID = groupID
        self.userName = userName
        self.groupName = groupName
        self.accessDate = accessDate
        self.statusChangeDate = statusChangeDate
        self.creationDate = creationDate
        self.extendedAttributes = extendedAttributes
        self.macMetadata = macMetadata
    }
}

/// A single entry to write into an archive, holding its path, metadata, and payload bytes.
///
/// You assemble an `EntryDraft` and append it to an ``ArchiveWriter``, or pass it
/// to the one-shot ``Archive`` helpers. `EntryDraft` is a mutable `Sendable` value
/// type.
///
/// ```swift
/// let entries = [
///     EntryDraft.file("hello.txt", text: "Hello, world!"),
///     EntryDraft.directory("logs"),
/// ]
/// ```
public struct EntryDraft: Sendable, Equatable {
    /// The entry path inside the archive.
    public var path: String
    /// The payload bytes; empty for directories and symlinks.
    public var bytes: [UInt8]
    /// The POSIX file type written via `archive_entry_set_filetype`.
    public var fileType: FileType
    /// The permission bits written via `archive_entry_set_perm`. Defaults to `0o644`.
    public var permissions: UInt16
    /// The declared size; defaults to `bytes.count`.
    public var size: Int64
    /// The optional modification time to record.
    public var modificationDate: Date?
    /// The symlink target; required when ``fileType`` is ``FileType/symlink``.
    public var symlinkTarget: String?
    /// The numeric owner user ID to record, or `nil` to leave it unset.
    public var userID: Int64?
    /// The numeric owner group ID to record, or `nil` to leave it unset.
    public var groupID: Int64?
    /// The owner user name to record, or `nil` to leave it unset.
    public var userName: String?
    /// The owner group name to record, or `nil` to leave it unset.
    public var groupName: String?
    /// The last-access time to record, or `nil` to leave it unset.
    public var accessDate: Date?
    /// The inode status-change time to record, or `nil` to leave it unset.
    public var statusChangeDate: Date?
    /// The creation (birth) time to record, or `nil` to leave it unset.
    public var creationDate: Date?
    /// The hardlink target to record; set this to write a hardlink entry.
    public var hardlinkTarget: String?
    /// The extended attributes to attach to the entry.
    public var extendedAttributes: [ExtendedAttribute]
    /// The Apple AppleDouble metadata blob to record, or `nil` for none.
    public var macMetadata: [UInt8]?

    /// Creates a draft, defaulting `size` to `bytes.count` and `permissions` to `0o644`.
    /// - Parameters:
    ///   - path: The entry path inside the archive.
    ///   - bytes: The payload bytes; empty for directories and symlinks.
    ///   - fileType: The POSIX file type. Defaults to ``FileType/regular``.
    ///   - permissions: The POSIX permission bits. Defaults to `0o644`.
    ///   - size: The declared size. Defaults to `bytes.count` when `nil`.
    ///   - modificationDate: The optional modification time to record.
    ///   - symlinkTarget: The symlink target; required when `fileType` is ``FileType/symlink``.
    ///   - userID: The numeric owner user ID to record, or `nil` to leave it unset.
    ///   - groupID: The numeric owner group ID to record, or `nil` to leave it unset.
    ///   - userName: The owner user name to record, or `nil` to leave it unset.
    ///   - groupName: The owner group name to record, or `nil` to leave it unset.
    ///   - accessDate: The last-access time to record, or `nil` to leave it unset.
    ///   - statusChangeDate: The inode status-change time to record, or `nil` to leave it unset.
    ///   - creationDate: The creation (birth) time to record, or `nil` to leave it unset.
    ///   - hardlinkTarget: The hardlink target to record, or `nil` for none.
    ///   - extendedAttributes: The extended attributes to attach to the entry.
    ///   - macMetadata: The Apple AppleDouble metadata blob to record, or `nil` for none.
    public init(
        path: String,
        bytes: [UInt8] = [],
        fileType: FileType = .regular,
        permissions: UInt16 = 0o644,
        size: Int64? = nil,
        modificationDate: Date? = nil,
        symlinkTarget: String? = nil,
        userID: Int64? = nil,
        groupID: Int64? = nil,
        userName: String? = nil,
        groupName: String? = nil,
        accessDate: Date? = nil,
        statusChangeDate: Date? = nil,
        creationDate: Date? = nil,
        hardlinkTarget: String? = nil,
        extendedAttributes: [ExtendedAttribute] = [],
        macMetadata: [UInt8]? = nil
    ) {
        self.path = path
        self.bytes = bytes
        self.fileType = fileType
        self.permissions = permissions
        self.size = size ?? Int64(bytes.count)
        self.modificationDate = modificationDate
        self.symlinkTarget = symlinkTarget
        self.userID = userID
        self.groupID = groupID
        self.userName = userName
        self.groupName = groupName
        self.accessDate = accessDate
        self.statusChangeDate = statusChangeDate
        self.creationDate = creationDate
        self.hardlinkTarget = hardlinkTarget
        self.extendedAttributes = extendedAttributes
        self.macMetadata = macMetadata
    }

    /// Creates a regular-file draft from a UTF-8 string payload.
    /// - Parameters:
    ///   - path: The entry path.
    ///   - text: The contents, encoded as UTF-8.
    ///   - permissions: The permission bits (defaults to `0o644`).
    public static func file(_ path: String, text: String, permissions: UInt16 = 0o644) -> EntryDraft {
        EntryDraft(path: path, bytes: Array(text.utf8), fileType: .regular, permissions: permissions)
    }

    /// Creates a regular-file draft from raw bytes.
    /// - Parameters:
    ///   - path: The entry path.
    ///   - bytes: The contents.
    ///   - permissions: The permission bits (defaults to `0o644`).
    public static func file(_ path: String, bytes: [UInt8], permissions: UInt16 = 0o644) -> EntryDraft {
        EntryDraft(path: path, bytes: bytes, fileType: .regular, permissions: permissions)
    }

    /// Creates a directory draft with an empty payload.
    /// - Parameters:
    ///   - path: The directory path.
    ///   - permissions: The permission bits (defaults to `0o755`).
    public static func directory(_ path: String, permissions: UInt16 = 0o755) -> EntryDraft {
        EntryDraft(path: path, bytes: [], fileType: .directory, permissions: permissions, size: 0)
    }

    /// Creates a symbolic-link draft that points at the given target.
    /// - Parameters:
    ///   - path: The link path.
    ///   - target: The link target path.
    public static func symlink(_ path: String, target: String) -> EntryDraft {
        EntryDraft(path: path, bytes: [], fileType: .symlink, size: 0, symlinkTarget: target)
    }

    /// Creates a hardlink draft that points at an existing entry in the same archive.
    ///
    /// libarchive records a hardlink as a regular-type entry whose hardlink target
    /// names the entry it duplicates, so the draft keeps ``FileType/regular`` and
    /// carries an empty payload while setting ``hardlinkTarget``.
    ///
    /// ```swift
    /// let entries = [
    ///     EntryDraft.file("orig.txt", text: "shared"),
    ///     EntryDraft.hardlink("dup.txt", target: "orig.txt"),
    /// ]
    /// ```
    ///
    /// - Parameters:
    ///   - path: The link path.
    ///   - target: The path of the entry this hardlink refers to.
    /// - Returns: A draft describing the hardlink.
    public static func hardlink(_ path: String, target: String) -> EntryDraft {
        EntryDraft(path: path, bytes: [], fileType: .regular, size: 0, hardlinkTarget: target)
    }

    /// Returns a copy with the given permission bits; the original is unchanged.
    /// - Parameter permissions: The new permission bits.
    public func withPermissions(_ permissions: UInt16) -> EntryDraft {
        var copy = self
        copy.permissions = permissions
        return copy
    }
}
