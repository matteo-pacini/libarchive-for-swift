import Foundation
import Testing
@testable import SwiftArchive

// MARK: - Shared helpers (file-unique names)

/// A deterministic PRNG so multi-block payloads are reproducible without any
/// platform randomness. Local to this file to avoid cross-file symbol clashes.
private struct FFSplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Builds `count` pseudo-random bytes from a fixed seed.
private func ffPseudoRandom(count: Int, seed: UInt64) -> [UInt8] {
    var gen = FFSplitMix64(seed: seed)
    return (0..<count).map { _ in UInt8(truncatingIfNeeded: gen.next()) }
}

/// Looks up a recovered entry by path.
private func ffEntry(_ path: String, in results: [ArchiveReader.EntryWithData]) -> ArchiveReader.EntryWithData? {
    results.first { $0.entry.path == path }
}

// MARK: - Format matrix round-trips (ff-01)

/// Exercises the public ``Archive`` write/read path across container formats that
/// the existing high-level suite does not cover, including self-compressing 7-Zip.
@Suite("FormatFilter format matrix")
struct FFFormatMatrixTests {

    /// A format under test paired with a display label.
    struct FFFormatCase: Sendable, CustomTestStringConvertible {
        let label: String
        let format: ArchiveFormat
        var testDescription: String { label }
    }

    /// Formats whose public round-trip is not already covered elsewhere. All paths
    /// are short so the v7tar 100-character name cap is never hit. 7-Zip is
    /// self-compressing, so the default ``ArchiveFilter/none`` is correct.
    static let cases: [FFFormatCase] = [
        FFFormatCase(label: "gnutar", format: .gnutar),
        FFFormatCase(label: "v7tar", format: .v7tar),
        FFFormatCase(label: "cpioNewc", format: .cpioNewc),
        FFFormatCase(label: "cpioOdc", format: .cpioOdc),
        FFFormatCase(label: "sevenZip", format: .sevenZip)
    ]

    @Test("each format round-trips a file and a directory through the public actor path", arguments: cases)
    func formatRoundTrips(_ testCase: FFFormatCase) async throws {
        let payload = Array("format-matrix payload for \(testCase.label)".utf8)
        let inputs: [EntryDraft] = [
            .file("file.txt", bytes: payload),
            .directory("dir")
        ]

        let bytes = try await Archive.write(inputs, format: testCase.format)
        #expect(!bytes.isEmpty)

        let recovered = try await Archive.read(from: .data(bytes))

        let file = try #require(ffEntry("file.txt", in: recovered))
        #expect(file.entry.fileType == .regular)
        #expect(file.entry.size == Int64(payload.count))
        #expect(file.bytes == payload)
    }
}

// MARK: - named() resolution (ff-02, ff-03)

@Suite("FormatFilter named resolution")
struct FFNamedResolutionTests {

    /// A libarchive format name that resolves to a real write setter.
    static let formatNames = ["ustar", "gnutar", "cpio"]

    @Test("ArchiveFormat.named resolves a real container that reads back the inputs", arguments: formatNames)
    func namedFormatResolves(_ name: String) async throws {
        let payload = Array("named-format \(name)".utf8)
        let inputs: [EntryDraft] = [.file("f.txt", bytes: payload)]

        // A broken set_format_by_name plumbing surfaces as a .setFormat throw here.
        let bytes = try await Archive.write(inputs, format: .named(name))
        #expect(!bytes.isEmpty)

        let recovered = try await Archive.read(from: .data(bytes))
        let entry = try #require(ffEntry("f.txt", in: recovered))
        #expect(entry.bytes == payload)
    }

    @Test("ArchiveFilter.named gzip resolves the gzip codec (magic 0x1f 0x8b) and round-trips")
    func namedGzipFilterResolves() async throws {
        let payload = Array("named-filter gzip payload that repeats and repeats".utf8)
        let inputs: [EntryDraft] = [.file("g.txt", bytes: payload)]

        let bytes = try await Archive.write(inputs, format: .ustar, filter: .named("gzip"))
        // A no-op / garbage resolution would not emit the gzip magic bytes.
        #expect(bytes.first == 0x1f)
        #expect(bytes.dropFirst().first == 0x8b)

        let recovered = try await Archive.read(from: .data(bytes))
        let entry = try #require(ffEntry("g.txt", in: recovered))
        #expect(entry.bytes == payload)
    }

    @Test("ArchiveFilter.named zstd shrinks a compressible payload and round-trips")
    func namedZstdFilterResolves() async throws {
        let payload = [UInt8](repeating: 0x5A, count: 16 * 1024)
        let inputs: [EntryDraft] = [.file("z.bin", bytes: payload)]

        let bytes = try await Archive.write(inputs, format: .ustar, filter: .named("zstd"))
        #expect(!bytes.isEmpty)
        // Trivially compressible input must shrink far below raw size.
        #expect(bytes.count < payload.count)

        let recovered = try await Archive.read(from: .data(bytes))
        let entry = try #require(ffEntry("z.bin", in: recovered))
        #expect(entry.bytes == payload)
    }
}

// MARK: - Bogus named() errors (ff-04)

@Suite("FormatFilter bogus named errors")
struct FFBogusNamedTests {

    @Test("a bogus ArchiveFormat.named throws a typed .setFormat error on construction")
    func bogusFormatThrows() async throws {
        await #expect {
            // The throw happens inside the writer's async init (configure applies the
            // format first), so the failure is observable on construction.
            let writer = try await ArchiveWriter(format: .named("definitely-not-a-format"), to: .memory)
            _ = try await writer.finish()
        } throws: { error in
            guard let archiveError = error as? ArchiveError,
                  case .setFormat(let name) = archiveError.stage else { return false }
            return name == "definitely-not-a-format" && !archiveError.status.isUsable
        }
    }

    @Test("a bogus ArchiveFilter.named (paired with a valid format) throws a typed .addFilter error")
    func bogusFilterThrows() async throws {
        await #expect {
            // Valid format so the format step succeeds and the throw is attributable
            // to the filter step.
            let writer = try await ArchiveWriter(format: .ustar, filter: .named("definitely-not-a-filter"), to: .memory)
            _ = try await writer.finish()
        } throws: { error in
            guard let archiveError = error as? ArchiveError,
                  case .addFilter(let name) = archiveError.stage else { return false }
            return name == "definitely-not-a-filter" && !archiveError.status.isUsable
        }
    }
}

// MARK: - Read auto-detection across sources (ff-05)

@Suite("FormatFilter read source independence")
struct FFReadSourceIndependenceTests {

    @Test("pax+xz auto-detects identically across .bytes, .data, and .fileURL")
    func autoDetectAcrossSources() async throws {
        // A multi-entry payload large enough that the compressed archive spans more
        // than one 64 KiB read block, so the .fileURL streaming reader genuinely
        // crosses block boundaries rather than loading a single block.
        let inputs: [EntryDraft] = [
            .file("a.bin", bytes: ffPseudoRandom(count: 256 * 1024, seed: 0xA11CE)),
            .file("b.bin", bytes: ffPseudoRandom(count: 256 * 1024, seed: 0xB0B))
        ]
        let archiveBytes = try await Archive.write(inputs, format: .pax, filter: .xz)
        #expect(!archiveBytes.isEmpty)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff-source-\(UUID().uuidString).tar.xz")
        defer { try? FileManager.default.removeItem(at: url) }
        try archiveBytes.write(to: url)

        let fromBytes = try await Archive.read(from: .bytes([UInt8](archiveBytes)))
        let fromData = try await Archive.read(from: .data(archiveBytes))
        let fromFile = try await Archive.read(from: .fileURL(url))

        #expect(!fromBytes.isEmpty)
        #expect(!fromData.isEmpty)
        #expect(!fromFile.isEmpty)

        // Recovered (path, size, bytes) must be pairwise identical across sources.
        #expect(fromBytes == fromData)
        #expect(fromData == fromFile)

        let a = try #require(ffEntry("a.bin", in: fromFile))
        #expect(a.bytes == inputs[0].bytes)
        let b = try #require(ffEntry("b.bin", in: fromFile))
        #expect(b.bytes == inputs[1].bytes)
    }
}

// MARK: - Text-encoding wrapper filters (ff-06)

@Suite("FormatFilter text-encoding wrappers")
struct FFTextWrapperTests {

    /// A text-wrapper filter case: the wrapper emits strictly 7-bit ASCII output.
    struct FFWrapperCase: Sendable, CustomTestStringConvertible {
        let label: String
        let filter: ArchiveFilter
        var testDescription: String { label }
    }

    static let cases: [FFWrapperCase] = [
        FFWrapperCase(label: "uuencode", filter: .uuencode),
        FFWrapperCase(label: "b64encode", filter: .b64encode)
    ]

    @Test("a text wrapper over ustar emits only ASCII and round-trips byte-exactly", arguments: cases)
    func textWrapperEmitsASCIIAndRoundTrips(_ testCase: FFWrapperCase) async throws {
        // A payload with high bytes so a raw tar/gzip stream would contain bytes
        // >= 0x80; the text wrapper must reduce everything below 0x80.
        let payload = ffPseudoRandom(count: 4 * 1024, seed: 0x7E47)
        let inputs: [EntryDraft] = [.file("t.bin", bytes: payload)]

        let bytes = try await Archive.write(inputs, format: .ustar, filter: testCase.filter)
        #expect(!bytes.isEmpty)
        // Every output byte is 7-bit ASCII: proves the text wrapper actually ran.
        #expect(bytes.allSatisfy { $0 < 0x80 })

        let recovered = try await Archive.read(from: .data(bytes))
        let entry = try #require(ffEntry("t.bin", in: recovered))
        #expect(entry.bytes == payload)
    }
}

// MARK: - Format x filter preservation matrix (ff-07)

@Suite("FormatFilter preservation matrix")
struct FFPreservationMatrixTests {

    /// A (format, filter) pair driven through the public reader/writer.
    struct FFPair: Sendable, CustomTestStringConvertible {
        let label: String
        let format: ArchiveFormat
        let filter: ArchiveFilter
        var testDescription: String { label }
    }

    static let pairs: [FFPair] = [
        FFPair(label: "cpioNewc+xz", format: .cpioNewc, filter: .xz),
        FFPair(label: "v7tar+lzip", format: .v7tar, filter: .lzip),
        FFPair(label: "ustar+lzma", format: .ustar, filter: .lzma),
        FFPair(label: "ustar+compress", format: .ustar, filter: .compress),
        FFPair(label: "gnutar+lz4", format: .gnutar, filter: .lz4),
        FFPair(label: "gnutar+bzip2", format: .gnutar, filter: .bzip2),
        FFPair(label: "ustar+lz4", format: .ustar, filter: .lz4)
    ]

    @Test("each format/filter pair preserves the entry through the public reader", arguments: pairs)
    func pairPreservesEntry(_ pair: FFPair) async throws {
        // Short path so the v7tar / ustar 100-char name cap is respected.
        let payload = Array("preservation payload for \(pair.label) ".utf8)
            + ffPseudoRandom(count: 2 * 1024, seed: 0xFEED)
        let inputs: [EntryDraft] = [.file("p.bin", bytes: payload)]

        let bytes = try await Archive.write(inputs, format: pair.format, filter: pair.filter)
        #expect(!bytes.isEmpty)

        let recovered = try await Archive.read(from: .data(bytes))
        let entry = try #require(ffEntry("p.bin", in: recovered))
        #expect(entry.entry.fileType == .regular)
        #expect(entry.bytes == payload)
    }
}

// MARK: - zip self-compresses vs ustar stores (ff-08)

@Suite("FormatFilter container compression contract")
struct FFContainerCompressionTests {

    /// A trivially compressible payload so deflate-vs-store is unambiguous.
    private static func compressiblePayload() -> [UInt8] {
        [UInt8](repeating: UInt8(ascii: "Q"), count: 8 * 1024)
    }

    @Test("zip with filter .none self-compresses below the raw payload")
    func zipSelfCompresses() async throws {
        let payload = Self.compressiblePayload()
        let bytes = try await Archive.write([.file("c.txt", bytes: payload)], format: .zip, filter: .none)
        #expect(!bytes.isEmpty)
        // zip's per-entry deflate shrinks the payload even with the external filter off.
        #expect(bytes.count < payload.count)

        let recovered = try await Archive.read(from: .data(bytes))
        let entry = try #require(ffEntry("c.txt", in: recovered))
        #expect(entry.bytes == payload)
    }

    @Test("ustar with filter .none stores verbatim (archive at least payload size) and round-trips")
    func ustarStoresVerbatim() async throws {
        let payload = Self.compressiblePayload()
        let bytes = try await Archive.write([.file("c.txt", bytes: payload)], format: .ustar, filter: .none)
        // ustar stores uncompressed, so the archive is no smaller than the payload.
        #expect(bytes.count >= payload.count)

        let recovered = try await Archive.read(from: .data(bytes))
        let entry = try #require(ffEntry("c.txt", in: recovered))
        #expect(entry.bytes == payload)
    }
}

// MARK: - Empty archive and zero-byte entries (ff-09)

@Suite("FormatFilter empty and zero-byte entries")
struct FFEmptyAndZeroByteTests {

    /// Filters that the zero-byte matrix runs against. zstd is safe in memory
    /// because the writer suppresses trailing-block padding.
    struct FFFilterCase: Sendable, CustomTestStringConvertible {
        let label: String
        let filter: ArchiveFilter
        var testDescription: String { label }
    }

    static let filters: [FFFilterCase] = [
        FFFilterCase(label: "none", filter: .none),
        FFFilterCase(label: "gzip", filter: .gzip),
        FFFilterCase(label: "zstd", filter: .zstd),
        FFFilterCase(label: "bzip2", filter: .bzip2),
        FFFilterCase(label: "xz", filter: .xz)
    ]

    @Test("an empty ustar archive is a valid container that reads back as no entries", arguments: filters)
    func emptyArchiveRoundTrips(_ testCase: FFFilterCase) async throws {
        // finish() opens the stream even with zero appends, so this is a valid container.
        let bytes = try await Archive.write([], format: .ustar, filter: testCase.filter)
        #expect(!bytes.isEmpty)

        let recovered = try await Archive.read(from: .data(bytes))
        #expect(recovered.isEmpty)
    }

    @Test("a zero-byte regular file round-trips as .regular with size 0 and empty payload", arguments: filters)
    func zeroByteEntryRoundTrips(_ testCase: FFFilterCase) async throws {
        let inputs: [EntryDraft] = [.file("empty.dat", bytes: [])]
        let bytes = try await Archive.write(inputs, format: .ustar, filter: testCase.filter)
        #expect(!bytes.isEmpty)

        let recovered = try await Archive.read(from: .data(bytes))
        let entry = try #require(ffEntry("empty.dat", in: recovered))
        #expect(entry.entry.fileType == .regular)
        #expect(entry.entry.size == 0)
        #expect(entry.bytes.isEmpty)
    }
}
