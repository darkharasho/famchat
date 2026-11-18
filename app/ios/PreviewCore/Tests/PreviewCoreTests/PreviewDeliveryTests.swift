import Foundation
import XCTest
@testable import PreviewCore

/// Collects deliveries from any thread.
private final class Deliveries {
    private let lock = NSLock()
    private var items: [String?] = []

    func append(_ body: String?) {
        lock.lock()
        items.append(body)
        lock.unlock()
    }

    var all: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

final class PreviewDeliveryTests: XCTestCase {
    func testFinishDeliversOnce() {
        let got = Deliveries()
        let delivery = PreviewDelivery(deliver: got.append)
        delivery.finish("a")
        delivery.finish("b")
        XCTAssertEqual(got.all, ["a"])
    }

    func testFinishAfterExpireIsIgnored() {
        let got = Deliveries()
        let delivery = PreviewDelivery(deliver: got.append)
        delivery.expire()
        delivery.finish("a")
        XCTAssertEqual(got.all, [nil])
    }

    func testConcurrentFinishDeliversOnce() {
        let got = Deliveries()
        let delivery = PreviewDelivery(deliver: got.append)
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            if i % 2 == 0 {
                delivery.finish("body \(i)")
            } else {
                delivery.expire()
            }
        }
        XCTAssertEqual(got.all.count, 1)
    }
}
