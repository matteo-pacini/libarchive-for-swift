import Foundation
import Testing
@testable import SwiftArchive

// MARK: - Temp directory helper

/// Creates a unique temporary directory and returns its URL, registering nothing for cleanup.
///
/// Callers are responsible for removing the directory, typically in a `defer`.
private func makeTempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("SwiftArchiveDiskTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Builds a small on-disk tree under `root`: two files and a subdirectory with one file.
///
/// - Parameter root: An existing directory to populate.
/// - Returns: A map of relative path to expected bytes for the regular files created.
@discardableResult
private func buildSampleTree(under root: URL) throws -> [String: [UInt8]] {
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)

    let files: [String: [UInt8]] = [
        "top.txt": Array("top-level".utf8),
        "data.bin": Array(0..<UInt8(64)).map { $0 &* 5 },
        "sub/nested.txt": Array("nested file".utf8)
    ]
    for (relative, bytes) in files {
        try Data(bytes).write(to: root.appendingPathComponent(relative))
    }
    return files
}

// MARK: - Extract to disk

@Suite("SwiftArchive extract to disk")
struct ExtractToDiskTests {

    @Test("extract writes files and directories to disk")
    func extractWritesFilesAndDirs() async throws {
        let entries: [EntryDraft] = [
            .file("hello.txt", text: "on disk"),
            .file("nested/data.bin", bytes: Array(0..<UInt8(32))),
            .directory("nested")
        ]
        let bytes = try await Archive.write(entries, format: .ustar)

        let destination = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        try await Archive.extract(.data(bytes), to: destination)

        let helloURL = destination.appendingPathComponent("hello.txt")
        let blobURL = destination.appendingPathComponent("nested/data.bin")
        #expect(FileManager.default.fileExists(atPath: helloURL.path))
        #expect(FileManager.default.fileExists(atPath: blobURL.path))

        let hello = try Data(contentsOf: helloURL)
        #expect([UInt8](hello) == Array("on disk".utf8))
        let blob = try Data(contentsOf: blobURL)
        #expect([UInt8](blob) == Array(0..<UInt8(32)))

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("nested").path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test("extract returns the number of entries written")
    func extractReturnsEntryCount() async throws {
        let entries: [EntryDraft] = [
            .file("a.txt", text: "a"),
            .file("b.txt", text: "b"),
            .directory("d")
        ]
        let bytes = try await Archive.write(entries, format: .ustar)

        let destination = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let count = try await Archive.extract(.data(bytes), to: destination)
        #expect(count == entries.count)
    }

    @Test("secure default rejects an absolute-path entry")
    func secureRejectsAbsolutePath() async throws {
        let entries = [EntryDraft.file("/etc/evil.txt", text: "pwn")]
        let bytes = try await Archive.write(entries, format: .ustar)

        let destination = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: ArchiveError.self) {
            try await Archive.extract(.data(bytes), to: destination)
        }
    }

    @Test("secure default rejects a dot-dot path-traversal entry")
    func secureRejectsDotDotTraversal() async throws {
        let entries = [EntryDraft.file("../escape.txt", text: "pwn")]
        let bytes = try await Archive.write(entries, format: .ustar)

        let destination = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: ArchiveError.self) {
            try await Archive.extract(.data(bytes), to: destination)
        }
        // The traversed file must not have escaped the destination's parent.
        let escaped = destination.deletingLastPathComponent().appendingPathComponent("escape.txt")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    @Test("opting into permissions restores mode bits")
    func optInPermissionsRestored() async throws {
        let entries = [EntryDraft.file("locked.txt", text: "secret", permissions: 0o600)]
        let bytes = try await Archive.write(entries, format: .ustar)

        let destination = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        try await Archive.extract(.data(bytes), to: destination, options: [.secure, .permissions])

        let fileURL = destination.appendingPathComponent("locked.txt")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.uint16Value & 0o777 == 0o600)
    }

    @Test("symlink entry is extracted as a symbolic link")
    func symlinkExtractedAsLink() async throws {
        let entries: [EntryDraft] = [
            .file("target.txt", text: "real"),
            .symlink("link.txt", target: "target.txt")
        ]
        let bytes = try await Archive.write(entries, format: .ustar)

        let destination = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        try await Archive.extract(.data(bytes), to: destination)

        let linkURL = destination.appendingPathComponent("link.txt")
        let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
        #expect(resolved == "target.txt")
    }

    @Test("extract honors cancellation", .timeLimit(.minutes(1)))
    func extractRespectsCancellation() async throws {
        // Many small entries give the cancellation check between entries a chance to fire.
        let entries = (0..<200).map { EntryDraft.file("file\($0).txt", text: "payload \($0)") }
        let bytes = try await Archive.write(entries, format: .ustar)

        let destination = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let task = Task {
            try await Archive.extract(.data(bytes), to: destination)
        }
        task.cancel()

        // The task either throws CancellationError or completes before the cancel landed; both
        // are acceptable. If it threw, it must be CancellationError, not an ArchiveError.
        do {
            _ = try await task.value
        } catch is CancellationError {
            // Expected when cancellation lands between entries.
        }
    }
}

// MARK: - Archive a directory

@Suite("SwiftArchive archive directory")
struct ArchiveDirectoryTests {

    @Test("archiving a folder round-trips through an in-memory archive")
    func archiveFolderRoundTrip() async throws {
        let source = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let expected = try buildSampleTree(under: source)

        let bytes = try await Archive.archive(directory: source, to: .memory, format: .ustar)
        #expect(!bytes.isEmpty)

        let recovered = try await Archive.read(from: .data(bytes))
        for (relative, content) in expected {
            let item = try #require(recovered.first { $0.entry.path == relative })
            #expect(item.entry.fileType == .regular)
            #expect(item.bytes == content)
        }
    }

    @Test("archive then extract reproduces the tree byte-for-byte")
    func archiveThenExtractRoundTrip() async throws {
        let source = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let expected = try buildSampleTree(under: source)

        let bytes = try await Archive.archive(directory: source, to: .memory, format: .ustar)

        let destination = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        try await Archive.extract(.data(bytes), to: destination)

        for (relative, content) in expected {
            let url = destination.appendingPathComponent(relative)
            let onDisk = try Data(contentsOf: url)
            #expect([UInt8](onDisk) == content)
        }
    }

    @Test("physical traversal stores a symlink as a link, not its target")
    func physicalTraversalStoresSymlink() async throws {
        let source = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }

        try Data(Array("real".utf8)).write(to: source.appendingPathComponent("target.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("link.txt").path,
            withDestinationPath: "target.txt"
        )

        let bytes = try await Archive.archive(directory: source, to: .memory, format: .ustar, followSymlinks: false)
        let recovered = try await Archive.read(from: .data(bytes))

        let link = try #require(recovered.first { $0.entry.path == "link.txt" })
        #expect(link.entry.fileType == .symlink)
        #expect(link.entry.symlinkTarget == "target.txt")
    }

    @Test("archiving to a file URL produces a readable archive on disk")
    func archiveToFileURL() async throws {
        let source = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        try buildSampleTree(under: source)

        let tarURL = try makeTempDirectory().appendingPathComponent("out.tar")
        defer { try? FileManager.default.removeItem(at: tarURL.deletingLastPathComponent()) }

        let result = try await Archive.archive(directory: source, to: .fileURL(tarURL), format: .ustar)
        #expect(result.isEmpty)
        #expect(FileManager.default.fileExists(atPath: tarURL.path))

        let recovered = try await Archive.read(from: .fileURL(tarURL))
        #expect(recovered.contains { $0.entry.path == "top.txt" })
    }

    @Test("archiving to memory returns bytes; archiving to file returns empty Data")
    func archiveDestinationReturnValue() async throws {
        let source = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        try buildSampleTree(under: source)

        let memoryBytes = try await Archive.archive(directory: source, to: .memory, format: .ustar)
        #expect(!memoryBytes.isEmpty)

        let tarURL = try makeTempDirectory().appendingPathComponent("out.tar")
        defer { try? FileManager.default.removeItem(at: tarURL.deletingLastPathComponent()) }
        let fileResult = try await Archive.archive(directory: source, to: .fileURL(tarURL), format: .ustar)
        #expect(fileResult.isEmpty)
    }
}
