import XCTest
@testable import MetaRouter

final class EventQueueTests: XCTestCase {

    func testEnqueueAndDrainFIFO() async {
        let q = EventQueue<Int>(capacity: 10)
        await q.enqueue(1)
        await q.enqueue(2)
        await q.enqueue(3)

        let a = await q.drain(max: 2)
        XCTAssertEqual(a, [1, 2])

        let b = await q.drain(max: 2)
        XCTAssertEqual(b, [3])
    }

    func testCapacityDropOldest() async {
        let q = EventQueue<Int>(capacity: 2, overflowBehavior: .dropOldest)
        await q.enqueue(1)
        await q.enqueue(2)
        await q.enqueue(3) // drops 1

        let a = await q.drain(max: 2)
        XCTAssertEqual(a, [2, 3])
    }

    func testRequeueToFront() async {
        let q = EventQueue<Int>(capacity: 10)
        await q.enqueue(3)
        await q.enqueue(4)
        await q.requeueToFront([1, 2])

        let a = await q.drain(max: 10)
        XCTAssertEqual(a, [1, 2, 3, 4])
    }

    func testDropFrontAndClear() async {
        let q = EventQueue<Int>(capacity: 10)
        await q.enqueue(1)
        await q.enqueue(2)
        await q.enqueue(3)
        await q.dropFront(2)
        var a = await q.drain(max: 10)
        XCTAssertEqual(a, [3])

        await q.enqueue(4)
        await q.enqueue(5)
        await q.clear()
        a = await q.drain(max: 10)
        XCTAssertEqual(a, [])
    }
}





