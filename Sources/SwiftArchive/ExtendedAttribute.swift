/// A single extended attribute attached to an archive entry, pairing a name with its raw bytes.
///
/// libarchive stores extended attributes as an ordered list of name/value pairs
/// (`archive_entry_xattr_add_entry`, `archive_entry_xattr_next`). The value is an
/// opaque byte blob, so it is exposed as `[UInt8]` rather than a decoded string.
///
/// ```swift
/// let xattr = ExtendedAttribute(name: "user.comment", value: Array("reviewed".utf8))
/// let draft = EntryDraft(path: "report.txt", bytes: payload, extendedAttributes: [xattr])
/// ```
public struct ExtendedAttribute: Sendable, Equatable {
    /// The attribute name, such as `"user.comment"` or `"com.apple.quarantine"`.
    public let name: String

    /// The attribute's raw value bytes.
    public let value: [UInt8]

    /// Creates an extended attribute from a name and its raw value bytes.
    /// - Parameters:
    ///   - name: The attribute name.
    ///   - value: The attribute's raw value bytes.
    public init(name: String, value: [UInt8]) {
        self.name = name
        self.value = value
    }
}
