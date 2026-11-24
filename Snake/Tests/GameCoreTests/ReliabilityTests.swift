import XCTest

@testable import Snakes

final class ReliabilityTests: XCTestCase {
  func testLostResponseAndDuplicateRequest() {
    var replies = ReplyWindow()
    var sends = RetryQueue()
    let now = ContinuousClock.now
    let join = Data([1])
    let response = Data([2])
    XCTAssertTrue(sends.record(7, bytes: join, kind: .control, at: now))
    replies.commit(7, response: response)
    XCTAssertEqual(sends.due(at: now + .milliseconds(99)), [])
    XCTAssertEqual(sends.due(at: now + .milliseconds(100)), [join])
    XCTAssertEqual(replies.lookup(7), .cached(response))
    sends.acknowledge(7)
    XCTAssertEqual(sends.due(at: now + .seconds(1)), [])
    replies.commit(1031, response: response)
    XCTAssertEqual(replies.lookup(7), .expired)
  }
  func testOutOfOrderState() {
    var order = SnapshotOrder()
    XCTAssertTrue(order.accept(3))
    XCTAssertFalse(order.accept(2))
    XCTAssertFalse(order.accept(3))
    XCTAssertTrue(order.accept(4))
  }
  func testCatalogueEntriesExpireSeparately() {
    var directory = GameDirectory<Int>()
    let a = GameDirectory<Int>.Key(game: "A", master: Endpoint(address: "127.0.0.1", port: 10001))
    let b = GameDirectory<Int>.Key(game: "A", master: Endpoint(address: "127.0.0.1", port: 10002))
    let now = ContinuousClock.now
    directory.observe(1, key: a, at: now)
    directory.observe(2, key: b, at: now + .seconds(1))
    XCTAssertEqual(directory.active(at: now + .seconds(3)), [b: 2])
  }
}
