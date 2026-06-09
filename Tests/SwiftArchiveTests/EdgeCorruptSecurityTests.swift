import Foundation
import Testing
@testable import SwiftArchive

// MARK: - File-local helpers (prefixed `ecs` to avoid cross-file collisions)

/// A tiny deterministic PRNG so payloads are reproducible without platform randomness.
///
/// Named uniquely for this file; `SwiftArchiveTests.swift` defines its own private
/// `SplitMix64`, and private types do not collide across files in the same target,
/// but the distinct name keeps intent local and unambiguous.
private struct ECSSplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Builds `count` bytes of pseudo-random, incompressible data from a fixed seed.
///
/// Incompressible content matters for the truncation tests: gzip output of random
/// bytes is roughly the same size as the input, so a fractional prefix genuinely
/// cuts the compressed stream mid-block instead of landing past a tiny payload.
private func ecsRandomBytes(count: Int, seed: UInt64) -> [UInt8] {
    var generator = ECSSplitMix64(seed: seed)
    return (0..<count).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
}

/// Returns the file-local error as an `ArchiveError`, or `nil` for any other error.
private func ecsArchiveError(_ error: any Error) -> ArchiveError? {
    error as? ArchiveError
}

/// Decodes classic uuencoded text (`begin <mode> <name>` ... `end`) into bytes.
///
/// The libarchive C test corpus ships fixtures in this format. The decoder is
/// deliberately small: it reads the body lines between `begin` and `end`, where the
/// first character of each line is the decoded byte count for that line and the
/// remaining characters are groups of four 6-bit values (offset by `0x20`, with a
/// backtick standing in for a space/zero). Returns `nil` if the text is not a
/// well-formed uuencoded block, so callers can skip cleanly.
private func ecsUUDecode(_ text: String) -> [UInt8]? {
    func sextet(_ scalar: UInt8) -> UInt8 { (scalar - 0x20) & 0x3F }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let beginIndex = lines.firstIndex(where: { $0.hasPrefix("begin ") }) else { return nil }

    var output: [UInt8] = []
    for line in lines[(beginIndex + 1)...] {
        if line.hasPrefix("end") { return output }
        let chars = Array(line.utf8)
        guard let first = chars.first else { continue }
        let lineLength = Int(sextet(first))
        if lineLength == 0 { continue }

        var decoded: [UInt8] = []
        var index = 1
        while index + 4 <= chars.count {
            let a = sextet(chars[index])
            let b = sextet(chars[index + 1])
            let c = sextet(chars[index + 2])
            let d = sextet(chars[index + 3])
            decoded.append((a << 2) | (b >> 4))
            decoded.append((b << 4) | (c >> 2))
            decoded.append((c << 6) | d)
            index += 4
        }
        guard lineLength <= decoded.count else { return nil }
        output.append(contentsOf: decoded.prefix(lineLength))
    }
    return nil // missing `end` terminator
}

/// The on-disk root of the bundled libarchive C test corpus.
///
/// These fixtures exist only when libarchive's sources have been cloned by the
/// build (`build/sources/...`), so the fixture-backed suite is gated with
/// `.enabled(if:)` on this directory existing and skips cleanly when the corpus
/// is absent (for example on a fresh checkout or CI). The path is derived from
/// `#filePath` so it is independent of where the repo is checked out.
private let ecsFixtureDirectory: String = {
    // <repo>/Tests/SwiftArchiveTests/EdgeCorruptSecurityTests.swift -> <repo>
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return repoRoot.appendingPathComponent("build/sources/libarchive/libarchive/test").path
}()

/// Loads and uudecodes a named `.uu` fixture, or returns `nil` if it is missing or
/// cannot be decoded.
private func ecsLoadUUFixture(_ name: String) -> [UInt8]? {
    let path = ecsFixtureDirectory + "/" + name
    guard FileManager.default.fileExists(atPath: path),
          let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return ecsUUDecode(text)
}

// MARK: - Truncated input

@Suite("Edge: truncated archives")
struct ECSTruncatedArchiveTests {

    /// A truncated compressed body must surface as a non-usable `ArchiveError`, never
    /// as a short or zeroed payload silently returned to the caller.
    ///
    /// libarchive bids the filter and format inside the open call and the reader
    /// defers open to the first read, so a cut compressed stream can fail at open,
    /// header, or data depending on where the cut lands; all three are accepted, but
    /// the load-bearing property is that the handle ends up non-usable and the
    /// entries are never handed back with truncated bytes.
    @Test("a truncated gzip body throws a non-usable ArchiveError, never short bytes")
    func truncatedGzipBodyThrows() async throws {
        let entries = [
            EntryDraft.file("a.bin", bytes: ecsRandomBytes(count: 8 * 1024, seed: 0xA1)),
            EntryDraft.file("b.bin", bytes: ecsRandomBytes(count: 8 * 1024, seed: 0xB2)),
        ]
        let full = try await Archive.write(entries, format: .ustar, filter: .gzip)
        // Incompressible payload keeps the gzip output large, so a 40% prefix cuts
        // the compressed stream well inside its body.
        let cut = full.prefix(Int(Double(full.count) * 0.4))
        #expect(cut.count >= 64)

        await #expect {
            let reader = try await ArchiveReader(reading: .data(Data(cut)))
            defer { Task { await reader.close() } }
            _ = try await reader.readAll()
        } throws: { error in
            guard let archiveError = ecsArchiveError(error) else { return false }
            let acceptedStages: Bool
            switch archiveError.stage {
            case .open, .readHeader, .readData: acceptedStages = true
            default: acceptedStages = false
            }
            return acceptedStages && !archiveError.status.isUsable
        }
    }

    /// An uncompressed ustar archive cut mid-header must fail at open or header, with
    /// a non-usable status, rather than reporting a clean empty read.
    @Test("a header truncated mid-block fails at open or header, never a clean empty read")
    func truncatedHeaderThrows() async throws {
        // A 4 KiB body produces several tar blocks, so a small prefix is guaranteed
        // to land inside the first header/body region.
        let entries = [EntryDraft.file("only.bin", bytes: ecsRandomBytes(count: 4 * 1024, seed: 0xC3))]
        let full = try await Archive.write(entries, format: .ustar)
        #expect(full.count >= 600)
        let cut = full.prefix(300)

        await #expect {
            _ = try await Archive.read(from: .bytes(Array(cut)))
        } throws: { error in
            guard let archiveError = ecsArchiveError(error) else { return false }
            switch archiveError.stage {
            case .open, .readHeader: return !archiveError.status.isUsable
            default: return false
            }
        }
    }
}

// MARK: - Degenerate buffers

@Suite("Edge: empty and zero buffers")
struct ECSDegenerateBufferTests {

    /// Empty input is a valid empty archive through every public entry point: no
    /// throw, zero entries.
    @Test("empty input is a valid empty archive with zero entries", arguments: [ArchiveSource.bytes([]), .data(Data())])
    func emptyInputIsEmptyArchive(_ source: ArchiveSource) async throws {
        let entries = try await Archive.read(from: source)
        #expect(entries.isEmpty)
    }

    /// A streaming reader over empty bytes yields `nil` from its first `nextEntry()`.
    ///
    /// Only a single pull is performed: once a fresh reader returns nil at EOF, a
    /// second pull (whether `nextEntry()` again or via `readAll()`) re-enters
    /// `archive_read_next_header` in libarchive's "eof" state and aborts with a
    /// fatal internal error on this build. The `readAll()`-on-empty contract is
    /// covered by `emptyInputIsEmptyArchive`, which drives a single fresh reader.
    @Test("a reader over empty bytes yields no entries")
    func emptyReaderYieldsNothing() async throws {
        let reader = try await ArchiveReader(reading: .bytes([]))
        #expect(try await reader.nextEntry() == nil)
        await reader.close()
    }

    /// An all-zero 1 KiB buffer is the tar end-of-archive marker; it must not be read
    /// as a fabricated zero-named entry. Either an empty result or a thrown
    /// `ArchiveError` is acceptable, but no recovered entry may carry an empty path.
    @Test("an all-zero buffer yields no fabricated entry")
    func allZeroBufferYieldsNoEntry() async throws {
        let zeros = [UInt8](repeating: 0, count: 1024)
        do {
            let entries = try await Archive.read(from: .bytes(zeros))
            #expect(entries.isEmpty)
            #expect(!entries.contains { $0.entry.path.isEmpty })
        } catch let error as ArchiveError {
            // A thrown read error is equally acceptable; the load-bearing property is
            // that no phantom entry is invented.
            #expect(!error.status.isUsable)
        }
    }
}

// MARK: - Malformed real-world fixtures

@Suite(
    "Edge: malformed fixtures from the libarchive corpus",
    .enabled(if: FileManager.default.fileExists(atPath: ecsFixtureDirectory),
             "libarchive source corpus not present; skipping fixture-backed tests")
)
struct ECSMalformedFixtureTests {

    /// A tar whose pax header declares a corrupt entry size must be rejected as an
    /// `ArchiveError` (or recovered with bounded bytes), never over-read or crash.
    ///
    /// The matcher is disjunctive so it stays robust across libarchive versions: the
    /// failure may surface at the header or while draining data; either way the
    /// memory-safety property (no read longer than the archive, no crash) holds.
    @Test("a tar with a corrupt pax size is rejected, never over-read")
    func corruptPaxSizeIsBounded() async throws {
        let bytes = try #require(
            ecsLoadUUFixture("test_read_format_tar_invalid_pax_size.tar.uu"),
            "fixture corpus not present; skipping"
        )

        do {
            let recovered = try await Archive.read(from: .bytes(bytes))
            // Bounded-recovery branch: nothing may exceed the whole archive's size.
            for item in recovered {
                #expect(item.bytes.count <= bytes.count)
            }
        } catch let error as ArchiveError {
            #expect(!error.status.isUsable)
        }
    }

    /// A malformed zip fixture must be rejected as an `ArchiveError`, not partially
    /// trusted. libarchive bids a header but draining the entry's data throws.
    @Test("a malformed zip is rejected, never partially trusted")
    func malformedZipIsRejected() async throws {
        let bytes = try #require(
            ecsLoadUUFixture("test_read_format_zip_malformed1.zip.uu"),
            "fixture corpus not present; skipping"
        )

        do {
            let recovered = try await Archive.read(from: .bytes(bytes))
            for item in recovered {
                #expect(item.bytes.count <= bytes.count)
            }
        } catch let error as ArchiveError {
            #expect(!error.status.isUsable)
        }
    }
}

// MARK: - Single-byte corruption of compressed streams

@Suite("Edge: corrupted compressed streams")
struct ECSCorruptedStreamTests {

    /// Flipping one byte in the middle of a compressed stream must never be silently
    /// accepted as the original content.
    ///
    /// The behaviour legitimately differs by filter: some throw at open or while
    /// reading, while gzip's framing may decode to wrong bytes without an error. The
    /// disjunctive matcher gives both branches teeth: either an `ArchiveError` is
    /// thrown with a non-usable status, or `readAll()` succeeds but the recovered
    /// bytes differ from the original payload. Both prove corruption was detected or
    /// surfaced, never passed off as the real data.
    @Test(
        "a single corrupted byte is never silently accepted",
        arguments: [ArchiveFilter.gzip, .zstd, .xz]
    )
    func singleByteCorruptionDetected(_ filter: ArchiveFilter) async throws {
        let payload = ecsRandomBytes(count: 16 * 1024, seed: 0xD4)
        let full = try await Archive.write([.file("p.bin", bytes: payload)], format: .ustar, filter: filter)
        #expect(full.count >= 16)

        // Corrupt a byte at the archive midpoint, well past any filter header.
        var corrupted = [UInt8](full)
        let midpoint = corrupted.count / 2
        corrupted[midpoint] ^= 0xFF

        do {
            let recovered = try await Archive.read(from: .bytes(corrupted))
            // No throw: corruption must show up as wrong content, not silent success.
            let item = try #require(recovered.first { $0.entry.path == "p.bin" })
            #expect(item.bytes != payload)
        } catch let error as ArchiveError {
            #expect(!error.status.isUsable)
        }
    }
}

// MARK: - Reader lifetime guards

@Suite("Edge: reader use-after-close")
struct ECSReaderLifetimeTests {

    /// After `close()` every read entry point returns a defined empty result and a
    /// second `close()` is a no-op; none of them crash or throw.
    @Test("a closed reader returns defined empty results and tolerates double close")
    func closedReaderGuardsAreTotal() async throws {
        let bytes = try await Archive.write([.file("a.txt", text: "payload")], format: .ustar)
        let reader = try await ArchiveReader(reading: .data(bytes))

        // Drain one entry first so the reader has done real work before closing.
        _ = try await reader.nextEntry()
        await reader.close()

        // Double close is a no-op.
        await reader.close()

        #expect(try await reader.nextEntry() == nil)
        #expect(try await reader.readData().isEmpty)
        #expect(try await reader.readAllData().isEmpty)
        #expect(try await reader.readAll().isEmpty)
        // skipData must not throw on a closed reader.
        try await reader.skipData()
    }
}

// MARK: - Reader EOF latching

@Suite("Edge: reader EOF latching")
struct ECSReaderEOFTests {

    /// Pulling one past the terminating `nil` must keep returning `nil`, never
    /// re-enter libarchive. Before the reader latched EOF, this second pull
    /// re-called `archive_read_next_header` in its EOF state and aborted the
    /// process with a fatal libarchive "INTERNAL ERROR".
    @Test("nextEntry past the end of the archive stays nil")
    func pullingPastEOFStaysNil() async throws {
        let bytes = try await Archive.write(
            [.file("a.txt", text: "alpha"), .file("b.txt", text: "bravo")],
            format: .ustar
        )
        let reader = try await ArchiveReader(reading: .data(bytes))
        defer { Task { await reader.close() } }

        var count = 0
        while try await reader.nextEntry() != nil { count += 1 }
        #expect(count == 2)

        // One past EOF — and again — must both be nil, not a crash.
        #expect(try await reader.nextEntry() == nil)
        #expect(try await reader.nextEntry() == nil)
    }

    /// An empty archive reports EOF on the first pull; every later pull is also nil.
    @Test("nextEntry on an empty archive is nil on every call")
    func emptyArchiveStaysNil() async throws {
        let bytes = try await Archive.write([], format: .ustar)
        let reader = try await ArchiveReader(reading: .data(bytes))
        defer { Task { await reader.close() } }

        #expect(try await reader.nextEntry() == nil)
        #expect(try await reader.nextEntry() == nil)
    }

    /// `readAll()` after the stream was already drained to EOF must return empty
    /// rather than looping `nextEntry()` back into libarchive past EOF.
    @Test("readAll after a manual drain to EOF returns empty")
    func readAllAfterDrainIsEmpty() async throws {
        let bytes = try await Archive.write([.file("only.txt", text: "x")], format: .ustar)
        let reader = try await ArchiveReader(reading: .data(bytes))
        defer { Task { await reader.close() } }

        while try await reader.nextEntry() != nil { }
        #expect(try await reader.readAll().isEmpty)
    }
}

// MARK: - Encryption without a passphrase

@Suite("Edge: encrypted data without a passphrase")
struct ECSEncryptedNoPassphraseTests {

    /// Builds an AES-256 encrypted zip in memory, or returns `nil` if this libarchive
    /// build cannot produce encrypted zips, so dependent tests skip cleanly.
    private static func makeEncryptedZip(passphrase: String, payload: [UInt8]) async throws -> [UInt8]? {
        do {
            let writer = try await ArchiveWriter(format: .zip, to: .memory)
            try await writer.setPassphrase(passphrase)
            try await writer.setOptions("zip:encryption=aes256")
            try await writer.append(.file("secret.txt", bytes: payload))
            let bytes = try await writer.finish()
            return bytes.isEmpty ? nil : Array(bytes)
        } catch {
            return nil
        }
    }

    /// Reading an encrypted entry with no passphrase registered must surface the
    /// failure while draining data, not at open: the header is plaintext and bids
    /// fine, but the ciphertext is never silently returned.
    @Test("decrypting with no passphrase fails at readData, not at open")
    func noPassphraseFailsAtReadData() async throws {
        let payload = Array("top secret payload".utf8)
        guard let bytes = try await Self.makeEncryptedZip(passphrase: "pw", payload: payload) else {
            return // build cannot make encrypted zips; skip
        }

        let reader = try await ArchiveReader(reading: .bytes(bytes))
        let header = try await reader.nextEntry()
        #expect(header?.path == "secret.txt")
        #expect(await reader.hasEncryptedEntries() == .yes)

        await #expect {
            _ = try await reader.readAllData()
        } throws: { error in
            guard let archiveError = ecsArchiveError(error),
                  case .readData(let path) = archiveError.stage else { return false }
            return path == "secret.txt" && !archiveError.status.isUsable
        }
        await reader.close()
    }
}

// MARK: - Missing source

@Suite("Edge: non-existent source")
struct ECSMissingSourceTests {

    /// Reading a non-existent file URL must throw at the open stage with a non-usable
    /// status. `Archive.read` drives a read internally, which triggers the deferred
    /// open, so the failure surfaces there.
    @Test("a non-existent file URL throws at the open stage")
    func nonExistentFileURLThrowsAtOpen() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ecs-does-not-exist-\(UUID().uuidString).tar")
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        await #expect {
            _ = try await Archive.read(from: .fileURL(missing))
        } throws: { error in
            guard let archiveError = ecsArchiveError(error) else { return false }
            return archiveError.stage == .open && !archiveError.status.isUsable
        }
    }
}
