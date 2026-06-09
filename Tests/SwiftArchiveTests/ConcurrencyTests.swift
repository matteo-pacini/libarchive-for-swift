import Foundation
import Testing
@testable import SwiftArchive

// MARK: - Shared deterministic helpers (unique to this file)

/// A tiny deterministic PRNG so large/varied payloads are reproducible without
/// pulling in platform randomness. Named to avoid colliding with the `SplitMix64`
/// in SwiftArchiveTests.swift.
private struct ConcRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }
    }
}

/// Builds a distinct deterministic payload for a given (id, size) pair.
private func concPayload(id: Int, size: Int) -> [UInt8] {
    var rng = ConcRNG(seed: 0xC0FFEE &+ UInt64(id))
    return rng.bytes(size)
}

/// A one-shot async gate: callers `await wait()`, and a single `open()` releases
/// every waiter. `wait()` does not throw on cancellation, so a task suspended on
/// the gate resumes normally once opened, letting a downstream
/// `Task.checkCancellation()` observe the cancelled state deterministically.
private actor ConcGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// A `Sendable` async byte source that yields a fixed prefix of chunks, then
/// blocks on a gate and keeps yielding until its consuming task is cancelled.
/// Used to drive `append(header:streamingFrom:)` to a chunk-boundary cancel.
private struct ConcCancellableChunks: AsyncSequence, Sendable {
    typealias Element = [UInt8]
    let prefix: [[UInt8]]
    let gate: ConcGate

    func makeAsyncIterator() -> Iterator { Iterator(prefix: prefix, gate: gate) }

    struct Iterator: AsyncIteratorProtocol {
        var prefix: [[UInt8]]
        let gate: ConcGate
        var index = 0
        var opened = false

        mutating func next() async throws -> [UInt8]? {
            if index < prefix.count {
                defer { index += 1 }
                return prefix[index]
            }
            // Exhausted the prefix: signal the test that the first chunks landed,
            // then spin yielding filler. The writer's per-chunk
            // `Task.checkCancellation()` ends this once the test cancels.
            if !opened {
                opened = true
                await gate.open()
            }
            await Task.yield()
            return [UInt8](repeating: 0xEE, count: 8)
        }
    }
}

// MARK: - conc-1: independent writer/reader pairs under contention

@Suite("Concurrency isolated actor pairs")
struct ConcIsolatedPairsTests {

    /// Each parallel task builds its OWN archive with a unique entry set and reads
    /// it back, asserting it recovers exactly its own paths and bytes. A leaked
    /// handle or shared buffer across actor instances would surface as wrong or
    /// foreign payloads.
    @Test("N independent writer+reader pairs each recover only their own payloads", .timeLimit(.minutes(1)))
    func independentPairsRecoverOwnPayloads() async throws {
        let pairCount = 24

        let results: [Int: [ArchiveReader.EntryWithData]] = try await withThrowingTaskGroup(
            of: (Int, [ArchiveReader.EntryWithData]).self
        ) { group in
            for id in 0..<pairCount {
                group.addTask {
                    let drafts: [EntryDraft] = [
                        .file("pair-\(id)/a.bin", bytes: concPayload(id: id, size: 700 + id)),
                        .file("pair-\(id)/b.bin", bytes: concPayload(id: id &+ 10_000, size: 300 + id)),
                    ]
                    let writer = try await ArchiveWriter(format: .ustar, to: .memory)
                    try await writer.append(contentsOf: drafts)
                    let bytes = try await writer.finish()

                    let reader = try await ArchiveReader(reading: .data(bytes))
                    let recovered = try await reader.readAll()
                    await reader.close()
                    return (id, recovered)
                }
            }
            var collected: [Int: [ArchiveReader.EntryWithData]] = [:]
            for try await (id, recovered) in group {
                collected[id] = recovered
            }
            return collected
        }

        #expect(results.count == pairCount)
        for id in 0..<pairCount {
            let recovered = try #require(results[id])
            let paths = Set(recovered.map(\.entry.path))
            #expect(paths == ["pair-\(id)/a.bin", "pair-\(id)/b.bin"])

            let a = try #require(recovered.first { $0.entry.path == "pair-\(id)/a.bin" })
            let b = try #require(recovered.first { $0.entry.path == "pair-\(id)/b.bin" })
            #expect(a.bytes == concPayload(id: id, size: 700 + id))
            #expect(b.bytes == concPayload(id: id &+ 10_000, size: 300 + id))
        }
    }
}

// MARK: - conc-11: concurrent one-shot Archive.read calls

@Suite("Concurrency one-shot reads")
struct ConcOneShotReadTests {

    /// Many `Archive.read` calls run concurrently over distinct prebuilt archives;
    /// each transient reader actor must return only its own entry. Cross-talk
    /// through shared global format/filter support state would surface as a wrong
    /// path or wrong bytes.
    @Test("concurrent Archive.read over distinct inputs return only their own entries", .timeLimit(.minutes(1)))
    func concurrentOneShotReadsAreIsolated() async throws {
        let count = 32

        // Prebuild distinct single-entry archives sequentially so the concurrent
        // phase only stresses the read path.
        var archives: [Int: Data] = [:]
        for id in 0..<count {
            let bytes = try await Archive.write(
                [.file("only-\(id).bin", bytes: concPayload(id: id, size: 256 + id))],
                format: .ustar
            )
            archives[id] = bytes
        }

        let recovered: [Int: [ArchiveReader.EntryWithData]] = try await withThrowingTaskGroup(
            of: (Int, [ArchiveReader.EntryWithData]).self
        ) { group in
            for id in 0..<count {
                let data = archives[id]!
                group.addTask {
                    (id, try await Archive.read(from: .data(data)))
                }
            }
            var collected: [Int: [ArchiveReader.EntryWithData]] = [:]
            for try await (id, entries) in group {
                collected[id] = entries
            }
            return collected
        }

        #expect(recovered.count == count)
        for id in 0..<count {
            let entries = try #require(recovered[id])
            #expect(entries.count == 1)
            let only = try #require(entries.first)
            #expect(only.entry.path == "only-\(id).bin")
            #expect(only.bytes == concPayload(id: id, size: 256 + id))
        }
    }
}

// MARK: - conc-2: ordered AsyncSequence iteration

@Suite("Concurrency ordered iteration")
struct ConcOrderedIterationTests {

    /// Iterating a many-entry archive must yield every entry exactly once, in
    /// archive (written) order, with correct payloads. Collecting into an ordered
    /// array (not a set) gives this teeth against drops, dups, and reordering.
    @Test("AsyncSequence iteration yields every entry once, in order, with correct bytes")
    func orderedIterationNoDropsNoDups() async throws {
        let count = 50
        let drafts = (0..<count).map { id in
            EntryDraft.file("entry-\(id).bin", bytes: concPayload(id: id, size: 64 + (id % 17)))
        }
        let bytes = try await Archive.write(drafts, format: .ustar)

        let reader = try await ArchiveReader(reading: .data(bytes))
        var orderedPaths: [String] = []
        var payloads: [String: [UInt8]] = [:]
        for try await item in reader {
            orderedPaths.append(item.entry.path)
            payloads[item.entry.path] = item.bytes
        }
        await reader.close()

        let expectedOrder = (0..<count).map { "entry-\($0).bin" }
        #expect(orderedPaths == expectedOrder)
        #expect(orderedPaths.count == count)
        // No duplicates: the set has the same cardinality as the ordered list.
        #expect(Set(orderedPaths).count == count)

        for id in 0..<count {
            #expect(payloads["entry-\(id).bin"] == concPayload(id: id, size: 64 + (id % 17)))
        }
    }
}

// MARK: - conc-3 (revised) + conc-4: dataStream slow consumer & cancellation

@Suite("Concurrency data stream")
struct ConcDataStreamTests {

    /// A 512 KiB entry, varied bytes, spanning many chunks.
    private static func bigPayload() -> [UInt8] {
        concPayload(id: 7, size: 512 * 1024)
    }

    /// conc-3 (revised): a slow consumer (Task.yield between chunks) loses no bytes
    /// and reassembles the entry byte-exact. The backpressure framing is dropped
    /// because `dataStream` uses an unbounded `AsyncThrowingStream`; this instead
    /// asserts fidelity under a yielding consumer.
    @Test("slow consumer reassembles a large entry byte-exact")
    func slowConsumerReassemblesExactly() async throws {
        let payload = Self.bigPayload()
        let bytes = try await Archive.write([.file("big.bin", bytes: payload)], format: .ustar)

        let reader = try await ArchiveReader(reading: .data(bytes))
        let header = try await reader.nextEntry()
        #expect(header?.path == "big.bin")

        var reassembled: [UInt8] = []
        for try await chunk in reader.dataStream(chunkSize: 16 * 1024) {
            reassembled.append(contentsOf: chunk)
            await Task.yield()
        }
        await reader.close()

        #expect(reassembled == payload)
    }

    /// conc-3 (revised, second teeth): break out of the stream early after K
    /// chunks, then `close()` the reader. This exercises the
    /// onTermination -> task.cancel() cleanup path on a partially-drained stream,
    /// distinguishing it from the fast full-drain test.
    @Test("breaking out of a dataStream early leaves the reader closable")
    func earlyBreakThenCloseSucceeds() async throws {
        let payload = Self.bigPayload()
        let bytes = try await Archive.write([.file("big.bin", bytes: payload)], format: .ustar)

        let reader = try await ArchiveReader(reading: .data(bytes))
        _ = try await reader.nextEntry()

        var chunksSeen = 0
        for try await _ in reader.dataStream(chunkSize: 16 * 1024) {
            chunksSeen += 1
            if chunksSeen >= 3 { break }
        }
        #expect(chunksSeen == 3)

        // close() must succeed on a partially-drained stream (no hang, no throw).
        await reader.close()
        // Idempotent close stays a no-op.
        await reader.close()
    }

    /// conc-4: cancelling the consuming task terminates the stream early without
    /// error and leaves the reader usable. Tolerance: collected byte count is in
    /// [0, fullSize] (one in-flight read may land), no error is thrown, and a
    /// subsequent close() succeeds. Cancellation is triggered by break-after-
    /// threshold inside a child task, not wall-clock.
    @Test("cancelling a dataStream consumer ends cleanly and leaves the reader usable", .timeLimit(.minutes(1)))
    func cancelledConsumerEndsCleanly() async throws {
        let payload = Self.bigPayload()
        let fullSize = payload.count
        let bytes = try await Archive.write([.file("big.bin", bytes: payload)], format: .ustar)

        let reader = try await ArchiveReader(reading: .data(bytes))
        _ = try await reader.nextEntry()

        // Run consumption in a child task and cancel it after a few chunks. The
        // task must NOT throw: a cancelled dataStream finishes (returns nil) rather
        // than throwing.
        let collectedCount: Int = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                var total = 0
                var seen = 0
                for try await chunk in reader.dataStream(chunkSize: 16 * 1024) {
                    total += chunk.count
                    seen += 1
                    if seen >= 2 {
                        // Cancel this very task; onTermination fires when the loop
                        // exits and the stream deinits.
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                return total
            }
            let value = try await group.next()!
            return value
        }

        #expect(collectedCount >= 0)
        #expect(collectedCount <= fullSize)

        // The reader is still usable: closing succeeds.
        await reader.close()
    }
}

// MARK: - conc-5: reader pull on a cancelled task never throws

@Suite("Concurrency reader cancellation contract")
struct ConcReaderCancelTests {

    /// The reader's documented contract is that a cancelled pull ends iteration by
    /// returning nil and NEVER throws CancellationError (opposite the writer). The
    /// assertion absorbs the checkpoint race: nextEntry returns nil OR a valid
    /// entry, but must never throw.
    @Test("nextEntry on an already-cancelled task returns cleanly and never throws", .timeLimit(.minutes(1)))
    func nextEntryOnCancelledTaskNeverThrows() async throws {
        let drafts = (0..<10).map { EntryDraft.file("f\($0).txt", text: "payload-\($0)") }
        let bytes = try await Archive.write(drafts, format: .ustar)
        let reader = try await ArchiveReader(reading: .data(bytes))

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // Cancel before the body runs so isCancelled is observed by the pull.
                withUnsafeCurrentTask { $0?.cancel() }
                // Must not throw; either nil (cancelled) or a valid entry (race).
                let entry = try? await reader.nextEntry()
                // try? swallows any throw; assert the cancelled-path contract by
                // confirming no CancellationError escaped via a strict probe below.
                _ = entry
            }
        }

        // Stronger, deterministic probe: run a pull inside a task we cancel up front
        // and assert it does not throw at all.
        let didThrow: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    _ = try await reader.nextEntry()
                    return false
                } catch {
                    return true
                }
            }
            return await group.next()!
        }
        #expect(didThrow == false)

        await reader.close()
    }
}

// MARK: - conc-6 (revised): writer.append throws CancellationError deterministically

@Suite("Concurrency writer cancellation contract")
struct ConcWriterCancelTests {

    /// conc-6 (revised): make the cancel deterministically precede append's first
    /// `Task.checkCancellation()`. The task awaits a gate (which does not throw on
    /// cancel) before calling append; the test cancels the task while it is parked
    /// on the gate, then opens the gate. append then resumes and its checkpoint is
    /// REQUIRED to throw CancellationError. The writer must remain finish()-able.
    @Test("append throws CancellationError when cancelled before its checkpoint", .timeLimit(.minutes(1)))
    func appendThrowsCancellationDeterministically() async throws {
        let writer = try await ArchiveWriter(format: .ustar, to: .memory)
        let gate = ConcGate()

        let task = Task {
            await gate.wait()
            try await writer.append(.file("late.txt", text: "never encoded"))
        }

        // Cancel while the task is parked on the gate, then release it so append
        // runs with the task already cancelled.
        task.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        // The writer is still usable after the cancelled append.
        try await writer.append(.file("ok.txt", text: "encoded"))
        let bytes = try await writer.finish()
        let recovered = try await Archive.read(from: .data(bytes))
        let paths = Set(recovered.map(\.entry.path))
        #expect(paths == ["ok.txt"])
    }
}

// MARK: - conc-7: streaming append propagates mid-stream cancellation

@Suite("Concurrency streaming append cancellation")
struct ConcStreamingAppendCancelTests {

    /// conc-7: the per-chunk `Task.checkCancellation()` inside the
    /// `append(header:streamingFrom:)` loop must propagate a cancellation thrown at
    /// a chunk boundary. A custom Sendable sequence yields a prefix, opens a gate,
    /// then spins; the test cancels at the chunk boundary via the gate (no sleeps),
    /// and the writer must remain finish()-able afterward.
    @Test("streaming append propagates a mid-stream cancellation", .timeLimit(.minutes(1)))
    func streamingAppendPropagatesCancellation() async throws {
        let writer = try await ArchiveWriter(format: .ustar, to: .memory)
        let gate = ConcGate()

        let prefix: [[UInt8]] = [
            Array("chunk-one-".utf8),
            Array("chunk-two-".utf8),
        ]
        var draft = EntryDraft(path: "stream.bin", fileType: .regular)
        // Declared size larger than the prefix so the entry stays mid-stream.
        draft.size = 1024
        let source = ConcCancellableChunks(prefix: prefix, gate: gate)

        let task = Task {
            try await writer.append(header: draft, streamingFrom: source)
        }

        // Wait until the prefix has been consumed (the sequence opens the gate once
        // it exhausts the prefix), then cancel at the next chunk boundary.
        await gate.wait()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        // The writer must still be finish()-able after the aborted streaming entry.
        let bytes = try await writer.finish()
        #expect(!bytes.isEmpty)
    }
}

// MARK: - conc-8 (revised): snapshot fidelity / no entry aliasing

@Suite("Concurrency snapshot fidelity")
struct ConcSnapshotFidelityTests {

    /// conc-8 (revised): the reader reuses one transient C entry across headers, so
    /// a snapshot that failed to deep-copy would make multiple entries alias the
    /// last one. Write several entries with DISTINCT metadata and payloads, read
    /// them back, and assert each recovered entry equals its own expectation AND
    /// that no two recovered entries are equal to each other.
    @Test("each recovered entry is a distinct, faithful snapshot (no aliasing)")
    func recoveredEntriesAreDistinctSnapshots() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let drafts: [EntryDraft] = (0..<6).map { id in
            EntryDraft(
                path: "snap-\(id).bin",
                bytes: concPayload(id: id, size: 32 + id),
                permissions: UInt16(0o600 + id),
                modificationDate: base.addingTimeInterval(Double(id) * 86_400),
                userID: Int64(500 + id),
                groupID: Int64(20 + id),
                userName: "user-\(id)",
                groupName: "group-\(id)"
            )
        }
        // pax preserves the rich metadata (ownership, names, mtime) this asserts on.
        let bytes = try await Archive.write(drafts, format: .pax)

        let recovered = try await Archive.read(from: .data(bytes))
        #expect(recovered.count == drafts.count)

        // Each recovered entry matches its own draft's distinguishing fields.
        for id in 0..<drafts.count {
            let item = try #require(recovered.first { $0.entry.path == "snap-\(id).bin" })
            #expect(item.bytes == concPayload(id: id, size: 32 + id))
            #expect(item.entry.permissions == UInt16(0o600 + id))
            #expect(item.entry.userID == Int64(500 + id))
            #expect(item.entry.groupID == Int64(20 + id))
            #expect(item.entry.userName == "user-\(id)")
            #expect(item.entry.groupName == "group-\(id)")
        }

        // No two recovered entries are equal: aliasing the reused C entry would
        // collapse them onto the last header's values.
        for i in recovered.indices {
            for j in recovered.indices where j > i {
                #expect(recovered[i] != recovered[j])
                #expect(recovered[i].entry != recovered[j].entry)
            }
        }
    }
}

// MARK: - conc-9: reader inert after close

@Suite("Concurrency closed reader contract")
struct ConcClosedReaderTests {

    /// conc-9: after close(), the reader is fully inert and non-throwing for the
    /// query/read accessors, except addPassphrase which throws a fatal setOption
    /// error with the exact stage .setOption("read-passphrase").
    @Test("a closed reader is inert: idempotent close, nil/empty accessors, unsupported encryption")
    func closedReaderIsInert() async throws {
        let bytes = try await Archive.write(
            [.file("a.txt", text: "alpha"), .file("b.txt", text: "bravo")],
            format: .ustar
        )
        let reader = try await ArchiveReader(reading: .data(bytes))
        await reader.close()
        // Second close is a no-op.
        await reader.close()

        #expect(try await reader.nextEntry() == nil)
        #expect(try await reader.readData() == [])
        #expect(try await reader.readAllData() == [])
        #expect(try await reader.readAll().isEmpty)
        // skipData returns without acting (no throw) on a closed reader.
        try await reader.skipData()
        #expect(await reader.hasEncryptedEntries() == .unsupported)

        await #expect {
            try await reader.addPassphrase("pw")
        } throws: { error in
            guard let archiveError = error as? ArchiveError else { return false }
            return archiveError.stage == .setOption("read-passphrase")
                && archiveError.status == .fatal
        }
    }
}

// MARK: - conc-10: interleaved skip and drain positioning

@Suite("Concurrency interleaved skip and drain")
struct ConcInterleavedSkipTests {

    /// conc-10: alternate skipping and draining across several distinct payloads,
    /// asserting the exact path sequence, that drained entries match their bytes,
    /// and that EOF returns nil. A positioning regression in skipData would desync
    /// the header walk and fail.
    @Test("interleaved skipData and readAllData keep the reader correctly positioned")
    func interleavedSkipAndDrainStaysPositioned() async throws {
        let count = 6
        let drafts = (0..<count).map { id in
            EntryDraft.file("walk-\(id).bin", bytes: concPayload(id: id, size: 100 + id * 7))
        }
        let bytes = try await Archive.write(drafts, format: .ustar)

        let reader = try await ArchiveReader(reading: .data(bytes))

        var seenPaths: [String] = []
        var index = 0
        while let entry = try await reader.nextEntry() {
            seenPaths.append(entry.path)
            if index.isMultiple(of: 2) {
                // Even index: skip this entry's data.
                try await reader.skipData()
            } else {
                // Odd index: drain and verify bytes.
                let data = try await reader.readAllData()
                #expect(data == concPayload(id: index, size: 100 + index * 7))
            }
            index += 1
        }

        // The loop already exited on the terminating nil, so EOF is proven. Do not
        // call nextEntry() again: a second pull past EOF re-enters
        // archive_read_next_header in libarchive's "eof" state and aborts with a
        // fatal internal error on this build.
        await reader.close()

        #expect(seenPaths == (0..<count).map { "walk-\($0).bin" })
        #expect(seenPaths.count == count)
    }
}
