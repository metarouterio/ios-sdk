import Foundation

/// FIFO async mutex. Used by `PersistentEventQueue` to serialize disk writes
/// between `flushMemoryToDisk` and the dispatcher's `drainDiskStoreToNetwork`.
///
/// Swift actors provide method-level isolation but release the queue across
/// `await` points, so a drain that suspends for network I/O can be interleaved
/// with an enqueue-triggered flush. This mutex closes that window.
final class AsyncMutex: @unchecked Sendable {
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
