import Testing
import libarchive

/// INTEGRATION tests for libarchive's compression *filters*.
///
/// Every filter classified `readBack: "yes"` in the support matrix is exercised
/// by writing a known payload through it into an in-memory archive and reading
/// it back via the auto-detecting reader (`*_support_format_all` /
/// `*_support_filter_all`, used by `readArchive`). All work is in-memory; there
/// is no filesystem access.
///
/// We deliberately pair the filters with the `ustar` format (a plain
/// `readBack: "full"` tar) so the test isolates the *filter* behaviour: the
/// container is trivial and well-understood, leaving the compression codec as
/// the variable under test. A handful of explicit format+filter combinations
/// drawn from `recommendedCombos` widen the coverage to other read-back-capable
/// formats, and a large deterministic payload proves true (de)compression
/// integrity rather than just trivial pass-through of tiny data.
@Suite("Compression filter integration")
struct CompressionFilterTests {

    // MARK: Filter matrix

    /// A `Sendable` wrapper so a filter can travel as a `@Test(arguments:)`
    /// value while still printing a readable case name in test output.
    struct FilterCase: Sendable, CustomStringConvertible {
        let name: String
        let filter: ArchiveFilter
        var description: String { name }
    }

    /// Every filter the support matrix marks `readBack: "yes"`. Each has a
    /// matching reader registered by `archive_read_support_filter_all`, so a
    /// generic auto-detecting read (as performed by `readArchive`) recovers the
    /// original bytes — including `uuencode` and `b64encode`, both handled by
    /// the shared uudecode reader.
    static let readBackFilters: [FilterCase] = [
        FilterCase(name: "none",      filter: .none),
        FilterCase(name: "gzip",      filter: .gzip),
        FilterCase(name: "bzip2",     filter: .bzip2),
        FilterCase(name: "xz",        filter: .xz),
        FilterCase(name: "lzma",      filter: .lzma),
        FilterCase(name: "lzip",      filter: .lzip),
        FilterCase(name: "zstd",      filter: .zstd),
        FilterCase(name: "lz4",       filter: .lz4),
        FilterCase(name: "compress",  filter: .compress),
        FilterCase(name: "uuencode",  filter: .uuencode),
        FilterCase(name: "b64encode", filter: .b64encode),
    ]

    // MARK: Deterministic payload generation

    /// A small, fixed pseudo-random-but-deterministic generator (xorshift64*).
    ///
    /// Used to fabricate payloads whose bytes are *not* trivially compressible
    /// (so a broken codec corrupting data is actually caught) yet are perfectly
    /// reproducible across runs (so a content mismatch is a real bug, not flake).
    struct DeterministicBytes {
        private var state: UInt64

        init(seed: UInt64) {
            // Avoid the zero fixed-point of xorshift.
            self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        }

        mutating func next() -> UInt64 {
            var x = state
            x ^= x >> 12
            x ^= x << 25
            x ^= x >> 27
            state = x
            return x &* 0x2545F4914F6CDD1D
        }

        mutating func bytes(count: Int) -> [UInt8] {
            var out = [UInt8]()
            out.reserveCapacity(count)
            while out.count < count {
                var word = next()
                for _ in 0..<8 where out.count < count {
                    out.append(UInt8(truncatingIfNeeded: word))
                    word >>= 8
                }
            }
            return out
        }
    }

    /// A representative, mixed payload: a chunk of compressible UTF-8 text and a
    /// chunk of high-entropy deterministic bytes. Exercises both the "shrinks"
    /// and "won't shrink" paths through each codec.
    static func mixedPayload(seed: UInt64) -> [UInt8] {
        var text = ""
        for i in 0..<256 {
            text += "line \(i): the quick brown fox jumps over the lazy dog\n"
        }
        var gen = DeterministicBytes(seed: seed)
        return Array(text.utf8) + gen.bytes(count: 4096)
    }

    // MARK: Parameterized round-trip over every read-back filter

    @Test(
        "ustar through each read-back filter round-trips a known payload",
        arguments: readBackFilters
    )
    func filterRoundTrip(_ f: FilterCase) throws {
        let payload = Self.mixedPayload(seed: 0xC0FFEE)
        let inputs = [
            ArchiveEntryData.file("text.txt", text: "filter under test: \(f.name)"),
            ArchiveEntryData.file("payload.bin", bytes: payload),
        ]

        let bytes = try writeArchive(format: .ustar, filter: f.filter, entries: inputs)
        #expect(!bytes.isEmpty, "filter \(f.name) produced an empty archive")

        let recovered = try readArchive(bytes)

        // Spot-check the high-entropy entry explicitly so a partial/garbled
        // decode is caught with a precise message, then verify the whole set.
        let bin = try #require(
            recovered.first { $0.path == "payload.bin" },
            "filter \(f.name): payload.bin was not recovered"
        )
        #expect(bin.bytes == payload, "filter \(f.name): payload.bin content mismatch")
        #expect(bin.bytes.count == payload.count, "filter \(f.name): payload.bin length mismatch")

        expectRoundTrip(inputs, recovered: recovered)
    }

    // MARK: Explicit format + filter combinations

    /// A `Sendable` wrapper carrying a named format+filter pair from the
    /// support matrix's `recommendedCombos`.
    struct ComboCase: Sendable, CustomStringConvertible {
        let name: String
        let format: ArchiveFormat
        let filter: ArchiveFilter
        var description: String { name }
    }

    /// Explicit combos drawn from `recommendedCombos`, restricted to the
    /// format/filter members the shared `TestSupport` helpers actually expose.
    /// Each pairs a `readBack: "full"` format with a `readBack: "yes"` filter.
    static let combos: [ComboCase] = [
        ComboCase(name: "pax + zstd",            format: .pax,           filter: .zstd),
        ComboCase(name: "pax + xz",              format: .pax,           filter: .xz),
        ComboCase(name: "pax_restricted + bzip2",format: .paxRestricted, filter: .bzip2),
        ComboCase(name: "gnutar + lz4",          format: .gnutar,        filter: .lz4),
        ComboCase(name: "v7tar + lzip",          format: .v7tar,         filter: .lzip),
        ComboCase(name: "cpio_newc + xz",        format: .cpioNewc,      filter: .xz),
        ComboCase(name: "cpio_odc + gzip",       format: .cpioOdc,       filter: .gzip),
        ComboCase(name: "ustar + lzma",          format: .ustar,         filter: .lzma),
        ComboCase(name: "ustar + compress",      format: .ustar,         filter: .compress),
        ComboCase(name: "ustar + uuencode",      format: .ustar,         filter: .uuencode),
        ComboCase(name: "ustar + b64encode",     format: .ustar,         filter: .b64encode),
    ]

    @Test(
        "explicit format + filter combinations round-trip",
        arguments: combos
    )
    func comboRoundTrip(_ c: ComboCase) throws {
        // v7tar limits pathnames to 100 chars; keep names short across the board.
        let payload = Self.mixedPayload(seed: 0xBADC0DE)
        let inputs = [
            ArchiveEntryData.file("a.txt", text: "combo: \(c.name)"),
            ArchiveEntryData.file("b.bin", bytes: payload),
        ]

        let recovered = try roundTrip(format: c.format, filter: c.filter, entries: inputs)

        let b = try #require(
            recovered.first { $0.path == "b.bin" },
            "combo \(c.name): b.bin was not recovered"
        )
        #expect(b.bytes == payload, "combo \(c.name): b.bin content mismatch")

        expectRoundTrip(inputs, recovered: recovered)
    }

    // MARK: Large, high-entropy payload (true compression integrity)

    /// Drives a >1 MiB deterministic high-entropy payload through a real
    /// compression codec (zstd) and asserts byte-exact recovery. This proves
    /// the filter genuinely compresses and decompresses a non-trivial stream —
    /// not just that tiny inputs survive a pass-through. A deterministic seed
    /// keeps any failure reproducible.
    @Test("large high-entropy payload survives true compression (zstd)")
    func largePayloadZstd() throws {
        var gen = DeterministicBytes(seed: 0x1234_5678_9ABC_DEF0)
        let size = 1_500_000  // > 1 MiB
        let payload = gen.bytes(count: size)
        #expect(payload.count == size)

        let inputs = [ArchiveEntryData.file("big.bin", bytes: payload)]

        let archived = try writeArchive(format: .ustar, filter: .zstd, entries: inputs)
        let recovered = try readArchive(archived)

        let big = try #require(
            recovered.first { $0.path == "big.bin" },
            "big.bin was not recovered from the compressed archive"
        )
        #expect(big.bytes.count == size, "recovered length mismatch")
        #expect(big.bytes == payload, "large-payload content mismatch after zstd round-trip")
        #expect(big.size == size, "header-declared size mismatch")

        expectRoundTrip(inputs, recovered: recovered)
    }

    /// Same large-payload integrity check, but using a *compressible* payload
    /// (a repeated pattern) through gzip. Verifies the codec both shrinks the
    /// stream meaningfully and restores it byte-for-byte.
    @Test("large compressible payload shrinks and restores exactly (gzip)")
    func largePayloadGzipShrinks() throws {
        let unit = Array("the quick brown fox jumps over the lazy dog 0123456789\n".utf8)
        var payload = [UInt8]()
        payload.reserveCapacity(1_200_000)
        while payload.count < 1_200_000 {
            payload.append(contentsOf: unit)
        }
        let inputs = [ArchiveEntryData.file("repeat.txt", bytes: payload)]

        let archived = try writeArchive(format: .ustar, filter: .gzip, entries: inputs)

        // Highly repetitive data must compress well below the raw size; this
        // confirms gzip is actually doing work, not storing.
        #expect(archived.count < payload.count / 2,
                "gzip did not meaningfully compress a repetitive payload (\(archived.count) vs \(payload.count) bytes)")

        let recovered = try readArchive(archived)
        let got = try #require(recovered.first { $0.path == "repeat.txt" })
        #expect(got.bytes == payload, "repetitive payload content mismatch after gzip round-trip")

        expectRoundTrip(inputs, recovered: recovered)
    }
}
