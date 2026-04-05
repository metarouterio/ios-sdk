import Foundation

/// FIFO event queue with capacity and batch draining semantics
/// Thread-safe via Swift actor
public actor EventQueue<Event: Sendable> {

    private var buffer: [Event] = []
    private let capacity: Int

    public init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { buffer.count }

    /// Enqueue an event; enforces capacity using configured overflow behavior
    /// Enqueue an event; enforces capacity using configured overflow behavior.
    /// Returns the queue count after insertion (atomic with the enqueue).
    @discardableResult
    public func enqueue(_ event: Event) -> Int {
        if buffer.count >= capacity {
            if !buffer.isEmpty { _ = buffer.removeFirst() }
            Logger.warn("Queue cap \(capacity) reached — dropped oldest event")
        }
        buffer.append(event)
        return buffer.count
    }

    /// Drain up to max elements from the front (FIFO). Returns drained events.
    public func drain(max count: Int) -> [Event] {
        let n = min(max(0, count), buffer.count)
        guard n > 0 else { return [] }
        let drained = Array(buffer.prefix(n))
        buffer.removeFirst(n)
        return drained
    }

    /// Requeue events at the front (used after retryable failures)
    public func requeueToFront(_ events: [Event]) {
        guard !events.isEmpty else { return }
        buffer.insert(contentsOf: events, at: 0)
        // Apply capacity if we exceeded due to requeue
        while buffer.count > capacity {
            _ = buffer.removeLast() // keep requeued items; drop the tail
        }
    }

    /// Drop current front batch without requeueing
    public func dropFront(_ count: Int) {
        let n = min(max(0, count), buffer.count)
        guard n > 0 else { return }
        buffer.removeFirst(n)
    }

    /// Clear queue
    public func clear() {
        buffer.removeAll(keepingCapacity: false)
    }
}


