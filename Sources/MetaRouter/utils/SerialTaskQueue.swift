import Foundation

/// Runs async jobs one at a time, in the order they were submitted.
///
/// Swift does not order separately created `Task`s. When every public call started
/// its own, `identify("u1"); track("Purchase")` could enrich the track first and ship
/// it without the userId — identity and timestamp are read when the job runs, not at
/// the call. Submission here is synchronous, so the host's call order is the order
/// the jobs run in.
internal final class SerialTaskQueue: Sendable {
    typealias Job = @Sendable () async -> Void

    private let continuation: AsyncStream<Job>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self)
        self.continuation = continuation
        // Holds the stream, never the owner: the worker ends when `deinit` finishes
        // the stream, after running whatever was already submitted.
        Task {
            for await job in stream {
                await job()
            }
        }
    }

    func enqueue(_ job: @escaping Job) {
        continuation.yield(job)
    }

    deinit {
        continuation.finish()
    }
}
