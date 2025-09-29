import Foundation

/// FIFO event queue with capacity and batch draining semantics
/// Thread-safe via Swift actor
public actor EventQueue<Event: Sendable> {

    public enum OverflowBehavior {
        case dropOldest
        case dropNewest
    }

    private var buffer: [Event] = []
    private let capacity: Int
    private let overflowBehavior: OverflowBehavior

    public init(capacity: Int = 2000, overflowBehavior: OverflowBehavior = .dropOldest) {
        self.capacity = max(1, capacity)
        self.overflowBehavior = overflowBehavior
    }

    public var count: Int { buffer.count }

    /// Enqueue an event; enforces capacity using configured overflow behavior
    public func enqueue(_ event: Event) {
        if buffer.count >= capacity {
            switch overflowBehavior {
            case .dropOldest:
                if !buffer.isEmpty { _ = buffer.removeFirst() }
                Logger.warn("Queue cap \(capacity) reached — dropped oldest event")
            case .dropNewest:
                Logger.warn("Queue cap \(capacity) reached — dropped newest event")
                return
            }
        }
        buffer.append(event)
    }

    /// Enqueue many events, applying capacity policy per element
    public func enqueue(contentsOf events: [Event]) async {
        for e in events { await enqueue(e) }
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
            switch overflowBehavior {
            case .dropOldest:
                _ = buffer.removeLast() // keep requeued items; drop the tail
            case .dropNewest:
                _ = buffer.removeFirst()
            }
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


