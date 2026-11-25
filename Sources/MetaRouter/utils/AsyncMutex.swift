import Foundation

/// FIFO async mutex. Used by `PersistentEventQueue` to serialize disk writes
/// between `flushMemoryToDisk` and the dispatcher's `drainDiskStoreToNetwork`.
///
/// Swift actors provide method-level isolation but release the queue across
/// `await` points, so a drain that suspends for network I/O can be interleaved
/// with an enqueue-triggered flush. This mutex closes that window.
final class AsyncMutex: @unchecked Sendable {
    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var byFile: [URL: AsyncMutex] = [:]  // under registryLock

    /// One mutex per file for the process: every client's queue over the same disk
    /// file must serialize against the others, not just against itself.
    static func shared(for file: URL) -> AsyncMutex {
        let file = file.standardizedFileURL.resolvingSymlinksInPath()
        return registryLock.withLock {
            if let existing = byFile[file] { return existing }
            let mutex = AsyncMutex()
            byFile[file] = mutex
            return mutex
        }
    }

    private let queue = DispatchQueue(label: "metarouter.asyncmutex.state")
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if !self.locked {
                    self.locked = true
                    cont.resume()
                } else {
                    self.waiters.append(cont)
                }
            }
        }
    }

    func unlock() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if let next = self.waiters.first {
                    self.waiters.removeFirst()
                    // Ownership transfers to the resumed waiter; `locked` stays true.
                    next.resume()
                } else {
                    self.locked = false
                }
                cont.resume()
            }
        }
    }
}
