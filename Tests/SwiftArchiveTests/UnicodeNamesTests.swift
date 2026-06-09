import Foundation
import Testing
@testable import SwiftArchive

// MARK: - Corpus

/// Non-ASCII entry names that must survive a write -> read round-trip unchanged.
/// Covers Latin diacritics, CJK, Greek, Cyrillic, an RTL script, a combining
/// mark sequence, a path with a separator, and an emoji.
private let unicodeNames: [String] = [
    "café.txt",
    "naïve/résumé.txt",
    "日本語.txt",
    "Ωμέγα.dat",
    "файл.txt",
    "مرحبا.txt",
    "Å-Ä-Ö.txt",
    "e\u{0301}-combining.txt",
    "emoji-📦.bin",
]

@Suite("Unicode entry names")
struct UnicodeNameTests {

    @Test("pax round-trip preserves non-ASCII pathnames", arguments: unicodeNames)
    func pathnameRoundTrip(_ name: String) async throws {
        let bytes = try await Archive.write([.file(name, text: "payload")], format: .pax)
        let recovered = try await Archive.read(from: .data(bytes))

        let item = try #require(recovered.first { $0.entry.path == name })
        #expect(item.entry.path == name)
        #expect(item.bytes == Array("payload".utf8))
    }

    @Test("zip round-trip preserves non-ASCII pathnames", arguments: unicodeNames)
    func zipPathnameRoundTrip(_ name: String) async throws {
        let bytes = try await Archive.write([.file(name, text: "payload")], format: .zip)
        let recovered = try await Archive.read(from: .data(bytes))

        let item = try #require(recovered.first { $0.entry.path == name })
        #expect(item.entry.path == name)
    }

    @Test("pax round-trip preserves a non-ASCII symlink target")
    func symlinkTargetRoundTrip() async throws {
        let link = "リンク.txt"
        let target = "目標/café.txt"

        let bytes = try await Archive.write([.symlink(link, target: target)], format: .pax)
        let recovered = try await Archive.read(from: .data(bytes))

        let item = try #require(recovered.first { $0.entry.path == link })
        #expect(item.entry.fileType == .symlink)
        #expect(item.entry.symlinkTarget == target)
    }
}
