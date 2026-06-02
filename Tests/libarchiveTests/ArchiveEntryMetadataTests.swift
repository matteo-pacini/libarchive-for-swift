import Testing
import libarchive

// MARK: - Archive entry metadata round-trip
//
// These tests exercise the `archive_entry` object in isolation: create an
// entry with `archive_entry_new()`, set metadata via the `archive_entry_set_*`
// setters, and assert the matching getters return what we set. No archive is
// written or read — this is purely the in-memory entry struct.
//
// Bridging reminders baked into these tests (see TestSupport.swift for more):
//   * `archive_entry_new()` returns `OpaquePointer?`; the entry is OURS, so we
//     `archive_entry_free` it (via `defer`) on every path.
//   * filetype SETTER takes `unsigned int` (UInt32 = `FileType.rawValue`) but
//     the GETTER returns `mode_t` (UInt16 on Apple) — widen with `UInt32(...)`
//     before masking/comparing.
//   * `set_perm` / `set_mode` / `perm` / `mode` all use `mode_t` (UInt16).
//   * `set_size` wants `la_int64_t` (Int64); `size` returns `la_int64_t`.
//   * `set_uid`/`set_gid` take `la_int64_t`; getters return `la_int64_t`.
//   * `set_mtime` takes (`time_t` = Int, nsec `long` = Int); getters return
//     `time_t` and `long`.
//   * pathname / symlink / hardlink getters return `UnsafePointer<CChar>?` —
//     map the optional through `String(cString:)`.

@Suite("Archive entry metadata")
struct ArchiveEntryMetadataTests {

    // MARK: Pathname

    @Test("pathname round-trips an ASCII name")
    func pathnameASCII() throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        archive_entry_set_pathname(entry, "dir/sub/file.txt")

        let got = try #require(archive_entry_pathname(entry).map { String(cString: $0) })
        #expect(got == "dir/sub/file.txt")
    }

    @Test("pathname round-trips a Unicode name")
    func pathnameUnicode() throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        // Mixed scripts + emoji to prove UTF-8 survives the C round-trip.
        let name = "café/日本語/πλοῖον/data-📦.txt"
        archive_entry_set_pathname(entry, name)

        let got = try #require(archive_entry_pathname(entry).map { String(cString: $0) })
        #expect(got == name)
    }

    @Test("pathname can be overwritten")
    func pathnameOverwrite() throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        archive_entry_set_pathname(entry, "first.txt")
        archive_entry_set_pathname(entry, "second.txt")

        let got = try #require(archive_entry_pathname(entry).map { String(cString: $0) })
        #expect(got == "second.txt")
    }

    // MARK: Size

    @Test("size round-trips", arguments: [0, 1, 512, 4096, 1_048_576, Int(Int32.max) + 1])
    func sizeRoundTrips(_ value: Int) throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        archive_entry_set_size(entry, la_int64_t(value))

        #expect(archive_entry_size_is_set(entry) != 0)
        #expect(Int(archive_entry_size(entry)) == value)
    }

    // MARK: Filetype

    @Test("filetype round-trips for every FileType", arguments: FileType.allCases)
    func filetypeRoundTrips(_ type: FileType) throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        // SETTER: unsigned int -> UInt32 (FileType.rawValue is already UInt32).
        archive_entry_set_filetype(entry, type.rawValue)

        // GETTER: mode_t -> UInt16 on Apple; widen before masking/comparing.
        let typeWord = UInt32(archive_entry_filetype(entry))
        #expect(typeWord & FileType.mask == type.rawValue)

        let recovered = try #require(FileType(modeWord: typeWord))
        #expect(recovered == type)
    }

    @Test("regular / directory / symlink filetypes are distinct and correct")
    func filetypeCoreThree() throws {
        for type in [FileType.regular, .directory, .symlink] {
            let entry = try #require(archive_entry_new())
            defer { archive_entry_free(entry) }

            archive_entry_set_filetype(entry, type.rawValue)
            let typeWord = UInt32(archive_entry_filetype(entry))
            #expect(FileType(modeWord: typeWord) == type)
        }
    }

    // MARK: Permissions / mode

    @Test("perm round-trips common permission bits",
          arguments: [0o000, 0o400, 0o600, 0o644, 0o664, 0o700, 0o755, 0o777, 0o4755] as [UInt16])
    func permRoundTrips(_ perm: UInt16) throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        archive_entry_set_perm(entry, perm)

        // `perm` masks off the file-type bits; compare against the permission
        // portion of what we set (07777 covers setuid/setgid/sticky + rwx).
        #expect(archive_entry_perm(entry) == (perm & 0o7777))
    }

    @Test("mode carries both file-type and permission bits")
    func modeCarriesTypeAndPerm() throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        let mode = UInt16(FileType.regular.rawValue) | 0o0644
        archive_entry_set_mode(entry, mode)

        #expect(archive_entry_mode(entry) == mode)
        #expect(archive_entry_perm(entry) == 0o0644)

        let typeWord = UInt32(archive_entry_filetype(entry))
        #expect(FileType(modeWord: typeWord) == .regular)
    }

    @Test("set_perm then set_filetype compose into the full mode")
    func permAndFiletypeCompose() throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        archive_entry_set_filetype(entry, FileType.directory.rawValue)
        archive_entry_set_perm(entry, 0o755)

        #expect(archive_entry_perm(entry) == 0o755)
        let typeWord = UInt32(archive_entry_filetype(entry))
        #expect(FileType(modeWord: typeWord) == .directory)
        #expect(archive_entry_mode(entry) == (UInt16(FileType.directory.rawValue) | 0o755))
    }

    // MARK: Mtime

    @Test("mtime round-trips seconds and nanoseconds",
          arguments: [(0, 0), (1, 0), (1_700_000_000, 123_456_789), (Int(Int32.max) + 1, 999_999_999)])
    func mtimeRoundTrips(_ pair: (sec: Int, nsec: Int)) throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        // set_mtime: (time_t = Int, long = Int)
        archive_entry_set_mtime(entry, pair.sec, pair.nsec)

        #expect(Int(archive_entry_mtime(entry)) == pair.sec)
        #expect(Int(archive_entry_mtime_nsec(entry)) == pair.nsec)
    }

    // MARK: UID / GID

    @Test("uid round-trips", arguments: [0, 1, 501, 65_534, Int64(Int32.max) + 1] as [Int64])
    func uidRoundTrips(_ uid: Int64) throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        archive_entry_set_uid(entry, la_int64_t(uid))
        #expect(archive_entry_uid(entry) == la_int64_t(uid))
    }

    @Test("gid round-trips", arguments: [0, 20, 1000, 65_534, Int64(Int32.max) + 1] as [Int64])
    func gidRoundTrips(_ gid: Int64) throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        archive_entry_set_gid(entry, la_int64_t(gid))
        #expect(archive_entry_gid(entry) == la_int64_t(gid))
    }

    @Test("uid and gid are independent")
    func uidGidIndependent() throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        archive_entry_set_uid(entry, 501)
        archive_entry_set_gid(entry, 20)

        #expect(archive_entry_uid(entry) == 501)
        #expect(archive_entry_gid(entry) == 20)
    }

    // MARK: Symlink

    @Test("symlink target round-trips")
    func symlinkTarget() throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        archive_entry_set_filetype(entry, FileType.symlink.rawValue)
        archive_entry_set_symlink(entry, "../target/path.txt")

        let typeWord = UInt32(archive_entry_filetype(entry))
        #expect(FileType(modeWord: typeWord) == .symlink)

        let target = try #require(archive_entry_symlink(entry).map { String(cString: $0) })
        #expect(target == "../target/path.txt")
    }

    @Test("symlink target round-trips a Unicode path")
    func symlinkTargetUnicode() throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        let target = "../データ/链接-🔗"
        archive_entry_set_filetype(entry, FileType.symlink.rawValue)
        archive_entry_set_symlink(entry, target)

        let got = try #require(archive_entry_symlink(entry).map { String(cString: $0) })
        #expect(got == target)
    }

    // MARK: Hardlink

    @Test("hardlink target round-trips")
    func hardlinkTarget() throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        archive_entry_set_pathname(entry, "alias.txt")
        archive_entry_set_hardlink(entry, "original.txt")

        let path = try #require(archive_entry_pathname(entry).map { String(cString: $0) })
        #expect(path == "alias.txt")

        let link = try #require(archive_entry_hardlink(entry).map { String(cString: $0) })
        #expect(link == "original.txt")
    }

    // MARK: Combined / full-entry round-trip

    @Test("a fully-populated entry preserves all of its metadata")
    func fullEntryRoundTrips() throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        let path = "var/log/café-📁/app.log"
        let size = 4096
        let perm: UInt16 = 0o640
        let mtimeSec = 1_700_000_000
        let mtimeNsec = 250_000_000
        let uid: la_int64_t = 501
        let gid: la_int64_t = 20

        archive_entry_set_pathname(entry, path)
        archive_entry_set_filetype(entry, FileType.regular.rawValue)
        archive_entry_set_size(entry, la_int64_t(size))
        archive_entry_set_perm(entry, perm)
        archive_entry_set_mtime(entry, mtimeSec, mtimeNsec)
        archive_entry_set_uid(entry, uid)
        archive_entry_set_gid(entry, gid)

        let gotPath = try #require(archive_entry_pathname(entry).map { String(cString: $0) })
        #expect(gotPath == path)
        #expect(Int(archive_entry_size(entry)) == size)
        #expect(archive_entry_perm(entry) == perm)
        #expect(FileType(modeWord: UInt32(archive_entry_filetype(entry))) == .regular)
        #expect(Int(archive_entry_mtime(entry)) == mtimeSec)
        #expect(Int(archive_entry_mtime_nsec(entry)) == mtimeNsec)
        #expect(archive_entry_uid(entry) == uid)
        #expect(archive_entry_gid(entry) == gid)
    }

    @Test("archive_entry_clear resets metadata for reuse")
    func clearResetsEntry() throws {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }

        archive_entry_set_pathname(entry, "first.txt")
        archive_entry_set_size(entry, 1234)
        archive_entry_set_uid(entry, 99)

        _ = archive_entry_clear(entry)

        // After clear, size is no longer "set" and numeric fields reset to 0.
        #expect(archive_entry_size_is_set(entry) == 0)
        #expect(archive_entry_uid(entry) == 0)
        #expect(archive_entry_size(entry) == 0)

        // The cleared entry is still usable for a fresh set of metadata.
        archive_entry_set_pathname(entry, "reused.txt")
        let got = try #require(archive_entry_pathname(entry).map { String(cString: $0) })
        #expect(got == "reused.txt")
    }
}
