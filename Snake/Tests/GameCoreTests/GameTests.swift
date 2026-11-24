import XCTest

@testable import Snakes

final class GameTests: XCTestCase {
  func board() throws -> Game {
    var game = try Game(name: "test", width: 10, height: 10, reserve: 0, interval: 100)
    try game.join(name: "A", playing: true)
    return game
  }
  func testWrapAndReverse() throws {
    var g = try board()
    g.players[1]?.body = [Cell(0, 0), Cell(1, 0)]
    g.players[1]?.heading = .left
    g.steer(.right, id: 1, sequence: 1)
    g.tick()
    XCTAssertEqual(g.players[1]?.body.first, Cell(9, 0))
  }
  func testFreedTail() throws {
    var g = try board()
    g.food = []
    g.players[1]?.body = [Cell(0, 0), Cell(1, 0), Cell(1, 1), Cell(0, 1)]
    g.players[1]?.heading = .down
    g.tick()
    XCTAssertEqual(g.players[1]?.body.count, 4)
  }
  func testHeadsOnFoodAndReturn() throws {
    var g = try board()
    try g.join(name: "B", playing: false)
    g.players[1]?.body = [Cell(1, 2), Cell(0, 2)]
    g.players[2]?.body = [Cell(3, 2), Cell(4, 2)]
    g.players[1]?.heading = .right
    g.players[2]?.heading = .left
    g.food = [Cell(2, 2)]
    g.tick()
    for id in [1, 2] {
      XCTAssertEqual(g.players[id]?.score, 2)
      XCTAssertEqual(g.players[id]?.body, [])
    }
    try g.setPlaying(true, id: 2)
    g.leave(1)
    XCTAssertEqual(g.players[2]?.score, 2)
    XCTAssertEqual(g.players[2]?.role, .master)
    XCTAssertEqual(g.players[2]?.body.count, 2)
  }
}
