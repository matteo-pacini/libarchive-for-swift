import Dispatch

/// A serial executor backed by a private `DispatchQueue`, used to run
/// libarchive's blocking calls off the Swift cooperative thread pool.
///
/// libarchive calls block their thread for the full duration of header parsing
/// plus inline (de)compression. Running them on a cooperative-pool thread would
/// violate the pool's forward-progress contract and can starve unrelated async
/// work. Backing the reader / writer actors with this executor keeps the
/// blocking work on a dedicated GCD thread, so awaiting callers merely suspend
/// and no caller-facing actor (including the MainActor) is ever blocked. This is
/// the sanctioned custom-executor use case for specific thread requirements / C
/// interop.
///
/// Internal; callers only ever see ``ArchiveReader`` and ``ArchiveWriter``.
final class ArchiveExecutor: SerialExecutor {

    /// The private serial queue that runs every job for the owning actor.
    ///
    /// A dedicated GCD queue grows its own threads on demand, so a blocking
    /// libarchive call parks one of *those* threads rather than a scarce
    /// cooperative-pool thread.
    private let queue: DispatchQueue

    init(label: String) {
        self.queue = DispatchQueue(label: label)
    }

    /// Schedules one job on the private serial queue.
    ///
    /// The job runs synchronously on the queue's thread; because the queue is
    /// serial, the owning actor's isolation is preserved (exactly one job, hence
    /// one access to the non-thread-safe handle, runs at a time).
    ///
    /// This uses the `UnownedJob` form of `enqueue` rather than the newer
    /// `consuming ExecutorJob` form: `ExecutorJob` / `UnownedJob.init(ExecutorJob)`
    /// are only available on macOS 14 / iOS 17, which is above this package's
    /// deployment targets (macOS 12, iOS 15, watchOS 9, tvOS 15). The `UnownedJob`
    /// requirement has existed since the executor protocols shipped, so it
    /// compiles for every supported platform version.
    ///
    /// - Parameter job: The executor job to run synchronously on the queue thread.
    func enqueue(_ job: UnownedJob) {
        let executor = asUnownedSerialExecutor()
        queue.async {
            job.runSynchronously(on: executor)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
