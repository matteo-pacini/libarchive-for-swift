import Foundation
import Testing
@testable import SwiftArchive

// MARK: - Fixtures

/// Builds an encrypted zip in memory using the given `zip:encryption` mode,
/// returning `nil` if this libarchive build cannot produce that mode (so a
/// dependent test skips cleanly rather than failing the whole case).
///
/// The nil-skip path mirrors the existing `makeEncryptedZip` helper in
/// `SwiftArchiveTests.swift`: any throw, or an empty result, is treated as
/// "unsupported on this build".
private func encMakeEncryptedZip(
    mode: String,
    passphrase: String,
    path: String,
    payload: [UInt8]
) async throws -> [UInt8]? {
    do {
        let writer = try await ArchiveWriter(format: .zip, to: .memory)
        try await writer.setPassphrase(passphrase)
        try await writer.setOptions("zip:encryption=\(mode)")
        try await writer.append(.file(path, bytes: payload))
        let bytes = try await writer.finish()
        return bytes.isEmpty ? nil : Array(bytes)
    } catch {
        return nil
    }
}

/// Looks up a recovered entry by path.
private func encEntry(_ path: String, in results: [ArchiveReader.EntryWithData]) -> ArchiveReader.EntryWithData? {
    results.first { $0.entry.path == path }
}

// MARK: - Read-side per-entry encryption flag

@Suite("SwiftArchive encryption read-side flags")
struct ENCReadSideFlagTests {

    @Test("an encrypted aes256 zip entry reads back isEncrypted == true")
    func encryptedEntryFlagIsTrue() async throws {
        let payload = Array("flagged secret".utf8)
        guard let bytes = try await encMakeEncryptedZip(
            mode: "aes256", passphrase: "pw", path: "secret.txt", payload: payload
        ) else { return }

        let reader = try await ArchiveReader(reading: .bytes(bytes))
        try await reader.addPassphrase("pw")
        let recovered = try await reader.readAll()
        await reader.close()

        let entry = try #require(encEntry("secret.txt", in: recovered))
        #expect(entry.entry.isEncrypted)
    }

    @Test("a plain ustar entry reads back isEncrypted == false")
    func plainEntryFlagIsFalse() async throws {
        let bytes = try await Archive.write([.file("plain.txt", text: "no secrets")], format: .ustar)
        let recovered = try await Archive.read(from: .data(bytes))
        let entry = try #require(encEntry("plain.txt", in: recovered))
        #expect(!entry.entry.isEncrypted)
    }
}

// MARK: - Read-side passphrase behavior

@Suite("SwiftArchive encryption passphrases")
struct ENCPassphraseTests {

    @Test("reading an encrypted entry with no passphrase fails at readData")
    func noPassphraseFailsAtReadData() async throws {
        let payload = Array("undisclosed payload".utf8)
        guard let bytes = try await encMakeEncryptedZip(
            mode: "aes256", passphrase: "pw", path: "secret.txt", payload: payload
        ) else { return }

        // No addPassphrase call: libarchive cannot decrypt and must fail the
        // data read rather than return a silent empty payload.
        let reader = try await ArchiveReader(reading: .bytes(bytes))
        await #expect {
            _ = try await reader.readAll()
        } throws: { error in
            guard let archiveError = error as? ArchiveError,
                  case .readData(let path) = archiveError.stage else { return false }
            return path == "secret.txt" && !archiveError.status.isUsable
        }
        await reader.close()
    }

    @Test("multiple passphrases: libarchive tries each and decrypts with the matching one")
    func multiplePassphrasesTryEach() async throws {
        let payload = Array("the real contents".utf8)
        guard let bytes = try await encMakeEncryptedZip(
            mode: "aes256", passphrase: "right", path: "secret.txt", payload: payload
        ) else { return }

        let reader = try await ArchiveReader(reading: .bytes(bytes))
        // Wrong first, right second: recovery proves try-each, not last-wins
        // (a last-wins-or-fail-on-first implementation would never decrypt).
        try await reader.addPassphrase("wrong")
        try await reader.addPassphrase("right")
        let recovered = try await reader.readAll()
        await reader.close()

        let entry = try #require(encEntry("secret.txt", in: recovered))
        #expect(entry.bytes == payload)
    }

    @Test("addPassphrase rejects an empty string as a setOption error")
    func emptyPassphraseRejected() async throws {
        // libarchive's archive_read_add_passphrase rejects an empty passphrase;
        // the wrapper surfaces that as a setOption error (it does not add a
        // Swift-side empty check). No encryption codec is needed: any valid
        // archive gives a live read handle to reject against.
        let bytes = try await Archive.write([.file("a.txt", text: "plain")], format: .ustar)
        let reader = try await ArchiveReader(reading: .data(bytes))
        await #expect {
            try await reader.addPassphrase("")
        } throws: { error in
            guard let archiveError = error as? ArchiveError,
                  case .setOption = archiveError.stage else { return false }
            return true
        }
        await reader.close()
    }
}

// MARK: - hasEncryptedEntries on a plain encryption-capable format

@Suite("SwiftArchive encryption detection")
struct ENCDetectionTests {

    @Test("a plain zip reports hasEncryptedEntries == .no, not .unsupported")
    func plainZipReportsNo() async throws {
        // A zip with no encrypted entries must report .no — distinguishing
        // "format supports encryption, none present" from "no encryption
        // concept" (.unsupported), which a plain ustar would report.
        let bytes = try await Archive.write([.file("a.txt", text: "plain")], format: .zip)
        let reader = try await ArchiveReader(reading: .data(bytes))
        _ = try await reader.nextEntry()
        #expect(await reader.hasEncryptedEntries() == .no)
        await reader.close()
    }
}

// MARK: - EncryptedEntriesState value mapping

@Suite("SwiftArchive EncryptedEntriesState mapping")
struct ENCStateMappingTests {

    @Test("EncryptedEntriesState(rawValue:) maps libarchive sentinels", arguments: [
        (Int32(1), EncryptedEntriesState.yes),
        (Int32(99), .yes),
        (Int32(0), .no),
        (Int32(-1), .unknown),
        (Int32(-2), .unsupported),
        (Int32(-3), .unsupported),
    ])
    func rawValueMapping(_ raw: Int32, _ expected: EncryptedEntriesState) {
        #expect(EncryptedEntriesState(rawValue: raw) == expected)
    }
}

// MARK: - Writer encryption lifecycle

@Suite("SwiftArchive encryption writer lifecycle")
struct ENCWriterLifecycleTests {

    @Test("setPassphrase after finish() throws a fatal setOption error")
    func setPassphraseAfterFinishIsFatal() async throws {
        // Write-side encryption lifecycle: once finished, the handle is no
        // longer in the pre-open "new" state, so the passphrase setter hits
        // the guard and fails fatally. No encryption codec is needed.
        let writer = try await ArchiveWriter(format: .zip, to: .memory)
        _ = try await writer.finish()
        await #expect {
            try await writer.setPassphrase("pw")
        } throws: { error in
            guard let archiveError = error as? ArchiveError,
                  case .setOption = archiveError.stage else { return false }
            return archiveError.status == .fatal
        }
    }
}

// MARK: - Encrypted round-trip parity across zip encryption modes

@Suite("SwiftArchive encryption round-trip parity")
struct ENCRoundTripParityTests {

    /// One argument per zip encryption scheme. `pkware` is intentionally absent
    /// from the asserted set: it skips cleanly on this build via the nil-skip
    /// helper rather than encrypting, so asserting against it would have no
    /// teeth. `traditional` and `zipcrypt` are aliases for the same scheme on
    /// this build; both are exercised to pin the alias.
    @Test("each supported zip encryption mode encrypts and round-trips", arguments: [
        "aes256", "aes128", "zipcrypt", "traditional",
    ])
    func modeRoundTrips(_ mode: String) async throws {
        let passphrase = "round-trip key"
        let payload = Array("parity payload for \(mode)".utf8)
        guard let bytes = try await encMakeEncryptedZip(
            mode: mode, passphrase: passphrase, path: "secret.txt", payload: payload
        ) else {
            // This build does not support this encryption scheme; skip.
            return
        }

        let reader = try await ArchiveReader(reading: .bytes(bytes))
        try await reader.addPassphrase(passphrase)
        let recovered = try await reader.readAll()
        await reader.close()

        let entry = try #require(encEntry("secret.txt", in: recovered))
        #expect(entry.bytes == payload)
        #expect(entry.entry.isEncrypted)
    }
}
