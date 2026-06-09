import Foundation
import Testing

@testable import SwiftArchive

// MARK: - Metadata fidelity fixtures and helpers

/// Writes a single draft to a memory archive in the given format and reads the
/// matching entry's metadata back, draining payloads.
///
/// Used by the fidelity tests that only care about the recovered header, where
/// the payload is small enough that a full ``Archive/read(from:)`` drain is fine.
private func mfRoundTripEntry(
    _ draft: EntryDraft,
    format: ArchiveFormat,
    filter: ArchiveFilter = .none
) async throws -> ArchiveEntry {
    let bytes = try await Archive.write([draft], format: format, filter: filter)
    let recovered = try await Archive.read(from: .data(bytes))
    return try #require(recovered.first { $0.entry.path == draft.path }?.entry)
}

/// A small, deterministic set of distinct timestamps (whole seconds) used to
/// prove the three preserved time slots are not cross-wired.
private enum MFTimes {
    static let mtime = Date(timeIntervalSince1970: 1000)
    static let atime = Date(timeIntervalSince1970: 2000)
    static let ctime = Date(timeIntervalSince1970: 3000)
    static let btime = Date(timeIntervalSince1970: 4000)
}

// MARK: - MF: entry metadata round-trip fidelity

@Suite("Metadata fidelity round-trips")
struct MetadataFidelityTests {

    // MARK: MF-1 — distinct time slots, birthtime dropped by pax

    @Test("pax preserves distinct mtime/atime/ctime without cross-wiring and drops birthtime")
    func mfDistinctTimeSlotsThroughPax() async throws {
        let draft = EntryDraft(
            path: "times.txt",
            bytes: Array("payload".utf8),
            modificationDate: MFTimes.mtime,
            accessDate: MFTimes.atime,
            statusChangeDate: MFTimes.ctime,
            creationDate: MFTimes.btime
        )
        let entry = try await mfRoundTripEntry(draft, format: .pax)

        let m = try #require(entry.modificationDate)
        let a = try #require(entry.accessDate)
        let c = try #require(entry.statusChangeDate)

        // Each slot recovers within a second of its own distinct source.
        #expect(abs(m.timeIntervalSince(MFTimes.mtime)) < 1)
        #expect(abs(a.timeIntervalSince(MFTimes.atime)) < 1)
        #expect(abs(c.timeIntervalSince(MFTimes.ctime)) < 1)

        // Mutually distinct: no slot picked up another's value.
        #expect(abs(m.timeIntervalSince(a)) >= 1)
        #expect(abs(m.timeIntervalSince(c)) >= 1)
        #expect(abs(a.timeIntervalSince(c)) >= 1)

        // libarchive 3.8.7 pax does not preserve birthtime; lock that behavior.
        #expect(entry.creationDate == nil)
    }

    // MARK: MF-2 — sub-second mtime: pax keeps the fraction, ustar truncates

    @Test("pax preserves a sub-second mtime fraction that ustar truncates")
    func mfSubSecondMtimePaxVsUstar() async throws {
        // 0.5 s fraction is exactly representable, so neither double rounding nor
        // ULP noise should cost more than a tiny epsilon.
        let when = Date(timeIntervalSince1970: 1_700_000_000.5)
        let draft = EntryDraft(
            path: "frac.txt",
            bytes: Array("payload".utf8),
            modificationDate: when
        )

        let paxEntry = try await mfRoundTripEntry(draft, format: .pax)
        let paxDate = try #require(paxEntry.modificationDate)
        let paxFraction = paxDate.timeIntervalSince1970 - paxDate.timeIntervalSince1970.rounded(.down)
        // pax carries the nanosecond field, so the 0.5 fraction survives.
        #expect(abs(paxFraction - 0.5) < 0.1)

        let ustarEntry = try await mfRoundTripEntry(draft, format: .ustar)
        let ustarDate = try #require(ustarEntry.modificationDate)
        let ustarFraction = ustarDate.timeIntervalSince1970 - ustarDate.timeIntervalSince1970.rounded(.down)
        // ustar stores whole-second mtime only, so the fraction is gone.
        #expect(ustarFraction < 1e-3)
    }

    // MARK: MF-3 — large declared size survives a pax header without payload

    @Test("a >4 GiB declared size survives a pax header read via nextEntry without draining payload")
    func mfLargeDeclaredSizeThroughPax() async throws {
        let declared: Int64 = 5_368_709_120  // 5 GiB, beyond the ustar octal range
        // A one-byte payload is truncated against the declared size on write; the
        // pax header still records the full 5 GiB size.
        let draft = EntryDraft(path: "huge.bin", bytes: [0x42], size: declared)
        let bytes = try await Archive.write([draft], format: .pax)

        // Read only the header. Archive.read / readAllData would try to drain 5 GiB
        // of absent payload, so we must use the low-level pull and not drain.
        let reader = try await ArchiveReader(reading: .data(bytes))
        let entry = try #require(try await reader.nextEntry())
        await reader.close()

        #expect(entry.path == "huge.bin")
        #expect(entry.size == declared)
    }

    // MARK: MF-4 — Apple metadata blob round-trips through pax

    @Test("the macMetadata AppleDouble blob round-trips byte-identical through pax")
    func mfMacMetadataThroughPax() async throws {
        // A synthetic, non-empty blob; the exact bytes are irrelevant beyond being
        // recoverable verbatim. macMetadata is otherwise only ever read back nil,
        // so the equality check is the whole point of this test.
        let blob: [UInt8] = [0, 5, 22, 7] + Array("AppleDouble".utf8)
        let draft = EntryDraft(
            path: "resourced.txt",
            bytes: Array("payload".utf8),
            macMetadata: blob
        )
        let entry = try await mfRoundTripEntry(draft, format: .pax)
        #expect(entry.macMetadata == blob)
    }

    // MARK: MF-5 — format-vs-field preservation matrix

    /// One expected-preservation row of the format/field matrix.
    struct MFOwnerExpectation: Sendable, CustomTestStringConvertible {
        let format: ArchiveFormat
        let expectIDs: Bool
        let expectNames: Bool
        let expectAtime: Bool
        var testDescription: String { "format=\(format.name)" }
    }

    @Test(
        "owner ids/names and atime preservation follows each format's documented behavior",
        arguments: [
            // pax keeps everything, including the access time.
            MetadataFidelityTests.MFOwnerExpectation(format: .pax, expectIDs: true, expectNames: true, expectAtime: true),
            // ustar keeps ids and names but stores no access time.
            MetadataFidelityTests.MFOwnerExpectation(format: .ustar, expectIDs: true, expectNames: true, expectAtime: false),
            // zip keeps numeric ids and the access time but drops POSIX owner names.
            MetadataFidelityTests.MFOwnerExpectation(format: .zip, expectIDs: true, expectNames: false, expectAtime: true),
        ]
    )
    func mfOwnerFieldMatrix(_ expectation: MFOwnerExpectation) async throws {
        let draft = EntryDraft(
            path: "owned.txt",
            bytes: Array("payload".utf8),
            permissions: 0o640,
            userID: 501,
            groupID: 20,
            userName: "alice",
            groupName: "staff",
            accessDate: MFTimes.atime
        )
        let entry = try await mfRoundTripEntry(draft, format: expectation.format)

        if expectation.expectIDs {
            #expect(entry.userID == 501)
            #expect(entry.groupID == 20)
        }
        if expectation.expectNames {
            #expect(entry.userName == "alice")
            #expect(entry.groupName == "staff")
        } else {
            #expect(entry.userName == nil)
            #expect(entry.groupName == nil)
        }
        if expectation.expectAtime {
            let a = try #require(entry.accessDate)
            #expect(abs(a.timeIntervalSince(MFTimes.atime)) < 1)
        } else {
            #expect(entry.accessDate == nil)
        }
    }

    // MARK: MF-6 — non-regular special file types preserve type and permissions

    @Test(
        "fifo/character/block preserve fileType and 0o644 permissions through pax and gnutar",
        arguments: [FileType.fifo, .character, .block],
        [ArchiveFormat.pax, .gnutar]
    )
    func mfSpecialFileTypes(_ fileType: FileType, _ format: ArchiveFormat) async throws {
        let draft = EntryDraft(
            path: "special",
            bytes: [],
            fileType: fileType,
            permissions: 0o644,
            size: 0
        )
        let entry = try await mfRoundTripEntry(draft, format: format)
        #expect(entry.fileType == fileType)
        #expect(entry.permissions & 0o777 == 0o644)
    }

    // MARK: MF-7 — extended attributes: binary and empty values survive through pax

    @Test("binary and empty extended-attribute values survive verbatim through pax")
    func mfExtendedAttributeValuesThroughPax() async throws {
        // libarchive pax emits each xattr under both SCHILY.xattr and
        // LIBARCHIVE.xattr, so a written attribute reads back as duplicate entries.
        // Assert per-name presence of the exact bytes rather than count or order.
        let binaryValue: [UInt8] = [0x00, 0xFF, 0x41]
        let emptyValue: [UInt8] = []
        let plainValue: [UInt8] = Array("plain".utf8)
        let draft = EntryDraft(
            path: "tagged.txt",
            bytes: Array("payload".utf8),
            extendedAttributes: [
                ExtendedAttribute(name: "user.binary", value: binaryValue),
                ExtendedAttribute(name: "user.empty", value: emptyValue),
                ExtendedAttribute(name: "user.plain", value: plainValue),
            ]
        )
        let entry = try await mfRoundTripEntry(draft, format: .pax)

        func value(forName name: String) -> [UInt8]? {
            entry.extendedAttributes.first { $0.name == name }?.value
        }

        // The NUL/0xFF-bearing value must survive byte-for-byte.
        #expect(value(forName: "user.binary") == binaryValue)
        // The empty value must be present-with-empty, not dropped.
        let empty = try #require(entry.extendedAttributes.first { $0.name == "user.empty" })
        #expect(empty.value.isEmpty)
        #expect(value(forName: "user.plain") == plainValue)
    }

    // MARK: MF-8 — symlink preserves target, exact permissions, and mtime

    @Test("a symlink preserves its target, 0o755 permissions, and mtime through pax")
    func mfSymlinkFidelityThroughPax() async throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        var link = EntryDraft.symlink("link", target: "real/target.txt")
        link.permissions = 0o755
        link.modificationDate = when

        let entry = try await mfRoundTripEntry(link, format: .pax)
        #expect(entry.fileType == .symlink)
        #expect(entry.symlinkTarget == "real/target.txt")
        // pax records the symlink's perm verbatim; it is not normalized to 0o777.
        #expect(entry.permissions & 0o777 == 0o755)
        let m = try #require(entry.modificationDate)
        #expect(abs(m.timeIntervalSince(when)) < 1)
    }

    @Test("symlinkTarget is nil for a non-symlink entry alongside a symlink")
    func mfSymlinkTargetNilForRegular() async throws {
        let entries: [EntryDraft] = [
            .file("real.txt", text: "contents"),
            .symlink("link", target: "real.txt"),
        ]
        let bytes = try await Archive.write(entries, format: .pax)
        let recovered = try await Archive.read(from: .data(bytes))

        let regular = try #require(recovered.first { $0.entry.path == "real.txt" }?.entry)
        #expect(regular.fileType == .regular)
        #expect(regular.symlinkTarget == nil)

        let link = try #require(recovered.first { $0.entry.path == "link" }?.entry)
        #expect(link.symlinkTarget == "real.txt")
    }
}
